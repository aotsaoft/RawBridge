import Foundation
import Combine

enum MediaKind: String {
    case raw = "RAW"
    case video = "VIDEO"
}

struct MediaItem: Identifiable {
    let id = UUID()
    let url: URL
    let relativePath: String
    let size: Int64
    let kind: MediaKind
}

@MainActor
final class TransferModel: ObservableObject {
    @Published var eventName = ""
    @Published var serverURL = "http://100.120.33.35:8000"
    @Published var selectedFolderName = "Chưa chọn"
    @Published var items: [MediaItem] = []
    @Published var scanning = false
    @Published var uploading = false
    @Published var currentFile = ""
    @Published var status = "Chọn thư mục trên thẻ nhớ để bắt đầu."
    @Published var overallProgress: Double = 0
    @Published var currentSpeedMBs: Double = 0
    @Published var averageSpeedMBs: Double = 0
    @Published var etaText = "--"

    private let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "dng", "pef", "srw"
    ]
    private let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mts", "m2ts", "avi", "mkv"
    ]

    private var scopedFolderURL: URL?
    private var stopRequested = false
    private let uploader = RawFileUploader()

    var rawCount: Int {
        items.filter { $0.kind == .raw }.count
    }

    var videoCount: Int {
        items.filter { $0.kind == .video }.count
    }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
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
        status = "Đang quét RAW và video..."

        let rawExts = rawExtensions
        let videoExts = videoExtensions
        let baseURL = url

        Task {
            let result: [MediaItem] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                guard let enumerator = fm.enumerator(
                    at: baseURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else {
                    return []
                }

                var found: [MediaItem] = []

                for case let fileURL as URL in enumerator {
                    let ext = fileURL.pathExtension.lowercased()
                    let kind: MediaKind?

                    if rawExts.contains(ext) {
                        kind = .raw
                    } else if videoExts.contains(ext) {
                        kind = .video
                    } else {
                        kind = nil
                    }

                    guard let kind else { continue }

                    let values = try? fileURL.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }

                    let size = Int64(values?.fileSize ?? 0)
                    let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
                    let relative = fileURL.path.hasPrefix(basePath)
                        ? String(fileURL.path.dropFirst(basePath.count))
                        : fileURL.lastPathComponent

                    found.append(
                        MediaItem(
                            url: fileURL,
                            relativePath: relative,
                            size: size,
                            kind: kind
                        )
                    )
                }

                return found.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            }.value

            items = result
            scanning = false
            status = "Đã tìm thấy \(rawCount) RAW + \(videoCount) video."
        }
    }

    func testConnection() async {
        guard var components = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            status = "Địa chỉ server không hợp lệ."
            return
        }

        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/health"

        guard let url = components.url else {
            status = "Địa chỉ server không hợp lệ."
            return
        }

        status = "Đang kiểm tra kết nối..."

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                status = "Không kết nối được server."
                return
            }
            status = "Kết nối PC thành công qua Tailscale."
        } catch {
            status = "Lỗi kết nối: \(error.localizedDescription)"
        }
    }

    func startUpload() async {
        guard !items.isEmpty else {
            status = "Chưa có RAW/video để gửi."
            return
        }

        let cleanEvent = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEvent.isEmpty else {
            status = "Hãy nhập tên sự kiện."
            return
        }

        stopRequested = false
        uploading = true
        overallProgress = 0
        currentSpeedMBs = 0
        averageSpeedMBs = 0
        etaText = "--"

        let total = max(totalBytes, 1)
        var completedBytes: Int64 = 0
        let globalStart = Date()

        do {
            for (index, item) in items.enumerated() {
                if stopRequested { throw CancellationError() }

                currentFile = item.relativePath
                status = "Đang gửi \(index + 1)/\(items.count)"

                let fileStart = Date()

                try await uploader.upload(
                    fileURL: item.url,
                    fileSize: item.size,
                    eventName: cleanEvent,
                    relativePath: item.relativePath,
                    serverBase: serverURL
                ) { [weak self] sent, expected in
                    Task { @MainActor in
                        guard let self else { return }

                        let fileElapsed = max(Date().timeIntervalSince(fileStart), 0.001)
                        self.currentSpeedMBs = Double(sent) / 1_048_576.0 / fileElapsed

                        let estimatedFileSent = min(sent, item.size)
                        let allSent = completedBytes + estimatedFileSent
                        self.overallProgress = min(Double(allSent) / Double(total), 1.0)

                        let globalElapsed = max(Date().timeIntervalSince(globalStart), 0.001)
                        self.averageSpeedMBs = Double(allSent) / 1_048_576.0 / globalElapsed

                        let remaining = Double(max(total - allSent, 0))
                        let bytesPerSecond = self.averageSpeedMBs * 1_048_576.0
                        if bytesPerSecond > 0 {
                            self.etaText = Self.formatDuration(remaining / bytesPerSecond)
                        }
                    }
                }

                completedBytes += item.size
                overallProgress = min(Double(completedBytes) / Double(total), 1.0)
            }

            status = "HOÀN TẤT — đã gửi \(items.count) file về PC."
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
