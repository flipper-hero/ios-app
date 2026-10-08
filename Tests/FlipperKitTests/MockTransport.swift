import Foundation
import FlipperKit
import FlipperProto

/// Simulated Flipper: decodes request frames and lets a responder script the reply.
final class MockTransport: FlipperTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var _requests: [PB_Main] = []
    var responder: (PB_Main) -> [PB_Main] = { _ in [] }

    init() {
        var cont: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { cont = $0 }
        continuation = cont
    }

    var requests: [PB_Main] { lock.withLock { _requests } }

    func send(_ data: Data) async throws {
        let messages = try lock.withLock { try decoder.append(data) }
        for message in messages {
            lock.withLock { _requests.append(message) }
            let replies = responder(message)
            // Deliver byte-by-byte-ish to exercise reassembly.
            for reply in replies {
                let frame = try FrameCodec.encode(reply)
                var offset = 0
                while offset < frame.count {
                    let end = min(offset + 7, frame.count)
                    continuation.yield(frame.subdata(in: offset ..< end))
                    offset = end
                }
            }
        }
    }

    func close() async { continuation.finish() }

    func inject(_ message: PB_Main) throws {
        continuation.yield(try FrameCodec.encode(message))
    }
}

func reply(to request: PB_Main, hasNext: Bool = false, status: PB_CommandStatus = .ok,
           _ content: PB_Main.OneOf_Content? = nil) -> PB_Main {
    var message = PB_Main()
    message.commandID = request.commandID
    message.hasNext_p = hasNext
    message.commandStatus = status
    message.content = content ?? .empty(PB_Empty())
    return message
}
