import XCTest
@testable import FlipperKit
import FlipperProto

/// App control, storage and system commands against `SimulatedFlipper`.
final class DeviceTests: XCTestCase {
    // MARK: App control

    func testTransmitOpensLoadsPressesReleasesAndCloses() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/subghz/Garage.sub": "Filetype: Flipper SubGhz Key File"])
        let client = await flipper.client()
        try await client.transmitOnce(.subGhz, path: "/ext/subghz/Garage.sub", hold: .milliseconds(1))
        XCTAssertEqual(flipper.log, ["stat /ext/subghz/Garage.sub", "appStart Sub-GHz RPC",
                                     "appLoad /ext/subghz/Garage.sub", "appPress ", "appRelease", "appExit"])
    }

    func testInfraredPassesTheButtonName() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/infrared/TV.ir": "Filetype: IR signals file"])
        let client = await flipper.client()
        try await client.transmitOnce(.infrared, path: "/ext/infrared/TV.ir", button: "Power", hold: .milliseconds(1))
        XCTAssertTrue(flipper.log.contains("appPress Power"))
    }

    func testWrongFileTypeIsRejectedBeforeTouchingTheDevice() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/nfc/Card.nfc": "x"])
        let client = await flipper.client()
        do {
            try await client.transmitOnce(.subGhz, path: "/ext/nfc/Card.nfc", hold: .milliseconds(1))
            XCTFail("expected invalidPath")
        } catch FlipperError.invalidPath {}
        XCTAssertTrue(flipper.log.isEmpty)
    }

    func testMissingFileStopsBeforeStartingTheApp() async throws {
        let flipper = SimulatedFlipper()
        let client = await flipper.client()
        do {
            try await client.emulate(.nfc, path: "/ext/nfc/Missing.nfc")
            XCTFail("expected an error")
        } catch FlipperError.rpc {}
        XCTAssertEqual(flipper.log, ["stat /ext/nfc/Missing.nfc"])
    }

    func testFailedLoadClosesTheApp() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/lfrfid/Tag.rfid": "x"])
        flipper.failures["appLoad"] = .errorInvalidParameters
        let client = await flipper.client()
        do {
            try await client.emulate(.rfid, path: "/ext/lfrfid/Tag.rfid")
            XCTFail("expected an error")
        } catch FlipperError.rpc {}
        XCTAssertEqual(flipper.log.last, "appExit")
    }

    func testFailedPressStillClosesTheApp() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/subghz/Gate.sub": "x"])
        flipper.failures["appPress"] = .errorInvalidParameters
        let client = await flipper.client()
        do {
            try await client.transmitOnce(.subGhz, path: "/ext/subghz/Gate.sub", hold: .milliseconds(1))
            XCTFail("expected an error")
        } catch FlipperError.rpc {}
        XCTAssertEqual(flipper.log.last, "appExit")
        XCTAssertFalse(flipper.log.contains("appRelease"))
    }

    func testEmulationKeepsTheAppOpen() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/ibutton/Door.ibtn": "x"])
        let client = await flipper.client()
        try await client.emulate(.iButton, path: "/ext/ibutton/Door.ibtn")
        XCTAssertEqual(flipper.log, ["stat /ext/ibutton/Door.ibtn", "appStart iButton RPC", "appLoad /ext/ibutton/Door.ibtn"])
        try await client.exitApp()
        XCTAssertEqual(flipper.log.last, "appExit")
    }

    func testBadKBIsOpenedWithTheScriptButNeverStarted() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/badusb/Hello.txt": "STRING hi"])
        let client = await flipper.client()
        try await client.loadBadKeyboardScript(path: "/ext/badusb/Hello.txt")
        XCTAssertEqual(flipper.log, ["stat /ext/badusb/Hello.txt", "appStart Bad KB /ext/badusb/Hello.txt"])
    }

    func testAppErrorIsReported() async throws {
        let flipper = SimulatedFlipper()
        let client = await flipper.client()
        let none = try await client.appError()
        XCTAssertNil(none)
        flipper.appErrorText = "Invalid file"
        let error = try await client.appError()
        XCTAssertEqual(error, "Invalid file")
    }

    // MARK: System

    func testRebootModesAndAlert() async throws {
        let flipper = SimulatedFlipper()
        let client = await flipper.client()
        try await client.reboot()
        try await client.rebootIntoUpdater()
        try await client.playAlert()
        XCTAssertEqual(flipper.log, ["reboot os", "reboot update", "alert"])
    }

    func testRebootToleratesTheLinkDropping() async throws {
        let flipper = SimulatedFlipper()
        flipper.transport.responder = { _ in [] }
        let client = await flipper.client()
        await flipper.transport.close()
        try await client.reboot()
    }

    func testUpdateRequestResult() async throws {
        let flipper = SimulatedFlipper()
        let client = await flipper.client()
        let ok = try await client.requestUpdate(manifestPath: "/ext/update/f7-update-mntm-012/update.fuf")
        XCTAssertEqual(ok, .ok)
        flipper.updateResult = .targetMismatch
        let rejected = try await client.requestUpdate(manifestPath: "/ext/update/f7-update-mntm-012/update.fuf")
        XCTAssertEqual(rejected, .rejected("targetMismatch"))
        XCTAssertEqual(flipper.log.first, "update /ext/update/f7-update-mntm-012/update.fuf")
    }

    // MARK: Storage

    func testWriteSplitsIntoChunksAndRoundTrips() async throws {
        let flipper = SimulatedFlipper()
        let client = await flipper.client()
        let data = Data((0..<1300).map { UInt8($0 % 251) })
        let progress = ProgressRecorder()
        try await client.write(path: "/ext/test.bin", data: data) { sent, total in progress.add(sent, total) }
        XCTAssertEqual(flipper.log.filter { $0 == "write /ext/test.bin" }.count, 3, "512 + 512 + 276 bytes")
        XCTAssertEqual(flipper.files["/ext/test.bin"], data)
        XCTAssertEqual(progress.last?.0, 1300)
        let back = try await client.read(path: "/ext/test.bin")
        XCTAssertEqual(back, data)
    }

    func testEmptyFileIsWrittenAsOneRequest() async throws {
        let flipper = SimulatedFlipper()
        let client = await flipper.client()
        try await client.write(path: "/ext/empty.txt", data: Data())
        XCTAssertEqual(flipper.files["/ext/empty.txt"], Data())
    }

    func testReadRefusesDirectoriesAndLargeFiles() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/big.bin": String(repeating: "x", count: 2000)])
        let client = await flipper.client()
        do { _ = try await client.read(path: "/ext", maxBytes: 100); XCTFail() } catch FlipperError.invalidPath {}
        do { _ = try await client.read(path: "/ext/big.bin", maxBytes: 100); XCTFail() } catch FlipperError.rpc {}
        XCTAssertFalse(flipper.log.contains("read /ext/big.bin"), "size is checked before any transfer")
    }

    func testMakeDirectoriesCreatesMissingParentsAndToleratesExisting() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/update/old.txt": "x"])
        let client = await flipper.client()
        try await client.makeDirectories(path: "/ext/update/f7-update-mntm-012")
        XCTAssertTrue(flipper.dirs.contains("/ext/update/f7-update-mntm-012"))
        XCTAssertEqual(flipper.log, ["mkdir /ext/update", "mkdir /ext/update/f7-update-mntm-012"])
    }

    func testDeleteRenameAndInfo() async throws {
        let flipper = SimulatedFlipper(files: ["/ext/a/one.txt": "1", "/ext/a/two.txt": "2", "/ext/b.txt": "b"])
        let client = await flipper.client()
        try await client.rename(from: "/ext/b.txt", to: "/ext/c.txt")
        try await client.delete(path: "/ext/a", recursive: true)
        let info = try await client.storageInfo()
        XCTAssertEqual(Set(flipper.files.keys), ["/ext/c.txt"])
        XCTAssertEqual(info, FlipperStorageInfo(totalSpace: 1000, freeSpace: 400))
        XCTAssertTrue(flipper.log.contains("delete /ext/a recursive"))
    }

    func testPathsOutsideTheSDCardNeverLeaveThePhone() async throws {
        let flipper = SimulatedFlipper()
        let client = await flipper.client()
        for path in ["/ext/../int/secret", "relative.txt", "/etc/passwd"] {
            do { _ = try await client.read(path: path); XCTFail(path) } catch FlipperError.invalidPath {}
        }
        XCTAssertTrue(flipper.log.isEmpty)
    }

    // MARK: Device name

    func testDeviceNameIsWrittenAndReadBack() async throws {
        let flipper = SimulatedFlipper()
        let client = await flipper.client()
        let before = try await client.customDeviceName()
        XCTAssertNil(before)
        try await client.setDeviceName("Hero")
        let after = try await client.customDeviceName()
        XCTAssertEqual(after, "Hero")
        XCTAssertEqual(String(data: flipper.files[FlipperName.path]!, encoding: .utf8),
                       "Filetype: Flipper Name File\nVersion: 1\nName: Hero\n")
    }

    func testDeviceNameValidation() async throws {
        XCTAssertEqual(try FlipperName.validate("  Hero_1 "), "Hero_1")
        XCTAssertThrowsError(try FlipperName.validate("NineChars")) { XCTAssertEqual($0 as? FlipperName.NameError, .tooLong(9)) }
        XCTAssertThrowsError(try FlipperName.validate("")) { XCTAssertEqual($0 as? FlipperName.NameError, .empty) }
        XCTAssertThrowsError(try FlipperName.validate("a b")) { XCTAssertEqual($0 as? FlipperName.NameError, .invalidCharacters) }
        XCTAssertNil(FlipperName.parse("Filetype: Flipper Name File\nName: \n"))

        let flipper = SimulatedFlipper()
        let client = await flipper.client()
        do { try await client.setDeviceName("WayTooLongName"); XCTFail() } catch is FlipperName.NameError {}
        XCTAssertNil(flipper.files[FlipperName.path], "an invalid name never reaches the SD card")
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func add(_ sent: Int, _ total: Int) { lock.withLock { values.append((sent, total)) } }
    var last: (Int, Int)? { lock.withLock { values.last } }
}
