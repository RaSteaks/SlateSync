import Foundation
import SlateSyncDomain

/// Every writable root and Python lookup base is injected. The resolver never
/// discovers a user's venv, Library or models and never writes into Resources.
public struct OCRRuntimePaths: Sendable {
    public enum Resources: Sendable { case development(URL), bundle(URL) }
    public let python: URL
    public let runner: URL
    public let workingDirectory: URL
    public let modelCache: URL
    public let environment: [String: String]
    public init(resources: Resources, python: URL, workingDirectory: URL, modelCache: URL, environment: [String: String]) throws {
        let resourceRoot: URL
        switch resources {
        case .development(let root): resourceRoot = root; runner = root.appendingPathComponent("scripts/paddleocr_runner.py")
        case .bundle(let root): resourceRoot = root; runner = root.appendingPathComponent("paddleocr_runner.py")
        }
        guard [resourceRoot, python, workingDirectory, modelCache].allSatisfy(\.isFileURL) else { throw MediaFailure.invalidInput }
        if case .bundle = resources {
            let base = resourceRoot.resolvingSymlinksInPath().path + "/"
            guard !modelCache.resolvingSymlinksInPath().path.hasPrefix(base), !workingDirectory.resolvingSymlinksInPath().path.hasPrefix(base), modelCache.resolvingSymlinksInPath() != resourceRoot.resolvingSymlinksInPath() else { throw MediaFailure.invalidInput }
        }
        self.python = python; self.workingDirectory = workingDirectory; self.modelCache = modelCache
        self.environment = OCRChildEnvironment.make(environment, modelCache: modelCache)
    }
    public func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.isReadableFile(atPath: runner.path),
              (try workingDirectory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              (try modelCache.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw MediaFailure.unavailable }
    }
    public static func resolve(_ path: String, relativeTo base: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }
}

public enum OCRChildEnvironment {
    public static func make(_ source: [String: String], modelCache: URL? = nil) -> [String: String] {
        // Runtime inference needs proxy/certificate settings but no Provider
        // credential or PIP_* mirror value. No fallback to process.environment.
        let keys = ["PATH","Path","HOME","TMPDIR","TEMP","TMP","LANG","LC_ALL","LANGUAGE","SLATESYNC_PROJECT_DIR","SLATESYNC_PACKAGED","PADDLE_PDX_CACHE_HOME","HTTPS_PROXY","HTTP_PROXY","NO_PROXY","REQUESTS_CA_BUNDLE","SSL_CERT_FILE"]
        var output = source.filter { keys.contains($0.key) }
        output["PYTHONUNBUFFERED"] = "1"
        output["PYTHONDONTWRITEBYTECODE"] = "1"
        output["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
        if let modelCache { output["PADDLE_PDX_CACHE_HOME"] = modelCache.path }
        if output["PATH"] == nil { output["PATH"] = output["Path"] }
        if output["Path"] == nil { output["Path"] = output["PATH"] }
        return output
    }
}
