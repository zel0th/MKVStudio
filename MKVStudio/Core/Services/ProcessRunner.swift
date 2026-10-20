import Foundation

struct ProcessExecutionResult: Sendable {
    var output: String
    var exitCode: Int32
}

/// Owns one child process. Cancellation can race safely with launch.
final class ProcessToken: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        self.process = process
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
    var processIdentifier: Int32? { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true ? process?.processIdentifier : nil }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum ProcessRunner {
    static func run(executable: URL, arguments: [String], token: ProcessToken = ProcessToken(), outputLimit: Int = 32 * 1024 * 1024, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ProcessExecutionResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    var env = ProcessInfo.processInfo.environment
                    env["LC_ALL"] = "en_US.UTF-8"; env["LANG"] = "en_US.UTF-8"
                    process.environment = env
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                    do {
                        try token.launch(process)
                        // One merged pipe, drained continuously off the main thread.
                        try? pipe.fileHandleForWriting.close()
                        var data = Data()
                        var pending = Data()
                        var truncated = false
                        let limit = max(1024, outputLimit)
                        while true {
                            let chunk = pipe.fileHandleForReading.availableData
                            if chunk.isEmpty { break }
                            data.append(chunk)
                            if data.count > limit { truncated = true }
                            // Compact in batches, avoiding a copy of the entire capture for each pipe read.
                            if data.count > limit * 2 { data = Data(data.suffix(limit)) }
                            pending.append(chunk)
                            while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                                let line = String(decoding: pending[..<end], as: UTF8.self)
                                pending.removeSubrange(...end)
                                if !line.isEmpty { onLine(line) }
                            }
                            // Bound partial lines too, including malformed or newline-free output.
                            if pending.count > 65536 {
                                onLine(String(decoding: pending.prefix(65536), as: UTF8.self))
                                pending = Data(pending.dropFirst(65536))
                            }
                        }
                        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                        process.waitUntilExit()
                        try? pipe.fileHandleForReading.close()
                        if token.isCancelled { throw CancellationError() }
                        continuation.resume(returning: ProcessExecutionResult(output: (truncated ? "[Ранний вывод сокращён]\n" : "") + String(decoding: data.suffix(limit), as: UTF8.self), exitCode: process.terminationStatus))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { token.cancel() }
    }
}

/// One bounded mailbox instead of an unbounded MainActor task for every log line.
final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var bytes = 0
    private var progress: String?
    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if line.hasPrefix("#GUI#progress ") { progress = line; return }
        let clipped = String(line.suffix(16_384))
        lines.append(clipped); bytes += clipped.utf8.count
        while bytes > 100_000, !lines.isEmpty { bytes -= lines.removeFirst().utf8.count }
    }
    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let result = lines + [progress].compactMap { $0 }
        lines.removeAll(keepingCapacity: true); bytes = 0; progress = nil
        return result
    }
}
