import XCTest
import FlipperKit
@testable import AgentKit

/// Builds .tgz archives in memory so tests need no fixtures.
enum TarBuilder {
    static func header(path: String, size: Int, directory: Bool) -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) { for (i, b) in text.utf8.enumerated() { h[offset + i] = b } }
        put(path, at: 0)
        put(directory ? "0000755" : "0000644", at: 100)
        put("0000000", at: 108); put("0000000", at: 116)
        put(String(format: "%011o", size), at: 124)
        put("00000000000", at: 136)
        put("        ", at: 148)
        h[156] = directory ? UInt8(ascii: "5") : UInt8(ascii: "0")
        put("ustar", at: 257); put("00", at: 263)
        let checksum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", checksum), at: 148); h[154] = 0; h[155] = 0x20
        return Data(h)
    }

    static func tar(_ entries: [(String, Data?)]) -> Data {
        var out = Data()
        for (path, data) in entries {
            out.append(header(path: path, size: data?.count ?? 0, directory: data == nil))
            if let data {
                out.append(data)
                out.append(Data(repeating: 0, count: (512 - data.count % 512) % 512))
            }
        }
        out.append(Data(repeating: 0, count: 1024))
        return out
    }

    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(try! (data as NSData).compressed(using: .zlib) as Data) // raw deflate
        out.append(Data(repeating: 0, count: 8)) // CRC and size; our reader does not need them
        return out
    }

    static func package(target: String = "7", extra: [(String, Data?)] = []) -> Data {
        let manifest = Data("Filetype: Flipper firmware upgrade configuration\nVersion: 2\nInfo: test-1\nTarget: \(target)\n".utf8)
        return gzip(tar([("f7-update-test-1/", nil),
                         ("f7-update-test-1/firmware.dfu", Data(repeating: 1, count: 3000)),
                         ("f7-update-test-1/update.fuf", manifest),
                         ("f7-update-test-1/updater.bin", Data(repeating: 2, count: 700))] + extra))
    }
}

actor FakeUpdatingFlipper: FlipperUpdating {
    var info = ["hardware_target": "7"]
    var power = ["charge_level": "80", "charge_state": "discharging"]
    var free: UInt64 = 10_000_000
    var updateResult = FlipperUpdateResult.ok
    private(set) var written: [String: Data] = [:]
    private(set) var order: [String] = []
    private(set) var rebootedIntoUpdater = false

    func set(power: [String: String]) { self.power = power }
    func set(free: UInt64) { self.free = free }
    func set(updateResult: FlipperUpdateResult) { self.updateResult = updateResult }

    func deviceInfo() -> [String: String] { info }
    func powerInfo() -> [String: String] { power }
    func storageInfo(path: String) -> FlipperStorageInfo { .init(totalSpace: 32_000_000, freeSpace: free) }
    func makeDirectories(path: String) { order.append("mkdir \(path)") }
    func write(path: String, data: Data, progress: (@Sendable (Int, Int) -> Void)?) {
        written[path] = data
        order.append("write \(path)")
        progress?(data.count, data.count)
    }
    func requestUpdate(manifestPath: String) -> FlipperUpdateResult { order.append("update \(manifestPath)"); return updateResult }
    func rebootIntoUpdater() { rebootedIntoUpdater = true; order.append("reboot") }
}

final class FirmwareUpdateTests: XCTestCase {
    func testExtractsAnArchive() throws {
        let entries = try TarGz.extract(TarBuilder.package())
        XCTAssertEqual(entries.map(\.path).sorted(),
                       ["f7-update-test-1/firmware.dfu", "f7-update-test-1/update.fuf", "f7-update-test-1/updater.bin"])
        XCTAssertEqual(entries.first { $0.path.hasSuffix("firmware.dfu") }?.data.count, 3000)
    }

    func testRejectsNonGzip() {
        XCTAssertThrowsError(try TarGz.extract(Data("not an archive at all, just text".utf8)))
    }

    func testPackageValidation() throws {
        let package = try FirmwareUpdatePackage(release: "test-1", entries: TarGz.extract(TarBuilder.package()))
        XCTAssertEqual(package.folder, "f7-update-test-1")
        XCTAssertEqual(package.target, "7")
        XCTAssertEqual(package.files.last?.path, "update.fuf", "the manifest is written last")
        XCTAssertEqual(package.manifestPath, "/ext/update/f7-update-test-1/update.fuf")

        let traversal = TarBuilder.package(extra: [("f7-update-test-1/../../int/evil", Data([1]))])
        XCTAssertThrowsError(try FirmwareUpdatePackage(release: "x", entries: TarGz.extract(traversal)))
        let twoFolders = TarBuilder.package(extra: [("other/file.bin", Data([1]))])
        XCTAssertThrowsError(try FirmwareUpdatePackage(release: "x", entries: TarGz.extract(twoFolders)))
        let noManifest = TarBuilder.gzip(TarBuilder.tar([("f7-x/firmware.dfu", Data([1]))]))
        XCTAssertThrowsError(try FirmwareUpdatePackage(release: "x", entries: TarGz.extract(noManifest)))
    }

    func testInstallUploadsEverythingThenStagesAndRestarts() async throws {
        let package = try FirmwareUpdatePackage(release: "test-1", entries: TarGz.extract(TarBuilder.package()))
        let flipper = FakeUpdatingFlipper()
        let last = LastValue()
        try await FirmwareUpdater.install(package, on: flipper, phase: { _ in }, progress: { last.value = $0 })
        let order = await flipper.order
        XCTAssertEqual(order.first, "mkdir /ext/update/f7-update-test-1")
        XCTAssertEqual(order.suffix(3), ["write /ext/update/f7-update-test-1/update.fuf",
                                         "update /ext/update/f7-update-test-1/update.fuf", "reboot"])
        let written = await flipper.written
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(written["/ext/update/f7-update-test-1/firmware.dfu"]?.count, 3000, "uploaded unmodified")
        XCTAssertEqual(last.value, 1, accuracy: 0.0001)
    }

    func testPreflightStopsBeforeWriting() async throws {
        let package = try FirmwareUpdatePackage(release: "test-1", entries: TarGz.extract(TarBuilder.package()))

        let low = FakeUpdatingFlipper()
        await low.set(power: ["charge_level": "12", "charge_state": "discharging"])
        await assertFails(package, on: low) { ($0 as? FirmwareUpdateError) == .batteryTooLow(12) }

        let lowButCharging = FakeUpdatingFlipper()
        await lowButCharging.set(power: ["charge_level": "12", "charge_state": "charging"])
        try await FirmwareUpdater.install(package, on: lowButCharging, phase: { _ in }, progress: { _ in })

        let full = FakeUpdatingFlipper()
        await full.set(free: 100)
        await assertFails(package, on: full) { if case .notEnoughSpace = $0 as? FirmwareUpdateError { true } else { false } }

        let wrong = try FirmwareUpdatePackage(release: "x", entries: TarGz.extract(TarBuilder.package(target: "18")))
        await assertFails(wrong, on: FakeUpdatingFlipper()) {
            ($0 as? FirmwareUpdatePackage.PackageError) == .wrongTarget(package: "18", device: "7")
        }
    }

    func testRejectionDoesNotRestart() async throws {
        let package = try FirmwareUpdatePackage(release: "test-1", entries: TarGz.extract(TarBuilder.package()))
        let flipper = FakeUpdatingFlipper()
        await flipper.set(updateResult: .rejected("manifestInvalid"))
        await assertFails(package, on: flipper) { ($0 as? FirmwareUpdateError) == .rejected("manifestInvalid") }
        let rebooted = await flipper.rebootedIntoUpdater
        XCTAssertFalse(rebooted)
    }

    /// Opt-in check against a real package: FH_REAL_UPDATE_TGZ=/path/to/flipper-z-f7-update-*.tgz swift test
    func testRealMomentumPackage() throws {
        guard let path = ProcessInfo.processInfo.environment["FH_REAL_UPDATE_TGZ"] else {
            throw XCTSkip("set FH_REAL_UPDATE_TGZ to run against a real update package")
        }
        let package = try FirmwareUpdatePackage(release: "real", entries: TarGz.extract(Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(package.target, "7")
        XCTAssertTrue(package.folder.hasPrefix("f7-update-"))
        XCTAssertTrue(package.files.contains { $0.path == "firmware.dfu" })
        XCTAssertGreaterThan(package.totalBytes, 1_000_000)
        print("real package: \(package.folder), \(package.files.count) files, \(package.totalBytes) bytes")
    }

    private func assertFails(_ package: FirmwareUpdatePackage, on flipper: FakeUpdatingFlipper,
                             _ matches: (Error) -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await FirmwareUpdater.install(package, on: flipper, phase: { _ in }, progress: { _ in })
            XCTFail("expected failure", file: file, line: line)
        } catch {
            XCTAssertTrue(matches(error), "unexpected error \(error)", file: file, line: line)
        }
    }
}

final class LastValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0
    var value: Double {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
