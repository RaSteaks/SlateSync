import Foundation

/// User-facing URL guidance is kept beside the shared URL contract so SwiftUI
/// can explain an endpoint mistake without inventing a second normalizer.
public enum ProviderURLGuidance {
    /// Returns the endpoint suffix that should not be included in a Base URL.
    /// The transport remains the source of truth for which request endpoint is
    /// eventually appended by `ProviderDescriptor.endpoint(for:)`.
    public static func endpointSuffix(in rawValue: String, transport: ProviderTransport) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme != nil else { return nil }
        let path = components.percentEncodedPath.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        let endpoint = transport == .responses ? "responses" : "chat/completions"
        if path == endpoint || path.hasSuffix("/" + endpoint) { return "/" + endpoint }
        if path == "models" || path.hasSuffix("/models") { return "/models" }
        return nil
    }

    /// A warning is deliberately advisory: existing saved values are not
    /// rewritten or guessed, while a new form can ask the user to correct the
    /// Base URL before saving it.
    public static func baseURLWarning(in rawValue: String, transport: ProviderTransport) -> String? {
        guard let suffix = endpointSuffix(in: rawValue, transport: transport) else { return nil }
        return "请填写 API 基础地址（Base URL），不要包含 \(suffix) 接口路径。"
    }
}
