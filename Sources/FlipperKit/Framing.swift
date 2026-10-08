import Foundation
import FlipperProto
import SwiftProtobuf

public enum FlipperError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case timeout
    case frameTooLarge(Int)
    case malformedFrame
    case rpc(String)
    case invalidPath(String)
    case unexpectedResponse

    public var description: String {
        switch self {
        case .notConnected: L("Flipper is not connected")
        case .timeout: L("Flipper did not answer in time")
        case .frameTooLarge(let n): L("Frame of \(n) bytes exceeds the limit")
        case .malformedFrame: L("Malformed RPC frame")
        case .rpc(let status): L("Flipper RPC error: \(status)")
        case .invalidPath(let why): L("Invalid path: \(why)")
        case .unexpectedResponse: L("Unexpected response from Flipper")
        }
    }
}

public enum Varint {
    public static func encode(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Returns (value, bytesConsumed), or nil if the buffer ends mid-varint.
    public static func decode(_ bytes: Data, from start: Data.Index) throws -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < bytes.endIndex {
            let byte = bytes[index]
            result |= UInt64(byte & 0x7F) << shift
            index = bytes.index(after: index)
            if byte & 0x80 == 0 { return (result, index - start) }
            shift += 7
            if shift > 28 { throw FlipperError.malformedFrame }
        }
        return nil
    }
}

/// Flipper RPC frames are length-delimited PB.Main messages (varint length prefix).
public struct FrameCodec {
    public static let maxFrameSize = 1 << 20

    public static func encode(_ message: PB_Main) throws -> Data {
        let body = try message.serializedData()
        var out = Data(Varint.encode(UInt64(body.count)))
        out.append(body)
        return out
    }
}

/// Reassembles frames out of arbitrarily chunked BLE notifications.
public struct FrameDecoder {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ chunk: Data) throws -> [PB_Main] {
        buffer.append(chunk)
        var messages: [PB_Main] = []
        while true {
            guard let (length, prefix) = try Varint.decode(buffer, from: buffer.startIndex) else { break }
            if length > UInt64(FrameCodec.maxFrameSize) {
                buffer.removeAll()
                throw FlipperError.frameTooLarge(Int(clamping: length))
            }
            let total = prefix + Int(length)
            guard buffer.count >= total else { break }
            let body = buffer.subdata(in: buffer.startIndex + prefix ..< buffer.startIndex + total)
            buffer = Data(buffer.dropFirst(total))
            do {
                messages.append(try PB_Main(serializedBytes: body))
            } catch {
                buffer.removeAll()
                throw FlipperError.malformedFrame
            }
        }
        return messages
    }
}
