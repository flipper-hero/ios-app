import XCTest
@testable import FlipperHero

/// Mapping from saved files to tools for Siri and Shortcuts, and update cancel states.
@MainActor
final class ShortcutTests: XCTestCase {
    func testCardsMapToTheirEmulationTool() {
        XCTAssertEqual(SavedCard(id: "/ext/nfc/Office.nfc").tool, "emulate_nfc")
        XCTAssertEqual(SavedCard(id: "/ext/lfrfid/Gate.rfid").tool, "emulate_rfid")
        XCTAssertEqual(SavedCard(id: "/ext/ibutton/Door.ibtn").tool, "emulate_ibutton")
        XCTAssertEqual(SavedCard(id: "/ext/nfc/Office.nfc").name, "Office")
    }

    func testSignalsMapToTheirTransmitTool() {
        XCTAssertEqual(SavedSignal(id: "/ext/subghz/Garage.sub").tool, "transmit_subghz")
        XCTAssertEqual(SavedSignal(id: "/ext/infrared/TV.ir").tool, "transmit_infrared")
    }

    func testOnlyMatchingFilesAreAccepted() {
        XCTAssertTrue(SavedCard.accepts("/ext/nfc/Hotel.nfc"))
        XCTAssertFalse(SavedCard.accepts("/ext/nfc/notes.txt"), "wrong extension")
        XCTAssertFalse(SavedCard.accepts("/ext/subghz/Garage.sub"), "a signal is not a card")
        XCTAssertFalse(SavedCard.accepts("/ext/nfcx/Hotel.nfc"), "folder prefix must match exactly")
        XCTAssertFalse(SavedSignal.accepts("/int/subghz/Garage.sub"))
        XCTAssertEqual(SavedSignal.entities(for: ["/ext/subghz/A.sub", "/ext/nfc/B.nfc"]).map(\.id), ["/ext/subghz/A.sub"])
    }

    func testCancellingWithoutAnUpdateSaysSo() {
        let controller = FirmwareUpdateController()
        XCTAssertEqual(controller.cancel(), "No update is running.")
        XCTAssertFalse(controller.isBusy)
    }

    func testShortcutErrorsReadWell() {
        let messages: [ShortcutError] = [.noKnownFlipper, .unreachable("Laisear"), .busy, .cancelled, .failed("x")]
        for error in messages {
            XCTAssertFalse(String(localized: error.localizedStringResource).isEmpty)
        }
        XCTAssertTrue(String(localized: ShortcutError.unreachable("Laisear").localizedStringResource).contains("Laisear"))
    }
}
