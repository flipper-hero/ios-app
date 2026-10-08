import XCTest
@testable import AgentKit

final class FirmwareDownloadTests: XCTestCase {
    override func tearDown() { StubURLProtocol.routes = []; super.tearDown() }

    private let momentum = FirmwareCatalog.identify(fork: "Momentum", version: "mntm-012")!

    private func release(_ assets: [(String, String)]) -> Data {
        let list = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"# }.joined(separator: ",")
        return Data(#"{"tag_name":"mntm-012","assets":[\#(list)]}"#.utf8)
    }

    func testPicksTheF7UpdatePackage() async throws {
        StubURLProtocol.routes = [("releases/latest", 200, release([
            ("flipper-z-f7-full-mntm-012.dfu", "https://github.com/Next-Flip/Momentum-Firmware/releases/download/mntm-012/full.dfu"),
            ("flipper-z-f7-update-mntm-012.tgz", "https://github.com/Next-Flip/Momentum-Firmware/releases/download/mntm-012/update.tgz"),
        ]))]
        let (tag, url) = try await FirmwareUpdater(session: StubURLProtocol.session()).latestPackageURL(for: momentum)
        XCTAssertEqual(tag, "mntm-012")
        XCTAssertEqual(url.lastPathComponent, "update.tgz")
    }

    func testRefusesPackagesFromOtherHosts() async {
        StubURLProtocol.routes = [("releases/latest", 200, release([
            ("flipper-z-f7-update-mntm-012.tgz", "https://evil.example.com/update.tgz"),
        ]))]
        do {
            _ = try await FirmwareUpdater(session: StubURLProtocol.session()).latestPackageURL(for: momentum)
            XCTFail("accepted a package from outside GitHub")
        } catch FirmwareUpdateError.noPackage {
        } catch { XCTFail("\(error)") }
    }

    func testMissingAssetIsReported() async {
        StubURLProtocol.routes = [("releases/latest", 200, release([]))]
        do {
            _ = try await FirmwareUpdater(session: StubURLProtocol.session()).latestPackageURL(for: momentum)
            XCTFail("expected noPackage")
        } catch FirmwareUpdateError.noPackage {
        } catch { XCTFail("\(error)") }
    }

    func testDownloadReturnsDataAndSurfacesHTTPErrors() async throws {
        let body = Data(repeating: 0x42, count: 4096)
        StubURLProtocol.routes = [("ok.tgz", 200, body), ("gone.tgz", 404, Data())]
        let updater = FirmwareUpdater(session: StubURLProtocol.session())
        let data = try await updater.download(URL(string: "https://github.com/x/ok.tgz")!) { _ in }
        XCTAssertEqual(data, body)
        do {
            _ = try await updater.download(URL(string: "https://github.com/x/gone.tgz")!) { _ in }
            XCTFail("expected an HTTP error")
        } catch CatalogError.http(let code) {
            XCTAssertEqual(code, 404)
        }
    }

    func testLatestReleaseForTheUpdateNotice() async throws {
        StubURLProtocol.routes = [("releases/latest", 200, Data(#"{"tag_name":"mntm-012"}"#.utf8))]
        let checker = FirmwareUpdateChecker(session: StubURLProtocol.session())
        let current = await checker.status(fork: "Momentum", version: "mntm-012")
        XCTAssertEqual(current?.updateAvailable, false)
        let old = await checker.status(fork: "Momentum", version: "mntm-011")
        XCTAssertEqual(old?.updateAvailable, true)
        let unknown = await checker.status(fork: "SomethingElse", version: "1.0")
        XCTAssertNil(unknown)
    }
}

final class FileAuditLogTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID().uuidString)/audit.jsonl")
    }

    func testRecordsSurviveReopeningAndKeepTheirOrder() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = FileAuditLog(url: url)
        for i in 1...3 {
            await log.record(.init(tool: "tool\(i)", summary: "step \(i)", risk: .low, decision: .auto,
                                   succeeded: true, detail: ""))
        }
        let reopened = FileAuditLog(url: url)
        let all = await reopened.load()
        XCTAssertEqual(all.map(\.tool), ["tool1", "tool2", "tool3"])
        let recent = await reopened.recent(limit: 2)
        XCTAssertEqual(recent.map(\.tool), ["tool2", "tool3"])
    }

    func testDamagedLinesAreSkipped() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = FileAuditLog(url: url)
        await log.record(.init(tool: "first", summary: "", risk: nil, decision: .invalid, succeeded: false, detail: "x"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        await log.record(.init(tool: "second", summary: "", risk: .high, decision: .shortcut, succeeded: true, detail: ""))
        let all = await log.load()
        XCTAssertEqual(all.map(\.tool), ["first", "second"])
        XCTAssertEqual(all.last?.decision, .shortcut)
    }

    func testMissingFileIsEmpty() async {
        let log = FileAuditLog(url: temporaryURL())
        let all = await log.load()
        XCTAssertTrue(all.isEmpty)
    }
}
