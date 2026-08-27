import Foundation
import Combine

final class RawBackgroundUploadManager:
    NSObject,
    ObservableObject,
    URLSessionTaskDelegate {

    static let shared =
        RawBackgroundUploadManager()

    @Published private(set) var totalFiles = 0
    @Published private(set) var completedFiles = 0
    @Published private(set) var currentFile = ""
    @Published private(set) var statusText =
        "Chưa upload."

    @Published private(set) var overallProgress:
        Double = 0

    @Published private(set) var isUploading = false
    @Published private(set) var isPaused = false
    @Published private(set) var sessionCompleted = false

    // Chỉ hiển thị MB/s theo yêu cầu.
    @Published private(set) var speedMBps:
        Double = 0

    @Published private(set) var etaText = "--"

    private let queueStoreURL: URL

    private var uploadQueue: [UploadJob] = []
    private var completedJobIDs: Set<UUID> = []

    private var serverBase =
        "http://100.120.33.35:8000"

    private var selectedExtensions: [String] = []

    private var backgroundCompletionHandler:
        (() -> Void)?

    private let stateLock = NSLock()

    private var sentByTask:
        [Int: Int64] = [:]

    private var lastSpeedTime:
        TimeInterval = 0

    private var lastSpeedBytes:
        Int64 = 0

    private var smoothedBytesPerSecond:
        Double = 0

    private lazy var session: URLSession = {
        let config =
            URLSessionConfiguration.background(
                withIdentifier:
                    "com.aotasoft.RawBridge.background-upload"
            )

        // Toàn bộ task được giao cho tiến trình hệ thống.
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true

        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true

        // Xếp sẵn toàn bộ task, nhưng chỉ chạy tối đa
        // vài kết nối đồng thời tới PC.
        config.httpMaximumConnectionsPerHost = 2

        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource =
            60 * 60 * 24

        return URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )
    }()

    struct UploadJob:
        Codable,
        Identifiable {

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
        let completedJobIDs: [UUID]
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

    override init() {
        let support =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!

        let folder =
            support.appendingPathComponent(
                "RawBridge",
                isDirectory: true
            )

        try? FileManager.default
            .createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )

        queueStoreURL =
            folder.appendingPathComponent(
                "upload_queue_v2.json"
            )

        super.init()

        // Tạo session cùng identifier ngay khi app mở,
        // để iOS reconnect các background task cũ.
        _ = session
        loadQueue()
    }

    // MARK: - App lifecycle

    func setBackgroundCompletionHandler(
        _ handler: @escaping () -> Void
    ) {
        backgroundCompletionHandler = handler
    }

    func resumeFromDisk() {
        loadQueue()

        guard !uploadQueue.isEmpty else {
            return
        }

        publishState()

        session.getAllTasks {
            [weak self] tasks in

            guard let self else { return }

            let activeIDs =
                Set(
                    tasks.compactMap {
                        self.jobID(from: $0)
                    }
                )

            self.scheduleMissingTasks(
                excluding: activeIDs
            )

            self.publish {
                if self.completedJobIDs.count <
                    self.uploadQueue.count {

                    self.isUploading = true
                    self.sessionCompleted = false

                    self.statusText =
                        "Đã khôi phục background queue: \(self.completedJobIDs.count)/\(self.uploadQueue.count) file xong."
                }
            }
        }
    }

    // MARK: - Start

    func enqueueAndStart(
        serverBase: String,
        eventName: String,
        roughContent: String,
        selectedExtensions: [String],
        files: [TransferModel.MediaRef]
    ) async throws {

        self.serverBase = serverBase
        self.selectedExtensions =
            selectedExtensions

        let expectedBytes =
            files.reduce(Int64(0)) {
                $0 + $1.size
            }

        // Gửi metadata trước. Chỉ khi metadata OK
        // mới xếp background tasks.
        try await postJSON(
            path: "/event-meta",
            body: EventMetaRequest(
                event_name: eventName,
                rough_content: roughContent,
                selected_extensions:
                    selectedExtensions,
                expected_file_count:
                    files.count,
                expected_bytes:
                    expectedBytes
            )
        )

        uploadQueue = files.map {
            UploadJob(
                id: UUID(),
                filePath: $0.url.path,
                fileName: $0.fileName,
                relativePath: $0.relativePath,
                eventName: eventName,
                fileSize: $0.size,
                cleanupAfterUpload:
                    $0.cleanupAfterUpload
            )
        }

        completedJobIDs = []
        resetSpeedMeter()
        persistQueue()

        publish {
            self.totalFiles =
                self.uploadQueue.count

            self.completedFiles = 0
            self.currentFile =
                self.uploadQueue.first?
                    .relativePath ?? ""

            self.overallProgress = 0
            self.isUploading = true
            self.isPaused = false
            self.sessionCompleted = false
            self.speedMBps = 0
            self.etaText = "--"

            self.statusText =
                "Đã xếp \(self.uploadQueue.count) file vào background queue."
        }

        // QUAN TRỌNG:
        // Xếp TẤT CẢ task ngay bây giờ.
        // iOS có thể suspend app nhưng tiến trình hệ thống
        // vẫn còn toàn bộ hàng đợi để tự chạy.
        scheduleMissingTasks(excluding: [])
    }

    private func scheduleMissingTasks(
        excluding activeIDs: Set<UUID>
    ) {
        guard !isPaused else { return }

        for job in uploadQueue {
            if completedJobIDs.contains(job.id) {
                continue
            }

            if activeIDs.contains(job.id) {
                continue
            }

            schedule(job)
        }
    }

    private func schedule(_ job: UploadJob) {
        guard FileManager.default
            .fileExists(atPath: job.url.path)
        else {
            fail(
                "Không còn tìm thấy file: \(job.fileName)"
            )
            return
        }

        guard var components =
            URLComponents(string: serverBase)
        else {
            fail("Server URL không hợp lệ.")
            return
        }

        var path = components.path

        if path.hasSuffix("/") {
            path.removeLast()
        }

        components.path =
            path + "/upload-file"

        components.queryItems = [
            URLQueryItem(
                name: "event_name",
                value: job.eventName
            ),
            URLQueryItem(
                name: "relative_path",
                value: job.relativePath
            ),
            URLQueryItem(
                name: "filename",
                value: job.fileName
            ),
            URLQueryItem(
                name: "job_id",
                value: job.id.uuidString
            )
        ]

        guard let url = components.url else {
            fail("Server URL không hợp lệ.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.setValue(
            String(job.fileSize),
            forHTTPHeaderField:
                "Content-Length"
        )

        let task =
            session.uploadTask(
                with: request,
                fromFile: job.url
            )

        task.taskDescription =
            job.id.uuidString

        task.countOfBytesClientExpectsToSend =
            job.fileSize

        task.countOfBytesClientExpectsToReceive =
            1024

        task.resume()
    }

    // MARK: - Pause / resume

    func pause() {
        session.getAllTasks {
            [weak self] tasks in

            guard let self else { return }

            tasks.forEach {
                $0.suspend()
            }

            self.resetSpeedMeter()

            self.publish {
                self.isPaused = true
                self.speedMBps = 0
                self.etaText = "--"
                self.statusText =
                    "Đã tạm dừng \(tasks.count) background task."
            }
        }
    }

    func resume() {
        isPaused = false
        resetSpeedMeter()

        session.getAllTasks {
            [weak self] tasks in

            guard let self else { return }

            let activeIDs =
                Set(
                    tasks.compactMap {
                        self.jobID(from: $0)
                    }
                )

            tasks.forEach {
                $0.resume()
            }

            self.scheduleMissingTasks(
                excluding: activeIDs
            )

            self.publish {
                self.isPaused = false
                self.isUploading = true
                self.statusText =
                    "Đang tiếp tục background queue..."
            }
        }
    }

    // MARK: - Completion / new session

    func resetForNewSession() {
        guard !isUploading else { return }

        for job in uploadQueue
        where job.cleanupAfterUpload {
            try? FileManager.default
                .removeItem(at: job.url)
        }

        uploadQueue = []
        completedJobIDs = []
        selectedExtensions = []

        stateLock.lock()
        sentByTask = [:]
        stateLock.unlock()

        resetSpeedMeter()

        try? FileManager.default
            .removeItem(at: queueStoreURL)

        publish {
            self.totalFiles = 0
            self.completedFiles = 0
            self.currentFile = ""
            self.statusText = "Chưa upload."
            self.overallProgress = 0
            self.isUploading = false
            self.isPaused = false
            self.sessionCompleted = false
            self.speedMBps = 0
            self.etaText = "--"
        }
    }

    private func markCompleted(
        jobID: UUID,
        taskIdentifier: Int
    ) {
        guard !completedJobIDs
            .contains(jobID)
        else {
            return
        }

        guard let job =
            uploadQueue.first(
                where: {
                    $0.id == jobID
                }
            )
        else {
            return
        }

        completedJobIDs.insert(jobID)

        stateLock.lock()
        sentByTask.removeValue(
            forKey: taskIdentifier
        )
        stateLock.unlock()

        if job.cleanupAfterUpload {
            try? FileManager.default
                .removeItem(at: job.url)
        }

        persistQueue()
        publishState()

        if completedJobIDs.count >=
            uploadQueue.count {

            resetSpeedMeter()

            publish {
                self.completedFiles =
                    self.uploadQueue.count

                self.overallProgress = 1
                self.isUploading = false
                self.isPaused = false
                self.sessionCompleted = true
                self.currentFile = ""
                self.speedMBps = 0
                self.etaText = "0s"

                self.statusText =
                    "HOÀN TẤT — server đã nhận \(self.uploadQueue.count) file."
            }

            // Server v1.5 tự tạo
            // UPLOAD_COMPLETE.json khi đủ job,
            // nên app không phải thức để gọi complete-event.
            try? FileManager.default
                .removeItem(at: queueStoreURL)
        }
    }

    // MARK: - Persistence

    private func loadQueue() {
        guard let data =
            try? Data(contentsOf: queueStoreURL),
              let payload =
            try? JSONDecoder()
                .decode(
                    PersistedQueue.self,
                    from: data
                )
        else {
            return
        }

        uploadQueue = payload.queue
        completedJobIDs =
            Set(payload.completedJobIDs)

        serverBase =
            payload.serverBase

        selectedExtensions =
            payload.selectedExtensions
    }

    private func persistQueue() {
        let payload =
            PersistedQueue(
                queue: uploadQueue,
                completedJobIDs:
                    Array(completedJobIDs),
                serverBase: serverBase,
                selectedExtensions:
                    selectedExtensions
            )

        if let data =
            try? JSONEncoder()
                .encode(payload) {

            try? data.write(
                to: queueStoreURL,
                options: .atomic
            )
        }
    }

    // MARK: - HTTP metadata

    private func postJSON<T: Encodable>(
        path: String,
        body: T
    ) async throws {

        guard var components =
            URLComponents(string: serverBase)
        else {
            throw NSError(
                domain: "RawBridge",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Server URL không hợp lệ."
                ]
            )
        }

        var basePath = components.path

        if basePath.hasSuffix("/") {
            basePath.removeLast()
        }

        components.path = basePath + path

        guard let url = components.url else {
            throw NSError(
                domain: "RawBridge",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Server URL không hợp lệ."
                ]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        request.setValue(
            "application/json",
            forHTTPHeaderField:
                "Content-Type"
        )

        request.httpBody =
            try JSONEncoder().encode(body)

        request.timeoutInterval = 15

        let config =
            URLSessionConfiguration.ephemeral

        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true

        let foreground =
            URLSession(configuration: config)

        let (_, response) =
            try await foreground
                .data(for: request)

        let code =
            (response as? HTTPURLResponse)?
                .statusCode ?? 500

        guard (200...299)
            .contains(code)
        else {
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

    // MARK: - Progress / speed

    private func publishState() {
        let completed =
            completedJobIDs.count

        let completedBytes =
            uploadQueue
                .filter {
                    completedJobIDs
                        .contains($0.id)
                }
                .reduce(Int64(0)) {
                    $0 + $1.fileSize
                }

        let totalBytes =
            uploadQueue.reduce(Int64(0)) {
                $0 + $1.fileSize
            }

        stateLock.lock()

        let activeSent =
            sentByTask.values.reduce(
                Int64(0),
                +
            )

        stateLock.unlock()

        let sent =
            min(
                completedBytes + activeSent,
                totalBytes
            )

        let progress =
            totalBytes > 0
            ? Double(sent) /
                Double(totalBytes)
            : 0

        publish {
            self.totalFiles =
                self.uploadQueue.count

            self.completedFiles =
                completed

            self.overallProgress =
                min(max(progress, 0), 1)

            self.isUploading =
                completed <
                self.uploadQueue.count
        }
    }

    private func updateSpeed(
        aggregateSent: Int64,
        totalBytes: Int64
    ) {
        let now =
            Date()
                .timeIntervalSinceReferenceDate

        var displaySpeed =
            smoothedBytesPerSecond

        if lastSpeedTime == 0 {
            lastSpeedTime = now
            lastSpeedBytes =
                aggregateSent
            return
        }

        let dt =
            now - lastSpeedTime

        guard dt >= 0.35 else {
            return
        }

        let delta =
            max(
                aggregateSent -
                lastSpeedBytes,
                0
            )

        let instant =
            Double(delta) / dt

        if smoothedBytesPerSecond <= 0 {
            smoothedBytesPerSecond =
                instant
        } else {
            smoothedBytesPerSecond =
                smoothedBytesPerSecond *
                    0.70 +
                instant * 0.30
        }

        displaySpeed =
            smoothedBytesPerSecond

        lastSpeedTime = now
        lastSpeedBytes =
            aggregateSent

        let remaining =
            max(
                totalBytes -
                aggregateSent,
                0
            )

        let eta =
            displaySpeed > 1024
            ? Double(remaining) /
                displaySpeed
            : Double.nan

        let mbps =
            displaySpeed /
            1_000_000.0

        let etaString =
            formattedETA(eta)

        publish {
            self.speedMBps = mbps
            self.etaText = etaString
        }
    }

    private func resetSpeedMeter() {
        lastSpeedTime = 0
        lastSpeedBytes = 0
        smoothedBytesPerSecond = 0
    }

    private func formattedETA(
        _ seconds: Double
    ) -> String {

        guard seconds.isFinite,
              seconds >= 0
        else {
            return "--"
        }

        let total =
            Int(seconds.rounded())

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

    private func jobID(
        from task: URLSessionTask
    ) -> UUID? {

        guard let description =
            task.taskDescription
        else {
            return nil
        }

        return UUID(
            uuidString: description
        )
    }

    private func fail(_ text: String) {
        resetSpeedMeter()

        publish {
            self.statusText = text
            self.speedMBps = 0
            self.etaText = "--"
        }

        persistQueue()
    }

    private func publish(
        _ block: @escaping () -> Void
    ) {
        DispatchQueue.main.async(
            execute: block
        )
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let jobID =
            jobID(from: task)
        else {
            return
        }

        guard let job =
            uploadQueue.first(
                where: {
                    $0.id == jobID
                }
            )
        else {
            return
        }

        stateLock.lock()

        sentByTask[
            task.taskIdentifier
        ] = min(
            totalBytesSent,
            job.fileSize
        )

        let activeSent =
            sentByTask.values.reduce(
                Int64(0),
                +
            )

        stateLock.unlock()

        let completedBytes =
            uploadQueue
                .filter {
                    completedJobIDs
                        .contains($0.id)
                }
                .reduce(Int64(0)) {
                    $0 + $1.fileSize
                }

        let totalBytes =
            uploadQueue.reduce(Int64(0)) {
                $0 + $1.fileSize
            }

        let aggregateSent =
            min(
                completedBytes +
                    activeSent,
                totalBytes
            )

        publish {
            self.currentFile =
                job.relativePath

            if totalBytes > 0 {
                self.overallProgress =
                    Double(aggregateSent) /
                    Double(totalBytes)
            }

            self.statusText =
                "Background queue đang chạy • \(self.completedJobIDs.count)/\(self.uploadQueue.count) file xong."
        }

        updateSpeed(
            aggregateSent:
                aggregateSent,
            totalBytes:
                totalBytes
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let jobID =
            jobID(from: task)
        else {
            return
        }

        stateLock.lock()
        sentByTask.removeValue(
            forKey: task.taskIdentifier
        )
        stateLock.unlock()

        if let error {
            // Giữ queue. Khi app được mở lại
            // hoặc người dùng bấm tiếp tục,
            // job bị lỗi sẽ được schedule lại.
            publish {
                self.statusText =
                    "Một file bị gián đoạn: \(error.localizedDescription). Queue vẫn được giữ."
            }

            persistQueue()

            // Nếu app vẫn còn sống, thử schedule
            // lại job sau khoảng ngắn.
            DispatchQueue.global()
                .asyncAfter(
                    deadline: .now() + 1.0
                ) {
                    self.session
                        .getAllTasks {
                            tasks in

                            let active =
                                Set(
                                    tasks
                                        .compactMap {
                                            self.jobID(
                                                from: $0
                                            )
                                        }
                                )

                            self.scheduleMissingTasks(
                                excluding:
                                    active
                            )
                        }
                }

            return
        }

        let code =
            (task.response as?
                HTTPURLResponse)?
                .statusCode ?? 500

        guard (200...299)
            .contains(code)
        else {
            publish {
                self.statusText =
                    "Server trả HTTP \(code). Queue vẫn được giữ để thử lại."
            }

            persistQueue()
            return
        }

        markCompleted(
            jobID: jobID,
            taskIdentifier:
                task.taskIdentifier
        )
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession session:
            URLSession
    ) {
        publish {
            let handler =
                self.backgroundCompletionHandler

            self.backgroundCompletionHandler =
                nil

            handler?()
        }
    }
}
