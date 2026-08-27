import Foundation

enum MediaCategory: String {
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
    struct MediaRef: Identifiable, Codable {
        let id = UUID()
        let url: URL
        let relativePath: String
        let size: Int64
        let ext: String
        let category: MediaCategory
    }

    static let rawExtensionSet: Set<String> = [
        "arw","cr2","cr3","nef","raf","orf","rw2","dng","pef","srw","3fr","erf","kdc","mos","mrw","nrw","raw","rwl","x3f"
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
    @Published var uploading = false
    @Published var currentFile = ""
    @Published var status = "Nhập thông tin sự kiện rồi chọn nguồn dữ liệu."
    @Published var overallProgress: Double = 0
    @Published var averageSpeedMBs: Double = 0
    @Published var etaText = "--"

    private let uploader = RawBackgroundUploadManager.shared

    init() {
        uploader.resumeFromDisk()
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
    var selectedSizeText: String { ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file) }
    var totalSizeText: String { ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.size }, countStyle: .file) }

    func isSelected(_ ext: String) -> Bool { selectedExtensions.contains(ext) }
    func setSelected(_ ext: String, _ selected: Bool) {
        if selected { selectedExtensions.insert(ext) } else { selectedExtensions.remove(ext) }
    }

    func testConnection() async {
        guard let url = endpoint("/health") else {
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

    func scanFilesFolder(_ url: URL) {
        scanning = true
        items = []
        selectedExtensions = []
        selectedFolderName = url.lastPathComponent
        status = "Đang quét thư mục..."

        let baseURL = url

        Task {
            let result: [MediaRef] = await Task.detached(priority: .userInitiated) {
                guard baseURL.startAccessingSecurityScopedResource() else { return [] }
                defer { baseURL.stopAccessingSecurityScopedResource() }

                let fm = FileManager.default
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
                guard let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
                    return []
                }

                var found: [MediaRef] = []
                let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"

                for case let fileURL as URL in enumerator {
                    let values = try? fileURL.resourceValues(forKeys: keys)
                    guard values?.isRegularFile == true else { continue }
                    let ext = fileURL.pathExtension.lowercased()
                    guard !ext.isEmpty else { continue }

                    let category: MediaCategory
                    if TransferModel.rawExtensionSet.contains(ext) {
                        category = .raw
                    } else if TransferModel.photoExtensionSet.contains(ext) {
                        category = .photo
                    } else if TransferModel.videoExtensionSet.contains(ext) {
                        category = .video
                    } else {
                        category = .other
                    }

                    let relative = fileURL.path.hasPrefix(basePath)
                        ? String(fileURL.path.dropFirst(basePath.count))
                        : fileURL.lastPathComponent

                    found.append(MediaRef(
                        url: fileURL,
                        relativePath: relative,
                        size: Int64(values?.fileSize ?? 0),
                        ext: ext,
                        category: category
                    ))
                }
                return found.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            }.value

            self.items = result
            self.scanning = false
            self.status = "Quét xong \(result.count) file. Hãy tích đuôi cần gửi."
        }
    }

    func scanCameraRoll() {
        scanning = true
        items = []
        selectedExtensions = []
        selectedFolderName = "Camera Roll"
        status = "Đang quét và export tài nguyên gốc từ Ảnh..."

        Task {
            do {
                let result = try await PhotoLibraryScanner.shared.scanRecentAssets()
                self.items = result
                self.scanning = false
                self.status = "Đã quét Camera Roll: \(result.count) file. Hãy tích đuôi cần gửi."
            } catch {
                self.scanning = false
                self.status = "Không đọc được Ảnh/Camera Roll: \(error.localizedDescription)"
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

        uploading = true
        status = "Chuẩn bị queue upload nền..."

        do {
            try await uploader.enqueueAndStart(
                serverBase: serverURL,
                eventName: cleanEvent,
                roughContent: roughContent,
                selectedExtensions: Array(selectedExtensions).sorted(),
                files: files
            )
            status = "Đã tạo queue upload nền. Có thể thoát app; vào lại sẽ tiếp tục queue còn lại."
        } catch {
            status = "Không tạo được queue upload: \(error.localizedDescription)"
            uploading = false
        }
    }

    func syncFromUploader() {
        self.uploading = uploader.isUploading
        self.currentFile = uploader.currentFile
        self.status = uploader.statusText
        self.overallProgress = uploader.overallProgress
        if selectedBytes > 0 && overallProgress > 0 {
            let estSent = Double(selectedBytes) * overallProgress
            // rough display only
            self.averageSpeedMBs = 0
            self.etaText = ByteCountFormatter.string(fromByteCount: Int64(estSent), countStyle: .file)
        }
    }

    private func endpoint(_ suffix: String) -> URL? {
        guard var components = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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
}
