import Darwin
import Foundation
import SlateSyncDomain

public struct PaddleInstallerCommandResult: Sendable {
    public let stdout: String
    public let stderr: String
    public init(stdout: String = "", stderr: String = "") {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol PaddleInstallerCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        timeout: Duration
    ) async throws -> PaddleInstallerCommandResult
    func cancel() async
}

/// Single-flight Paddle environment installer. Only the checked-in pinned
/// requirements file is accepted, every child receives a credential-free
/// environment, and cancellation is delegated to the TERM→2s→KILL runner.
public actor PaddleOCRInstallerService {
    public static let paddleVersion = "3.3.1"
    public static let paddleOCRVersion = "3.7.0"
    public static let commandTimeout: Duration = .seconds(30 * 60)

    private let userDataRoot: URL
    private let requirementsURL: URL
    private let runner: any PaddleInstallerCommandRunning
    private var installing = false
    private var cancelRequested = false

    public init(
        userDataRoot: URL,
        requirementsURL: URL,
        runner: any PaddleInstallerCommandRunning = ProcessPaddleInstallerCommandRunner()
    ) {
        self.userDataRoot = userDataRoot.standardizedFileURL
        self.requirementsURL = requirementsURL.standardizedFileURL
        self.runner = runner
    }

    public func install(
        progress: @escaping @Sendable (PaddleOcrInstallProgress) -> Void
    ) async throws -> PaddleOcrInstallResult {
        guard !installing else {
            throw SlateSyncError(code: "PADDLEOCR_INSTALL_BUSY", message: "PaddleOCR 安装正在进行中")
        }
        installing = true
        cancelRequested = false
        defer { installing = false }

        try validateRequirements()
        let venv = userDataRoot.appending(path: "paddleocr-venv", directoryHint: .isDirectory)
        let installHome = userDataRoot.appending(path: "paddle-install-home", directoryHint: .isDirectory)
        try validateInstallPath(installHome)
        try FileManager.default.createDirectory(at: userDataRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installHome, withIntermediateDirectories: true)
        try validateInstallPath(installHome)
        let environment = sanitizedEnvironment(home: installHome)

        emit(.detectPython, 5, "正在检查本机 Python 环境…", progress)
        let python = try await detectPython(environment: environment)
        try checkCanceled()
        // Keep environment probing non-destructive for an existing venv; its
        // complete path audit still happens before the first venv mutation.
        try validateInstallPath(venv)

        emit(.createEnvironment, 20, "已找到 Python，正在创建独立运行环境…", progress)
        _ = try await command(python.executable, python.prefix + ["-m", "venv", "--copies", venv.path], environment)
        try validateInstallPath(venv)
        let installedPython = venv.appending(path: "bin/python")

        emit(.installDependencies, 35, "正在安装 PaddleOCR 固定版本依赖…", progress)
        _ = try await command(installedPython, ["-m", "pip", "install", "--upgrade", "pip"], environment)
        _ = try await command(
            installedPython,
            ["-m", "pip", "install", "--disable-pip-version-check", "--no-input", "-r", requirementsURL.path],
            environment
        )

        emit(.verify, 90, "依赖已安装，正在验证 PaddleOCR…", progress)
        let verified = try await command(
            installedPython,
            ["-c", "import paddle,paddleocr;print(paddle.__version__+'\\t'+paddleocr.__version__)"],
            environment
        )
        let versions = verified.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard versions.count == 2,
              versions[0] == Substring(Self.paddleVersion),
              versions[1] == Substring(Self.paddleOCRVersion) else {
            throw SlateSyncError(code: "PADDLEOCR_VERIFY_FAILED", message: "PaddleOCR 验证版本与固定依赖不一致")
        }
        try checkCanceled()
        emit(.completed, 100, "PaddleOCR 已安装并验证通过。", progress)
        return PaddleOcrInstallResult(
            pythonPath: installedPython.path,
            setupCompleted: true,
            setupSkipped: false,
            paddleVersion: String(versions[0]),
            paddleOcrVersion: String(versions[1])
        )
    }

    public func cancel() async {
        guard installing else { return }
        cancelRequested = true
        await runner.cancel()
    }

    /// Application termination must not merely signal the child process; it
    /// waits until the install call observes TERM/KILL and leaves single-flight
    /// state before the lifecycle owner replies to AppKit.
    public func cancelAndDrain() async {
        await cancel()
        while installing {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct PythonCommand { let executable: URL; let prefix: [String] }

    private func detectPython(environment: [String: String]) async throws -> PythonCommand {
        let candidates = [
            PythonCommand(executable: URL(fileURLWithPath: "/opt/homebrew/bin/python3"), prefix: []),
            PythonCommand(executable: URL(fileURLWithPath: "/usr/local/bin/python3"), prefix: []),
            PythonCommand(executable: URL(fileURLWithPath: "/usr/bin/env"), prefix: ["python3"]),
        ]
        for candidate in candidates {
            do {
                let result = try await command(candidate.executable, candidate.prefix + ["--version"], environment)
                let version = result.stdout + " " + result.stderr
                if Self.isSupportedPython(version) { return candidate }
            } catch {
                if cancelRequested { throw canceledError() }
            }
        }
        throw SlateSyncError(code: "PADDLEOCR_PYTHON_MISSING", message: "未找到 Python 3.10 或更高版本")
    }

    private func command(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]
    ) async throws -> PaddleInstallerCommandResult {
        try checkCanceled()
        do {
            let result = try await runner.run(
                executable: executable,
                arguments: arguments,
                directory: requirementsURL.deletingLastPathComponent(),
                environment: environment,
                timeout: Self.commandTimeout
            )
            try checkCanceled()
            return result
        } catch let error as SlateSyncError {
            if cancelRequested { throw canceledError() }
            // Timeout and runner-defined stable codes remain observable to the
            // settings recovery UI; child stderr is intentionally discarded.
            throw error
        } catch {
            if cancelRequested { throw canceledError() }
            throw SlateSyncError(code: "PADDLEOCR_INSTALL_COMMAND_FAILED", message: "PaddleOCR 安装命令失败", retryable: true)
        }
    }

    private func validateRequirements() throws {
        var status = stat()
        guard lstat(requirementsURL.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw SlateSyncError(code: "PADDLEOCR_REQUIREMENTS_MISSING", message: "安装包缺少可信的固定依赖清单")
        }
        let data = try Data(contentsOf: requirementsURL, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8),
              text.split(whereSeparator: \.isNewline).map(String.init).filter({ !$0.hasPrefix("#") }) == [
                "paddlepaddle==\(Self.paddleVersion)", "paddleocr==\(Self.paddleOCRVersion)"
              ] else {
            throw SlateSyncError(code: "PADDLEOCR_REQUIREMENTS_MISSING", message: "安装包缺少 PaddleOCR 固定依赖清单")
        }
    }

    private func validateInstallPath(_ venv: URL) throws {
        let root = userDataRoot.resolvingSymlinksInPath().path + "/"
        guard venv.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" == root else {
            throw SlateSyncError(code: "PADDLEOCR_INSTALL_PATH_INVALID", message: "PaddleOCR 安装路径越界")
        }
        var status = stat()
        if lstat(venv.path, &status) == 0,
           (status.st_mode & S_IFMT) == S_IFLNK || (status.st_mode & S_IFMT) != S_IFDIR {
            throw SlateSyncError(code: "PADDLEOCR_INSTALL_PATH_INVALID", message: "PaddleOCR 安装目录被文件或符号链接占用")
        }
        // Reinstall may encounter a previously created environment. Checking
        // only its top directory allows bin/lib descendants to redirect venv
        // creation or pip outside the managed root. --copies keeps Python
        // itself local; any existing escaping descendant is rejected first.
        if let children = FileManager.default.enumerator(at: venv, includingPropertiesForKeys: nil) {
            for case let child as URL in children {
                var childStatus = stat()
                guard lstat(child.path, &childStatus) == 0 else { throw invalidPath() }
                if (childStatus.st_mode & S_IFMT) == S_IFLNK {
                    children.skipDescendants()
                    guard child.resolvingSymlinksInPath().path.hasPrefix(venv.resolvingSymlinksInPath().path + "/") else {
                        throw invalidPath()
                    }
                }
            }
        }
    }

    private func invalidPath() -> SlateSyncError {
        .init(code: "PADDLEOCR_INSTALL_PATH_INVALID", message: "PaddleOCR 安装目录包含越界链接")
    }

    private func sanitizedEnvironment(home: URL) -> [String: String] {
        let allowed = ["PATH", "TMPDIR", "LANG", "LC_ALL", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"]
        var result = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        // HOME and pip configuration are redirected into the managed install
        // area so user-level config, netrc and package-index credentials cannot
        // enter the child. Proxies remain useful only without URL userinfo.
        for key in ["HTTPS_PROXY", "HTTP_PROXY"] {
            if let raw = result[key],
               let components = URLComponents(string: raw),
               components.user != nil || components.password != nil {
                result[key] = nil
            }
        }
        result["HOME"] = home.path
        result["XDG_CONFIG_HOME"] = home.appending(path: ".config", directoryHint: .isDirectory).path
        result["XDG_CACHE_HOME"] = home.appending(path: ".cache", directoryHint: .isDirectory).path
        result["PIP_CONFIG_FILE"] = "/dev/null"
        result["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        result["PIP_NO_INPUT"] = "1"
        result["PYTHONNOUSERSITE"] = "1"
        result["PYTHONUNBUFFERED"] = "1"
        result["PYTHONDONTWRITEBYTECODE"] = "1"
        result["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
        return result
    }

    private func checkCanceled() throws { if cancelRequested { throw canceledError() } }
    private func canceledError() -> SlateSyncError {
        SlateSyncError(code: "PADDLEOCR_INSTALL_CANCELED", message: "PaddleOCR 安装已取消，可以稍后重试")
    }
    private func emit(_ stage: PaddleOcrInstallStage, _ percent: Double, _ message: String, _ sink: @Sendable (PaddleOcrInstallProgress) -> Void) {
        sink(.init(stage: stage, percent: percent, message: message))
    }

    private nonisolated static func isSupportedPython(_ output: String) -> Bool {
        guard let match = output.firstMatch(of: /Python\s+(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2) else { return false }
        return major > 3 || (major == 3 && minor >= 10)
    }
}

/// Production Process owner. Polling yields the actor between reads, so cancel
/// can send TERM immediately and schedule KILL after the fixed two-second grace.
public actor ProcessPaddleInstallerCommandRunner: PaddleInstallerCommandRunning {
    private var process: Process?
    private var canceled = false
    private var generation = 0
    private var terminationDeadline: ContinuousClock.Instant?

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        timeout: Duration
    ) async throws -> PaddleInstallerCommandResult {
        guard process == nil else { throw SlateSyncError(code: "PADDLEOCR_INSTALL_BUSY", message: "安装命令正在运行") }
        canceled = false
        terminationDeadline = nil
        generation += 1
        let runGeneration = generation
        let child = Process(), output = Pipe(), errors = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.environment = environment
        child.standardOutput = output
        child.standardError = errors
        child.standardInput = FileHandle.nullDevice
        do { try child.run() } catch {
            close(output); close(errors)
            throw SlateSyncError(code: "PADDLEOCR_INSTALL_COMMAND_FAILED", message: "无法启动 PaddleOCR 安装命令", retryable: true)
        }
        process = child
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        for fd in [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var stdout = Data(), stderr = Data()
        defer {
            close(output); close(errors)
            if process === child { process = nil }
        }
        var timedOut = false
        while child.isRunning {
            drain(output.fileHandleForReading.fileDescriptor, into: &stdout)
            drain(errors.fileHandleForReading.fileDescriptor, into: &stderr)
            // Keep ownership until the child actually exits. Throwing as soon
            // as TERM is sent would clear `process` before the two-second KILL
            // fallback can observe and terminate a non-cooperative child.
            if !timedOut, ContinuousClock.now >= deadline {
                timedOut = true
                requestStop(child)
            }
            if Task.isCancelled, !canceled { await cancel() }
            if let terminationDeadline, ContinuousClock.now >= terminationDeadline {
                _ = Darwin.kill(child.processIdentifier, SIGKILL)
                self.terminationDeadline = nil
            }
            // This awaited sleeper is intentionally independent of caller
            // cancellation. Cleanup continues yielding until exit/reap rather
            // than throwing from sleep and losing ownership of a live child.
            await Task { try? await Task.sleep(for: .milliseconds(20)) }.value
        }
        // The poll above joins Foundation's termination observation. Avoid a
        // second synchronous run-loop wait from this cooperative executor.
        drain(output.fileHandleForReading.fileDescriptor, into: &stdout)
        drain(errors.fileHandleForReading.fileDescriptor, into: &stderr)
        if timedOut {
            throw SlateSyncError(code: "PADDLEOCR_INSTALL_TIMEOUT", message: "PaddleOCR 安装命令超时", retryable: true)
        }
        guard runGeneration == generation, !canceled else {
            throw SlateSyncError(code: "PADDLEOCR_INSTALL_CANCELED", message: "PaddleOCR 安装已取消")
        }
        guard child.terminationStatus == 0 else {
            throw SlateSyncError(code: "PADDLEOCR_INSTALL_COMMAND_FAILED", message: "PaddleOCR 安装命令异常退出", retryable: true)
        }
        return .init(
            stdout: String(decoding: stdout.suffix(32 * 1024), as: UTF8.self),
            stderr: String(decoding: stderr.suffix(32 * 1024), as: UTF8.self)
        )
    }

    public func cancel() async {
        guard let process, !canceled else { return }
        canceled = true
        requestStop(process)
    }

    private func requestStop(_ child: Process) {
        guard child.isRunning, terminationDeadline == nil else { return }
        _ = Darwin.kill(child.processIdentifier, SIGTERM)
        terminationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    }

    private func drain(_ descriptor: Int32, into data: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        // A continuously writing child must yield back to deadline/cancel
        // checks even if its output pipe never becomes temporarily empty.
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 64 * 1024 { data = Data(data.suffix(64 * 1024)) }
        }
    }

    private func close(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}
