import Foundation

/// An ephemeral transfer with a hard byte limit, no cookies/cache, and cancellable I/O.
/// Delegate callbacks are serialized; the lock coordinates cancellation from Swift tasks.
final class BoundedHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPPayload, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var data = Data()
    private var status = 0
    private let limit: Int
    private let poster: Bool
    init(limit: Int, poster: Bool) { self.limit = limit; self.poster = poster }
    static func load(_ request: URLRequest, limit: Int, poster: Bool) async throws -> HTTPPayload {
        let transfer = BoundedHTTP(limit: limit, poster: poster)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(request, continuation: $0) }
        } onCancel: { transfer.complete(.failure(CancellationError())) }
    }
    private func start(_ request: URLRequest, continuation: CheckedContinuation<HTTPPayload, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request); self.task = task
        task.resume(); lock.unlock()
    }
    private func complete(_ result: Result<HTTPPayload, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = continuation, session = session
        continuation = nil; self.session = nil; task = nil; data.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel(); callback?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= limit else {
            completionHandler(.cancel); complete(.failure(StudioError.message("Ответ сервиса превышает допустимый размер."))); return
        }
        lock.lock(); status = response.statusCode; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard chunk.count <= limit - data.count else {
            lock.unlock(); complete(.failure(StudioError.message("Ответ сервиса превышает допустимый размер."))); return
        }
        data.append(chunk); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); let result = HTTPPayload(status: status, data: data); lock.unlock()
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { complete(.failure(CancellationError())) }
            else { complete(.failure(StudioError.message("Не удалось подключиться к сервису. Проверьте интернет и повторите запрос."))) }
        } else { complete(.success(result)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard poster, let url = request.url, KinopoiskClient.posterURL(url.absoluteString) == url else { completionHandler(nil); return }
        var safe = request; safe.setValue(nil, forHTTPHeaderField: "X-API-KEY")
        completionHandler(safe)
    }
}
