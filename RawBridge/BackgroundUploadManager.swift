import Foundation
import Combine

final class RawBackgroundUploadManager: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = RawBackgroundUploadManager()

    @Published private(set) var totalFiles: Int = 0
    @Published private(set) var completedFiles: Int = 0
    @Published private(set) var currentFile: String = ""
    @Published private(set) var statusText: String = "Chưa upload."
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var isUploading: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var sessionCompleted: Bool = false

    @Published private(set) var speedMBs: Double = 0
    @Published private(set) var speedMbps: Double = 0
    @Published private(set) var etaText: String = "--"

    private let queueStoreURL: URL
    private var uploadQueue: [UploadJob] = []
    private var currentIndex: Int = 0
    private var serverBase: String = "http://100.120.33.35:8000"
    private var selectedExtensions: [String] = []
    private var totalBytesExpected: Int64 = 0
    private var totalBytesCompleted: Int64 = 0
    private var backgroundCompletionHandler: (() -> Void)?

    private var lastSpeedTime: TimeInterval = 0
    private var lastSpeedBytes: Int64 = 0
    private var smoothedBytesPerSecond: Double = 0

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.aotasoft.RawBridge.background-upload"
        )
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 60 * 60 * 24

        return URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }()

    struct UploadJob: Codable, Identifiable {
        let id: UUID
        let filePath: String
        let fileName: String
        let relativePath: String
        let eventName: String
        let fileSize: Int64
        let cleanupAfterUpload: Bool

        var url: URL {
            URL(fileURLWithPath: filePath)
        }
    }

    struct PersistedQueue: Codable {
        let queue: [UploadJob]
        let currentIndex: Int
        let serverBase: String
        let selectedExtensions: [String]
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

    override init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let folder = support.appendingPathComponent(
            "RawBridge",
            isDirectory: true
        )

        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        queueStoreURL = folder.appendingPathComponent("upload_queue.json")
        super.init()

        _ = session
        loadQueue()
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    func resumeFromDisk() {
        loadQueue()

        guard !uploadQueue.isEmpty,
              currentIndex < uploadQueue.count else {
            return
        }

        totalBytesExpected = uploadQueue.reduce(0) { $0 + $1.fileSize }
        totalBytesCompleted = uploadQueue
            .prefix(currentIndex)
            .reduce(0) { $0 + $1.fileSize }

        publish {
            self.totalFiles = self.uploadQueue.count
            self.completedFiles = self.currentIndex
            self.currentFile = self.uploadQueue[self.currentIndex].relativePath
            self.isUploading = true
            self.sessionCompleted = false
            self.statusText = "Đang khôi phục queue upload..."
        }

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }

            if tasks.isEmpty {
                self.startNextIfNeeded()
            } else {
                self.publish {
                    self.statusText = "Đã khôi phục tác vụ upload nền."
                    self.isPaused = tasks.allSatisfy { $0.state == .suspended }
                }
            }
        }
    }

    func enqueueAndStart(
        serverBase: String,
        eventName: String,
        roughContent: String,
        selectedExtensions: [String],
        files: [TransferModel.MediaRef]
    ) async throws {
        self.serverBase = serverBase
        self.selectedExtensions = selectedExtensions

        let expectedBytes = files.reduce(Int64(0)) { $0 + $1.size }

        try await postJSON(
            path: "/event-meta",
            body: EventMetaRequest(
                event_name: eventName,
                rough_content: roughContent,
                selected_extensions: selectedExtensions,
                expected_file_count: files.count,
                expected_bytes: expectedBytes
            )
        )

        let jobs = files.map {
            UploadJob(
                id: UUID(),
                filePath: $0.url.path,
                fileName: $0.fileName,
                relativePath: $0.relativePath,
                eventName: eventName,
                fileSize: $0.size,
                cleanupAfterUpload: $0.cleanupAfterUpload
            )
        }

        uploadQueue = jobs
        currentIndex = 0
        totalBytesExpected = expectedBytes
        totalBytesCompleted = 0
        resetSpeedMeter()
        persistQueue()

        publish {
            self.totalFiles = jobs.count
            self.completedFiles = 0
            self.currentFile = jobs.first?.relativePath ?? ""
            self.overallProgress = 0
            self.isUploading = true
            self.isPaused = false
            self.sessionCompleted = false
            self.speedMBs = 0
            self.speedMbps = 0
            self.etaText = "--"
            self.statusText = "Bắt đầu upload nền..."
        }

        startNextIfNeeded()
    }

    func pause() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }

            tasks.forEach { $0.suspend() }
            self.resetSpeedMeter()

            self.publish {
                self.isPaused = true
                self.speedMBs = 0
                self.speedMbps = 0
                self.etaText = "--"
                self.statusText = "Đã tạm dừng."
            }
        }
    }

    func resume() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }

            self.resetSpeedMeter()

            if tasks.isEmpty {
                self.publish {
                    self.isPaused = false
                    self.isUploading = true
                    self.statusText = "Đang tiếp tục..."
                }
                self.startNextIfNeeded()
            } else {
                tasks.forEach { $0.resume() }

                self.publish {
                    self.isPaused = false
                    self.isUploading = true
                    self.statusText = "Đang tiếp tục upload..."
                }
            }
        }
    }

    func resetForNewSession() {
        guard !isUploading else { return }

        for job in uploadQueue where job.cleanupAfterUpload {
            try? FileManager.default.removeItem(at: job.url)
        }

        uploadQueue.removeAll()
        currentIndex = 0
        selectedExtensions = []
        totalBytesExpected = 0
        totalBytesCompleted = 0
        resetSpeedMeter()
        try? FileManager.default.removeItem(at: queueStoreURL)

        publish {
            self.totalFiles = 0
            self.completedFiles = 0
            self.currentFile = ""
            self.statusText = "Chưa upload."
            self.overallProgress = 0
            self.isUploading = false
            self.isPaused = false
            self.sessionCompleted = false
            self.speedMBs = 0
            self.speedMbps = 0
            self.etaText = "--"
        }
    }

    private func startNextIfNeeded() {
        guard !isPaused else { return }

        guard currentIndex < uploadQueue.count else {
            finishEvent()
            return
        }

        let job = uploadQueue[currentIndex]
        resetSpeedMeter()

        publish {
            self.currentFile = job.relativePath
            self.isUploading = true
            self.statusText =
                "Đang gửi \(self.currentIndex + 1)/\(self.uploadQueue.count): \(job.fileName)"
        }

        guard var components = URLComponents(string: serverBase) else {
            fail("Server URL không hợp lệ.")
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
            fail("Server URL không hợp lệ.")
            return
        }

        guard FileManager.default.fileExists(atPath: job.url.path) else {
            fail("Không còn tìm thấy file: \(job.fileName)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            String(job.fileSize),
            forHTTPHeaderField: "Content-Length"
        )

        let task = session.uploadTask(with: request, fromFile: job.url)
        task.taskDescription = job.id.uuidString
        task.resume()
    }

    private func finishEvent() {
        guard let eventName = uploadQueue.first?.eventName else {
            clearPersistedQueueAfterCompletion()
            return
        }

        let totalBytes = uploadQueue.reduce(Int64(0)) { $0 + $1.fileSize }
        let fileCount = uploadQueue.count

        Task {
            do {
                try await postJSON(
                    path: "/complete-event",
                    body: EventCompleteRequest(
                        event_name: eventName,
                        selected_extensions: selectedExtensions,
                        file_count: fileCount,
                        total_bytes: totalBytes
                    )
                )

                resetSpeedMeter()

                publish {
                    self.completedFiles = fileCount
                    self.overallProgress = 1
                    self.isUploading = false
                    self.isPaused = false
                    self.sessionCompleted = true
                    self.currentFile = ""
                    self.speedMBs = 0
                    self.speedMbps = 0
                    self.etaText = "0s"
                    self.statusText = "HOÀN TẤT — đã gửi \(fileCount) file."
                }

                clearPersistedQueueAfterCompletion()
            } catch {
                fail(
                    "Đã gửi file nhưng chưa đánh dấu hoàn tất: \(error.localizedDescription)"
                )
            }
        }
    }

    private func postJSON<T: Encodable>(
        path: String,
        body: T
    ) async throws {
        guard var components = URLComponents(string: serverBase) else {
            throw NSError(
                domain: "RawBridge",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Server URL không hợp lệ."
                ]
            )
        }

        var basePath = components.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path

        guard let url = components.url else {
            throw NSError(
                domain: "RawBridge",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Server URL không hợp lệ."
                ]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 15

        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 500

        guard (200...299).contains(code) else {
            throw NSError(
                domain: "RawBridge",
                code: code,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Server trả lỗi HTTP \(code)."
                ]
            )
        }
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueStoreURL),
              let payload = try? JSONDecoder().decode(
                PersistedQueue.self,
                from: data
              ) else {
            return
        }

        uploadQueue = payload.queue
        currentIndex = payload.currentIndex
        serverBase = payload.serverBase
        selectedExtensions = payload.selectedExtensions
    }

    private func persistQueue() {
        let payload = PersistedQueue(
            queue: uploadQueue,
            currentIndex: currentIndex,
            serverBase: serverBase,
            selectedExtensions: selectedExtensions
        )

        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: queueStoreURL, options: .atomic)
        }
    }

    private func clearPersistedQueueAfterCompletion() {
        uploadQueue.removeAll()
        currentIndex = 0
        totalBytesExpected = 0
        totalBytesCompleted = 0
        try? FileManager.default.removeItem(at: queueStoreURL)
    }

    private func fail(_ text: String) {
        resetSpeedMeter()

        publish {
            self.isUploading = false
            self.speedMBs = 0
            self.speedMbps = 0
            self.etaText = "--"
            self.statusText = text
        }

        persistQueue()
    }

    private func resetSpeedMeter() {
        lastSpeedTime = 0
        lastSpeedBytes = 0
        smoothedBytesPerSecond = 0
    }

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func formattedETA(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }

        let total = Int(seconds.rounded())

        if total < 60 {
            return "\(total)s"
        }

        let minutes = total / 60
        let sec = total % 60

        if minutes < 60 {
            return "\(minutes)m \(sec)s"
        }

        let hours = minutes / 60
        let min = minutes % 60
        return "\(hours)h \(min)m"
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let sentOverall = totalBytesCompleted + totalBytesSent
        let total = max(totalBytesExpected, 1)
        let now = Date().timeIntervalSinceReferenceDate

        var displaySpeed = smoothedBytesPerSecond

        if lastSpeedTime == 0 {
            lastSpeedTime = now
            lastSpeedBytes = sentOverall
        } else {
            let dt = now - lastSpeedTime

            if dt >= 0.35 {
                let byteDelta = max(sentOverall - lastSpeedBytes, 0)
                let instant = Double(byteDelta) / dt

                if smoothedBytesPerSecond <= 0 {
                    smoothedBytesPerSecond = instant
                } else {
                    smoothedBytesPerSecond =
                        (smoothedBytesPerSecond * 0.70) + (instant * 0.30)
                }

                displaySpeed = smoothedBytesPerSecond
                lastSpeedTime = now
                lastSpeedBytes = sentOverall
            }
        }

        let remaining = max(totalBytesExpected - sentOverall, 0)
        let eta =
            displaySpeed > 1024
            ? Double(remaining) / displaySpeed
            : Double.nan

        let mbPerSecond = displaySpeed / 1_000_000.0
        let megabitsPerSecond = mbPerSecond * 8.0
        let etaString = formattedETA(eta)

        publish {
            self.overallProgress =
                min(Double(sentOverall) / Double(total), 1.0)

            if displaySpeed > 0 {
                self.speedMBs = mbPerSecond
                self.speedMbps = megabitsPerSecond
                self.etaText = etaString
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            fail(
                "Upload bị gián đoạn: \(error.localizedDescription). Bấm TIẾP TỤC để gửi lại file hiện tại."
            )
            return
        }

        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 500

        guard (200...299).contains(code) else {
            fail("Server trả lỗi HTTP \(code).")
            return
        }

        guard currentIndex < uploadQueue.count else {
            finishEvent()
            return
        }

        let job = uploadQueue[currentIndex]

        if job.cleanupAfterUpload {
            try? FileManager.default.removeItem(at: job.url)
        }

        totalBytesCompleted += job.fileSize
        currentIndex += 1
        persistQueue()

        publish {
            self.completedFiles = self.currentIndex
            self.overallProgress =
                min(
                    Double(self.totalBytesCompleted) /
                        Double(max(self.totalBytesExpected, 1)),
                    1.0
                )
        }

        startNextIfNeeded()
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        publish {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
