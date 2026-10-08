import XCTest
import FlipperKit
@testable import AgentKit

/// Runs every tool the agent has, once, through the real executor. A new tool without a sample
/// here fails `testEveryToolHasASample`, so nothing ships untested.
final class ToolSweepTests: XCTestCase {
    /// One valid call per tool, in an order that works against one shared fake device.
    static let samples: [(name: String, args: String)] = [
        ("get_device_info", "{}"),
        ("get_power_info", "{}"),
        ("get_storage_info", "{}"),
        ("list_directory", #"{"path":"/ext/nfc"}"#),
        ("read_file", #"{"path":"/ext/nfc/Card.nfc"}"#),
        ("create_directory", #"{"path":"/ext/sweep"}"#),
        ("write_file", #"{"path":"/ext/sweep/note.txt","content":"hello"}"#),
        ("rename", #"{"from":"/ext/old.txt","to":"/ext/new.txt"}"#),
        ("delete", #"{"path":"/ext/sweep/note.txt"}"#),
        ("launch_app", #"{"name":"Snake"}"#),
        ("transmit_subghz", #"{"path":"/ext/subghz/Garage.sub"}"#),
        ("transmit_infrared", #"{"path":"/ext/infrared/TV.ir","button":"Power"}"#),
        ("emulate_nfc", #"{"path":"/ext/nfc/Card.nfc"}"#),
        ("emulate_rfid", #"{"path":"/ext/lfrfid/Tag.rfid"}"#),
        ("emulate_ibutton", #"{"path":"/ext/ibutton/Door.ibtn"}"#),
        ("load_badusb_script", #"{"path":"/ext/badusb/Hello.txt"}"#),
        ("stop_app", "{}"),
        ("alert_device", "{}"),
        ("forge_payload", #"{"type":"badusb","description":"type hello","path":"/ext/badusb/forged.txt"}"#),
        ("search_faphub", #"{"query":"analog_clock"}"#),
        ("install_faphub_app", #"{"query":"analog_clock"}"#),
        ("github_search", #"{"query":"samsung tv","extension":"ir"}"#),
        ("download_resource", #"{"url":"https://raw.githubusercontent.com/a/b/main/tv.ir","path":"/ext/infrared/tv.ir"}"#),
        ("refresh_device_knowledge", "{}"),
        ("set_device_name", #"{"name":"Hero"}"#),
        ("check_firmware", "{}"),
        ("restart_device", "{}"),
        ("get_audit_log", #"{"limit":5}"#),
        ("get_app_settings", "{}"),
        ("set_read_aloud", #"{"enabled":true}"#),
        ("set_auto_connect", #"{"enabled":false}"#),
        ("set_yolo_mode", #"{"enabled":false}"#),
        ("set_yolo_asks_after_reading", #"{"enabled":true}"#),
        ("set_auto_approve_medium", #"{"enabled":false}"#),
        ("set_model", #"{"model":"anthropic/claude-sonnet-4.5"}"#),
        ("install_firmware_update", "{}"),
        ("firmware_update_status", "{}"),
        ("cancel_firmware_update", "{}"),
        ("look_at_screen", "{}"),
        ("press_buttons", #"{"keys":["down","ok","long_back"],"look_after":false}"#),
        ("set_engagement_mode", #"{"enabled":true,"raw_rpc":true,"auto_badusb":true,"note":"sweep"}"#),
        ("generate_engagement_report", "{}"),
        ("gpio", #"{"action":"configure","pin":"pb3","direction":"input","pull":"up"}"#),
        ("badusb_execute", #"{"path":"/ext/badusb/Hello.txt"}"#),
        ("rpc_raw", #"{"request":"{\"content\":{\"systemPingRequest\":{}}}"}"#),
        ("set_engagement_mode", #"{"enabled":false}"#),
    ]

    override func tearDown() { StubURLProtocol.routes = []; super.tearDown() }

    private func device() -> FakeFlipper {
        FakeFlipper(files: [
            "/ext/nfc/Card.nfc": "Filetype: Flipper NFC device",
            "/ext/lfrfid/Tag.rfid": "Filetype: Flipper RFID key",
            "/ext/ibutton/Door.ibtn": "Filetype: Flipper iButton key",
            "/ext/subghz/Garage.sub": "Filetype: Flipper SubGhz Key File",
            "/ext/infrared/TV.ir": "Filetype: IR signals file",
            "/ext/badusb/Hello.txt": "STRING hello",
            "/ext/old.txt": "old",
        ])
    }

    private func network() {
        var fap = Data([0x7F, 0x45, 0x4C, 0x46]); fap.append(Data(repeating: 7, count: 20))
        StubURLProtocol.routes = [
            ("/application?", 200, Data("""
            [{"_id":"a1","alias":"analog_clock","category_id":"c1",
              "current_version":{"_id":"v1","name":"Analog Clock","version":"1.4","short_description":"Shows a clock"}}]
            """.utf8)),
            ("/build/compatible", 200, fap),
            ("/category", 200, Data(#"[{"_id":"c1","name":"Tools"}]"#.utf8)),
            ("search/code", 200, Data(#"{"items":[{"path":"remotes/tv.ir","repository":{"full_name":"a/b"},"html_url":"https://github.com/a/b/blob/main/remotes/tv.ir"}]}"#.utf8)),
            ("raw.githubusercontent.com", 200, Data("Filetype: IR signals file\nVersion: 1\n".utf8)),
            ("releases/latest", 200, Data(#"{"tag_name":"mntm-012"}"#.utf8)),
        ]
    }

    /// Thread-safe stand-in for the app's policy box: the executor reads engagement state here,
    /// the FakeAppControls sample call writes it, mirroring the app wiring.
    final class EngagementBox: @unchecked Sendable {
        private let lock = NSLock()
        private var state = EngagementState.inactive
        func apply(_ state: EngagementState) { lock.withLock { self.state = state } }
        var current: EngagementState { lock.withLock { state } }
    }

    private func executor(flipper: FakeFlipper, gate: ScriptedGate, audit: AuditSink,
                          controls: FakeAppControls, engagement: EngagementBox) -> ToolExecutor {
        let session = StubURLProtocol.session()
        return ToolExecutor(
            flipper: flipper, gate: gate, audit: audit,
            forge: PayloadForge(llm: StubLLM(content: "STRING hello\nENTER")),
            profileStore: DeviceProfileStore(directory: FileManager.default.temporaryDirectory
                .appending(path: "sweep-\(UUID().uuidString)")),
            fapHub: FapHubClient(session: session), gitHub: GitHubClient(session: session),
            appControls: controls, firmwareChecker: FirmwareUpdateChecker(session: session),
            settings: { ApprovalSettings(engagement: engagement.current) })
    }

    func testEveryToolHasASample() {
        let specced = Set(ToolCatalog.specs.map(\.name))
        let sampled = Set(Self.samples.map(\.name))
        XCTAssertEqual(specced.subtracting(sampled), [], "tools without a sample in ToolSweepTests")
        XCTAssertEqual(sampled.subtracting(specced), [], "samples for tools that do not exist")
        // set_engagement_mode is sampled twice on purpose: arming first, disarming last.
        let counts = Dictionary(grouping: Self.samples.map(\.name), by: { $0 }).mapValues(\.count)
        let duplicated = counts.filter { $0.value > 1 }
        XCTAssertEqual(duplicated, ["set_engagement_mode": 2], "only the engagement pair may repeat")
    }

    func testEverySampleParsesWithASummaryAndARisk() throws {
        for sample in Self.samples {
            let invocation = try ToolInvocation(name: sample.name, arguments: sample.args)
            XCTAssertEqual(invocation.toolName, sample.name)
            XCTAssertFalse(invocation.summary.isEmpty, sample.name)
            let risk = RiskAssessor.assess(invocation)
            XCTAssertNotEqual(risk.level, .blocked, sample.name)
            XCTAssertFalse(risk.reasons.isEmpty, "\(sample.name) needs a reason the user can read")
        }
    }

    func testEveryToolRunsAndIsAudited() async {
        network()
        let flipper = device()
        let audit = InMemoryAuditLog()
        let controls = FakeAppControls()
        let engagement = EngagementBox()
        let ex = executor(flipper: flipper, gate: ScriptedGate(answer: true), audit: audit, controls: controls,
                          engagement: engagement)
        for sample in Self.samples {
            let result = await ex.execute(ToolCall(id: sample.name, name: sample.name, arguments: sample.args))
            XCTAssertEqual(result.kind, .ok, "\(sample.name): \(result.content)")
            if sample.name == "set_engagement_mode" {
                engagement.apply(await controls.engagement)
            }
        }
        let records = await audit.recent(limit: 100)
        XCTAssertEqual(records.map(\.tool), Self.samples.map(\.name))
        XCTAssertTrue(records.allSatisfy(\.succeeded))

        let calls = await flipper.calls
        for expected in ["transmit Sub-GHz /ext/subghz/Garage.sub ", "transmit Infrared /ext/infrared/TV.ir Power",
                         "emulate NFC /ext/nfc/Card.nfc", "emulate 125 kHz RFID /ext/lfrfid/Tag.rfid",
                         "emulate iButton /ext/ibutton/Door.ibtn", "badusb /ext/badusb/Hello.txt", "exitApp",
                         "alert", "setName Hero", "write /ext/apps/Tools/analog_clock.fap"] {
            XCTAssertTrue(calls.contains(expected), "missing \(expected)")
        }
        let files = await flipper.files
        XCTAssertEqual(files["/ext/new.txt"], Data("old".utf8))
        XCTAssertNil(files["/ext/sweep/note.txt"])
        XCTAssertEqual(files["/ext/badusb/forged.txt"], Data("STRING hello\nENTER".utf8))
        XCTAssertNotNil(files["/ext/infrared/tv.ir"])
        let presses = await flipper.presses
        // The trailing "ok" is badusb_execute sending Run after loading the script.
        XCTAssertEqual(presses, ["down", "ok", "long_back", "ok"])
        let state = await controls.state
        XCTAssertEqual(state.model, "anthropic/claude-sonnet-4.5")
        XCTAssertTrue(state.readAloud)
        XCTAssertFalse(state.autoConnect)
        let restarts = await controls.restarts
        XCTAssertEqual(restarts, 1)
    }

    func testDeniedToolsChangeNothing() async {
        network()
        let flipper = device()
        let before = await flipper.files
        let controls = FakeAppControls()
        let gate = ScriptedGate(answer: false)
        let ex = executor(flipper: flipper, gate: gate, audit: InMemoryAuditLog(), controls: controls,
                          engagement: EngagementBox())
        var asked: [String] = []
        for sample in Self.samples {
            let count = gate.requests.count
            let result = await ex.execute(ToolCall(id: sample.name, name: sample.name, arguments: sample.args))
            if gate.requests.count > count {
                asked.append(sample.name)
                XCTAssertEqual(result.kind, .denied, sample.name)
            }
        }
        let after = await flipper.files
        XCTAssertEqual(after, before, "a denied tool wrote, moved or deleted something")
        let calls = await flipper.calls
        // alert_device only beeps to find the device; it is low risk on purpose.
        for forbidden in ["transmit", "emulate", "badusb", "startApp", "setName", "mkdir", "write", "delete", "rename"] {
            XCTAssertFalse(calls.contains { $0.hasPrefix(forbidden) }, "\(forbidden) ran without approval")
        }
        let presses = await flipper.presses
        XCTAssertTrue(presses.isEmpty)
        let restarts = await controls.restarts
        let updates = await controls.updatesStarted
        XCTAssertEqual(restarts + updates, 0)
        for physical in ["transmit_subghz", "transmit_infrared", "emulate_nfc", "emulate_rfid", "emulate_ibutton",
                         "load_badusb_script", "press_buttons", "install_firmware_update", "install_faphub_app"] {
            XCTAssertTrue(asked.contains(physical), "\(physical) must ask")
        }
    }

    /// Every tool named in the AGENTS.md parity table has to exist.
    func testParityTableOnlyNamesRealTools() throws {
        let agents = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "AGENTS.md")
        let text = try String(contentsOf: agents, encoding: .utf8)
        let table = text.components(separatedBy: "\n").filter { $0.hasPrefix("|") && !$0.hasPrefix("|---") }
        let names = Set(table.flatMap { row in
            row.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        }.filter { $0.range(of: #"^[a-z]+(_[a-z]+)+$"#, options: .regularExpression) != nil })
        XCTAssertGreaterThan(names.count, 20)
        let tools = Set(ToolCatalog.specs.map(\.name))
        XCTAssertEqual(names.subtracting(tools), [], "AGENTS.md names tools that do not exist")
    }
}
