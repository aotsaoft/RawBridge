import Foundation

final class RawBackgroundUploadManager: NSObject, ObservableObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = RawBackgroundUploadManager()

    @Published var totalFiles: Int = 0
    @Published var completedFiles: Int = 0
    @Published var currentFile: String = ""
    @Published var statusText: String = "Chưa upload."
    @Published var overallProgress: Double = 0
    @Published var isUploading: Bool = false

    private let queueStoreURL: URL
    private var uploadQueue: [UploadJob] = []
    private var currentIndex: Int = 0
    private var serverBase: String = "http://100.120.33.35:8000"
    private var session: URLSession!
    private var taskMap: [Int: URL] = [:]
    private var activeResponses: [Int: Data] = [:]
    private var totalBytesExpected: Int64 = 0
    private var totalBytesCompleted: Int64 = 0

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("RawBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.queueStoreURL = folder.appendingPathComponent("upload_queue.json")

        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: "com.aotasoft.RawBridge.bg")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 60 * 60 * 12
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        loadQueue()
    }

    struct UploadJob: Codable, Identifiable {
        let id: UUID
        let filePath: String
        let fileName: String
        let relativePath: String
        let eventName: String
        let fileSize: Int64

        var url: URL { URL(fileURLWithPath: filePath) }
    }

    struct EventMetaRequest: Codable {
        let event_name: String
        let rough_content: String
        let selected_extensions: [String]
        let expected_file_count: Int
        let expected_bytes: Int64
    }

    struct EventCompleteRequest: Codable {
        let event_name: String
        let selected_extensions: [String]
        let file_count: Int
        let total_bytes: Int64
    }

    func configure(serverBase: String) {
        self.serverBase = serverBase
    }

    func replaceQueue(with jobs: [UploadJob]) {
        uploadQueue = jobs
        currentIndex = 0
        totalFiles = jobs.count
        completedFiles = 0
        totalBytesCompleted = 0
        totalBytesExpected = jobs.reduce(0) { $0 + $1.fileSize }
        persistQueue()
    }

    func resumeFromDisk() {
        loadQueue()
        if !uploadQueue.isEmpty {
            totalFiles = uploadQueue.count
            completedFiles = currentIndex
            totalBytesExpected = uploadQueue.reduce(0) { $0 + $1.fileSize }
            totalBytesCompleted = uploadQueue.prefix(currentIndex).reduce(0) { $0 + $1.fileSize }
            isUploading = currentIndex < uploadQueue.count
            statusText = isUploading ? "Khôi phục queue upload..." : "Queue đã hoàn tất."
        }
    }

    func clearQueue() {
        uploadQueue = []
        currentIndex = 0
        totalFiles = 0
        completedFiles = 0
        totalBytesCompleted = 0
        totalBytesExpected = 0
        overallProgress = 0
        isUploading = false
        statusText = "Đã xóa queue."
        try? FileManager.default.removeItem(at: queueStoreURL)
    }

    func enqueueAndStart(
        serverBase: String,
        eventName: String,
        roughContent: String,
        selectedExtensions: [String],
        files: [TransferModel.MediaRef]
    ) async throws {
        configure(serverBase: serverBase)
        let expectedBytes = files.reduce(Int64(0)) { $0 + $1.size }

        try await postJSON(path: "/event-meta", body: EventMetaRequest(
            event_name: eventName,
            rough_content: roughContent,
            selected_extensions: selectedExtensions,
            expected_file_count: files.count,
            expected_bytes: expectedBytes
        ))

        let jobs = files.map {
            UploadJob(
                id: UUID(),
                filePath: $0.url.path,
                fileName: $0.url.lastPathComponent,
                relativePath: $0.relativePath,
                eventName: eventName,
                fileSize: $0.size
            )
        }

        await MainActor.run {
            self.replaceQueue(with: jobs)
            self.isUploading = true
            self.statusText = "Bắt đầu upload nền..."
        }

        startNextIfNeeded(selectedExtensions: selectedExtensions)
    }

    private func startNextIfNeeded(selectedExtensions: [String]) {
        guard currentIndex < uploadQueue.count else {
            Task {
                if let eventName = uploadQueue.first?.eventName {
                    try? await postJSON(path: "/complete-event", body: EventCompleteRequest(
                        event_name: eventName,
                        selected_extensions: selectedExtensions,
                        file_count: uploadQueue.count,
                        total_bytes: uploadQueue.reduce(0) { $0 + $1.fileSize }
                    ))
                }
                await MainActor.run {
                    self.isUploading = false
                    self.statusText = "HOÀN TẤT — đã gửi xong queue."
                    self.overallProgress = 1
                }
                self.clearQueue()
            }
            return
        }

        let job = uploadQueue[currentIndex]
        currentFile = job.relativePath
        statusText = "Đang gửi \(currentIndex + 1)/\(uploadQueue.count): \(job.fileName)"

        guard var components = URLComponents(string: serverBase) else {
            statusText = "Server URL không hợp lệ."
            isUploading = false
            return
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/upload-file"
        components.queryItems = [
            URLQueryItem(name: "event_name", value: job.eventName),
            URLQueryItem(name: "relative_path", value: job.relativePath),
            URLQueryItem(name: "filename", value: job.fileName)
        ]
        guard let url = components.url else {
            statusText = "Server URL không hợp lệ."
            isUploading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(job.fileSize), forHTTPHeaderField: "Content-Length")

        let task = session.uploadTask(with: request, fromFile: job.url)
        taskMap[task.taskIdentifier] = job.url
        activeResponses[task.taskIdentifier] = Data()
        task.resume()
    }

    private func postJSON<T: Encodable>(path: String, body: T) async throws {
        guard var components = URLComponents(string: serverBase) else {
            throw NSError(domain: "RawBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }
        var p = components.path
        if p.hasSuffix("/") { p.removeLast() }
        components.path = p + path
        guard let url = components.url else {
            throw NSError(domain: "RawBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200...299).contains(code) else {
            throw NSError(domain: "RawBridge", code: code, userInfo: [NSLocalizedDescriptionKey: "Server trả lỗi \(code)"])
        }
    }

    private func persistQueue() {
        let payload = PersistedQueue(queue: uploadQueue, currentIndex: currentIndex)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: queueStoreURL, options: .atomic)
        }
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueStoreURL),
              let payload = try? JSONDecoder().decode(PersistedQueue.self, from: data) else { return }
        self.uploadQueue = payload.queue
        self.currentIndex = payload.currentIndex
    }

    struct PersistedQueue: Codable {
        let queue: [UploadJob]
        let currentIndex: Int
    }

    // MARK: URLSession delegates
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        activeResponses[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        let sentOverall = totalBytesCompleted + totalBytesSent
        let total = max(totalBytesExpected, 1)
        DispatchQueue.main.async {
            self.overallProgress = min(Double(sentOverall) / Double(total), 1.0)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            taskMap.removeValue(forKey: task.taskIdentifier)
            activeResponses.removeValue(forKey: task.taskIdentifier)
        }

        if let error = error {
            DispatchQueue.main.async {
                self.isUploading = false
                self.statusText = "Upload tạm dừng/lỗi: \(error.localizedDescription). Mở lại app để gửi tiếp queue."
            }
            persistQueue()
            return
        }

        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200...299).contains(statusCode) else {
            DispatchQueue.main.async {
                self.isUploading = false
                self.statusText = "Server lỗi HTTP \(statusCode)."
            }
            persistQueue()
            return
        }

        if currentIndex < uploadQueue.count {
            totalBytesCompleted += uploadQueue[currentIndex].fileSize
            currentIndex += 1
            completedFiles = currentIndex
            persistQueue()
        }

        // Reuse currently selected extensions from queue snapshot
        let exts = Array(Set(uploadQueue.map { URL(fileURLWithPath: $0.fileName).pathExtension.lowercased() })).sorted()
        DispatchQueue.main.async {
            self.statusText = "Đã gửi xong \(self.completedFiles)/\(self.totalFiles) file."
        }
        startNextIfNeeded(selectedExtensions: exts)
    }
}
