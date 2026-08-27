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

        // false = file từ thẻ/Files, cần copy vào app sandbox trước background upload.
        // true = Camera Roll đã export vào app sandbox.
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

    @Published var items: [MediaRef] = []
    @Published var selectedExtensions: Set<String> = []

    @Published var scanning = false
    @Published var preparing = false
    @Published var status = "Nhập thông tin sự kiện rồi thêm dữ liệu."

    @Published var connectionStatus = "Chưa kiểm tra kết nối."
    @Published var connectionOK: Bool? = nil
    @Published var isTestingConnection = false

    private var scopedFolderURLs: [URL] = []
    private let uploader = RawBackgroundUploadManager.shared

    init() {
        uploader.resumeFromDisk()
    }

    deinit {
        for url in scopedFolderURLs {
            url.stopAccessingSecurityScopedResource()
        }
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

    var filesSourceCount: Int {
        items.filter { !$0.cleanupAfterUpload }.count
    }

    var cameraRollCount: Int {
        items.filter { $0.cleanupAfterUpload }.count
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
        guard !isTestingConnection else { return }

        guard let url = endpoint("/health") else {
            connectionOK = false
            connectionStatus = "Địa chỉ server không hợp lệ."
            return
        }

        isTestingConnection = true
        connectionOK = nil
        connectionStatus = "Đang kiểm tra \(url.host ?? "server")..."

        defer {
            isTestingConnection = false
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 8

            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                connectionOK = false
                connectionStatus = "Không nhận được phản hồi HTTP từ PC."
                return
            }

            guard (200...299).contains(http.statusCode) else {
                connectionOK = false
                connectionStatus = "PC có phản hồi nhưng server trả HTTP \(http.statusCode)."
                return
            }

            var detail = ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let service = json["service"] as? String
                let version = json["version"] as? String

                if let service, let version {
                    detail = " • \(service) v\(version)"
                } else if let version {
                    detail = " • server v\(version)"
                }
            }

            connectionOK = true
            connectionStatus = "Kết nối thành công\(detail)"
        } catch {
            connectionOK = false

            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    connectionStatus = "Hết thời gian chờ. Kiểm tra Tailscale và server PC."
                case .cannotConnectToHost:
                    connectionStatus = "Không kết nối được cổng 8000 trên PC."
                case .notConnectedToInternet:
                    connectionStatus = "iPhone hiện không có kết nối mạng."
                default:
                    connectionStatus = "Lỗi kết nối: \(urlError.localizedDescription)"
                }
            } else {
                connectionStatus = "Lỗi kết nối: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Thẻ / Files: THÊM vào danh sách hiện tại, không xóa Camera Roll

    func addFilesFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            status = "iOS không cấp quyền truy cập thư mục này."
            return
        }

        scopedFolderURLs.append(url)
        scanning = true
        status = "Đang quét thẻ / Files..."

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

                    let relative = fileURL.path.hasPrefix(basePath)
                        ? String(fileURL.path.dropFirst(basePath.count))
                        : fileURL.lastPathComponent

                    found.append(
                        MediaRef(
                            url: fileURL,
                            fileName: fileURL.lastPathComponent,
                            relativePath: "Files/\(baseURL.lastPathComponent)/\(relative)",
                            size: Int64(values?.fileSize ?? 0),
                            ext: ext,
                            category: Self.category(for: ext),
                            cleanupAfterUpload: false
                        )
                    )
                }

                return found.sorted {
                    $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                }
            }.value

            self.appendUnique(result)
            self.scanning = false
            self.status =
                "Đã thêm \(result.count) file từ thẻ/Files. Tổng hiện có \(self.items.count) file."
        }
    }

    // MARK: - Camera Roll: THÊM vào danh sách hiện tại, không xóa thẻ/Files

    func addCameraRoll(assetIDs: [String]) {
        guard !assetIDs.isEmpty else { return }

        scanning = true
        status = "Đang lấy file gốc từ Camera Roll..."

        Task {
            do {
                let result = try await PhotoLibraryScanner.shared.importAssets(
                    assetIDs: assetIDs
                )

                self.appendUnique(result)
                self.scanning = false
                self.status =
                    "Đã thêm \(result.count) file từ Camera Roll. Tổng hiện có \(self.items.count) file."
            } catch {
                self.scanning = false
                self.status = "Không đọc được Camera Roll: \(error.localizedDescription)"
            }
        }
    }

    private func appendUnique(_ newItems: [MediaRef]) {
        // Tránh add trùng cùng một file trong cùng lần thao tác.
        var existing = Set(
            items.map {
                "\($0.relativePath.lowercased())|\($0.size)"
            }
        )

        for item in newItems {
            let key = "\(item.relativePath.lowercased())|\(item.size)"
            if existing.insert(key).inserted {
                items.append(item)
            } else if item.cleanupAfterUpload {
                // Camera Roll export ra file tạm nhưng bị trùng -> dọn file tạm.
                try? FileManager.default.removeItem(at: item.url)
            }
        }
    }

    func clearMediaSelection() {
        guard !uploader.isUploading else { return }

        for item in items where item.cleanupAfterUpload {
            try? FileManager.default.removeItem(at: item.url)
        }

        items = []
        selectedExtensions = []

        for url in scopedFolderURLs {
            url.stopAccessingSecurityScopedResource()
        }
        scopedFolderURLs = []

        status = "Đã xóa danh sách media. Có thể chọn lại từ thẻ và Camera Roll."
    }

    // MARK: - Upload mixed sources

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
        status = "Đang chuẩn bị \(files.count) file cho upload nền..."

        do {
            // Media từ Camera Roll đã ở app sandbox.
            // Media từ thẻ/Files được copy vào app sandbox.
            let preparedFiles = try await prepareMixedFiles(files)

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

    private func prepareMixedFiles(
        _ files: [MediaRef]
    ) async throws -> [MediaRef] {
        let externalFiles = files.filter { !$0.cleanupAfterUpload }
        let alreadyLocal = files.filter { $0.cleanupAfterUpload }

        guard !externalFiles.isEmpty else {
            return alreadyLocal
        }

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

        let externalBytes = externalFiles.reduce(Int64(0)) { $0 + $1.size }

        if let values = try? support.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage {

            let required = externalBytes + 300_000_000

            if available < required {
                throw NSError(
                    domain: "RawBridge",
                    code: 10,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "iPhone không đủ dung lượng trống để copy media từ thẻ cho upload nền. Cần khoảng \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))."
                    ]
                )
            }
        }

        let stagedExternal: [MediaRef] = try await Task.detached(
            priority: .userInitiated
        ) {
            let fm = FileManager.default
            var staged: [MediaRef] = []

            for (index, item) in externalFiles.enumerated() {
                let safeName =
                    "\(index)_\(UUID().uuidString)_\(item.fileName)"

                let target = stagingRoot.appendingPathComponent(safeName)

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

        // Giữ đúng thứ tự tương đối không quan trọng; PC vẫn phân loại theo đường dẫn/đuôi.
        return stagedExternal + alreadyLocal
    }

    // MARK: - Phiên mới

    func newTransferSession() {
        guard !uploader.isUploading else { return }

        uploader.resetForNewSession()

        for item in items where item.cleanupAfterUpload {
            try? FileManager.default.removeItem(at: item.url)
        }

        for url in scopedFolderURLs {
            url.stopAccessingSecurityScopedResource()
        }
        scopedFolderURLs = []

        eventName = ""
        roughContent = ""
        items = []
        selectedExtensions = []
        scanning = false
        preparing = false
        status = "Phiên mới. Nhập tên sự kiện và thêm media."
        // Giữ nguyên serverURL và trạng thái kết nối để thao tác nhanh.
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
