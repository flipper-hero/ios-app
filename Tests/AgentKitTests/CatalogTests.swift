import XCTest
@testable import AgentKit

/// Serves canned HTTP responses so catalog tests make no network calls.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [(match: String, status: Int, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let route = Self.routes.first { url.contains($0.match) }
        let status = route?.status ?? 404
        let body = route?.body ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class CatalogTests: XCTestCase {
    private let searchBody = Data("""
    [{"_id":"a1","alias":"analog_clock","category_id":"c1",
      "current_version":{"_id":"v1","name":"Analog Clock","version":"1.4","short_description":"Shows a clock"}}]
    """.utf8)

    override func tearDown() { StubURLProtocol.routes = []; super.tearDown() }

    func testSearchParsing() async throws {
        StubURLProtocol.routes = [("/application?", 200, searchBody)]
        let apps = try await FapHubClient(session: StubURLProtocol.session()).search("clock", api: "87.1")
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].alias, "analog_clock")
        XCTAssertEqual(apps[0].versionID, "v1")
        XCTAssertEqual(apps[0].version, "1.4")
    }

    func testDownloadRejectsNonELF() async {
        StubURLProtocol.routes = [("/build/compatible", 200, Data("not an app".utf8))]
        let client = FapHubClient(session: StubURLProtocol.session())
        do {
            _ = try await client.downloadBuild(versionID: "v1", api: "87.1")
            XCTFail("expected rejection")
        } catch CatalogError.malformed {
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testDownloadAcceptsELF() async throws {
        var fap = Data([0x7F, 0x45, 0x4C, 0x46])
        fap.append(Data(repeating: 0, count: 100))
        StubURLProtocol.routes = [("/build/compatible", 200, fap)]
        let data = try await FapHubClient(session: StubURLProtocol.session()).downloadBuild(versionID: "v1", api: "87.1")
        XCTAssertEqual(data.count, 104)
    }

    func testHTTPErrorSurfaces() async {
        StubURLProtocol.routes = [("/application?", 503, Data())]
        do {
            _ = try await FapHubClient(session: StubURLProtocol.session()).search("x", api: "87.1")
            XCTFail("expected error")
        } catch CatalogError.http(let code) {
            XCTAssertEqual(code, 503)
        } catch { XCTFail("\(error)") }
    }

    func testGitHubFetchOnlyAllowsGitHubHosts() async {
        let client = GitHubClient(session: StubURLProtocol.session())
        for bad in ["https://evil.example.com/x.sub", "http://raw.githubusercontent.com/a/b", "file:///etc/passwd"] {
            do {
                _ = try await client.fetchRaw(bad)
                XCTFail("accepted \(bad)")
            } catch {}
        }
    }

    func testInstallUsesDeviceAPIVersionAndWritesToCategoryFolder() async throws {
        var fap = Data([0x7F, 0x45, 0x4C, 0x46]); fap.append(Data(repeating: 7, count: 20))
        StubURLProtocol.routes = [
            ("/application?", 200, searchBody),
            ("/build/compatible", 200, fap),
            ("/category", 200, Data(#"[{"_id":"c1","name":"Tools"}]"#.utf8)),
        ]
        let flipper = FakeFlipper()
        let gate = ScriptedGate(answer: true)
        let ex = ToolExecutor(flipper: flipper, gate: gate, audit: InMemoryAuditLog(),
                              fapHub: FapHubClient(session: StubURLProtocol.session()))
        let result = await ex.execute(ToolCall(id: "1", name: "install_faphub_app",
                                               arguments: #"{"query":"analog_clock"}"#))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(gate.requests.first?.risk, .high, "installing executable code must be high risk")
        let written = await flipper.files["/ext/apps/Tools/analog_clock.fap"]
        XCTAssertEqual(written?.count, 24)
    }

    func testInstallDeniedDoesNotWrite() async throws {
        var fap = Data([0x7F, 0x45, 0x4C, 0x46]); fap.append(Data(repeating: 7, count: 20))
        StubURLProtocol.routes = [
            ("/application?", 200, searchBody),
            ("/build/compatible", 200, fap),
            ("/category", 200, Data(#"[{"_id":"c1","name":"Tools"}]"#.utf8)),
        ]
        let flipper = FakeFlipper()
        let ex = ToolExecutor(flipper: flipper, gate: ScriptedGate(answer: false), audit: InMemoryAuditLog(),
                              fapHub: FapHubClient(session: StubURLProtocol.session()))
        let result = await ex.execute(ToolCall(id: "1", name: "install_faphub_app",
                                               arguments: #"{"query":"analog_clock"}"#))
        XCTAssertEqual(result.kind, .denied)
        let calls = await flipper.calls
        XCTAssertTrue(calls.filter { $0.hasPrefix("write") }.isEmpty)
    }

    func testGitHubSearchResultsAreFencedAndTaint() async throws {
        let body = Data(#"{"items":[{"path":"remotes/tv.ir","repository":{"full_name":"a/b"},"html_url":"https://github.com/a/b/blob/main/remotes/tv.ir"}]}"#.utf8)
        StubURLProtocol.routes = [("search/code", 200, body)]
        let ex = ToolExecutor(flipper: FakeFlipper(), gate: ScriptedGate(answer: true), audit: InMemoryAuditLog(),
                              gitHub: GitHubClient(session: StubURLProtocol.session()), nonce: "n1")
        let result = await ex.execute(ToolCall(id: "1", name: "github_search",
                                               arguments: #"{"query":"samsung tv","extension":"ir"}"#))
        XCTAssertTrue(result.content.contains("<<<FLIPPER_DATA"), "internet results are untrusted input")
        XCTAssertTrue(result.content.contains("raw.githubusercontent.com/a/b/main/remotes/tv.ir"))
        let tainted = await ex.isTainted
        XCTAssertTrue(tainted)
    }
}
