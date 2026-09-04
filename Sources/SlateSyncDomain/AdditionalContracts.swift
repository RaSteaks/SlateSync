import Foundation

public struct SaveFileRequest: Codable, Hashable, Sendable {
    public let defaultFilename: String
    public let data: Data

    public init(defaultFilename: String, data: Data) {
        self.defaultFilename = defaultFilename
        self.data = data
    }
}

public struct ScanSlateDirectoryRequest: Codable, Hashable, Sendable {
    public let dirPath: String
    public let expectedKeys: [String]
    public let maxDepth: Int?

    public init(dirPath: String, expectedKeys: [String], maxDepth: Int? = nil) {
        self.dirPath = dirPath
        self.expectedKeys = expectedKeys
        self.maxDepth = maxDepth
    }
}

public struct OcrSettingsRequest: Codable, Hashable, Sendable {
    public let pythonPath: String?
    public let skip: Bool?

    public init(pythonPath: String? = nil, skip: Bool? = nil) {
        self.pythonPath = pythonPath
        self.skip = skip
    }
}

public struct OcrCheckRequest: Codable, Hashable, Sendable {
    public let pythonPath: String

    public init(pythonPath: String) {
        self.pythonPath = pythonPath
    }
}

public struct OcrSettings: Codable, Hashable, Sendable {
    public let pythonPath: String
    public let setupCompleted: Bool
    public let setupSkipped: Bool

    public init(pythonPath: String = "", setupCompleted: Bool = false, setupSkipped: Bool = false) {
        self.pythonPath = pythonPath
        self.setupCompleted = setupCompleted
        self.setupSkipped = setupSkipped
    }
}

public enum PaddleOcrInstallStage: String, Codable, Hashable, Sendable {
    case detectPython = "detect-python"
    case createEnvironment = "create-environment"
    case installDependencies = "install-dependencies"
    case verify
    case completed
}

public struct PaddleOcrInstallProgress: Codable, Hashable, Sendable {
    public let stage: PaddleOcrInstallStage
    public let percent: Double
    public let message: String

    public init(stage: PaddleOcrInstallStage, percent: Double, message: String) {
        self.stage = stage
        self.percent = percent
        self.message = message
    }
}

public struct PaddleOcrInstallResult: Codable, Hashable, Sendable {
    public let pythonPath: String
    public let setupCompleted: Bool
    public let setupSkipped: Bool
    public let paddleVersion: String
    public let paddleOcrVersion: String

    public init(pythonPath: String, setupCompleted: Bool, setupSkipped: Bool, paddleVersion: String, paddleOcrVersion: String) {
        self.pythonPath = pythonPath
        self.setupCompleted = setupCompleted
        self.setupSkipped = setupSkipped
        self.paddleVersion = paddleVersion
        self.paddleOcrVersion = paddleOcrVersion
    }
}

public struct OcrCheckError: Codable, Hashable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// The Swift enum preserves the TypeScript `ok` union while making impossible
/// combinations unrepresentable. Its compatibility initializer is throwing so
/// native callers cannot accidentally emit fields from the opposite branch.
public enum OcrCheckResult: Codable, Hashable, Sendable {
    case success(paddleVersion: String, paddleOcrVersion: String)
    case failure(error: OcrCheckError)

    public init(
        ok: Bool,
        paddleVersion: String? = nil,
        paddleOcrVersion: String? = nil,
        error: OcrCheckError? = nil
    ) throws {
        if ok {
            guard let paddleVersion, let paddleOcrVersion, error == nil else {
                throw DiscriminatedResultSupport.initializationError("OCR 检查成功结果字段无效")
            }
            self = .success(paddleVersion: paddleVersion, paddleOcrVersion: paddleOcrVersion)
        } else {
            guard paddleVersion == nil, paddleOcrVersion == nil, let error else {
                throw DiscriminatedResultSupport.initializationError("OCR 检查失败结果字段无效")
            }
            self = .failure(error: error)
        }
    }

    public var ok: Bool {
        if case .success = self { return true }
        return false
    }

    public var paddleVersion: String? {
        guard case .success(let value, _) = self else { return nil }
        return value
    }

    public var paddleOcrVersion: String? {
        guard case .success(_, let value) = self else { return nil }
        return value
    }

    public var error: OcrCheckError? {
        guard case .failure(let value) = self else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case paddleVersion
        case paddleOcrVersion
        case error
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try values.decode(Bool.self, forKey: .ok)
        if ok {
            guard values.contains(.paddleVersion),
                  values.contains(.paddleOcrVersion),
                  !values.contains(.error) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "OCR 检查成功结果包含非法分支字段")
            }
            self = .success(
                paddleVersion: try values.decode(String.self, forKey: .paddleVersion),
                paddleOcrVersion: try values.decode(String.self, forKey: .paddleOcrVersion)
            )
        } else {
            guard !values.contains(.paddleVersion),
                  !values.contains(.paddleOcrVersion),
                  values.contains(.error) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "OCR 检查失败结果包含非法分支字段")
            }
            self = .failure(error: try values.decode(OcrCheckError.self, forKey: .error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let paddleVersion, let paddleOcrVersion):
            try values.encode(true, forKey: .ok)
            try values.encode(paddleVersion, forKey: .paddleVersion)
            try values.encode(paddleOcrVersion, forKey: .paddleOcrVersion)
        case .failure(let error):
            try values.encode(false, forKey: .ok)
            try values.encode(error, forKey: .error)
        }
    }
}

public enum VisionOcrCheckResult: Codable, Hashable, Sendable {
    case success(engine: String, modelVersion: String, systemVersion: String)
    case failure(error: OcrCheckError)

    public init(
        ok: Bool,
        engine: String? = nil,
        modelVersion: String? = nil,
        systemVersion: String? = nil,
        error: OcrCheckError? = nil
    ) throws {
        if ok {
            guard let engine, let modelVersion, let systemVersion, error == nil else {
                throw DiscriminatedResultSupport.initializationError("Vision OCR 成功结果字段无效")
            }
            self = .success(engine: engine, modelVersion: modelVersion, systemVersion: systemVersion)
        } else {
            guard engine == nil, modelVersion == nil, systemVersion == nil, let error else {
                throw DiscriminatedResultSupport.initializationError("Vision OCR 失败结果字段无效")
            }
            self = .failure(error: error)
        }
    }

    public var ok: Bool {
        if case .success = self { return true }
        return false
    }

    public var engine: String? {
        guard case .success(let value, _, _) = self else { return nil }
        return value
    }

    public var modelVersion: String? {
        guard case .success(_, let value, _) = self else { return nil }
        return value
    }

    public var systemVersion: String? {
        guard case .success(_, _, let value) = self else { return nil }
        return value
    }

    public var error: OcrCheckError? {
        guard case .failure(let value) = self else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case engine
        case modelVersion
        case systemVersion
        case error
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try values.decode(Bool.self, forKey: .ok)
        if ok {
            guard values.contains(.engine),
                  values.contains(.modelVersion),
                  values.contains(.systemVersion),
                  !values.contains(.error) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "Vision OCR 成功结果包含非法分支字段")
            }
            self = .success(
                engine: try values.decode(String.self, forKey: .engine),
                modelVersion: try values.decode(String.self, forKey: .modelVersion),
                systemVersion: try values.decode(String.self, forKey: .systemVersion)
            )
        } else {
            guard !values.contains(.engine),
                  !values.contains(.modelVersion),
                  !values.contains(.systemVersion),
                  values.contains(.error) else {
                throw DiscriminatedResultSupport.decodingError(decoder, "Vision OCR 失败结果包含非法分支字段")
            }
            self = .failure(error: try values.decode(OcrCheckError.self, forKey: .error))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let engine, let modelVersion, let systemVersion):
            try values.encode(true, forKey: .ok)
            try values.encode(engine, forKey: .engine)
            try values.encode(modelVersion, forKey: .modelVersion)
            try values.encode(systemVersion, forKey: .systemVersion)
        case .failure(let error):
            try values.encode(false, forKey: .ok)
            try values.encode(error, forKey: .error)
        }
    }
}

public struct JsonSchemaCapabilityResult: Codable, Hashable, Sendable {
    public let supported: Bool
    public let model: String
    public let transport: ProviderTransport
    public let status: Int?
    public let checkedAt: String
    public let message: String

    public init(supported: Bool, model: String, transport: ProviderTransport, status: Int? = nil, checkedAt: String, message: String) {
        self.supported = supported
        self.model = model
        self.transport = transport
        self.status = status
        self.checkedAt = checkedAt
        self.message = message
    }
}

public struct ModelProbeRequest: Codable, Hashable, Sendable {
    public let providerId: String
    public let modelIds: [String]?

    public init(providerId: String, modelIds: [String]? = nil) {
        self.providerId = providerId
        self.modelIds = modelIds
    }
}

public struct ModelProbeProgress: Codable, Hashable, Sendable {
    public let providerId: String
    public let revision: Int?
    public let model: String
    public let completed: Int
    public let total: Int
    public let percent: Double
    public let result: ModelCapabilityProbeResult?

    public init(providerId: String, revision: Int? = nil, model: String, completed: Int, total: Int, percent: Double, result: ModelCapabilityProbeResult? = nil) {
        self.providerId = providerId
        self.revision = revision
        self.model = model
        self.completed = completed
        self.total = total
        self.percent = percent
        self.result = result
    }
}

public struct ModelCapabilityProbeResult: Codable, Hashable, Sendable {
    public let supported: Bool
    public let model: String
    public let transport: ProviderTransport
    public let status: Int?
    public let checkedAt: String
    public let message: String
    public let capabilityStatus: ModelCapabilityStatus

    public init(supported: Bool, model: String, transport: ProviderTransport, status: Int? = nil, checkedAt: String, message: String, capabilityStatus: ModelCapabilityStatus) {
        self.supported = supported
        self.model = model
        self.transport = transport
        self.status = status
        self.checkedAt = checkedAt
        self.message = message
        self.capabilityStatus = capabilityStatus
    }
}

public struct ModelProbeResult: Codable, Hashable, Sendable {
    public let canceled: Bool
    public let revision: Int?
    public let results: [ModelCapabilityProbeResult]
    public let completed: Int
    public let total: Int

    public init(canceled: Bool, revision: Int? = nil, results: [ModelCapabilityProbeResult], completed: Int, total: Int) {
        self.canceled = canceled
        self.revision = revision
        self.results = results
        self.completed = completed
        self.total = total
    }
}
