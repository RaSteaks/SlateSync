import Foundation
import SlateSyncDomain
import SlateSyncMedia

/// Bounded, credential-free subprocess probes. Imports verify binary loading;
/// no OCR instance is constructed, so checking never downloads model weights.
public struct OCREnvironmentChecker: Sendable {
    private let runner: any PaddleInstallerCommandRunning
    public init(runner: any PaddleInstallerCommandRunning = ProcessPaddleInstallerCommandRunner()) {
        self.runner = runner
    }

    public func check(values: GlobalSettingValues, directory: URL, runnerURL: URL,
                      environment: [String: String]) async throws -> [OCREnvironmentCheck] {
        let visionConfig = VisionOCRConfiguration(values)
        // Match the recognition facade: relative custom Vision binaries have
        // no implicit base and must not be reported usable by diagnostics.
        let vision = VisionOCRService(configuration: visionConfig)
        let available = await vision.isAvailable()
        await vision.close()
        var checks: [OCREnvironmentCheck] = [
            .init(id: "vision", title: "Vision OCR", status: available ? .passed : .failed,
                  detail: available ? "Vision 环境可用；无需 Python。" : "Vision 不可用，请检查识别语言、识别级别或自定义程序路径。"),
            .init(id: "runner", title: "Paddle OCR 运行脚本",
                  status: FileManager.default.isReadableFile(atPath: runnerURL.path) ? .passed : .failed,
                  detail: runnerURL.path)
        ]
        let configured = values[.paddleOCRPython]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let childEnvironment = OCRChildEnvironment.make(environment, modelCache: directory.appending(path: "paddle-models"))
        // An explicit path must never silently fall back to another Python.
        let candidates = configured.isEmpty
            ? ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/env"] + Self.frameworkPythons() : [configured]
        var python: URL?
        var prefix: [String] = []
        var unsupportedPython: PythonInfo?
        for path in candidates {
            try Task.checkCancellation()
            let executable = URL(fileURLWithPath: path)
            let arguments = path == "/usr/bin/env" && configured.isEmpty ? ["python3"] : []
            do {
                let output = try await runner.run(executable: executable, arguments: arguments + ["-c", Self.pythonScript],
                                                  directory: directory, environment: childEnvironment, timeout: .seconds(10))
                let info = try JSONDecoder().decode(PythonInfo.self, from: Data(output.stdout.utf8))
                guard info.supported else {
                    unsupportedPython = info
                    if configured.isEmpty { continue }
                    break
                }
                python = executable; prefix = arguments
                checks.append(.init(id: "python", title: "Python", status: .passed,
                                    detail: "\(info.version) · \(info.architecture)\n\(info.executable)"))
                break
            } catch {
                try Task.checkCancellation()
                // Do not expose arbitrary child output or environment values.
                continue
            }
        }
        guard let python else {
            if let info = unsupportedPython {
                checks.append(.init(id: "python", title: "Python", status: .failed,
                                    detail: "\(info.version) · \(info.architecture)\n\(info.executable)"))
                checks.append(.init(id: "pythonRequirement", title: "Python 3.10+", status: .failed,
                                    detail: "需要 Python 3.10 或更高版本。"))
            } else {
                checks.append(.init(id: "python", title: "Python", status: .failed,
                                    detail: "未找到可运行的 Python 3.10+，请检查 Python 路径或先安装 Python。"))
            }
            return checks
        }
        if configured.isEmpty {
            checks.append(.init(id: "configuration", title: "Paddle OCR 配置", status: .warning,
                                detail: "当前未配置 OCR Python 路径；以下检测使用本机 Python。请填写路径并保存，或安装 PaddleOCR。"))
        }
        do {
            let output = try await runner.run(executable: python, arguments: prefix + ["-c", Self.dependenciesScript],
                                              directory: directory, environment: childEnvironment, timeout: .seconds(45))
            let dependencies = try JSONDecoder().decode([Dependency].self, from: Data(output.stdout.utf8))
            guard dependencies.map(\.name) == ["paddle", "paddleocr", "cv2", "numpy", "pip", "venv"] else {
                throw SlateSyncError(code: "OCR_CHECK_RESPONSE", message: "OCR 环境检测返回无效结果")
            }
            checks += dependencies.map { dependency in
                let optional = ["pip", "venv"].contains(dependency.name)
                return .init(id: dependency.name, title: dependency.name,
                             status: dependency.available ? .passed : (optional ? .warning : .failed),
                             detail: dependency.available ? dependency.version : (optional
                                ? "安装工具不可用；不影响已有 OCR 环境识别。"
                                : "依赖缺失或无法加载，请安装或重新安装 PaddleOCR。"))
            }
        } catch {
            try Task.checkCancellation()
            checks.append(.init(id: "dependencies", title: "Paddle OCR 依赖", status: .failed,
                                detail: "依赖检测失败或超时，请检查 Python 环境，或重新安装 PaddleOCR。"))
        }
        return checks
    }

    /// Finder-launched apps often lack python.org's framework bin directory
    /// in PATH. Inspect only this standard install root, never user venvs.
    private static func frameworkPythons() -> [String] {
        let root = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions")
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.split(separator: ".").allSatisfy { Int($0) != nil } }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appending(path: "bin/python3").path }
    }

    private struct PythonInfo: Decodable {
        let supported: Bool
        let version: String
        let executable: String
        let architecture: String
    }
    private struct Dependency: Decodable {
        let name: String
        let available: Bool
        let version: String
    }

    // JSON is the only accepted stdout. Library initialization output remains
    // in the runner's bounded stderr buffer and never enters settings state.
    private static let pythonScript = """
    import json, sys, platform
    print(json.dumps(dict(supported=sys.version_info >= (3, 10), version=platform.python_version(), executable=sys.executable, architecture=platform.machine())))
    """
    private static let dependenciesScript = """
    import contextlib, importlib, importlib.metadata, json, re, sys
    results = []
    for name, distribution in [('paddle', 'paddlepaddle'), ('paddleocr', 'paddleocr'), ('cv2', 'opencv-python'), ('numpy', 'numpy'), ('pip', 'pip'), ('venv', '')]:
        try:
            with contextlib.redirect_stdout(sys.stderr):
                module = importlib.import_module(name)
                if name == 'paddleocr':
                    getattr(module, 'PaddleOCR')
                version = str(getattr(module, '__version__', ''))
                if not version and distribution:
                    version = importlib.metadata.version(distribution)
            version = version if re.fullmatch(r'[a-zA-Z0-9.+_-]{1,80}', version) else 'OK'
            results.append(dict(name=name, available=True, version=version))
        except Exception:
            results.append(dict(name=name, available=False, version=''))
    print(json.dumps(results))
    """
}
