import XCTest
import FlipperKit
@testable import AgentKit

final class FirmwareTests: XCTestCase {
    func testIdentifiesKnownDistributions() {
        XCTAssertEqual(FirmwareCatalog.identify(fork: "Momentum", version: "mntm-dev")?.name, "Momentum")
        XCTAssertEqual(FirmwareCatalog.identify(fork: nil, version: "mntm-009")?.name, "Momentum")
        XCTAssertEqual(FirmwareCatalog.identify(fork: nil, version: "unlshd-078")?.name, "Unleashed")
        XCTAssertEqual(FirmwareCatalog.identify(fork: "RogueMaster", version: nil)?.name, "RogueMaster")
        XCTAssertEqual(FirmwareCatalog.identify(fork: "flipperdevices", version: "1.0.1")?.name, nil)
        XCTAssertNil(FirmwareCatalog.identify(fork: nil, version: nil))
    }

    func testDevBuildsAreNotReportedAsOutdated() {
        XCTAssertNil(FirmwareUpdateChecker.compare("mntm-dev", "mntm-010"), "dev builds have no release tag to compare")
        XCTAssertNil(FirmwareUpdateChecker.compare("unknown", "mntm-010"))
        XCTAssertNil(FirmwareUpdateChecker.compare("mntm-009", nil))
    }

    func testReleaseComparison() {
        XCTAssertEqual(FirmwareUpdateChecker.compare("mntm-009", "mntm-010"), true)
        XCTAssertEqual(FirmwareUpdateChecker.compare("mntm-010", "mntm-010"), false)
        XCTAssertEqual(FirmwareUpdateChecker.compare("009", "mntm-009"), false, "same digits means same release")
    }

    func testStatusSummaryWording() {
        let momentum = FirmwareCatalog.known[0]
        XCTAssertTrue(FirmwareStatus(distribution: momentum, installedVersion: "mntm-009",
                                     latestRelease: "mntm-010", updateAvailable: true)
            .summary.contains("mntm-010 is available"))
        XCTAssertTrue(FirmwareStatus(distribution: momentum, installedVersion: "mntm-dev",
                                     latestRelease: "mntm-010", updateAvailable: nil)
            .summary.contains("dev build"))
    }

    func testNameValidation() throws {
        XCTAssertEqual(try FlipperName.validate("  Hero  "), "Hero")
        XCTAssertThrowsError(try FlipperName.validate(""))
        XCTAssertThrowsError(try FlipperName.validate("ThisIsWayTooLong"))
        XCTAssertThrowsError(try FlipperName.validate("bad name"))
        XCTAssertThrowsError(try FlipperName.validate("emoji🙂"))
    }

    func testNameFileRoundTrip() {
        let contents = FlipperName.fileContents(for: "Laisear")
        XCTAssertTrue(contents.hasPrefix("Filetype: Flipper Name File\nVersion: 1\n"))
        XCTAssertEqual(FlipperName.parse(contents), "Laisear")
        XCTAssertNil(FlipperName.parse("Filetype: Flipper Name File\nVersion: 1\n"))
    }

    func testRenameToolWritesTheNameFile() async throws {
        let flipper = FakeFlipper()
        let gate = ScriptedGate(answer: true)
        let ex = ToolExecutor(flipper: flipper, gate: gate, audit: InMemoryAuditLog())
        let result = await ex.execute(ToolCall(id: "1", name: "set_device_name", arguments: #"{"name":"Hero"}"#))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(gate.requests.first?.risk, .medium)
        let calls = await flipper.calls
        XCTAssertTrue(calls.contains("setName Hero"))
    }
}
