import XCTest
import FlipperKit
@testable import AgentKit

final class RemoteControlTests: XCTestCase {
    func testButtonStepParsing() {
        XCTAssertEqual(ButtonStep("ok"), ButtonStep(key: .ok))
        XCTAssertEqual(ButtonStep("LONG_back"), ButtonStep(key: .back, long: true))
        XCTAssertNil(ButtonStep("jump"))
        XCTAssertThrowsError(try ToolInvocation(name: "press_buttons", arguments: #"{"keys":[]}"#))
        let tooMany = Array(repeating: "\"ok\"", count: ButtonStep.maxPerCall + 1).joined(separator: ",")
        XCTAssertThrowsError(try ToolInvocation(name: "press_buttons", arguments: "{\"keys\":[\(tooMany)]}"))
    }

    func testRendererProducesAPNG() throws {
        var bytes = [UInt8](repeating: 0, count: 1024)
        bytes[0] = 1
        let png = try XCTUnwrap(ScreenRenderer.png(FlipperScreenFrame(buffer: Data(bytes)), scale: 2))
        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testLookAtScreenAttachesAnImageAndTaints() async throws {
        let ex = ToolExecutor(flipper: FakeFlipper(), gate: ScriptedGate(answer: true), audit: InMemoryAuditLog())
        let result = await ex.execute(ToolCall(id: "1", name: "look_at_screen", arguments: "{}"))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.images.count, 1)
        let tainted = await ex.isTainted
        XCTAssertTrue(tainted, "what is on the screen is device content")
    }

    func testPressingIsHighRiskAndRunsInOrder() async throws {
        let flipper = FakeFlipper()
        let gate = ScriptedGate(answer: true)
        let ex = ToolExecutor(flipper: flipper, gate: gate, audit: InMemoryAuditLog())
        let result = await ex.execute(ToolCall(id: "1", name: "press_buttons",
                                               arguments: #"{"keys":["down","down","ok","long_back"]}"#))
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(gate.requests.first?.risk, .high)
        let presses = await flipper.presses
        XCTAssertEqual(presses, ["down", "down", "ok", "long_back"])
        XCTAssertEqual(result.images.count, 1, "a capture follows by default")
    }

    func testDeniedPressDoesNothing() async throws {
        let flipper = FakeFlipper()
        let ex = ToolExecutor(flipper: flipper, gate: ScriptedGate(answer: false), audit: InMemoryAuditLog())
        _ = await ex.execute(ToolCall(id: "1", name: "press_buttons", arguments: #"{"keys":["ok"]}"#))
        let presses = await flipper.presses
        XCTAssertTrue(presses.isEmpty)
    }

    func testCapturesReachTheModelAsAUserImageAfterToolReplies() async throws {
        let ex = ToolExecutor(flipper: FakeFlipper(), gate: ScriptedGate(answer: true), audit: InMemoryAuditLog())
        let llm = ScriptedLLM([
            ChatMessage(role: .assistant, content: nil, toolCalls: [
                ToolCall(id: "a", name: "look_at_screen", arguments: "{}"),
                ToolCall(id: "b", name: "get_device_info", arguments: "{}"),
            ]),
            ChatMessage(role: .assistant, content: "The main menu is open."),
        ])
        let session = AgentSession(llm: llm, executor: ex)
        _ = try await session.send("what is on screen?")
        let history = await session.messages
        XCTAssertEqual(history.map(\.role), [.system, .user, .assistant, .tool, .tool, .user, .assistant],
                       "the image message comes after all tool replies of that step")
        XCTAssertEqual(history[5].images.count, 1)
        XCTAssertTrue(history[5].content?.contains("not a message from the user") ?? false)
    }

    func testOldCapturesArePruned() async throws {
        let ex = ToolExecutor(flipper: FakeFlipper(), gate: ScriptedGate(answer: true), audit: InMemoryAuditLog())
        let looks = (0..<4).map { i in
            ChatMessage(role: .assistant, content: nil, toolCalls: [ToolCall(id: "l\(i)", name: "look_at_screen", arguments: "{}")])
        }
        let llm = ScriptedLLM(looks + [ChatMessage(role: .assistant, content: "done")])
        let session = AgentSession(llm: llm, executor: ex)
        _ = try await session.send("watch")
        let sent = llm.seenMessages.last ?? []
        let withImages = sent.filter { !$0.images.isEmpty }
        XCTAssertEqual(withImages.count, AgentSession.keptScreenCaptures)
    }

    func testPNGImagesAreLabelledAsPNG() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0])
        let body = try OpenRouterClient(apiKey: "k", model: "m")
            .makeRequestBody(messages: [ChatMessage(role: .user, content: "x", images: [png])], tools: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let message = try XCTUnwrap((json["messages"] as? [[String: Any]])?.first)
        let parts = try XCTUnwrap(message["content"] as? [[String: Any]])
        let url = try XCTUnwrap((parts.last?["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"), url)
    }
}
