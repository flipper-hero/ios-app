import Foundation
import FlipperProto

/// One frame of the Flipper's 128x64 monochrome display.
/// The firmware sends the raw u8g2 buffer: 8 pages of 128 bytes, each byte a vertical
/// strip of 8 pixels with the least significant bit at the top.
public struct FlipperScreenFrame: Sendable, Equatable {
    public static let width = 128
    public static let height = 64

    public enum Orientation: Sendable, Equatable {
        case normal, flipped, vertical, verticalFlipped
    }

    public let buffer: Data
    public let orientation: Orientation

    public init(buffer: Data, orientation: Orientation = .normal) {
        self.buffer = buffer
        self.orientation = orientation
    }

    init?(_ frame: PBGui_ScreenFrame) {
        guard frame.data.count >= Self.width * Self.height / 8 else { return nil }
        let orientation: Orientation = switch frame.orientation {
        case .horizontalFlip: .flipped
        case .vertical: .vertical
        case .verticalFlip: .verticalFlipped
        default: .normal
        }
        self.init(buffer: frame.data, orientation: orientation)
    }

    /// Size as shown to the user, after applying the orientation.
    public var displaySize: (width: Int, height: Int) {
        switch orientation {
        case .normal, .flipped: (Self.width, Self.height)
        case .vertical, .verticalFlipped: (Self.height, Self.width)
        }
    }

    /// Raw buffer pixel, in the framebuffer's own coordinates.
    public func rawPixel(x: Int, y: Int) -> Bool {
        guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return false }
        let index = (y / 8) * Self.width + x
        return buffer[buffer.startIndex + index] & (1 << UInt8(y % 8)) != 0
    }

    /// Pixel as it appears to the user, honouring the orientation.
    public func pixel(x: Int, y: Int) -> Bool {
        switch orientation {
        case .normal: rawPixel(x: x, y: y)
        case .flipped: rawPixel(x: Self.width - 1 - x, y: Self.height - 1 - y)
        case .vertical: rawPixel(x: Self.width - 1 - y, y: x)
        case .verticalFlipped: rawPixel(x: y, y: Self.height - 1 - x)
        }
    }

    /// Row-major on/off pixels in display orientation, convenient for rendering.
    public func pixels() -> [Bool] {
        let size = displaySize
        var out = [Bool](repeating: false, count: size.width * size.height)
        for y in 0..<size.height {
            for x in 0..<size.width { out[y * size.width + x] = pixel(x: x, y: y) }
        }
        return out
    }
}

public enum FlipperKey: String, Sendable, CaseIterable {
    case up, down, left, right, ok, back

    var proto: PBGui_InputKey {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .ok: .ok
        case .back: .back
        }
    }
}

extension FlipperRPCClient {
    /// Live frames. The caller must hold the stream via `acquireScreenStream()`.
    public func screenFrames() -> AsyncStream<FlipperScreenFrame> {
        let messages = unsolicitedMessages()
        return AsyncStream { continuation in
            let task = Task {
                for await message in messages {
                    if case .guiScreenFrame(let raw)? = message.content, let frame = FlipperScreenFrame(raw) {
                        continuation.yield(frame)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One current frame. Starting the stream makes the firmware redraw, so a frame arrives
    /// even on a static screen.
    public func captureScreen(timeout: Duration = .seconds(5)) async throws -> FlipperScreenFrame {
        let frames = screenFrames()
        try await acquireScreenStream()
        defer { Task { await self.releaseScreenStream() } }
        return try await withThrowingTaskGroup(of: FlipperScreenFrame?.self) { group in
            group.addTask {
                for await frame in frames { return frame }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let frame = first else { throw FlipperError.timeout }
            return frame
        }
    }

    /// Presses a button the way a finger does: press, short or long, release.
    /// The three events go out together; waiting for each answer made the remote feel slow.
    public func press(_ key: FlipperKey, long: Bool = false) async throws {
        let events: [PB_Main.OneOf_Content] = [.press, long ? .long : .short, .release].map { (type: PBGui_InputType) in
            var event = PBGui_SendInputEventRequest()
            event.key = key.proto
            event.type = type
            return .guiSendInputEventRequest(event)
        }
        try await callPipelined(events)
    }
}
