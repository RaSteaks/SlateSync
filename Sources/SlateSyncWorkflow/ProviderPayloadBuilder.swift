import Foundation
import SlateSyncDomain

/// Owns provider-specific wire payloads and the ordered structured-output
/// fallback ladder. Credentials stay in the transport and never enter JSON.
public enum ProviderPayloadBuilder {
    public static func payload(_ request: RecognitionStageRequest, mode: ProviderJSONMode) throws -> Data {
        let schemaText = String(data: try encoded(request.schema), encoding: .utf8) ?? "{}"
        let needsPromptSchema = mode != .jsonSchema
        let system: String
        if needsPromptSchema {
            let prefix = request.provider.transport == .responses
                ? "只返回一个 JSON 对象，不要输出 Markdown、解释或代码块，并严格遵守以下 Schema："
                : "当前模型端点不支持原生 JSON Schema。请只返回一个 JSON 对象，不要输出 Markdown、解释或代码块，并严格遵守以下 Schema："
            system = request.systemPrompt + "\n\n" + prefix + "\n" + schemaText
        } else {
            system = request.systemPrompt
        }
        let userText = userText(request)
        let root = request.provider.transport == .responses
            ? responsesPayload(request, mode: mode, system: system, userText: userText)
            : chatPayload(request, mode: mode, system: system, userText: userText)
        return try encoded(root)
    }

    public static func userText(_ request: RecognitionStageRequest) -> String {
        let core = request.stage != .primary
        let count = request.images.count
        let base: String
        if core {
            base = "以下 \(count) 张图是同一个来源页的核心字段局部放大视图，必须合并为一页识别，不能重复输出记录。来源：\(request.filename)"
        } else if count > 1 {
            base = "以下 \(count) 张图是同一个来源页的整页图与局部放大图，必须合并为一页识别，不能重复输出记录。来源：\(request.filename)"
        } else {
            base = "识别这一页场记单。来源：\(request.filename)"
        }
        guard let instruction = request.userInstruction?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty else { return base }
        return base + "\n\n" + instruction
    }

    private static func responsesPayload(_ request: RecognitionStageRequest, mode: ProviderJSONMode, system: String, userText: String) -> JSONValue {
        let images = request.images.map { image in
            JSONValue.object(["type": .string("input_image"), "image_url": .string(image.dataURL), "detail": .string(request.model.imageDetail.rawValue)])
        }
        var root: [String: JSONValue] = [
            "model": .string(request.model.apiID), "store": .boolean(false), "max_output_tokens": .number(16_000),
            "input": .array([
                .object(["role": .string("system"), "content": .string(system)]),
                .object(["role": .string("user"), "content": .array([.object(["type": .string("input_text"), "text": .string(userText)])] + images)]),
            ]),
        ]
        if mode == .jsonSchema {
            root["text"] = .object(["format": .object(["type": .string("json_schema"), "name": .string("slate_sheet"), "description": .string("场记单结构化识别结果"), "strict": .boolean(true), "schema": request.schema])])
        } else if mode == .jsonObject {
            root["text"] = .object(["format": .object(["type": .string("json_object")])])
        }
        return .object(root)
    }

    private static func chatPayload(_ request: RecognitionStageRequest, mode: ProviderJSONMode, system: String, userText: String) -> JSONValue {
        let images = request.images.map { image in
            JSONValue.object(["type": .string("image_url"), "image_url": .object(["url": .string(image.dataURL), "detail": .string(request.model.imageDetail.rawValue)])])
        }
        var root: [String: JSONValue] = [
            "model": .string(request.model.apiID), "stream": .boolean(false), "max_tokens": .number(16_000),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(system)]),
                .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string(userText)])] + images)]),
            ]),
        ]
        if mode == .jsonSchema {
            root["response_format"] = .object(["type": .string("json_schema"), "json_schema": .object(["name": .string("slate_sheet"), "description": .string("场记单结构化识别结果"), "strict": .boolean(true), "schema": request.schema])])
        } else if mode == .jsonObject {
            root["response_format"] = .object(["type": .string("json_object")])
        }
        if request.provider.id == "openrouter" { root["provider"] = .object(["require_parameters": .boolean(true)]) }
        return .object(root)
    }

    private static func encoded(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// Converts provider wire responses back into one provider-neutral stage
/// result while preserving the narrow legacy fallback classification.
public actor ProviderRecognitionClient {
    private let transport: any ProviderHTTPTransporting

    public init(transport: any ProviderHTTPTransporting) { self.transport = transport }

    public func recognize(_ request: RecognitionStageRequest) async throws -> RecognitionStageResponse {
        var mode = request.model.jsonMode
        while true {
            try Task.checkCancellation()
            do {
                let body = try ProviderPayloadBuilder.payload(request, mode: mode)
                let response = try await transport.send(.init(
                    provider: request.provider, purpose: request.stage == .primary ? .recognition : .probe,
                    method: .post, body: body, timeoutMilliseconds: request.timeoutMilliseconds,
                    maximumTimeoutRetries: request.maximumTimeoutRetries
                ))
                return try Self.extract(response.body, transport: request.provider.transport, mode: mode)
            } catch is CancellationError {
                throw RecognitionFailure.canceled
            } catch let error as SlateSyncError {
                guard let next = Self.nextMode(mode, error: error) else { throw error }
                mode = next
            }
        }
    }

    public func close() async { await transport.close() }

    public nonisolated static func nextMode(_ current: ProviderJSONMode, error: SlateSyncError) -> ProviderJSONMode? {
        guard [400, 404, 422].contains(error.status ?? -1) else { return nil }
        let text = error.message.lowercased()
        let unsupported = text.range(of: #"response[_ -]?format|json[_ -]?schema|json[_ -]?object|structured output|unsupported.*(?:schema|json)|no endpoints found that can handle the requested parameters"#, options: .regularExpression) != nil
        guard unsupported else { return nil }
        if current == .jsonSchema { return .jsonObject }
        if current == .jsonObject { return .prompt }
        return nil
    }

    public nonisolated static func extract(_ data: Data, transport: ProviderTransport, mode: ProviderJSONMode) throws -> RecognitionStageResponse {
        let root: JSONValue
        do { root = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw RecognitionFailure.invalidResponse }
        guard case .object(let fields) = root else { throw RecognitionFailure.invalidResponse }
        let text: String
        switch transport {
        case .responses:
            if case .string(let direct)? = fields["output_text"], !direct.isEmpty { text = direct }
            else {
                var parts: [String] = []
                if case .array(let outputs)? = fields["output"] {
                    for output in outputs {
                        guard case .object(let outputFields) = output, case .array(let content)? = outputFields["content"] else { continue }
                        for part in content {
                            guard case .object(let partFields) = part,
                                  case .string("output_text")? = partFields["type"],
                                  case .string(let value)? = partFields["text"] else { continue }
                            parts.append(value)
                        }
                    }
                }
                guard !parts.isEmpty else { throw RecognitionFailure.provider(message: "OpenAI 响应中没有可用的文本结果", status: 502) }
                text = parts.joined()
            }
        case .chatCompletions:
            guard case .array(let choices)? = fields["choices"], let first = choices.first,
                  case .object(let choice) = first, case .object(let message)? = choice["message"],
                  let extracted = chatText(message["content"]) else {
                throw RecognitionFailure.provider(message: "Chat Completions 响应中没有可用的文本结果", status: 502)
            }
            text = extracted
        }
        let usage = tokenUsage(fields["usage"])
        let responseID = string(fields["id"])
        return .init(text: text, usage: usage, responseID: responseID, model: string(fields["model"]), formatMode: mode)
    }

    public nonisolated static func structuredJSON(from text: String) throws -> JSONValue {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^```(?:json)?\s*"#, options: [.regularExpression, .caseInsensitive]) != nil {
            value = value.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            value = value.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw RecognitionFailure.invalidStructuredJSON
        }
        return decoded
    }

    private nonisolated static func chatText(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }
        guard case .array(let parts)? = value else { return nil }
        let text = parts.compactMap { part -> String? in
            guard case .object(let fields) = part, case .string("text")? = fields["type"], case .string(let text)? = fields["text"] else { return nil }
            return text
        }.joined()
        return text.isEmpty ? nil : text
    }

    private nonisolated static func tokenUsage(_ value: JSONValue?) -> TokenUsage? {
        guard case .object(let fields)? = value else { return nil }
        func integer(_ keys: [String]) -> Int? {
            for key in keys {
                if case .number(let number)? = fields[key], number.isFinite, number.rounded() == number, number >= 0, number <= Double(Int.max) { return Int(number) }
            }
            return nil
        }
        let result = TokenUsage(
            promptTokens: integer(["prompt_tokens"]), completionTokens: integer(["completion_tokens"]),
            totalTokens: integer(["total_tokens"]), inputTokens: integer(["input_tokens"]), outputTokens: integer(["output_tokens"])
        )
        return [result.promptTokens, result.completionTokens, result.totalTokens, result.inputTokens, result.outputTokens].allSatisfy { $0 == nil } ? nil : result
    }

    private nonisolated static func string(_ value: JSONValue?) -> String? {
        if case .string(let string)? = value { return string }
        return nil
    }
}
