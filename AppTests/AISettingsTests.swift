import XCTest
import Security
import AgentKit
@testable import FlipperHero

private final class SettingsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var reply = "OK"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                                             httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": Self.reply]]]])
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        return URLSession(configuration: config)
    }
}

@MainActor
final class AISettingsTests: XCTestCase {
    func testProviderPreferencesStaySeparateAndLegacyOpenRouterModelSurvives() {
        let suite = "FlipperHero.ProviderTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-model", forKey: "openrouterModel")
        XCTAssertEqual(AISettings.load(.openrouter, defaults: defaults).model, "legacy-model")
        AISettings(provider: .kimi, model: "kimi-custom", baseURL: "https://api.moonshot.cn/v1").persist(defaults: defaults)
        XCTAssertEqual(AISettings.load(.openrouter, defaults: defaults).model, "legacy-model")
        XCTAssertEqual(AISettings.load(.kimi, defaults: defaults).model, "kimi-custom")
        XCTAssertEqual(AISettings.load(.kimi, defaults: defaults).baseURL, "https://api.moonshot.cn/v1")
        XCTAssertEqual(AISettings.load(.minimax, defaults: defaults).model, AIProvider.minimax.defaultModel)
    }

    func testRejectedKeyOrEmptyResponseNeverReplacesStoredKey() async throws {
        let settings = AISettings.load(.kimi)
        for (status, reply) in [(401, "OK"), (200, "")] {
            SettingsURLProtocol.status = status
            SettingsURLProtocol.reply = reply
            var stored = "previous-key"
            do {
                try await settings.verifyAndSave(key: "replacement-key", session: SettingsURLProtocol.session()) { key, _ in
                    stored = key
                    return errSecSuccess
                }
                XCTFail("verification must fail")
            } catch { XCTAssertEqual(stored, "previous-key") }
        }
    }

    func testVerifiedKeyIsWrittenOnlyToSelectedProvider() async throws {
        SettingsURLProtocol.status = 200
        SettingsURLProtocol.reply = "OK"
        var writes: [String: String] = ["openrouter": "previous-key"]
        try await AISettings.load(.kimi).verifyAndSave(key: "replacement-key", session: SettingsURLProtocol.session()) { key, account in
            writes[account] = key
            return errSecSuccess
        }
        XCTAssertEqual(writes, ["openrouter": "previous-key", "kimi": "replacement-key"])
    }
}
