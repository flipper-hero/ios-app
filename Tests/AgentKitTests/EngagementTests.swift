import XCTest
import FlipperKit
@testable import AgentKit

final class EngagementTests: XCTestCase {
    private func make(engagement: EngagementState = .inactive, approve: Bool = true,
                      files: [String: String] = [:])
        -> (ToolExecutor, FakeFlipper, ScriptedGate, InMemoryAuditLog, FakeAppControls) {
        let flipper = FakeFlipper(files: files)
        let gate = ScriptedGate(answer: approve)
        let audit = InMemoryAuditLog()
        let controls = FakeAppControls()
        let ex = ToolExecutor(flipper: flipper, gate: gate, audit: audit, appControls: controls,
                              settings: { ApprovalSettings(engagement: engagement) })
        return (ex, flipper, gate, audit, controls)
    }

    private func armed(autoApprovals: Bool = true, rawRPC: Bool = false, autoBadKB: Bool = false) -> EngagementState {
        EngagementState(active: true, profile: EngagementProfile(autoApprovals: autoApprovals, rawRPC: rawRPC,
                                                                 autoBadKB: autoBadKB), startedAt: Date())
    }

    // MARK: Policy

    func testEngagementAutoApprovalsSkipPromptsButBlockedStaysBlocked() async throws {
        let (ex, flipper, gate, audit, _) = make(engagement: armed())
        let medium = await ex.execute(ToolCall(id: "1", name: "create_directory", arguments: #"{"path":"/ext/e"}"#))
        XCTAssertFalse(medium.isError)
        let high = await ex.execute(ToolCall(id: "2", name: "transmit_subghz",
                                             arguments: #"{"path":"/ext/subghz/g.sub"}"#))
        XCTAssertFalse(high.isError, high.content)
        await flipper.seed("/ext/subghz/g.sub", bytes: Data("x".utf8))
        let blocked = await ex.execute(ToolCall(id: "3", name: "write_file",
                                                arguments: #"{"path":"/int/x","content":"x"}"#))
        XCTAssertEqual(blocked.kind, .blocked)
        XCTAssertTrue(gate.requests.isEmpty, "armed engagement must not prompt")
        let decisions = await audit.records.map(\.decision)
        XCTAssertEqual(decisions, [.engaged, .engaged, .blocked])
        let calls = await flipper.calls
        XCTAssertTrue(calls.contains { $0.hasPrefix("transmit") })
    }

    func testEngagementWithoutAutoApprovalsStillAsks() async throws {
        let (ex, _, gate, _, _) = make(engagement: armed(autoApprovals: false))
        _ = await ex.execute(ToolCall(id: "1", name: "create_directory", arguments: #"{"path":"/ext/e"}"#))
        XCTAssertEqual(gate.requests.count, 1, "capabilities alone do not skip prompts")
    }

    func testArmingAlwaysNeedsConsentEvenUnderEveryYoloFlag() async throws {
        let controls = FakeAppControls()
        let gate = ScriptedGate(answer: false)
        let ex = ToolExecutor(flipper: FakeFlipper(), gate: gate, audit: InMemoryAuditLog(),
                              appControls: controls,
                              settings: { ApprovalSettings(autoApproveMedium: true, yolo: true, yoloAsksAfterUntrusted: false) })
        let result = await ex.execute(ToolCall(id: "1", name: "set_engagement_mode",
                                               arguments: #"{"enabled":true,"raw_rpc":true}"#))
        XCTAssertEqual(result.kind, .denied)
        XCTAssertEqual(gate.requests.count, 1)
        XCTAssertTrue(gate.requests[0].isPermissionChange)
        let state = await controls.engagement
        XCTAssertFalse(state.active, "a denied request must leave engagement mode off")
    }

    func testApprovedArmingAppliesProfileAndDisarmingIsFree() async throws {
        let (ex, _, gate, _, controls) = make()
        _ = await ex.execute(ToolCall(id: "1", name: "set_engagement_mode",
                                      arguments: #"{"enabled":true,"raw_rpc":true,"note":"client X physical"}"#))
        let armed = await controls.engagement
        XCTAssertTrue(armed.active)
        XCTAssertTrue(armed.profile.rawRPC)
        XCTAssertEqual(armed.profile.note, "client X physical")
        XCTAssertEqual(gate.requests.count, 1)

        _ = await ex.execute(ToolCall(id: "2", name: "set_engagement_mode", arguments: #"{"enabled":false}"#))
        XCTAssertEqual(gate.requests.count, 1, "disarming needs no dialog")
        let disarmed = await controls.engagement
        XCTAssertFalse(disarmed.active)
    }

    // MARK: Capability gates

    func testBadUsbExecuteIsLockedUntilArmed() async throws {
        let (ex, flipper, gate, audit, _) = make(files: ["/ext/badusb/a.txt": "REM x"])
        let locked = await ex.execute(ToolCall(id: "1", name: "badusb_execute",
                                               arguments: #"{"path":"/ext/badusb/a.txt"}"#))
        XCTAssertTrue(locked.isError)
        XCTAssertTrue(locked.content.contains("engagement mode"))
        let calls = await flipper.calls
        XCTAssertTrue(calls.isEmpty, "a locked capability must not touch the device")
        XCTAssertTrue(gate.requests.isEmpty)
        let decisions = await audit.records.map(\.decision)
        XCTAssertEqual(decisions, [.blocked])

        let (ex2, flipper2, _, _, _) = make(engagement: armed(autoApprovals: false, autoBadKB: true),
                                            approve: false, files: ["/ext/badusb/a.txt": "REM x"])
        let asked = await ex2.execute(ToolCall(id: "1", name: "badusb_execute",
                                               arguments: #"{"path":"/ext/badusb/a.txt"}"#))
        XCTAssertEqual(asked.kind, .denied, "armed capability without auto-approvals still asks")
        let presses = await flipper2.presses
        XCTAssertTrue(presses.isEmpty)
    }

    func testBadUsbExecuteRunsTheScriptWhenArmed() async throws {
        let (ex, flipper, _, audit, _) = make(engagement: armed(autoBadKB: true),
                                              files: ["/ext/badusb/a.txt": "STRING hi"])
        let result = await ex.execute(ToolCall(id: "1", name: "badusb_execute",
                                               arguments: #"{"path":"/ext/badusb/a.txt"}"#))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.images.count, 1, "the capture after Run is attached")
        let calls = await flipper.calls
        XCTAssertTrue(calls.contains("badusb /ext/badusb/a.txt"))
        XCTAssertTrue(calls.contains("capture"))
        let presses = await flipper.presses
        XCTAssertEqual(presses, ["ok"], "the OK input event starts the script")
        let decisions = await audit.records.map(\.decision)
        XCTAssertEqual(decisions, [.engaged])
    }

    func testRawRPCIsLockedUntilArmedAndFencesOutput() async throws {
        let (ex, flipper, _, _, _) = make()
        let locked = await ex.execute(ToolCall(id: "1", name: "rpc_raw",
                                               arguments: #"{"request":"{\"content\":{\"systemPingRequest\":{}}}"}"#))
        XCTAssertTrue(locked.isError)
        let calls = await flipper.calls
        XCTAssertTrue(calls.isEmpty)

        let (ex2, flipper2, _, _, _) = make(engagement: armed(rawRPC: true))
        let ok = await ex2.execute(ToolCall(id: "1", name: "rpc_raw",
                                            arguments: #"{"request":"{\"content\":{\"systemPingRequest\":{}}}"}"#))
        XCTAssertFalse(ok.isError, ok.content)
        XCTAssertTrue(ok.content.contains("<<<FLIPPER_DATA"), "raw device data is untrusted content")
        let raw = await flipper2.rawRequests
        XCTAssertEqual(raw.first, #"{"content":{"systemPingRequest":{}}}"#)
        let tainted = await ex2.isTainted
        XCTAssertTrue(tainted)
    }

    func testGpioTools() async throws {
        let (ex, flipper, gate, _, _) = make(approve: false)
        let read = await ex.execute(ToolCall(id: "1", name: "gpio",
                                             arguments: #"{"action":"read","pin":"pa4"}"#))
        XCTAssertFalse(read.isError)
        XCTAssertTrue(read.content.contains("high"))
        let write = await ex.execute(ToolCall(id: "2", name: "gpio",
                                              arguments: #"{"action":"write","pin":"pa7","value":"1"}"#))
        XCTAssertEqual(write.kind, .denied, "driving a pin asks")
        XCTAssertEqual(gate.requests.count, 1)
        let configure = await ex.execute(ToolCall(id: "3", name: "gpio",
                                                  arguments: #"{"action":"configure","pin":"pb3","direction":"input","pull":"up"}"#))
        XCTAssertEqual(configure.kind, .denied)
        let calls = await flipper.calls
        XCTAssertEqual(calls, ["gpio read pa4"])
        XCTAssertThrowsError(try ToolInvocation(name: "gpio", arguments: #"{"action":"read","pin":"zz9"}"#))
        XCTAssertThrowsError(try ToolInvocation(name: "gpio", arguments: #"{"action":"explode","pin":"pa4"}"#))
    }

    // MARK: Report

    func testReportContainsTimelineAndDecisions() async throws {
        let audit = InMemoryAuditLog()
        let (ex, _, _, _, _) = make(engagement: armed(autoBadKB: true),
                                    files: ["/ext/badusb/a.txt": "STRING hi"])
        _ = await ex.execute(ToolCall(id: "1", name: "get_device_info", arguments: "{}"))
        _ = await ex.execute(ToolCall(id: "2", name: "badusb_execute", arguments: #"{"path":"/ext/badusb/a.txt"}"#))
        let result = await ex.execute(ToolCall(id: "3", name: "generate_engagement_report", arguments: "{}"))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("# Engagement report"))
        XCTAssertTrue(result.content.contains("| get_device_info | low | auto | ok |"))
        XCTAssertTrue(result.content.contains("| badusb_execute | high | engaged | ok |"))
        XCTAssertTrue(result.content.contains("auto_approvals+auto_badusb"))

        let markdown = EngagementReport.markdown(records: await audit.recent(limit: 10), engagement: .inactive)
        XCTAssertFalse(markdown.contains("Engagement armed"), "a disarmed session reports no arming")
        let hostile = AuditRecord(tool: "read_file", summary: "path | with pipe\nnewline", risk: .low,
                                  decision: .auto, succeeded: true, detail: "")
        let escaped = EngagementReport.markdown(records: [hostile], engagement: .inactive)
        XCTAssertFalse(escaped.components(separatedBy: "\n").contains { $0.contains("path | with pipe") },
                       "table cells must not break the markdown table")
    }

    // MARK: Settings and prompt

    func testSettingsReportEngagementState() async throws {
        let (ex, _, _, _, controls) = make()
        await controls.setEngagement(armed(rawRPC: true))
        let result = await ex.execute(ToolCall(id: "1", name: "get_app_settings", arguments: "{}"))
        XCTAssertTrue(result.content.contains("engagement_mode: armed (auto_approvals+raw_rpc)"), result.content)
        let off = make().0
        let disabled = await off.execute(ToolCall(id: "1", name: "get_app_settings", arguments: "{}"))
        XCTAssertTrue(disabled.content.contains("engagement_mode: off"))
    }

    func testPromptReflectsArming() {
        let locked = AgentPrompts.system(nonce: "n1")
        XCTAssertTrue(locked.contains("not armed"))
        XCTAssertTrue(locked.contains("<<<FLIPPER_DATA"), "the data fence rule stays in every mode")
        let armedPrompt = AgentPrompts.system(nonce: "n1",
                                              engagement: EngagementState(active: true,
                                                                          profile: EngagementProfile(autoBadKB: true),
                                                                          startedAt: Date()))
        XCTAssertTrue(armedPrompt.contains("ARMED"))
        XCTAssertTrue(armedPrompt.contains("badusb_execute"))
        XCTAssertFalse(armedPrompt.contains("Scope note"), "no note, no scope line")
        let scoped = AgentPrompts.system(nonce: "n1",
                                         engagement: EngagementState(active: true,
                                                                     profile: EngagementProfile(note: "office lobby"),
                                                                     startedAt: Date()))
        XCTAssertTrue(scoped.contains("office lobby"))
    }

    func testArgumentParsing() throws {
        let engage = try ToolInvocation(name: "set_engagement_mode",
                                        arguments: #"{"enabled":true,"raw_rpc":true,"note":"x"}"#)
        XCTAssertEqual(engage.toolName, "set_engagement_mode")
        XCTAssertTrue(engage.requiresExplicitConsent)
        guard case .setEngagementMode(true, let profile) = engage else { return XCTFail() }
        XCTAssertTrue(profile.rawRPC)
        XCTAssertFalse(profile.autoBadKB)
        XCTAssertFalse(try ToolInvocation(name: "set_engagement_mode", arguments: #"{"enabled":false}"#)
            .requiresExplicitConsent)
        let report = try ToolInvocation(name: "generate_engagement_report", arguments: "{}")
        XCTAssertEqual(report, .generateEngagementReport(limit: 200))
        let raw = try ToolInvocation(name: "rpc_raw", arguments: #"{"request":"{}"}"#)
        XCTAssertEqual(raw.summary, "Send the raw device command request")
    }
}
