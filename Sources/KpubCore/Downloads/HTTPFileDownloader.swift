import Foundation

public enum DownloadError: LocalizedError {
    case badStatus(Int)
    case incomplete(received: Int64, expected: Int64)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            "Сервер ответил HTTP \(code)"
        case .incomplete(let received, let expected):
            "Файл скачан не полностью (\(received) из \(expected) байт)"
        }
    }

    /// Ссылка протухла или недоступна — имеет смысл запросить свежие ссылки у API.
    public var isLinkExpired: Bool {
        if case .badStatus(let code) = self { return [401, 403, 404, 410].contains(code) }
        return false
    }
}

public struct DownloadProgress: Sendable {
    public var received: Int64
    public var total: Int64?
    public var bytesPerSecond: Double
    public var fractionOverride: Double? = nil

    public var fraction: Double? {
        if let fractionOverride { return min(max(fractionOverride, 0), 1) }
        guard let total, total > 0 else { return nil }
        return min(Double(received) / Double(total), 1)
    }
}

/// Докачиваемая загрузка одного файла через HTTP Range в `destination` (.part-файл).
public final class HTTPFileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let userAgent: String
    private let onProgress: @Sendable (DownloadProgress) -> Void

    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var lastReport = Date.distantPast
    private var speedWindowStart = Date()
    private var speedWindowBytes: Int64 = 0
    private var speed: Double = 0

    private init(url: URL, destination: URL, userAgent: String, onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.url = url
        self.destination = destination
        self.userAgent = userAgent
        self.onProgress = onProgress
    }

    public static func download(
        from url: URL,
        to destination: URL,
        userAgent: String = KpubAPI.userAgent,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        let downloader = HTTPFileDownloader(url: url, destination: destination, userAgent: userAgent, onProgress: onProgress)
        try await downloader.start()
    }

    private func start() async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        let existing = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        received = existing

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    self.continuation = cont
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate (вызывается на последовательной очереди)

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = DownloadError.badStatus(0)
            completionHandler(.cancel)
            return
        }
        do {
            switch http.statusCode {
            case 206:
                total = Self.parseTotal(contentRange: http.value(forHTTPHeaderField: "Content-Range"))
                handle = try FileHandle(forWritingTo: destination)
                try handle?.seekToEnd()
            case 200:
                // Сервер проигнорировал Range — начинаем заново.
                received = 0
                total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
                handle = try FileHandle(forWritingTo: destination)
                try handle?.truncate(atOffset: 0)
            case 416:
                // Диапазон за концом файла: скорее всего, уже всё скачано.
                let fullSize = Self.parseTotal(contentRange: http.value(forHTTPHeaderField: "Content-Range"))
                if let fullSize, fullSize == received {
                    total = fullSize
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    failure = DownloadError.incomplete(received: received, expected: fullSize ?? -1)
                }
                completionHandler(.cancel)
                return
            default:
                failure = DownloadError.badStatus(http.statusCode)
                completionHandler(.cancel)
                return
            }
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        report(force: true)
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        speedWindowBytes += Int64(data.count)
        report(force: false)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        report(force: true)
        let cont = continuation
        continuation = nil

        if let failure {
            cont?.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                cont?.resume(throwing: CancellationError())
            } else {
                cont?.resume(throwing: error)
            }
        } else if let total, received < total {
            cont?.resume(throwing: DownloadError.incomplete(received: received, expected: total))
        } else {
            cont?.resume()
        }
    }

    private func report(force: Bool) {
        let now = Date()
        let windowLength = now.timeIntervalSince(speedWindowStart)
        if windowLength >= 2 {
            let current = Double(speedWindowBytes) / windowLength
            speed = speed == 0 ? current : speed * 0.6 + current * 0.4
            speedWindowStart = now
            speedWindowBytes = 0
        }
        guard force || now.timeIntervalSince(lastReport) >= 0.5 else { return }
        lastReport = now
        onProgress(DownloadProgress(received: received, total: total, bytesPerSecond: speed))
    }

    /// "bytes 100-199/1000" → 1000
    static func parseTotal(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...])
    }
}
