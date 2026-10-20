import Foundation

/// Запуск внешнего процесса с построчным чтением stdout и поддержкой отмены через Task.
enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String

        /// Последние строки stderr — для сообщения об ошибке.
        var stderrTail: String {
            stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
        }
    }

    private final class Buffers: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var pending = Data()
        private let collectStdout: Bool
        private let onLine: ((String) -> Void)?

        init(collectStdout: Bool, onLine: ((String) -> Void)?) {
            self.collectStdout = collectStdout
            self.onLine = onLine
        }

        func appendStdout(_ data: Data) {
            var lines: [String] = []
            lock.lock()
            if collectStdout { stdout.append(data) }
            if onLine != nil {
                pending.append(data)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[pending.startIndex..<nl]
                    lines.append(String(decoding: lineData, as: UTF8.self))
                    pending.removeSubrange(pending.startIndex...nl)
                }
            }
            lock.unlock()
            lines.forEach { onLine?($0) }
        }

        func appendStderr(_ data: Data) {
            lock.lock()
            stderr.append(data)
            if stderr.count > 64 * 1024 { stderr = stderr.suffix(32 * 1024) }
            lock.unlock()
        }

        func result(status: Int32) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return Result(
                status: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        onStdoutLine: ((String) -> Void)? = nil
    ) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffers = Buffers(collectStdout: onStdoutLine == nil, onLine: onStdoutLine)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffers.appendStdout(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffers.appendStderr(data) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !restOut.isEmpty { buffers.appendStdout(restOut) }
                    let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if !restErr.isEmpty { buffers.appendStderr(restErr) }
                    continuation.resume(returning: buffers.result(status: p.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
