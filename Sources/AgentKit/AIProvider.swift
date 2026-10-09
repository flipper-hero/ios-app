import Foundation

public enum AIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case openrouter, ai2342, blackbit, orcarouter, zai, kimi, qwen, minimax
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .openrouter: "OpenRouter"
        case .ai2342: "2342.ai"
        case .blackbit: "Blackbit"
        case .orcarouter: "OrcaRouter"
        case .zai: "Z.ai"
        case .kimi: "Kimi"
        case .qwen: "Qwen Cloud"
        case .minimax: "MiniMax"
        }
    }
    public var baseURL: String {
        switch self {
        case .openrouter: "https://openrouter.ai/api/v1"
        case .ai2342: "https://2342.ai/v1"
        case .blackbit: "https://void.blackbit.sh/v1"
        case .orcarouter: "https://api.orcarouter.ai/v1"
        case .zai: "https://api.z.ai/api/paas/v4"
        case .kimi: "https://api.moonshot.ai/v1"
        case .qwen: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .minimax: "https://api.minimax.io/v1"
        }
    }
    public var defaultModel: String {
        switch self {
        case .openrouter: "anthropic/claude-sonnet-4.5"
        // 2342.ai publishes model IDs only in the authenticated live catalog.
        case .ai2342: ""
        case .blackbit: "zai_glm_5_2"
        case .orcarouter: "orcarouter/auto"
        case .zai: "glm-5.3-flash"
        case .kimi: "kimi-k3"
        case .qwen: "qwen-plus"
        case .minimax: "MiniMax-M3"
        }
    }
    public var documentation: URL {
        let address: String
        switch self {
        case .openrouter: address = "https://openrouter.ai/docs"
        case .ai2342: address = "https://2342.ai/en/messages-responses-api-proxy"
        case .blackbit: address = "https://docs.blackbit.sh"
        case .orcarouter: address = "https://docs.orcarouter.ai/introduction"
        case .zai: address = "https://docs.z.ai/guides/overview/quick-start"
        case .kimi: address = "https://platform.moonshot.ai/docs/guide/start-using-kimi-api"
        case .qwen: address = "https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope"
        case .minimax: address = "https://platform.minimax.io/docs/api-reference/text-openai-api"
        }
        return URL(string: address)!
    }

    /// Keep keys within the selected provider, including its regional API hosts.
    public func validatedBaseURL(_ address: String) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { throw ProviderError.invalidEndpoint }
        let allowed: Bool
        switch self {
        case .openrouter: allowed = host == "openrouter.ai"
        case .ai2342: allowed = host == "2342.ai"
        case .blackbit: allowed = host == "void.blackbit.sh"
        case .orcarouter: allowed = host == "api.orcarouter.ai"
        case .zai: allowed = ["api.z.ai", "open.bigmodel.cn"].contains(host)
        case .kimi: allowed = ["api.moonshot.ai", "api.moonshot.cn"].contains(host)
        case .qwen:
            allowed = ["dashscope-intl.aliyuncs.com", "dashscope-us.aliyuncs.com", "dashscope.aliyuncs.com"].contains(host)
                || host.hasSuffix(".maas.aliyuncs.com")
        case .minimax: allowed = ["api.minimax.io", "api.minimaxi.com"].contains(host)
        }
        guard allowed else { throw ProviderError.invalidEndpoint }
        return url
    }
}

public enum ProviderError: Error, CustomStringConvertible, LocalizedError {
    case invalidEndpoint, missingKey, missingModel, emptyReply, modelsUnavailable
    case status(Int)
    public var description: String {
        switch self {
        case .invalidEndpoint: L("Use an HTTPS API URL from this provider.")
        case .missingKey: L("Add an API key in Settings first.")
        case .missingModel: L("Choose a model first.")
        case .emptyReply: L("The model did not reply. Try another model.")
        case .modelsUnavailable: L("No model list is available. Enter a model ID from the provider documentation.")
        case .status(let code): L("API request failed (HTTP \(code)). Check your key, model and account credit.")
        }
    }
    public var errorDescription: String? { description }
}

public struct AIModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Refuse redirects so a provider cannot forward a customer's key to another host.
final class ProviderRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ProviderAPI: Sendable {
    public let provider: AIProvider
    public let baseURL: URL
    public let apiKey: String
    public let session: URLSession
    public init(provider: AIProvider, baseURL: String, apiKey: String, session: URLSession = .shared) throws {
        self.provider = provider
        self.baseURL = try provider.validatedBaseURL(baseURL)
        self.apiKey = apiKey
        self.session = session
    }
    public func client(model: String) -> ChatCompletionsClient {
        ChatCompletionsClient(apiKey: apiKey, model: model,
                              endpoint: baseURL.appendingPathComponent("chat/completions"),
                              provider: provider, session: session)
    }
    public func models() async throws -> [AIModel] {
        if apiKey.isEmpty && ![AIProvider.openrouter, .blackbit, .orcarouter].contains(provider) {
            throw ProviderError.missingKey
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 30
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request, delegate: ProviderRequestDelegate())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if [404, 405, 501].contains(status) { throw ProviderError.modelsUnavailable }
        guard (200..<300).contains(status) else { throw ProviderError.status(status) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else { throw ProviderError.modelsUnavailable }
        var seen = Set<String>()
        let models = entries.compactMap { entry -> AIModel? in
            guard let id = entry["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            if let parameters = entry["supported_parameters"] as? [String], !parameters.contains("tools") { return nil }
            return AIModel(id: id, name: entry["name"] as? String ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !models.isEmpty else { throw ProviderError.modelsUnavailable }
        return models
    }
    /// Only this fixed prompt is sent: no conversation, device data or tools.
    public func test(model: String) async throws {
        guard !apiKey.isEmpty else { throw ProviderError.missingKey }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.missingModel }
        var client = client(model: model)
        client.connectionTest = true
        let reply = try await client.complete(
            messages: [ChatMessage(role: .user, content: "Reply with exactly OK.")], tools: [])
        guard !(reply.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            throw ProviderError.emptyReply
        }
    }
}
