import Foundation
import Security
import AgentKit

struct AISettings: Equatable {
    let provider: AIProvider
    var model: String
    var baseURL: String

    static let providerKey = "aiProvider"
    static func load(_ provider: AIProvider, defaults: UserDefaults = .standard) -> AISettings {
        AISettings(provider: provider,
                   model: defaults.string(forKey: modelKey(provider)) ?? provider.defaultModel,
                   baseURL: defaults.string(forKey: urlKey(provider)) ?? provider.baseURL)
    }
    // Keep existing OpenRouter keys and model preferences when upgrading.
    static func modelKey(_ provider: AIProvider) -> String {
        provider == .openrouter ? "openrouterModel" : "aiModel.\(provider.rawValue)"
    }
    static func urlKey(_ provider: AIProvider) -> String { "aiBaseURL.\(provider.rawValue)" }
    func persist(defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        defaults.set(model, forKey: Self.modelKey(provider))
        defaults.set(baseURL, forKey: Self.urlKey(provider))
    }
    func api(key: String, session: URLSession = .shared) throws -> ProviderAPI {
        try ProviderAPI(provider: provider, baseURL: baseURL, apiKey: key, session: session)
    }
    /// Validate before touching Keychain or preferences. A failed check preserves the old key.
    func verifyAndSave(key: String, session: URLSession = .shared,
                       writeKey: (String, String) -> OSStatus = { KeychainStore.write($0, account: $1) }) async throws {
        try await api(key: key, session: session).test(model: model)
        let status = writeKey(key, provider.rawValue)
        guard status == errSecSuccess else {
            throw LLMError.malformed(String(localized: "Could not save the key (Keychain status \(status)). It is still in the field, nothing was lost."))
        }
    }
}
