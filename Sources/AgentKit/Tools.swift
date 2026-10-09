import FlipperKit
import Foundation

public enum ToolError: Error, Equatable, CustomStringConvertible {
    case unknownTool(String)
    case badArguments(String)
    public var description: String {
        switch self {
        case .unknownTool(let n): "Unknown tool '\(n)'"
        case .badArguments(let why): "Invalid arguments: \(why)"
        }
    }
}

/// A validated, typed request coming from the model.
public enum ToolInvocation: Sendable, Equatable {
    case listDirectory(path: String)
    case readFile(path: String)
    case getDeviceInfo
    case getPowerInfo
    case getStorageInfo(path: String)
    case createDirectory(path: String)
    case writeFile(path: String, content: String)
    case rename(from: String, to: String)
    case launchApp(name: String, args: String)
    case delete(path: String, recursive: Bool)
    case transmitSubGhz(path: String)
    case transmitInfrared(path: String, button: String)
    case emulateNFC(path: String)
    case emulateRFID(path: String)
    case emulateIButton(path: String)
    case loadBadKeyboardScript(path: String)
    case stopApp
    case alertDevice
    case forgePayload(kind: PayloadKind, description: String, path: String)
    case searchFapHub(query: String)
    case installFapHubApp(query: String)
    case searchGitHub(query: String, fileExtension: String)
    case downloadResource(url: String, path: String)
    case refreshDeviceKnowledge
    case setDeviceName(name: String)
    case checkFirmware
    case restartDevice
    case getAuditLog(limit: Int)
    case getAppSettings
    case setReadAloud(Bool)
    case setAutoConnect(Bool)
    case setYoloMode(Bool)
    case setYoloAsksAfterReading(Bool)
    case setAutoApproveMedium(Bool)
    case setModel(String)
    case setProvider(AIProvider, baseURL: String?)
    case listModels
    case testConnection
    case lookAtScreen
    case installFirmwareUpdate
    case firmwareUpdateStatus
    case cancelFirmwareUpdate
    case pressButtons([ButtonStep], lookAfter: Bool)
#if !FLIPPERHERO_STORE
    case badUsbExecute(path: String)
    case gpioConfigure(pin: FlipperGPIOPin, output: Bool, pullUp: Bool?)
    case gpioRead(pin: FlipperGPIOPin)
    case gpioWrite(pin: FlipperGPIOPin, level: Bool)
    case rawRPC(request: String)
    case setEngagementMode(enabled: Bool, profile: EngagementProfile)
    case generateEngagementReport(limit: Int)
#endif

    public var toolName: String {
        switch self {
        case .listDirectory: "list_directory"
        case .readFile: "read_file"
        case .getDeviceInfo: "get_device_info"
        case .getPowerInfo: "get_power_info"
        case .getStorageInfo: "get_storage_info"
        case .createDirectory: "create_directory"
        case .writeFile: "write_file"
        case .rename: "rename"
        case .launchApp: "launch_app"
        case .delete: "delete"
        case .transmitSubGhz: "transmit_subghz"
        case .transmitInfrared: "transmit_infrared"
        case .emulateNFC: "emulate_nfc"
        case .emulateRFID: "emulate_rfid"
        case .emulateIButton: "emulate_ibutton"
        case .loadBadKeyboardScript: "load_badusb_script"
        case .stopApp: "stop_app"
        case .alertDevice: "alert_device"
        case .forgePayload: "forge_payload"
        case .searchFapHub: "search_faphub"
        case .installFapHubApp: "install_faphub_app"
        case .searchGitHub: "github_search"
        case .downloadResource: "download_resource"
        case .refreshDeviceKnowledge: "refresh_device_knowledge"
        case .setDeviceName: "set_device_name"
        case .checkFirmware: "check_firmware"
        case .restartDevice: "restart_device"
        case .getAuditLog: "get_audit_log"
        case .getAppSettings: "get_app_settings"
        case .setReadAloud: "set_read_aloud"
        case .setAutoConnect: "set_auto_connect"
        case .setYoloMode: "set_yolo_mode"
        case .setYoloAsksAfterReading: "set_yolo_asks_after_reading"
        case .setAutoApproveMedium: "set_auto_approve_medium"
        case .setModel: "set_model"
        case .setProvider: "set_ai_provider"
        case .listModels: "list_models"
        case .testConnection: "test_model_connection"
        case .lookAtScreen: "look_at_screen"
        case .installFirmwareUpdate: "install_firmware_update"
        case .firmwareUpdateStatus: "firmware_update_status"
        case .cancelFirmwareUpdate: "cancel_firmware_update"
        case .pressButtons: "press_buttons"
#if !FLIPPERHERO_STORE
        case .badUsbExecute: "badusb_execute"
        case .gpioConfigure, .gpioRead, .gpioWrite: "gpio"
        case .rawRPC: "rpc_raw"
        case .setEngagementMode: "set_engagement_mode"
        case .generateEngagementReport: "generate_engagement_report"
#endif
        }
    }

    /// Engagement capability this tool needs armed, if any. Checked by the executor.
#if FLIPPERHERO_STORE
    public var armedCapability: KeyPath<EngagementProfile, Bool>? { nil }
#else
    public var armedCapability: KeyPath<EngagementProfile, Bool>? {
        switch self {
        case .badUsbExecute: \.autoBadKB
        case .rawRPC: \.rawRPC
        default: nil
        }
    }
#endif

    /// One-line, human-readable description used for approval prompts and the audit log.
    public var summary: String {
        switch self {
        case .listDirectory(let p): L("List \(p)")
        case .readFile(let p): L("Read \(p)")
        case .getDeviceInfo: L("Read device info")
        case .getPowerInfo: L("Read battery info")
        case .getStorageInfo(let p): L("Read storage info for \(p)")
        case .createDirectory(let p): L("Create folder \(p)")
        case .writeFile(let p, let c): L("Write \(c.utf8.count) bytes to \(p)")
        case .rename(let a, let b): L("Move \(a) to \(b)")
        case .launchApp(let n, let a): a.isEmpty ? L("Launch app \(n)") : L("Launch app \(n) with argument \(a)")
        case .delete(let p, let r): r ? L("Delete \(p) and everything inside") : L("Delete \(p)")
        case .transmitSubGhz(let p): L("Transmit the radio signal \(p)")
        case .transmitInfrared(let p, let b):
            b.isEmpty ? L("Send the infrared remote \(p)") : L("Send infrared button '\(b)' from \(p)")
        case .emulateNFC(let p): L("Emulate the NFC card \(p)")
        case .emulateRFID(let p): L("Emulate the 125 kHz tag \(p)")
        case .emulateIButton(let p): L("Emulate the iButton key \(p)")
        case .loadBadKeyboardScript(let p): L("Open Bad KB with the script \(p) loaded (not started)")
        case .stopApp: L("Close the app running on the Flipper")
        case .alertDevice: L("Make the Flipper beep and blink")
        case .forgePayload(let k, let d, let p): L("Generate a \(k.rawValue) file from \"\(d)\" and write it to \(p)")
        case .searchFapHub(let q): L("Search the Flipper app catalog for \"\(q)\"")
        case .installFapHubApp(let q): L("Download and install the app \"\(q)\" from the official catalog")
        case .searchGitHub(let q, let e): e.isEmpty ? L("Search GitHub for \"\(q)\"") : L("Search GitHub for \"\(q)\" (.\(e) files)")
        case .downloadResource(let u, let p): L("Download \(u) to \(p)")
        case .refreshDeviceKnowledge: L("Re-read what is installed and saved on the Flipper")
        case .setDeviceName(let n): L("Rename the Flipper to \"\(n)\" (applies after a restart)")
        case .checkFirmware: L("Check the firmware for updates")
        case .restartDevice: L("Restart the Flipper")
        case .getAuditLog(let n): L("Show the last \(n) actions from the audit log")
        case .getAppSettings: L("Read the app settings")
        case .setReadAloud(let on): on ? L("Read replies aloud") : L("Stop reading replies aloud")
        case .setAutoConnect(let on): on ? L("Connect to the last Flipper on launch") : L("Stop connecting automatically on launch")
        case .setYoloMode(let on): on ? L("Turn on YOLO mode: changes, deletes and transmissions run without asking") : L("Turn off YOLO mode")
        case .setYoloAsksAfterReading(let on): on ? L("Ask again after reading Flipper content, even in YOLO mode") : L("Stop asking after reading Flipper content in YOLO mode")
        case .setAutoApproveMedium(let on): on ? L("Skip prompts for medium-risk actions") : L("Ask again for medium-risk actions")
        case .setModel(let m): L("Switch the model to \(m)")
        case .setProvider(let provider, _): L("Switch the AI provider to \(provider.name)")
        case .listModels: L("Choose model")
        case .testConnection: L("Test connection")
        case .lookAtScreen: L("Look at the Flipper's screen")
        case .installFirmwareUpdate: L("Download and install the newest firmware release on the Flipper")
        case .firmwareUpdateStatus: L("Check how the firmware update is going")
        case .cancelFirmwareUpdate: L("Cancel the running firmware update")
        case .pressButtons(let keys, _): Self.pressSummary(keys)
#if !FLIPPERHERO_STORE
        case .badUsbExecute(let p): L("Start the Bad KB script \(p) on the Flipper now")
        case .gpioConfigure(let pin, let output, _):
            output ? L("Set GPIO pin \(pin.rawValue) to output") : L("Set GPIO pin \(pin.rawValue) to input")
        case .gpioRead(let pin): L("Read the level of GPIO pin \(pin.rawValue)")
        case .gpioWrite(let pin, let level): L("Drive GPIO pin \(pin.rawValue) \(level ? "high" : "low")")
        case .rawRPC(let request): L("Send the raw device command \(Self.rawCommandName(request))")
        case .setEngagementMode(let enabled, let profile):
            enabled
                ? L("Arm engagement mode (\(profile.summary))\(profile.note.isEmpty ? "" : ": \(profile.note)")")
                : L("End engagement mode")
        case .generateEngagementReport(let n): L("Compile the last \(n) audit entries into an engagement report")
#endif
        }
    }

#if !FLIPPERHERO_STORE
    /// First protobuf message name inside a raw request's content, for the audit line.
    private static func rawCommandName(_ request: String) -> String {
        guard let data = request.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let props)? = json["content"],
              let name = props.keys.sorted().first else { return "request" }
        return name
    }
#endif

    private static func pressSummary(_ keys: [ButtonStep]) -> String {
        let list = keys.map { $0.long ? L("long \($0.key.rawValue)") : $0.key.rawValue }.joined(separator: ", ")
        return L("Press \(list) on the Flipper")
    }

    public static let maxWriteBytes = 32 * 1024

    /// Loosens the agent's own permissions. Always shown to the user as a permission dialog,
    /// regardless of YOLO or auto-approve, because those are exactly what it would change.
    public var requiresExplicitConsent: Bool {
        switch self {
        case .setYoloMode(true), .setAutoApproveMedium(true), .setYoloAsksAfterReading(false):
            true
#if !FLIPPERHERO_STORE
        case .setEngagementMode(true, _): true
#endif
        default: false
        }
    }

    public init(name: String, arguments: String) throws {
        let data = Data(arguments.isEmpty ? "{}".utf8 : arguments.utf8)
        guard let args = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = args else {
            throw ToolError.badArguments("arguments are not a JSON object")
        }
        func bool(_ key: String) throws -> Bool {
            guard let v = args[key]?.boolValue else { throw ToolError.badArguments("missing boolean '\(key)'") }
            return v
        }
        func string(_ key: String, optional: Bool = false) throws -> String {
            if let v = args[key]?.stringValue { return v }
            if optional { return "" }
            throw ToolError.badArguments("missing string '\(key)'")
        }
        switch name {
        case "list_directory": self = .listDirectory(path: try string("path"))
        case "read_file": self = .readFile(path: try string("path"))
        case "get_device_info": self = .getDeviceInfo
        case "get_power_info": self = .getPowerInfo
        case "get_storage_info":
            let p = try string("path", optional: true)
            self = .getStorageInfo(path: p.isEmpty ? "/ext" : p)
        case "create_directory": self = .createDirectory(path: try string("path"))
        case "write_file":
            let content = try string("content")
            guard content.utf8.count <= Self.maxWriteBytes else {
                throw ToolError.badArguments("content larger than \(Self.maxWriteBytes) bytes")
            }
            self = .writeFile(path: try string("path"), content: content)
        case "rename", "move": self = .rename(from: try string("from"), to: try string("to"))
        case "launch_app":
            let appName = try string("name")
            guard !appName.isEmpty, appName.count <= 128,
                  !appName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw ToolError.badArguments("invalid app name")
            }
            self = .launchApp(name: appName, args: try string("args", optional: true))
        case "delete": self = .delete(path: try string("path"), recursive: args["recursive"]?.boolValue ?? false)
        case "transmit_subghz": self = .transmitSubGhz(path: try string("path"))
        case "transmit_infrared":
            self = .transmitInfrared(path: try string("path"), button: try string("button", optional: true))
        case "emulate_nfc": self = .emulateNFC(path: try string("path"))
        case "emulate_rfid": self = .emulateRFID(path: try string("path"))
        case "emulate_ibutton": self = .emulateIButton(path: try string("path"))
        case "load_badusb_script": self = .loadBadKeyboardScript(path: try string("path"))
        case "stop_app": self = .stopApp
        case "alert_device": self = .alertDevice
        case "search_faphub": self = .searchFapHub(query: try string("query"))
        case "install_faphub_app": self = .installFapHubApp(query: try string("query"))
        case "github_search":
            self = .searchGitHub(query: try string("query"), fileExtension: try string("extension", optional: true))
        case "refresh_device_knowledge": self = .refreshDeviceKnowledge
        case "set_device_name": self = .setDeviceName(name: try string("name"))
        case "check_firmware": self = .checkFirmware
        case "look_at_screen": self = .lookAtScreen
        case "install_firmware_update": self = .installFirmwareUpdate
        case "firmware_update_status": self = .firmwareUpdateStatus
        case "cancel_firmware_update": self = .cancelFirmwareUpdate
        case "press_buttons":
            guard case .array(let raw)? = args["keys"], !raw.isEmpty else {
                throw ToolError.badArguments("keys must be a non-empty array")
            }
            guard raw.count <= ButtonStep.maxPerCall else {
                throw ToolError.badArguments("at most \(ButtonStep.maxPerCall) presses per call")
            }
            let steps = try raw.map { value -> ButtonStep in
                guard let text = value.stringValue, let step = ButtonStep(text) else {
                    throw ToolError.badArguments("unknown key '\(value.stringValue ?? "?")'")
                }
                return step
            }
            self = .pressButtons(steps, lookAfter: args["look_after"]?.boolValue ?? true)
        case "restart_device": self = .restartDevice
        case "get_audit_log":
            let raw = args["limit"].flatMap { value -> Int? in
                if case .number(let n) = value { return Int(n) } else { return nil }
            } ?? 10
            self = .getAuditLog(limit: min(max(raw, 1), 50))
        case "get_app_settings": self = .getAppSettings
        case "set_read_aloud": self = .setReadAloud(try bool("enabled"))
        case "set_auto_connect": self = .setAutoConnect(try bool("enabled"))
        case "set_yolo_mode": self = .setYoloMode(try bool("enabled"))
        case "set_yolo_asks_after_reading": self = .setYoloAsksAfterReading(try bool("enabled"))
        case "set_auto_approve_medium": self = .setAutoApproveMedium(try bool("enabled"))
        case "set_model":
            let model = try string("model").trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty, model.count <= 120,
                  model.allSatisfy({ $0.isLetter || $0.isNumber || "/-_.:".contains($0) }) else {
                throw ToolError.badArguments("invalid model id")
            }
            self = .setModel(model)
        case "set_ai_provider":
            guard let provider = AIProvider(rawValue: try string("provider")) else {
                throw ToolError.badArguments("unknown AI provider")
            }
            let baseURL = args["base_url"]?.stringValue
            if let baseURL { _ = try provider.validatedBaseURL(baseURL) }
            self = .setProvider(provider, baseURL: baseURL)
        case "list_models": self = .listModels
        case "test_model_connection": self = .testConnection
        case "download_resource":
            self = .downloadResource(url: try string("url"), path: try string("path"))
        case "forge_payload":
            let raw = try string("type")
            guard let kind = PayloadKind(rawValue: raw.lowercased()) else {
                throw ToolError.badArguments("unknown payload type '\(raw)'")
            }
#if FLIPPERHERO_STORE
            guard kind != .badusb else {
                throw ToolError.badArguments("badusb payloads are not available in this edition")
            }
#endif
            let desc = try string("description")
            var target = try string("path", optional: true)
            if target.isEmpty { throw ToolError.badArguments("missing target 'path'") }
            if !target.lowercased().hasSuffix("." + kind.fileExtension) { target += "." + kind.fileExtension }
            self = .forgePayload(kind: kind, description: desc, path: target)
#if !FLIPPERHERO_STORE
        case "badusb_execute": self = .badUsbExecute(path: try string("path"))
        case "gpio":
            func pin() throws -> FlipperGPIOPin {
                let raw = try string("pin").lowercased()
                guard let parsed = FlipperGPIOPin(rawValue: raw) else {
                    throw ToolError.badArguments("unknown pin '\(raw)' (one of: \(FlipperGPIOPin.allCases.map(\.rawValue).joined(separator: ", ")))")
                }
                return parsed
            }
            switch try string("action").lowercased() {
            case "configure":
                let output = (args["direction"]?.stringValue ?? "output").lowercased() != "input"
                let pull = args["pull"]?.stringValue.map { $0.lowercased() }
                self = .gpioConfigure(pin: try pin(), output: output,
                                      pullUp: pull == "up" ? true : pull == "down" ? false : nil)
            case "read": self = .gpioRead(pin: try pin())
            case "write":
                let level = args["value"]?.stringValue.map { $0 == "1" || $0.lowercased() == "high" } ?? args["value"]?.boolValue
                guard let level else { throw ToolError.badArguments("write needs a 'value' of 0/1 or low/high") }
                self = .gpioWrite(pin: try pin(), level: level)
            default: throw ToolError.badArguments("action must be configure, read or write")
            }
        case "rpc_raw":
            let request = try string("request")
            guard request.utf8.count <= 16 * 1024 else {
                throw ToolError.badArguments("request larger than 16 KB")
            }
            self = .rawRPC(request: request)
        case "set_engagement_mode":
            let enabled = try bool("enabled")
            let profile = EngagementProfile(
                autoApprovals: args["auto_approvals"]?.boolValue ?? true,
                rawRPC: args["raw_rpc"]?.boolValue ?? false,
                autoBadKB: args["auto_badusb"]?.boolValue ?? false,
                note: try string("note", optional: true))
            self = .setEngagementMode(enabled: enabled, profile: profile)
        case "generate_engagement_report":
            let raw = args["limit"].flatMap { value -> Int? in
                if case .number(let n) = value { return Int(n) } else { return nil }
            } ?? 200
            self = .generateEngagementReport(limit: min(max(raw, 1), 400))
#endif
        default: throw ToolError.unknownTool(name)
        }
    }
}

public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
}

public enum ToolCatalog {
    /// Payload types forge_payload offers; the store edition leaves out Bad KB.
    static var forgePayloadTypes: String {
#if FLIPPERHERO_STORE
        "subghz, infrared, nfc, rfid, ibutton"
#else
        "badusb, subghz, infrared, nfc, rfid, ibutton"
#endif
    }

    private static func object(_ props: [String: (String, String)], required: [String]) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for (key, (type, doc)) in props {
            properties[key] = .object(["type": .string(type), "description": .string(doc)])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    public static let specs: [ToolSpec] = {
        var specs: [ToolSpec] = [
        ToolSpec(name: "list_directory", description: "List files and folders at an absolute Flipper path such as /ext/nfc.",
                 parameters: object(["path": ("string", "Absolute path under /ext")], required: ["path"])),
        ToolSpec(name: "read_file", description: "Read a small text file (max 16 KB). Binary files return only a summary.",
                 parameters: object(["path": ("string", "Absolute file path")], required: ["path"])),
        ToolSpec(name: "get_device_info", description: "Hardware name, firmware version and commit of the connected Flipper.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "get_power_info", description: "Battery charge and charging state.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "get_storage_info", description: "Total and free space of the SD card (/ext).",
                 parameters: object(["path": ("string", "Storage root, default /ext")], required: [])),
        ToolSpec(name: "create_directory", description: "Create a folder. Requires user approval.",
                 parameters: object(["path": ("string", "Absolute folder path")], required: ["path"])),
        ToolSpec(name: "write_file", description: "Create or overwrite a text file (max 32 KB). Requires user approval and shows a diff.",
                 parameters: object(["path": ("string", "Absolute file path"), "content": ("string", "Full new file content")],
                                    required: ["path", "content"])),
        ToolSpec(name: "rename", description: "Move or rename a file or folder. Requires user approval.",
                 parameters: object(["from": ("string", "Existing absolute path"), "to": ("string", "New absolute path")],
                                    required: ["from", "to"])),
        ToolSpec(name: "launch_app", description: "Start an app on the Flipper by its name. Passing an argument always needs explicit user approval.",
                 parameters: object(["name": ("string", "App name, e.g. Sub-GHz"), "args": ("string", "Optional app argument")],
                                    required: ["name"])),
        ToolSpec(name: "delete", description: "Delete a file or folder. Always requires explicit user approval.",
                 parameters: object(["path": ("string", "Absolute path"), "recursive": ("boolean", "Delete folder contents too")],
                                    required: ["path"])),
        ToolSpec(name: "transmit_subghz", description: "Transmit a saved .sub radio signal once. Real-world effect, always needs user approval.",
                 parameters: object(["path": ("string", "Absolute path to a .sub file")], required: ["path"])),
        ToolSpec(name: "transmit_infrared", description: "Send a saved .ir remote command once. Real-world effect, always needs user approval.",
                 parameters: object(["path": ("string", "Absolute path to an .ir file"),
                                     "button": ("string", "Button name inside the remote, e.g. Power")], required: ["path"])),
        ToolSpec(name: "emulate_nfc", description: "Emulate a saved .nfc card until stopped. Real-world effect, always needs user approval.",
                 parameters: object(["path": ("string", "Absolute path to a .nfc file")], required: ["path"])),
        ToolSpec(name: "emulate_rfid", description: "Emulate a saved .rfid tag until stopped. Real-world effect, always needs user approval.",
                 parameters: object(["path": ("string", "Absolute path to a .rfid file")], required: ["path"])),
        ToolSpec(name: "emulate_ibutton", description: "Emulate a saved .ibtn key until stopped. Real-world effect, always needs user approval.",
                 parameters: object(["path": ("string", "Absolute path to an .ibtn file")], required: ["path"])),
        ToolSpec(name: "load_badusb_script", description: "Open Bad KB with a script loaded. It is NOT started; the user still presses Run on the Flipper itself.",
                 parameters: object(["path": ("string", "Absolute path to a .txt script")], required: ["path"])),
        ToolSpec(name: "stop_app", description: "Close whatever app is currently running on the Flipper, which also stops emulation.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "alert_device", description: "Make the Flipper beep, blink and vibrate so the user can find it.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "forge_payload", description: "Generate a Flipper file (\(Self.forgePayloadTypes)) from a description and write it to the Flipper. The full generated content is shown to the user for approval before anything is written.",
                 parameters: object([
                    "type": ("string", "One of: badusb, subghz, infrared, nfc, rfid, ibutton"),
                    "description": ("string", "What the file should do, in plain language"),
                    "path": ("string", "Absolute target path, e.g. /ext/badusb/demo.txt"),
                 ], required: ["type", "description", "path"])),
        ToolSpec(name: "search_faphub", description: "Search the official Flipper app catalog. Only returns apps built for the firmware the connected device is running.",
                 parameters: object(["query": ("string", "What to search for")], required: ["query"])),
        ToolSpec(name: "install_faphub_app", description: "Download an app from the official catalog and install it on the Flipper. Installs executable code, so it always needs user approval.",
                 parameters: object(["query": ("string", "App name or alias, as returned by search_faphub")], required: ["query"])),
        ToolSpec(name: "github_search", description: "Search GitHub for Flipper-compatible files, for example .sub or .ir remotes. Returns repository, path and a raw URL.",
                 parameters: object(["query": ("string", "Search terms"),
                                     "extension": ("string", "Restrict to a file extension, e.g. ir or sub")], required: ["query"])),
        ToolSpec(name: "download_resource", description: "Download a raw file from GitHub and write it to the Flipper. The content is shown to the user before anything is written.",
                 parameters: object(["url": ("string", "Raw GitHub URL from github_search"),
                                     "path": ("string", "Absolute target path on the Flipper")], required: ["url", "path"])),
        ToolSpec(name: "refresh_device_knowledge", description: "Re-read the Flipper's firmware, installed apps and saved files. Use when the inventory looks stale or something you expected is missing.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "set_device_name", description: "Rename the Flipper. At most 8 characters, letters, digits, hyphen and underscore. Takes effect after the device restarts.",
                 parameters: object(["name": ("string", "New device name, max 8 characters")], required: ["name"])),
        ToolSpec(name: "check_firmware", description: "Identify the installed firmware distribution and look up its newest release.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "restart_device", description: "Restart the Flipper, for example to apply a new name. The connection drops and the app reconnects.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "get_audit_log", description: "List the most recent actions taken in this app, with the approval decision for each.",
                 parameters: object(["limit": ("integer", "How many entries, 1 to 50, default 10")], required: [])),
        ToolSpec(name: "get_app_settings", description: "Read the app settings: YOLO mode, approval switches, read-aloud, auto-connect, model, and whether an API key is stored.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "set_read_aloud", description: "Turn reading replies aloud on or off.",
                 parameters: object(["enabled": ("boolean", "true to read replies aloud")], required: ["enabled"])),
        ToolSpec(name: "set_auto_connect", description: "Turn connecting to the last Flipper on app launch on or off.",
                 parameters: object(["enabled": ("boolean", "true to auto-connect")], required: ["enabled"])),
        ToolSpec(name: "set_yolo_mode", description: "Turn YOLO mode on or off. Turning it on always shows the user a permission dialog; you cannot enable it yourself. Only offer it when the user asks about it or about fewer prompts.",
                 parameters: object(["enabled": ("boolean", "true to request YOLO mode")], required: ["enabled"])),
        ToolSpec(name: "set_yolo_asks_after_reading", description: "Whether YOLO mode still asks after you read content from the Flipper. Turning this off always needs the user's permission.",
                 parameters: object(["enabled": ("boolean", "true to keep asking after reading device content")], required: ["enabled"])),
        ToolSpec(name: "set_auto_approve_medium", description: "Skip prompts for medium-risk actions. Turning it on always needs the user's permission.",
                 parameters: object(["enabled": ("boolean", "true to skip medium-risk prompts")], required: ["enabled"])),
        ToolSpec(name: "set_model", description: "Switch the model used for the next chat. Use an ID from list_models or provider documentation.",
                 parameters: object(["model": ("string", "Provider model ID")], required: ["model"])),
        ToolSpec(name: "set_ai_provider", description: "Select the AI provider for the next chat: openrouter, ai2342, blackbit, orcarouter, zai, kimi, qwen, minimax. Restores its saved model and key. Optional base_url must be an HTTPS API base on that provider's own domain, for regional or coding-plan access. Never reads or writes keys.",
                 parameters: object(["provider": ("string", "Provider ID"), "base_url": ("string", "Optional regional API base URL")], required: ["provider"])),
        ToolSpec(name: "list_models", description: "Fetch the selected provider's model catalog using its stored key. Credentials are never returned.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "test_model_connection", description: "Send a tiny fixed OK prompt to the selected model using the stored key. May incur provider charges. Sends no conversation or device data.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "install_firmware_update", description: "Download the newest release of the installed firmware distribution and install it over Bluetooth. Runs in the background for 15 to 25 minutes; the Flipper restarts at the end. Check check_firmware first and tell the user what will be installed.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "firmware_update_status", description: "Progress of a running firmware update, or the result of the last one.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "cancel_firmware_update", description: "Cancel a running firmware update. Works while downloading or uploading; once the Flipper restarts into its updater it finishes on its own.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "look_at_screen", description: "Capture the Flipper's 128x64 screen and look at it as an image. Use it to see which app or menu is open before pressing buttons.",
                 parameters: object([:], required: [])),
        ToolSpec(name: "press_buttons",
                 description: "Press buttons on the Flipper like a finger would, to operate any app or menu. Keys: up, down, left, right, ok, back; prefix with long_ for a long press (long_back exits apps). Returns a screen capture afterwards unless look_after is false.",
                 parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "keys": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                         "description": .string("Sequence, e.g. [\"down\", \"down\", \"ok\"], at most 12")]),
                        "look_after": .object(["type": .string("boolean"),
                                               "description": .string("Capture the screen afterwards, default true")]),
                    ]),
                    "required": .array([.string("keys")]),
                    "additionalProperties": .bool(false),
                 ])),
        ]
        #if !FLIPPERHERO_STORE
        specs += [
        ToolSpec(name: "badusb_execute",
                 description: "Start a Bad KB script immediately, without anyone pressing Run on the Flipper. Only available after the operator armed engagement mode with auto_badusb; ask them to arm it first. Keystrokes go to whatever machine the Flipper is plugged into.",
                 parameters: object(["path": ("string", "Absolute path to a .txt script, e.g. from forge_payload or write_file")], required: ["path"])),
        ToolSpec(name: "gpio",
                 description: "Use the GPIO pins on the Flipper's expansion header. Actions: configure (direction input/output, optional pull up/down for inputs), read (level of an input pin), write (drive an output pin high/low). Real-world effect on whatever is wired to the pin.",
                 parameters: object([
                    "action": ("string", "configure, read or write"),
                    "pin": ("string", "One of: pc0, pc1, pc3, pb2, pb3, pa4, pa6, pa7"),
                    "direction": ("string", "For configure: output (default) or input"),
                    "pull": ("string", "For configure with input: up, down or none (default)"),
                    "value": ("string", "For write: 1/high or 0/low"),
                 ], required: ["action", "pin"])),
        ToolSpec(name: "rpc_raw",
                 description: "Send any command from the device's protobuf surface and get the JSON responses back. Request body is a PB_Main JSON with a content field, e.g. {\"content\":{\"systemPingRequest\":{}}}. Only available after the operator armed engagement mode with raw_rpc; ask them to arm it first. It bypasses the path and file protections of the normal tools.",
                 parameters: object(["request": ("string", "PB_Main JSON with exactly one content entry, at most 16 KB")], required: ["request"])),
        ToolSpec(name: "set_engagement_mode",
                 description: "Arm or end engagement mode. Arming always shows the operator a permission dialog; you cannot arm it yourself, only request it. Capabilities: auto_approvals (actions run without per-action prompts), raw_rpc (unlocks rpc_raw), auto_badusb (unlocks badusb_execute). The note is the operator's scope note and is shown on the banner.",
                 parameters: object([
                    "enabled": ("boolean", "true to request arming, false to disarm (disarming needs no dialog)"),
                    "auto_approvals": ("boolean", "Skip per-action prompts, default true"),
                    "raw_rpc": ("boolean", "Unlock raw device commands, default false"),
                    "auto_badusb": ("boolean", "Unlock starting Bad KB scripts, default false"),
                    "note": ("string", "Short scope note for the banner, e.g. the engagement name"),
                 ], required: ["enabled"])),
        ToolSpec(name: "generate_engagement_report",
                 description: "Compile recent audit log entries into a markdown engagement report: every action with time, tool, risk, decision and outcome. Use it at the end of an engagement, or when the operator asks for a timeline or report.",
                 parameters: object(["limit": ("integer", "How many entries, 1 to 400, default 200")], required: [])),
        ]
        #endif
        return specs
    }()
}

/// One button press for `press_buttons`, parsed from "ok" or "long_back".
public struct ButtonStep: Sendable, Equatable {
    public static let maxPerCall = 12
    public var key: FlipperKey
    public var long: Bool

    public init(key: FlipperKey, long: Bool = false) { self.key = key; self.long = long }

    public init?(_ text: String) {
        var name = text.lowercased().trimmingCharacters(in: .whitespaces)
        let long = name.hasPrefix("long_") || name.hasPrefix("long ")
        if long { name = String(name.dropFirst(5)) }
        guard let key = FlipperKey(rawValue: name) else { return nil }
        self.init(key: key, long: long)
    }
}
