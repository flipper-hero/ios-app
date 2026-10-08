import Foundation
import FlipperKit

public enum RiskLevel: Int, Sendable, Comparable, Codable {
    case low = 0, medium, high, blocked
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct RiskAssessment: Sendable, Equatable {
    public var level: RiskLevel
    public var reasons: [String]
}

/// Deterministic, model-independent risk classification.
public enum RiskAssessor {
    /// Internal flash holds pairing keys and system state: never touched by the agent.
    static let blockedRoots = ["/int"]
    static let sensitiveExtensions: Set<String> = ["key", "pem", "priv", "secret", "p12"]
    /// Places where a written file can later execute or reconfigure the device.
    static let executableRoots = ["/ext/apps", "/ext/update", "/ext/badusb", "/ext/apps_data/js_app"]
    static let executableExtensions: Set<String> = ["fap", "js", "dfu", "bin", "elf", "tgz", "fuf"]

    public static func assess(_ invocation: ToolInvocation) -> RiskAssessment {
        switch invocation {
        case .getDeviceInfo, .getPowerInfo:
            return .init(level: .low, reasons: [L("read-only")])
        case .getStorageInfo(let p), .listDirectory(let p):
            return pathRead(p)
        case .readFile(let p):
            var result = pathRead(p)
            if result.level != .blocked, sensitiveExtensions.contains(ext(p)) {
                result = .init(level: .blocked, reasons: [L("reading key or secret files is not allowed")])
            }
            return result
        case .createDirectory(let p):
            return pathWrite(p, base: .medium, why: L("creates a folder"))
        case .writeFile(let p, _):
            return pathWrite(p, base: .medium, why: L("writes a file"))
        case .rename(let a, let b):
            return combine(pathWrite(a, base: .medium, why: L("moves a file")), pathWrite(b, base: .medium, why: L("moves a file")))
        case .launchApp(let name, let args):
            if !args.isEmpty {
                return .init(level: .high, reasons: [L("app '\(name)' receives an argument (it may run or transmit a file)")])
            }
            return .init(level: .medium, reasons: [L("starts an app on the device")])
        case .transmitSubGhz(let p):
            return physical(p, L("transmits a radio signal"))
        case .transmitInfrared(let p, _):
            return physical(p, L("sends an infrared command"))
        case .emulateNFC(let p):
            return physical(p, L("emulates this card to any nearby reader"))
        case .emulateRFID(let p):
            return physical(p, L("emulates this 125 kHz tag to any nearby reader"))
        case .emulateIButton(let p):
            return physical(p, L("emulates this iButton key"))
        case .loadBadKeyboardScript(let p):
            return physical(p, L("loads a keystroke-injection script (you still start it on the Flipper)"))
        case .stopApp:
            return .init(level: .low, reasons: [L("closes the app running on the Flipper")])
        case .installFirmwareUpdate:
            return .init(level: .high, reasons: [L("replaces the firmware; takes 15 to 25 minutes and the Flipper restarts")])
        case .firmwareUpdateStatus:
            return .init(level: .low, reasons: [L("read-only")])
        case .cancelFirmwareUpdate:
            return .init(level: .low, reasons: [L("stops an update before anything is installed")])
        case .lookAtScreen:
            return .init(level: .low, reasons: [L("takes a screenshot of the Flipper")])
        case .pressButtons:
            return .init(level: .high, reasons: [L("presses buttons in whatever app is open, which can start transmissions or delete data")])
        case .checkFirmware, .getAuditLog, .getAppSettings:
            return .init(level: .low, reasons: [L("read-only")])
        case .setReadAloud, .setAutoConnect:
            return .init(level: .low, reasons: [L("changes a harmless app preference")])
        case .restartDevice:
            return .init(level: .medium, reasons: [L("restarts the Flipper; whatever runs on it stops and the connection drops briefly")])
        case .setModel:
            return .init(level: .medium, reasons: [L("changes which model provider receives your conversation and file contents")])
        case .setYoloMode(let on):
            return on ? .init(level: .high, reasons: [L("the agent could then change, delete and transmit without asking you")])
                      : .init(level: .low, reasons: [L("makes the agent ask again")])
        case .setAutoApproveMedium(let on):
            return on ? .init(level: .high, reasons: [L("medium-risk changes would no longer ask you")])
                      : .init(level: .low, reasons: [L("makes the agent ask again")])
        case .setYoloAsksAfterReading(let on):
            return on ? .init(level: .low, reasons: [L("makes the agent ask again after reading device content")])
                      : .init(level: .high, reasons: [L("removes the protection against instructions planted in files on the Flipper")])
        case .setDeviceName:
            return .init(level: .medium, reasons: [L("changes the device name and its Bluetooth identity")])
        case .refreshDeviceKnowledge:
            return .init(level: .low, reasons: [L("reads the device inventory")])
        case .searchFapHub, .searchGitHub:
            return .init(level: .low, reasons: [L("searches the internet, changes nothing")])
        case .installFapHubApp(let q):
            return .init(level: .high, reasons: [L("installs an app '\(q)' that can run code on the device")])
        case .downloadResource(_, let p):
            return pathWrite(p, base: .medium, why: L("writes a file downloaded from the internet"))
        case .forgePayload(_, _, let p):
            return pathWrite(p, base: .medium, why: L("writes a generated file"))
        case .alertDevice:
            return .init(level: .low, reasons: [L("beeps and blinks so you can find the device")])
        case .delete(let p, let recursive):
            guard let n = try? FlipperPath.normalize(p) else { return invalid(p) }
            if isBlocked(n) { return .init(level: .blocked, reasons: [L("protected path")]) }
            let depth = n.split(separator: "/").count
            if recursive && depth <= 2 {
                return .init(level: .blocked, reasons: [L("refusing recursive delete of a top-level folder")])
            }
            return .init(level: .high, reasons: [recursive ? L("deletes a folder and its contents") : L("deletes data")])
#if !FLIPPERHERO_STORE
        case .badUsbExecute(let p):
            return physical(p, L("types a keystroke-injection script into the connected machine on its own"))
        case .gpioConfigure(let pin, let output, _):
            return .init(level: .high, reasons: [output ? L("drives GPIO pin \(pin.rawValue) from the expansion header")
                                                        : L("reconfigures GPIO pin \(pin.rawValue) on the expansion header")])
        case .gpioRead(let pin):
            return .init(level: .low, reasons: [L("reads GPIO pin \(pin.rawValue), changes nothing")])
        case .gpioWrite(let pin, let level):
            return .init(level: .high, reasons: [L("puts \(level ? "3.3 V" : "0 V") on GPIO pin \(pin.rawValue)")])
        case .rawRPC:
            return .init(level: .high, reasons: [L("sends a raw device command that bypasses the normal tool checks")])
        case .setEngagementMode(let enabled, let profile):
            if !enabled {
                return .init(level: .low, reasons: [L("ends engagement mode; the agent asks again")])
            }
            var reasons = [L("the agent runs actions without asking for the rest of the session")]
            if profile.rawRPC { reasons.append(L("raw device commands can reach anything the firmware exposes")) }
            if profile.autoBadKB { reasons.append(L("Bad KB scripts start without anyone pressing Run")) }
            return .init(level: .high, reasons: reasons)
        case .generateEngagementReport:
            return .init(level: .low, reasons: [L("reads the audit log")])
#endif
        }
    }

    // MARK: helpers

    private static func ext(_ path: String) -> String {
        (path.split(separator: ".").last.map(String.init) ?? "").lowercased()
    }

    private static func invalid(_ p: String) -> RiskAssessment {
        .init(level: .blocked, reasons: [L("invalid path")])
    }

    private static func isBlocked(_ normalized: String) -> Bool {
        blockedRoots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    private static func under(_ normalized: String, _ roots: [String]) -> Bool {
        roots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    private static func pathRead(_ p: String) -> RiskAssessment {
        guard let n = try? FlipperPath.normalize(p) else { return invalid(p) }
        if isBlocked(n) { return .init(level: .blocked, reasons: [L("protected path (internal storage)")]) }
        return .init(level: .low, reasons: [L("read-only")])
    }

    private static func pathWrite(_ p: String, base: RiskLevel, why: String) -> RiskAssessment {
        guard let n = try? FlipperPath.normalize(p) else { return invalid(p) }
        if isBlocked(n) { return .init(level: .blocked, reasons: [L("protected path (internal storage)")]) }
        var level = base
        var reasons = [why]
        if under(n, executableRoots) || executableExtensions.contains(ext(n)) {
            level = .high
            reasons.append(L("target can execute code or reconfigure the device"))
        }
        let comps = n.split(separator: "/")
        if comps.count == 2, comps[1].hasPrefix(".") {
            level = .high
            reasons.append(L("hidden configuration file at the SD card root"))
        }
        return .init(level: level, reasons: reasons)
    }

    private static func physical(_ p: String, _ why: String) -> RiskAssessment {
        guard let n = try? FlipperPath.normalize(p) else { return invalid(p) }
        if isBlocked(n) { return .init(level: .blocked, reasons: [L("protected path (internal storage)")]) }
        return .init(level: .high, reasons: [why])
    }

    private static func combine(_ a: RiskAssessment, _ b: RiskAssessment) -> RiskAssessment {
        .init(level: max(a.level, b.level), reasons: Array(Set(a.reasons + b.reasons)).sorted())
    }
}
