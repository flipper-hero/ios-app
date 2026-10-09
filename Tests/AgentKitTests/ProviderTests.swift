import XCTest
@testable import AgentKit

final class ProviderURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handle: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let (status, data) = try Self.handle!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                                 httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]
        return URLSession(configuration: config)
    }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

final class ProviderTests: XCTestCase {
    override func tearDown() { ProviderURLProtocol.handle = nil; super.tearDown() }

    func testEveryProviderUsesItsOwnEndpointsAndBearerKey() async throws {
        for provider in AIProvider.allCases {
            ProviderURLProtocol.handle = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
                XCTAssertEqual(request.url?.absoluteString, provider.baseURL + "/models")
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, Data(#"{"data":[{"id":"m/test","name":"Test model"}]}"#.utf8))
            }
            let api = try ProviderAPI(provider: provider, baseURL: provider.baseURL, apiKey: "test-key", session: ProviderURLProtocol.session())
            let models = try await api.models()
            XCTAssertEqual(models, [AIModel(id: "m/test", name: "Test model")])
            ProviderURLProtocol.handle = { request in
                XCTAssertEqual(request.url?.absoluteString, provider.baseURL + "/chat/completions")
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try ProviderURLProtocol.body(request)
                XCTAssertEqual(body["model"] as? String, "m/test")
                XCTAssertEqual(body["max_tokens"] as? Int, 1024)
                XCTAssertNil(body["tools"], "the check must never execute agent tools")
                let messages = body["messages"] as! [[String: Any]]
                XCTAssertEqual(messages.count, 1)
                XCTAssertEqual(messages[0]["content"] as? String, "Reply with exactly OK.")
                return (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8))
            }
            try await api.test(model: "m/test")
        }
    }

    func testModelListFiltersExplicitlyUnsupportedToolsAndDeduplicates() async throws {
        ProviderURLProtocol.handle = { _ in (200, Data(#"{"data":[{"id":"b","name":"Beta","supported_parameters":["tools"]},{"id":"a","name":"Alpha"},{"id":"b"},{"id":"image","supported_parameters":["size"]},{"name":"Missing ID"}]}"#.utf8)) }
        let api = try ProviderAPI(provider: .openrouter, baseURL: AIProvider.openrouter.baseURL, apiKey: "", session: ProviderURLProtocol.session())
        let models = try await api.models()
        XCTAssertEqual(models.map(\.id), ["a", "b"])
    }

    func testUnsupportedModelEndpointIsDistinctFromRejectedKey() async throws {
        let api = try ProviderAPI(provider: .minimax, baseURL: AIProvider.minimax.baseURL, apiKey: "test-key", session: ProviderURLProtocol.session())
        for status in [404, 401, 403, 429] {
            ProviderURLProtocol.handle = { _ in (status, Data(#"{"error":{"message":"test-key"}}"#.utf8)) }
            do { _ = try await api.models(); XCTFail("must fail") }
            catch let error as ProviderError {
                if status == 404 {
                    guard case .modelsUnavailable = error else { return XCTFail("wrong failure") }
                } else {
                    guard case .status(let actual) = error else { return XCTFail("wrong failure") }
                    XCTAssertEqual(actual, status)
                }
                XCTAssertFalse(error.description.contains("test-key"))
            }
        }
    }

    func testProbeRejectsEmptyReplyAndRedactsProviderErrors() async throws {
        let api = try ProviderAPI(provider: .kimi, baseURL: AIProvider.kimi.baseURL, apiKey: "test-key", session: ProviderURLProtocol.session())
        ProviderURLProtocol.handle = { _ in (200, Data(#"{"choices":[{"message":{"content":null,"reasoning_content":"thinking"}}]}"#.utf8)) }
        do { try await api.test(model: "kimi-k3"); XCTFail("empty reply") }
        catch let error as ProviderError { guard case .emptyReply = error else { return XCTFail("wrong failure") } }
        ProviderURLProtocol.handle = { _ in (401, Data(#"{"error":{"message":"bad key test-key"}}"#.utf8)) }
        do { try await api.test(model: "kimi-k3"); XCTFail("invalid key") }
        catch { XCTAssertFalse(String(describing: error).contains("test-key")) }
    }

    func testReasoningFieldsSurviveToolContinuationWithoutTemperatureConstraints() throws {
        let data = Data(#"{"choices":[{"message":{"content":null,"reasoning_content":"opaque reasoning","reasoning_details":[{"type":"signature","data":"opaque"}],"tool_calls":[{"id":"1","function":{"name":"get_app_settings","arguments":"{}"}}]}}]}"#.utf8)
        let message = try ChatCompletionsClient.parseResponse(data)
        let client = ChatCompletionsClient(apiKey: "k", model: "kimi-k3", provider: .kimi)
        let root = try JSONSerialization.jsonObject(with: client.makeRequestBody(messages: [message], tools: [])) as! [String: Any]
        let wire = (root["messages"] as! [[String: Any]])[0]
        XCTAssertEqual(wire["reasoning_content"] as? String, "opaque reasoning")
        XCTAssertEqual((wire["reasoning_details"] as? [[String: String]])?.first?["data"], "opaque")
        XCTAssertEqual((wire["tool_calls"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(root["temperature"])
    }

    func testRegionalURLsWorkAndCannotSendKeysToAnotherProvider() throws {
        XCTAssertNoThrow(try AIProvider.qwen.validatedBaseURL("https://workspace.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"))
        XCTAssertNoThrow(try AIProvider.zai.validatedBaseURL("https://api.z.ai/api/coding/paas/v4"))
        XCTAssertNoThrow(try AIProvider.kimi.validatedBaseURL("https://api.moonshot.cn/v1"))
        for address in ["http://api.moonshot.ai/v1", "https://api.moonshot.ai.evil.example/v1", "https://user:pass@api.moonshot.ai/v1", "https://openrouter.ai/api/v1", "https://api.moonshot.ai:8080/v1"] {
            XCTAssertThrowsError(try AIProvider.kimi.validatedBaseURL(address))
        }
    }
}
