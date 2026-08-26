import Foundation
import Combine

enum MediaCategory: String {
    case raw = "RAW"
    case photo = "PHOTO"
    case video = "VIDEO"
    case other = "OTHER"
}

struct MediaItem: Identifiable {
    let id = UUID()
    let url: URL
    let relativePath: String
    let size: Int64
    let ext: String
    let category: MediaCategory
}

struct ExtensionStat: Identifiable {
    var id: String { ext }
    let ext: String
    let count: Int
    let bytes: Int64
    let category: MediaCategory

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
final class TransferModel: ObservableObject {
    @Published var eventName = ""
    @Published var roughContent = ""
    @Published var serverURL = "http://100.120.33.35:8000"

    @Published var selectedFolderName = "Chưa chọn"
    @Published var items: [MediaItem] = []
    @Published var selectedExtensions: Set<String> = []

    @Published var scanning = false
    @Published var uploading = false
    @Published var currentFile = ""
    @Published var status = "Nhập thông tin sự kiện rồi chọn thư mục trên thẻ nhớ."
    @Published var overallProgress: Double = 0
    @Published var currentSpeedMBs: Double = 0
    @Published var averageSpeedMBs: Double = 0
    @Published var etaText = "--"

    private let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2",
        "dng", "pef", "srw", "3fr", "erf", "kdc", "mos",
        "mrw", "nrw", "raw", "rwl", "x3f"
    ]

    private let photoExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp"
    ]

    private let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mts", "m2ts", "avi", "mkv", "3gp"
    ]

    private var scopedFolderURL: URL?
    private var stopRequested = false
    private let uploader = RawFileUploader()

    var extensionStats: [ExtensionStat] {
        let grouped = Dictionary(grouping: items, by: { $0.ext })
        return grouped.map { ext, files in
            ExtensionStat(
                ext: ext,
                count: files.count,
                bytes: files.reduce(0) { $0 + $1.size },
                category: files.first?.category ?? .other
            )
        }
        .sorted {
            let rankA = categoryRank($0.category)
            let rankB = categoryRank($1.category)
            if rankA != rankB { return rankA < rankB }
            return $0.ext.localizedStandardCompare($1.ext) == .orderedAscending
        }
    }

    var selectedItems: [MediaItem] {
        items.filter { selectedExtensions.contains($0.ext) }
    }

    var selectedCount: Int {
        selectedItems.count
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    var selectedSizeText: String {
        ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
    }

    var totalSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: items.reduce(0) { $0 + $1.size },
            countStyle: .file
        )
    }

    func isSelected(_ ext: String) -> Bool {
        selectedExtensions.contains(ext)
    }

    func setSelected(_ ext: String, _ selected: Bool) {
        if selected {
            selectedExtensions.insert(ext)
        } else {
            selectedExtensions.remove(ext)
        }
    }

    func selectAll() {
        selectedExtensions = Set(extensionStats.map { $0.ext })
    }

    func clearSelection() {
        selectedExtensions.removeAll()
    }

    func selectRawOnly() {
        selectedExtensions = Set(
            extensionStats
                .filter { $0.category == .raw }
                .map { $0.ext }
        )
    }

    func selectPhotoAndRaw() {
        selectedExtensions = Set(
            extensionStats
                .filter { $0.category == .raw || $0.category == .photo }
                .map { $0.ext }
        )
    }

    func selectVideoOnly() {
        selectedExtensions = Set(
            extensionStats
                .filter { $0.category == .video }
                .map { $0.ext }
        )
    }

    func selectFolder(_ url: URL) {
        if let old = scopedFolderURL {
            old.stopAccessingSecurityScopedResource()
        }

        guard url.startAccessingSecurityScopedResource() else {
            status = "iOS không cấp quyền truy cập thư mục này."
            return
        }

        scopedFolderURL = url
        selectedFolderName = url.lastPathComponent
        scanning = true
        items = []
        selectedExtensions = []
        status = "Đang quét toàn bộ file trong thư mục..."

        let rawExts = rawExtensions
        let photoExts = photoExtensions
        let videoExts = videoExtensions
        let baseURL = url

        Task {
            let result: [MediaItem] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]

                guard let enumerator = fm.enumerator(
                    at: baseURL,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                ) else {
                    return []
                }

                var found: [MediaItem] = []
                let basePath = baseURL.path.hasSuffix("/")
                    ? baseURL.path
                    : baseURL.path + "/"

                for case let fileURL as URL in enumerator {
                    let values = try? fileURL.resourceValues(forKeys: keys)
                    guard values?.isRegularFile == true else { continue }

                    let ext = fileURL.pathExtension.lowercased()
                    guard !ext.isEmpty else { continue }

                    let category: MediaCategory
                    if rawExts.contains(ext) {
                        category = .raw
                    } else if photoExts.contains(ext) {
                        category = .photo
                    } else if videoExts.contains(ext) {
                        category = .video
                    } else {
                        category = .other
                    }

                    let relative = fileURL.path.hasPrefix(basePath)
                        ? String(fileURL.path.dropFirst(basePath.count))
                        : fileURL.lastPathComponent

                    found.append(
                        MediaItem(
                            url: fileURL,
                            relativePath: relative,
                            size: Int64(values?.fileSize ?? 0),
                            ext: ext,
                            category: category
                        )
                    )
                }

                return found.sorted {
                    $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                }
            }.value

            items = result
            scanning = false

            let supportedCount = result.filter { $0.category != .other }.count
            status = "Quét xong \(result.count) file. Có \(supportedCount) file ảnh/video được nhận diện. Hãy tích đuôi cần gửi."
        }
    }

    func testConnection() async {
        guard let url = endpoint("/health") else {
            status = "Địa chỉ server không hợp lệ."
            return
        }

        status = "Đang kiểm tra kết nối..."

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                status = "Không kết nối được server."
                return
            }
            status = "Kết nối PC thành công qua Tailscale."
        } catch {
            status = "Lỗi kết nối: \(error.localizedDescription)"
        }
    }

    func startUpload() async {
        let cleanEvent = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEvent.isEmpty else {
            status = "Hãy nhập tên sự kiện."
            return
        }

        let files = selectedItems
        guard !files.isEmpty else {
            status = "Hãy tích ít nhất một đuôi file cần gửi."
            return
        }

        stopRequested = false
        uploading = true
        overallProgress = 0
        currentSpeedMBs = 0
        averageSpeedMBs = 0
        etaText = "--"

        let total = max(files.reduce(0) { $0 + $1.size }, 1)
        let selectedExts = Array(selectedExtensions).sorted()
        var completedBytes: Int64 = 0
        let globalStart = Date()

        do {
            try await sendEventMetadata(
                eventName: cleanEvent,
                roughContent: roughContent,
                selectedExtensions: selectedExts,
                expectedFileCount: files.count,
                expectedBytes: total
            )

            for (index, item) in files.enumerated() {
                if stopRequested { throw CancellationError() }

                currentFile = item.relativePath
                status = "Đang gửi \(index + 1)/\(files.count) • .\(item.ext.uppercased())"

                let fileStart = Date()
                let completedSnapshot = completedBytes

                try await uploader.upload(
                    fileURL: item.url,
                    fileSize: item.size,
                    eventName: cleanEvent,
                    relativePath: item.relativePath,
                    serverBase: serverURL
                ) { [weak self] sent, _ in
                    Task { @MainActor in
                        guard let self else { return }

                        let fileElapsed = max(Date().timeIntervalSince(fileStart), 0.001)
                        self.currentSpeedMBs =
                            Double(sent) / 1_048_576.0 / fileElapsed

                        let estimatedFileSent = min(sent, item.size)
                        let allSent = completedSnapshot + estimatedFileSent
                        self.overallProgress =
                            min(Double(allSent) / Double(total), 1.0)

                        let globalElapsed =
                            max(Date().timeIntervalSince(globalStart), 0.001)
                        self.averageSpeedMBs =
                            Double(allSent) / 1_048_576.0 / globalElapsed

                        let remaining = Double(max(total - allSent, 0))
                        let bytesPerSecond =
                            self.averageSpeedMBs * 1_048_576.0

                        if bytesPerSecond > 0 {
                            self.etaText =
                                Self.formatDuration(remaining / bytesPerSecond)
                        }
                    }
                }

                completedBytes += item.size
                overallProgress =
                    min(Double(completedBytes) / Double(total), 1.0)
            }

            try await markEventComplete(
                eventName: cleanEvent,
                selectedExtensions: selectedExts,
                fileCount: files.count,
                totalBytes: total
            )

            status = "HOÀN TẤT — đã gửi \(files.count) file. PC đã nhận dấu UPLOAD_COMPLETE."
            currentFile = ""
            etaText = "0s"
        } catch is CancellationError {
            status = "Đã dừng upload."
        } catch {
            status = "Upload lỗi: \(error.localizedDescription)"
        }

        uploading = false
    }

    func stopUpload() {
        stopRequested = true
        uploader.cancel()
        status = "Đang dừng..."
    }

    private func sendEventMetadata(
        eventName: String,
        roughContent: String,
        selectedExtensions: [String],
        expectedFileCount: Int,
        expectedBytes: Int64
    ) async throws {
        guard let url = endpoint("/event-meta") else {
            throw UploadError.invalidServerURL
        }

        let body: [String: Any] = [
            "event_name": eventName,
            "rough_content": roughContent,
            "selected_extensions": selectedExtensions,
            "expected_file_count": expectedFileCount,
            "expected_bytes": expectedBytes
        ]

        try await postJSON(url: url, body: body)
    }

    private func markEventComplete(
        eventName: String,
        selectedExtensions: [String],
        fileCount: Int,
        totalBytes: Int64
    ) async throws {
        guard let url = endpoint("/complete-event") else {
            throw UploadError.invalidServerURL
        }

        let body: [String: Any] = [
            "event_name": eventName,
            "selected_extensions": selectedExtensions,
            "file_count": fileCount,
            "total_bytes": totalBytes
        ]

        try await postJSON(url: url, body: body)
    }

    private func postJSON(url: URL, body: [String: Any]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.unexpectedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw UploadError.serverError(http.statusCode)
        }
    }

    private func endpoint(_ suffix: String) -> URL? {
        guard var components = URLComponents(
            string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            return nil
        }

        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + suffix
        return components.url
    }

    private func categoryRank(_ category: MediaCategory) -> Int {
        switch category {
        case .raw: return 0
        case .photo: return 1
        case .video: return 2
        case .other: return 3
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let value = Int(seconds.rounded())
        let h = value / 3600
        let m = (value % 3600) / 60
        let s = value % 60

        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
