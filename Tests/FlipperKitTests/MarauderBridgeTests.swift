import XCTest
@testable import FlipperKit
import FlipperProto

final class MarauderBridgeTests: XCTestCase {
    func testRPCBridgeForwardsOutputAndClosesApp() async throws {
        let transport = MockTransport()
        transport.responder = { request in
            switch request.content {
            case .appStartRequest:
                var state = PBApp_AppStateResponse()
                state.state = .appStarted
                var notification = PB_Main()
                notification.commandID = 0
                notification.content = .appStateResponse(state)
                return [reply(to: request), notification]
            case .appDataExchangeRequest(let command):
                XCTAssertEqual(String(decoding: command.data, as: UTF8.self), "help")
                var data = PBApp_DataExchangeRequest()
                data.data = Data("#help\r\nscanap\n".utf8)
                var notification = PB_Main()
                notification.commandID = 0
                notification.content = .appDataExchangeRequest(data)
                return [reply(to: request), notification]
            default:
                return [reply(to: request)]
            }
        }
        let client = FlipperRPCClient(transport: transport)
        await client.start()
        let output = try await client.marauder(.commands)
        XCTAssertEqual(output, "#help\nscanap")
        XCTAssertTrue(transport.requests.contains { if case .appExitRequest = $0.content { true } else { false } })
        await client.stop()
    }
}
