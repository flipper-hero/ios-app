import XCTest
@testable import FlipperKit
import FlipperProto

final class FramingTests: XCTestCase {
    func testVarintRoundTrip() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 16_383, 16_384, 1 << 20] {
            let bytes = Data(Varint.encode(value))
            let (decoded, used) = try XCTUnwrap(Varint.decode(bytes, from: bytes.startIndex))
            XCTAssertEqual(decoded, value)
            XCTAssertEqual(used, bytes.count)
        }
    }

    func testVarintIncompleteReturnsNil() throws {
        XCTAssertNil(try Varint.decode(Data([0x80]), from: 0))
    }

    func testDecoderReassemblesByteByByte() throws {
        var a = PB_Main(); a.commandID = 1; a.content = .systemPingRequest(.init())
        var b = PB_Main(); b.commandID = 2; b.content = .systemDeviceInfoRequest(.init())
        var stream = try FrameCodec.encode(a)
        stream.append(try FrameCodec.encode(b))

        var decoder = FrameDecoder()
        var out: [PB_Main] = []
        for byte in stream { out += try decoder.append(Data([byte])) }
        XCTAssertEqual(out.map(\.commandID), [1, 2])
    }

    func testDecoderRejectsOversizedFrame() {
        var decoder = FrameDecoder()
        let huge = Data(Varint.encode(UInt64(FrameCodec.maxFrameSize) + 1))
        XCTAssertThrowsError(try decoder.append(huge)) { error in
            guard case FlipperError.frameTooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testDecoderRejectsGarbageBody() {
        var decoder = FrameDecoder()
        var frame = Data(Varint.encode(3))
        frame.append(contentsOf: [0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try decoder.append(frame))
    }

    func testPathNormalization() throws {
        XCTAssertEqual(try FlipperPath.normalize("/ext//nfc/./a.nfc"), "/ext/nfc/a.nfc")
        XCTAssertEqual(try FlipperPath.normalize("/ext/"), "/ext")
        XCTAssertThrowsError(try FlipperPath.normalize("/ext/../int/x"))
        XCTAssertThrowsError(try FlipperPath.normalize("relative/path"))
        XCTAssertThrowsError(try FlipperPath.normalize("/etc/passwd"))
        XCTAssertThrowsError(try FlipperPath.normalize("/ext/a\nb"))
        XCTAssertThrowsError(try FlipperPath.normalize(""))
        XCTAssertThrowsError(try FlipperPath.normalize("/ext/" + String(repeating: "a", count: 300)))
    }
}
