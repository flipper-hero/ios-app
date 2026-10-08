import XCTest
@testable import FlipperKit
import FlipperProto

final class ScreenTests: XCTestCase {
    /// Builds a framebuffer with the given display pixels set, in u8g2 page layout.
    private func buffer(setting points: [(Int, Int)]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 1024)
        for (x, y) in points { bytes[(y / 8) * 128 + x] |= 1 << UInt8(y % 8) }
        return Data(bytes)
    }

    func testPageLayoutDecoding() {
        let frame = FlipperScreenFrame(buffer: buffer(setting: [(0, 0), (127, 63), (5, 9)]))
        XCTAssertTrue(frame.pixel(x: 0, y: 0))
        XCTAssertTrue(frame.pixel(x: 127, y: 63))
        XCTAssertTrue(frame.pixel(x: 5, y: 9))
        XCTAssertFalse(frame.pixel(x: 5, y: 8))
        XCTAssertFalse(frame.pixel(x: 6, y: 9))
        XCTAssertEqual(frame.pixels().filter { $0 }.count, 3)
    }

    func testFlippedOrientationRotates180() {
        let frame = FlipperScreenFrame(buffer: buffer(setting: [(0, 0)]), orientation: .flipped)
        XCTAssertTrue(frame.pixel(x: 127, y: 63))
        XCTAssertFalse(frame.pixel(x: 0, y: 0))
    }

    func testVerticalOrientationSwapsSize() {
        let frame = FlipperScreenFrame(buffer: buffer(setting: []), orientation: .vertical)
        XCTAssertEqual(frame.displaySize.width, 64)
        XCTAssertEqual(frame.displaySize.height, 128)
    }

    func testCaptureReceivesTheUnsolicitedFrame() async throws {
        let transport = MockTransport()
        let pixelBuffer = buffer(setting: [(10, 10)])
        transport.responder = { request in
            switch request.content {
            case .guiStartScreenStreamRequest:
                var frame = PBGui_ScreenFrame()
                frame.data = pixelBuffer
                var unsolicited = PB_Main()
                unsolicited.commandID = 0
                unsolicited.content = .guiScreenFrame(frame)
                return [reply(to: request), unsolicited]
            default:
                return [reply(to: request)]
            }
        }
        let client = FlipperRPCClient(transport: transport, timeout: .seconds(2))
        await client.start()
        let frame = try await client.captureScreen(timeout: .seconds(2))
        XCTAssertTrue(frame.pixel(x: 10, y: 10))
        try await Task.sleep(for: .milliseconds(100))
        let stops = transport.requests.filter { if case .guiStopScreenStreamRequest = $0.content { true } else { false } }
        XCTAssertEqual(stops.count, 1, "the stream is stopped again after a one-off capture")
    }

    func testSharedStreamIsStartedOnceAndStoppedLast() async throws {
        let transport = MockTransport()
        transport.responder = { [reply(to: $0)] }
        let client = FlipperRPCClient(transport: transport, timeout: .seconds(2))
        await client.start()
        try await client.acquireScreenStream()
        try await client.acquireScreenStream()
        await client.releaseScreenStream()
        func count(_ predicate: (PB_Main) -> Bool) -> Int { transport.requests.filter(predicate).count }
        XCTAssertEqual(count { if case .guiStartScreenStreamRequest = $0.content { true } else { false } }, 1)
        XCTAssertEqual(count { if case .guiStopScreenStreamRequest = $0.content { true } else { false } }, 0)
        await client.releaseScreenStream()
        XCTAssertEqual(count { if case .guiStopScreenStreamRequest = $0.content { true } else { false } }, 1)
    }

    func testPressSendsPressShortRelease() async throws {
        let transport = MockTransport()
        transport.responder = { [reply(to: $0)] }
        let client = FlipperRPCClient(transport: transport, timeout: .seconds(2))
        await client.start()
        try await client.press(.ok)
        try await client.press(.back, long: true)
        let events = transport.requests.compactMap { message -> PBGui_SendInputEventRequest? in
            if case .guiSendInputEventRequest(let e) = message.content { return e }
            return nil
        }
        XCTAssertEqual(events.map(\.type), [.press, .short, .release, .press, .long, .release])
        XCTAssertEqual(events.map(\.key), [.ok, .ok, .ok, .back, .back, .back])
    }

    func testPressSendsAllEventsBeforeWaitingForAnswers() async throws {
        // Answers only come once all three events arrived; a press that waited for each answer would time out.
        let transport = MockTransport()
        var held: [PB_Main] = []
        transport.responder = { request in
            held.append(request)
            guard held.count == 3 else { return [] }
            defer { held = [] }
            return held.map { reply(to: $0) }
        }
        let client = FlipperRPCClient(transport: transport, timeout: .seconds(1))
        await client.start()
        try await client.press(.down)
        try await client.press(.up, long: true)
        XCTAssertEqual(transport.requests.count, 6)
    }

    func testPressReportsARejectedEvent() async throws {
        let transport = MockTransport()
        transport.responder = { request in
            var answer = reply(to: request)
            if case .guiSendInputEventRequest(let e) = request.content, e.type == .short {
                answer.commandStatus = .errorInvalidParameters
            }
            return [answer]
        }
        let client = FlipperRPCClient(transport: transport, timeout: .seconds(1))
        await client.start()
        do {
            try await client.press(.ok)
            XCTFail("expected an error")
        } catch FlipperError.rpc {
        }
        // Nothing left behind: the next press works normally.
        try await client.press(.ok, long: true)
    }
}
