import XCTest
@testable import AgentKit

final class PayloadForgeTests: XCTestCase {
    func testEveryKindHasAFormatReferenceTheModelSees() {
        for kind in PayloadKind.allCases {
            XCTAssertGreaterThan(kind.formatReference.count, 80, "\(kind)")
            if kind != .badusb { XCTAssertTrue(kind.formatReference.contains("Filetype:"), "\(kind)") }
        }
    }

    func testFlipperFilesNeedHeaderAndVersion() throws {
        for kind in PayloadKind.allCases where kind != .badusb {
            XCTAssertNoThrow(try PayloadForge.validate("Filetype: Flipper File\nVersion: 1\n", kind: kind))
            XCTAssertThrowsError(try PayloadForge.validate("Version: 1\n", kind: kind), "\(kind) without header")
            XCTAssertThrowsError(try PayloadForge.validate("Filetype: Flipper File\n", kind: kind), "\(kind) without version")
        }
    }

    func testFencesAreStrippedAndEmptyOutputIsRejected() async throws {
        XCTAssertEqual(PayloadForge.stripFences("```\nSTRING hi\n```"), "STRING hi")
        let fenced = PayloadForge(llm: StubLLM(content: "```duckyscript\nREM hi\nSTRING hello\n```"))
        let content = try await fenced.forge(.badusb, description: "say hello")
        XCTAssertEqual(content, "REM hi\nSTRING hello")
        do {
            _ = try await PayloadForge(llm: StubLLM(content: "```\n```")).forge(.badusb, description: "x")
            XCTFail("expected empty")
        } catch ForgeError.empty {}
    }
}
