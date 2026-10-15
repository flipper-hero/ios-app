import XCTest
@testable import AgentKit

final class MarauderTests: XCTestCase {
    func testDeauthRequiresOneBoundedAPIndex() throws {
        XCTAssertThrowsError(try ToolInvocation(name: "marauder", arguments: #"{"action":"attack","mode":"deauth"}"#))
        XCTAssertThrowsError(try ToolInvocation(name: "marauder", arguments: #"{"action":"attack","mode":"deauth","ap_index":100}"#))
        XCTAssertThrowsError(try ToolInvocation(name: "marauder", arguments: #"{"action":"attack","mode":"deauth","ap_index":0,"seconds":11}"#))
        XCTAssertThrowsError(try ToolInvocation(name: "marauder", arguments: #"{"action":"attack","mode":"probe"}"#))
        XCTAssertThrowsError(try ToolInvocation(name: "marauder", arguments: #"{"action":"attack","mode":"probe","ap_index":1}"#))
        let valid = try ToolInvocation(name: "marauder", arguments: #"{"action":"attack","mode":"deauth","ap_index":2,"seconds":3}"#)
        XCTAssertEqual(RiskAssessor.assess(valid).level, .high)
        let probe = try ToolInvocation(name: "marauder", arguments: #"{"action":"attack","mode":"probe","ssid_index":1}"#)
        XCTAssertEqual(RiskAssessor.assess(probe).level, .high)
    }

    func testAttackAlwaysAsksEvenInYoloMode() async {
        let flipper = FakeFlipper()
        let gate = ScriptedGate(answer: false)
        let executor = ToolExecutor(flipper: flipper, gate: gate, audit: InMemoryAuditLog(),
                                    settings: { ApprovalSettings(yolo: true) })
        let call = ToolCall(id: "attack", name: "marauder",
                            arguments: #"{"action":"attack","mode":"deauth","ap_index":2,"seconds":3}"#)
        let result = await executor.execute(call)
        XCTAssertEqual(result.kind, .denied)
        XCTAssertEqual(gate.requests.count, 1)
        XCTAssertEqual(gate.requests.first?.risk, .high)
        XCTAssertFalse(gate.requests.first?.isPermissionChange ?? true)
        let calls = await flipper.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMarauderOutputIsUntrusted() async {
        let executor = ToolExecutor(flipper: FakeFlipper(), gate: ScriptedGate(answer: true),
                                    audit: InMemoryAuditLog())
        let result = await executor.execute(ToolCall(id: "list", name: "marauder",
                                                     arguments: #"{"action":"list_ap"}"#))
        XCTAssertEqual(result.kind, .ok)
        XCTAssertTrue(result.content.contains("Lab Wi-Fi"))
        let tainted = await executor.isTainted
        XCTAssertTrue(tainted)
    }
}
