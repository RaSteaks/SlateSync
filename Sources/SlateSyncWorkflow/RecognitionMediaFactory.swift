import Foundation
import SlateSyncDomain
import SlateSyncMedia
import SlateSyncPersistence

/// Shared native/headless composition. Both entrypoints use the same OCR
/// selection, runner resolution and lifecycle; only task persistence differs.
public enum RecognitionMediaFactory {
    public static func make(runtime: SlateSyncRuntime, values: GlobalSettingValues,
        resources: OCRRuntimePaths.Resources? = nil
    ) async throws -> RecognitionCoordinator.MediaFactory {
        let probe = VisionOCRService(configuration: VisionOCRConfiguration(values))
        let visionAvailable = await probe.isAvailable()
        await probe.close()
        let paths = try paddlePaths(runtime: runtime, values: values, resources: resources ?? paddleResources())
        let paddleAvailable = paths.map { (try? $0.validate()) != nil } ?? false
        return {
            let vision = VisionOCRService(configuration: VisionOCRConfiguration(values))
            let paddle = paths.map { PaddleOCRService(configuration: PaddleOCRConfiguration(values), paths: $0) }
            return MediaOCRWorkflow(ocr: LocalOCRService(vision: vision, paddle: paddle, settings: values,
                visionAvailable: visionAvailable, paddleAvailable: paddleAvailable))
        }
    }

    private static func paddlePaths(runtime: SlateSyncRuntime, values: GlobalSettingValues,
        resources: OCRRuntimePaths.Resources
    ) throws -> OCRRuntimePaths? {
        let python = values[.paddleOCRPython]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !python.isEmpty else { return nil }
        let work = runtime.locator.url.appending(path: "paddle-runtime", directoryHint: .isDirectory)
        let cache = runtime.locator.url.appending(path: "paddle-models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return try OCRRuntimePaths(resources: resources, python: URL(fileURLWithPath: python),
            workingDirectory: work, modelCache: cache, environment: ProcessInfo.processInfo.environment)
    }

    /// Diagnostics and inference resolve the same trusted runner resources.
    public static func paddleResources() -> OCRRuntimePaths.Resources {
        if let root = Bundle.main.resourceURL?.appending(path: "PaddleOCR", directoryHint: .isDirectory),
           FileManager.default.isReadableFile(atPath: root.appending(path: "paddleocr_runner.py").path) {
            return .bundle(root)
        }
        return .development(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }
}
