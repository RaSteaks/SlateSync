import Darwin
import Foundation
import SlateSyncDomain

/// A single actor owns Process, all pipe ends and byte buffers. Nonblocking
/// reads/writes drain both output streams while sending large Base64 requests;
/// no FileHandle callbacks, reader tasks or unsafe Sendable wrappers escape it.
public actor ManagedOCRProcess: OCRProcessTransport {
    private let launch: OCRProcessLaunch
    private let clock: any OCRClock
    private var child: Process?
    private var input: Pipe?, output: Pipe?, errorOutput: Pipe?
    private var remainder = Data()
    private var stderrTail = Data()
    private var closing = false
    private var busy = false
    private var teardown: Task<Void, Never>?
    public init(launch: OCRProcessLaunch, clock: any OCRClock = SystemOCRClock()) { self.launch = launch; self.clock = clock }

    public func exchange(_ request: Data, requestID: String?, oneShot: Bool, deadline: OCRDeadline, operation: MediaOperation, progress: MediaProgressSink?) async throws -> Data {
        guard !closing, !busy else { throw MediaFailure.closed }
        busy = true
        defer { busy = false }
        do {
            try deadline.check(clock: clock, operation: operation)
            if child == nil { try start() }
            guard let child, let input, let output, let errorOutput else { throw MediaFailure.closed }
            var sent = 0, stdoutBytes = remainder.count
            var final: Data?, eof = false, inputClosed = false
            while true {
                try deadline.check(clock: clock, operation: operation)
                guard !closing else { throw MediaFailure.closed }
                if sent < request.count {
                    let written = request.withUnsafeBytes { bytes in
                        Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress?.advanced(by: sent), min(64 * 1024, request.count - sent))
                    }
                    if written > 0 { sent += written }
                    else if written < 0, ![EAGAIN,EWOULDBLOCK,EINTR].contains(errno) {
                        // 请求可达数十 MB，而单次写入仅 64KB：子进程在读取中途
                        // 死亡时大概率先命中 EPIPE 而不是退出检测。这里按子进程
                        // 是否已退出分类，让监督者的 one-shot 恢复白名单能接管
                        // 进程退出故障，而不是把它当作不可恢复的协议错误。
                        throw classifyPipeFailure()
                    }
                }
                if oneShot, sent == request.count, !inputClosed { try input.fileHandleForWriting.close(); inputClosed = true }
                // Bound each drain batch as well as retained data. A noisy child
                // cannot starve deadline/cancellation checks or the other stream.
                let stdout = try drain(output.fileHandleForReading.fileDescriptor)
                eof = eof || stdout.eof
                stdoutBytes += stdout.bytes.count
                guard stdoutBytes <= 32 * 1024 * 1024 else { throw MediaFailure.protocolError }
                remainder.append(stdout.bytes)
                let stderr = try drain(errorOutput.fileHandleForReading.fileDescriptor)
                stderrTail.append(stderr.bytes)
                if stderrTail.count > 128 * 1024 { stderrTail = Data(stderrTail.suffix(128 * 1024)) }
                while let end = remainder.firstIndex(of: 10) {
                    let line = Data(remainder[..<end]); remainder.removeSubrange(...end)
                    try consume(line, requestID: requestID, final: &final, operation: operation, progress: progress)
                }
                if eof, !remainder.isEmpty {
                    let line = remainder; remainder.removeAll(keepingCapacity: false)
                    try consume(line, requestID: requestID, final: &final, operation: operation, progress: progress)
                }
                if !child.isRunning {
                    // Drain again after observing exit, so the final bytes and
                    // exit status both precede completion. No success on nonzero.
                    if !eof { continue }
                    guard child.terminationStatus == 0, let final else {
                        // stderr 尾部是唯一能说明子进程侧死因的线索，随退出
                        // 错误一并暴露（有界 + 脱敏）。
                        throw SlateSyncError(code: "OCR_PROCESS_EXIT", message: "本地 OCR 进程异常退出" + stderrDiagnostic(), retryable: true)
                    }
                    try deadline.check(clock: clock, operation: operation)
                    if oneShot { await close() }
                    return final
                }
                if let final, !oneShot {
                    try deadline.check(clock: clock, operation: operation)
                    return final
                }
                if eof { throw MediaFailure.protocolError }
                try await clock.sleep(milliseconds: 5)
            }
        } catch {
            await close()
            if operation.isCanceled || error is CancellationError { throw MediaFailure.canceled }
            throw error
        }
    }

    private func start() throws {
        let child = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = launch.executable; child.arguments = launch.arguments
        child.currentDirectoryURL = launch.directory; child.environment = launch.environment
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        do { try child.run() }
        catch {
            for handle in [input.fileHandleForReading,input.fileHandleForWriting,output.fileHandleForReading,output.fileHandleForWriting,errors.fileHandleForReading,errors.fileHandleForWriting] { try? handle.close() }
            throw SlateSyncError(code: "OCR_PROCESS_START", message: "无法启动本地 OCR 进程", retryable: true)
        }
        self.child = child; self.input = input; self.output = output; self.errorOutput = errors
        for fd in [input.fileHandleForWriting.fileDescriptor,output.fileHandleForReading.fileDescriptor,errors.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
    }
    private func drain(_ fd: Int32) throws -> (bytes: Data, eof: Bool) {
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        for _ in 0..<16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { bytes.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { return (bytes, true) }
            else if [EAGAIN,EWOULDBLOCK,EINTR].contains(errno) { return (bytes, false) }
            else { throw classifyPipeFailure() }
        }
        return (bytes, false)
    }

    /// 将管道读写故障分类为可恢复的进程退出或真正的协议错误。子进程死亡
    /// 时的 EPIPE/EIO 退出状态由 Foundation 异步收割，这里给一个有界窗口
    /// 等待 isRunning 翻转；命中退出则映射为 OCR_PROCESS_EXIT（监督者恢复
    /// 白名单成员），子进程仍存活时的错误保持协议错误，不触发恢复。
    private func classifyPipeFailure() -> SlateSyncError {
        if let child {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                usleep(5_000)
            }
            if !child.isRunning {
                return SlateSyncError(code: "OCR_PROCESS_EXIT", message: "本地 OCR 进程异常退出" + stderrDiagnostic(), retryable: true)
            }
        }
        return MediaFailure.protocolError
    }

    /// 提取子进程 stderr 尾部的有界诊断摘录。先限长、再脱敏、再截断，
    /// 确保错误通道不会携带大块日志或敏感值；无有效内容时返回空串。
    private func stderrDiagnostic() -> String {
        guard !stderrTail.isEmpty else { return "" }
        let text = String(decoding: stderrTail.suffix(2 * 1024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let redacted = StructuredLogRedactor.redactText(text)
        let excerpt = redacted.count > 500 ? String(redacted.suffix(500)) : redacted
        return "；stderr 尾部：\(excerpt)"
    }
    private func consume(_ line: Data, requestID: String?, final: inout Data?, operation: MediaOperation, progress: MediaProgressSink?) throws {
        let marker = Data("__SLATESYNC_OCR_JSON__".utf8), progressMarker = Data("__SLATESYNC_OCR_PROGRESS__".utf8)
        if line.starts(with: marker) {
            guard final == nil else { throw MediaFailure.protocolError }
            let data = Data(line.dropFirst(marker.count))
            guard let value = try? JSONDecoder().decode(WireHeader.self, from: data), value.requestId == requestID else { throw MediaFailure.protocolError }
            final = data
        } else if line.starts(with: progressMarker), !operation.isCanceled {
            if let value = try? JSONDecoder().decode(WireProgress.self, from: line.dropFirst(progressMarker.count)), value.requestId == requestID {
                progress?(.init(stage: value.stage, completed: value.completedViews ?? 0, total: value.totalViews ?? 0))
            }
        }
        // Non-sentinel library logs are discarded, never surfaced with secrets.
    }
    public func close() async {
        if let teardown { await teardown.value; return }
        closing = true
        // The independent teardown task is not canceled with its requester.
        // All callers await the same TERM -> 1000ms -> KILL -> exit sequence.
        let task = Task { await self.terminateOwnedProcess() }
        teardown = task
        await task.value
    }
    private func terminateOwnedProcess() async {
        if let child {
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGTERM) }
            let grace = ProcessInfo.processInfo.systemUptime + 1
            while child.isRunning {
                if ProcessInfo.processInfo.systemUptime >= grace { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                try? await Task.sleep(for: .milliseconds(5))
            }
            // Foundation has already observed termination when isRunning
            // becomes false. A second synchronous waitUntilExit on a Swift
            // executor thread can stall its private run loop after that event
            // was delivered elsewhere. Keep cleanup entirely asynchronous.
        }
        for pipe in [input,output,errorOutput].compactMap({ $0 }) {
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
        }
        input = nil; output = nil; errorOutput = nil; child = nil
        remainder.removeAll(); stderrTail.removeAll()
    }
}

struct WireHeader: Decodable { let requestId: String?; let ok: Bool }
private struct WireProgress: Decodable { let requestId: String?; let stage: String; let completedViews: Int?; let totalViews: Int? }
