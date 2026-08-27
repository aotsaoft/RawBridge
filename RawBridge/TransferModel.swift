import Foundation
import Combine

enum MediaCategory: String, Codable, Sendable {
    case raw = "RAW"
    case photo = "PHOTO"
    case video = "VIDEO"
    case other = "OTHER"
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
    struct MediaRef: Identifiable {
        let id = UUID()
        let url: URL
        let fileName: String
        let relativePath: String
        let size: Int64
        let ext: String
        let category: MediaCategory
        let cleanupAfterUpload: Bool
    }

    static let rawExtensionSet: Set<String> = [
        "arw","cr2","cr3","nef","raf","orf","rw2","dng","pef","srw",
        "3fr","erf","kdc","mos","mrw","nrw","raw","rwl","x3f"
    ]

    static let photoExtensionSet: Set<String> = [
        "jpg","jpeg","heic","heif","png","tif","tiff","webp"
    ]

    static let videoExtensionSet: Set<String> = [
        "mp4","mov","m4v","mts","m2ts","avi","mkv","3gp"
    ]

    @Published var eventName = ""
    @Published var roughContent = ""
    @Published var serverURL = "http://100.120.33.35:8000"
    @Published var importSource: ImportSource = .files

    @Published var selectedFolderName = "Chưa chọn"
    @Published var items: [MediaRef] = []
    @Published var selectedExtensions: Set<String> = []

    @Published var scanning = false
    @Published var preparing = false
    @Published var status = "Nhập thông tin sự kiện rồi chọn nguồn dữ liệu."

    private var scopedFolderURL: URL?
    private let uploader = RawBackgroundUploadManager.shared

    init() {
        uploader.resumeFromDisk()
    }

    deinit {
        scopedFolderURL?.stopAccessingSecurityScopedResource()
    }

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

    var selectedItems: [MediaRef] {
        items.filter { selectedExtensions.contains($0.ext) }
    }

    var selectedCount: Int { selectedItems.count }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

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

    func scanFilesFolder(_ url: URL) {
        scopedFolderURL?.stopAccessingSecurityScopedResource()
        scopedFolderURL = nil

        guard url.startAccessingSecurityScopedResource() else {
            status = "iOS không cấp quyền truy cập thư mục này."
            return
        }

        scopedFolderURL = url
        scanning = true
        items = []
        selectedExtensions = []
        selectedFolderName = url.lastPathComponent
        status = "Đang quét thư mục..."

        let baseURL = url

        Task {
            let result: [MediaRef] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]

                guard let enumerator = fm.enumerator(
                    at: baseURL,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                ) else {
                    return []
                }

                var found: [MediaRef] = []
                let basePath = baseURL.path.hasSuffix("/")
                    ? baseURL.path
                    : baseURL.path + "/"

                for case let fileURL as URL in enumerator {
                    let values = try? fileURL.resourceValues(forKeys: keys)
                    guard values?.isRegularFile == true else { continue }

                    let ext = fileURL.pathExtension.lowercased()
                    guard !ext.isEmpty else { continue }

                    let category = Self.category(for: ext)

                    let relative = fileURL.path.hasPrefix(basePath)
                        ? String(fileURL.path.dropFirst(basePath.count))
                        : fileURL.lastPathComponent

                    found.append(
                        MediaRef(
                            url: fileURL,
                            fileName: fileURL.lastPathComponent,
                            relativePath: relative,
                            size: Int64(values?.fileSize ?? 0),
                            ext: ext,
                            category: category,
                            cleanupAfterUpload: false
                        )
                    )
                }

                return found.sorted {
                    $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                }
            }.value

            self.items = result
            self.scanning = false
            self.status = "Quét xong \(result.count) file. Hãy tích đuôi cần gửi."
        }
    }

    func importCameraRoll(assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }

        scanning = true
        items = []
        selectedExtensions = []
        selectedFolderName = "Camera Roll"
        status = "Đang lấy file gốc từ Camera Roll..."

        Task {
            do {
                let result = try await PhotoLibraryScanner.shared.importAssets(assetIDs: assetIDs)
                self.items = result
                self.scanning = false
                self.status = "Đã lấy \(result.count) file gốc từ Camera Roll. Hãy tích đuôi cần gửi."
            } catch {
                self.scanning = false
                self.status = "Không đọc được Camera Roll: \(error.localizedDescription)"
            }
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

        preparing = true
        status = "Đang chuẩn bị file cho upload nền..."

        do {
            let preparedFiles: [MediaRef]

            if importSource == .files {
                preparedFiles = try await stageExternalFiles(files, eventName: cleanEvent)
            } else {
                // Camera Roll imports are already exported into app sandbox.
                preparedFiles = files
            }

            try await uploader.enqueueAndStart(
                serverBase: serverURL,
                eventName: cleanEvent,
                roughContent: roughContent,
                selectedExtensions: Array(selectedExtensions).sorted(),
                files: preparedFiles
            )

            status = "Queue upload nền đã sẵn sàng."
        } catch {
            status = "Không tạo được queue upload: \(error.localizedDescription)"
        }

        preparing = false
    }

    private func stageExternalFiles(
        _ files: [MediaRef],
        eventName: String
    ) async throws -> [MediaRef] {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let stagingRoot = support
            .appendingPathComponent("RawBridge/UploadStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }

        if let values = try? support.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage {
            let required = totalBytes + 300_000_000
            if available < required {
                throw NSError(
                    domain: "RawBridge",
                    code: 10,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "iPhone không đủ dung lượng trống để chuẩn bị upload nền. Cần khoảng \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))."
                    ]
                )
            }
        }

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var staged: [MediaRef] = []

            for (index, item) in files.enumerated() {
                let safeName = "\(index)_\(UUID().uuidString)_\(item.fileName)"
                let target = stagingRoot.appendingPathComponent(safeName)

                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }

                try fm.copyItem(at: item.url, to: target)

                staged.append(
                    MediaRef(
                        url: target,
                        fileName: item.fileName,
                        relativePath: item.relativePath,
                        size: item.size,
                        ext: item.ext,
                        category: item.category,
                        cleanupAfterUpload: true
                    )
                )
            }

            return staged
        }.value
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

    nonisolated static func category(for ext: String) -> MediaCategory {
        if rawExtensionSet.contains(ext) { return .raw }
        if photoExtensionSet.contains(ext) { return .photo }
        if videoExtensionSet.contains(ext) { return .video }
        return .other
    }
}
