import Foundation

enum UploadError: LocalizedError {
    case invalidServerURL
    case serverError(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Địa chỉ server không hợp lệ."
        case .serverError(let code):
            return "Server trả về lỗi HTTP \(code)."
        case .unexpectedResponse:
            return "Phản hồi từ server không hợp lệ."
        }
    }
}

final class RawFileUploader: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var progressHandler: ((Int64, Int64) -> Void)?
    private var activeTask: URLSessionUploadTask?
    private var responseData = Data()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 6
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func upload(
        fileURL: URL,
        fileSize: Int64,
        eventName: String,
        relativePath: String,
        serverBase: String,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        guard var components = URLComponents(string: serverBase.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UploadError.invalidServerURL
        }

        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/upload-raw"
        components.queryItems = [
            URLQueryItem(name: "event_name", value: eventName),
            URLQueryItem(name: "relative_path", value: relativePath),
            URLQueryItem(name: "filename", value: fileURL.lastPathComponent)
        ]

        guard let url = components.url else {
            throw UploadError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.progressHandler = progress
            self.responseData = Data()

            let task = self.session.uploadTask(with: request, fromFile: fileURL)
            self.activeTask = task
            task.resume()
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progressHandler?(totalBytesSent, max(totalBytesExpectedToSend, 1))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        responseData.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            activeTask = nil
            progressHandler = nil
            continuation = nil
            responseData = Data()
        }

        if let error {
            continuation?.resume(throwing: error)
            return
        }

        guard let response = task.response as? HTTPURLResponse else {
            continuation?.resume(throwing: UploadError.unexpectedResponse)
            return
        }

        guard (200...299).contains(response.statusCode) else {
            continuation?.resume(throwing: UploadError.serverError(response.statusCode))
            return
        }

        continuation?.resume()
    }
}
