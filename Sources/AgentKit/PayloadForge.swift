import Foundation

public enum PayloadKind: String, Sendable, CaseIterable {
    case badusb, subghz, infrared, nfc, rfid, ibutton

    public var fileExtension: String {
        switch self {
        case .badusb: "txt"
        case .subghz: "sub"
        case .infrared: "ir"
        case .nfc: "nfc"
        case .rfid: "rfid"
        case .ibutton: "ibtn"
        }
    }

    /// Default folder on the Flipper for this kind of file.
    public var folder: String {
        switch self {
        case .badusb: "/ext/badusb"
        case .subghz: "/ext/subghz"
        case .infrared: "/ext/infrared"
        case .nfc: "/ext/nfc"
        case .rfid: "/ext/lfrfid"
        case .ibutton: "/ext/ibutton"
        }
    }

    /// Format reference handed to the model. Taken from this firmware's parsers and real sample files,
    /// so generated files actually load on the device.
    var formatReference: String {
        switch self {
        case .badusb:
            """
            Flipper "Bad KB" DuckyScript. One command per line.

            Supported keywords in this firmware:
            REM (comment), DELAY <ms>, DEFAULTDELAY/DEFAULT_DELAY <ms>, STRINGDELAY/STRING_DELAY <ms>,
            STRING <text>, STRINGLN <text> (types text then Enter), REPEAT <n> (repeats previous line),
            WAIT_FOR_BUTTON_PRESS, HOLD <key>, RELEASE <key>, ALTCHAR/ALTCODE/ALTSTRING,
            Modifiers: CTRL/CONTROL, ALT, SHIFT, GUI/WINDOWS, FN
            Keys: ENTER, ESC/ESCAPE, TAB, SPACE, BACKSPACE/BACK, DELETE, INSERT, HOME, END,
            PAGEUP, PAGEDOWN, UP/UPARROW, DOWN/DOWNARROW, LEFT/LEFTARROW, RIGHT/RIGHTARROW,
            F1-F24, CAPSLOCK, NUMLOCK, SCROLLLOCK, PRINTSCREEN, PAUSE, BREAK, MENU, APP, POWER,
            Media: MUTE, VOLUME_UP, VOLUME_DOWN, PLAY, PLAY_PAUSE, STOP, NEXT_TRACK, PREV_TRACK, EJECT,
            Mouse: LEFTCLICK/LEFT_CLICK, RIGHTCLICK/RIGHT_CLICK, MIDDLECLICK, WHEELCLICK,
            MOUSEMOVE <x> <y>, MOUSESCROLL <n>
            Combine modifiers with a key on one line, e.g. "GUI r" or "CTRL SHIFT ESC".

            Start with REM lines describing what the script does. Begin with a DELAY of at least 500
            so the host enumerates the keyboard before typing.
            """
        case .subghz:
            """
            Flipper Sub-GHz file. Two forms.

            Protocol-based (preferred when the protocol is known):
            Filetype: Flipper SubGhz Key File
            Version: 1
            Frequency: 433920000
            Preset: FuriHalSubGhzPresetOok650Async
            Protocol: Princeton
            Bit: 24
            Key: 00 00 00 00 00 12 34 56
            TE: 400

            RAW capture:
            Filetype: Flipper SubGhz RAW File
            Version: 1
            Frequency: 433920000
            Preset: FuriHalSubGhzPresetOok270Async
            Protocol: RAW
            RAW_Data: 400 -400 800 -800 ...   (durations in microseconds, negative = low)

            Presets: FuriHalSubGhzPresetOok270Async, FuriHalSubGhzPresetOok650Async,
            FuriHalSubGhzPreset2FSKDev238Async, FuriHalSubGhzPreset2FSKDev476Async.
            Frequency must be a legal band for the user's region (433.92, 868.35, 315, 915 MHz).
            """
        case .infrared:
            """
            Flipper infrared remote file. One block per button.

            Filetype: IR signals file
            Version: 1
            #
            name: POWER
            type: parsed
            protocol: NEC
            address: 07 00 00 00
            command: 02 00 00 00

            Protocols: NEC, NECext, NEC42, NEC42ext, Samsung32, RC5, RC5X, RC6, SIRC, SIRC15,
            SIRC20, Kaseikyo, RCA, Pioneer.
            Raw blocks use: type: raw, frequency: 38000, duty_cycle: 0.330000,
            data: <space separated durations>.
            Button names are free text, commonly POWER, VOL_UP, VOL_DN, CH_UP, CH_DN, MUTE.
            """
        case .nfc:
            """
            Flipper NFC dump.

            Filetype: Flipper NFC device
            Version: 4
            Device type: UID
            UID: 04 11 22 33
            ATQA: 00 44
            SAK: 00

            Card contents normally come from reading a real card. Generating a dump only makes
            sense for simple UID-only tags; anything with keys or sectors should be captured.
            """
        case .rfid:
            """
            Flipper 125 kHz RFID key file.

            Filetype: Flipper RFID key
            Version: 1
            Key type: EM4100
            Data: 12 34 56 78 90

            Key types: EM4100, H10301, Idteck, Indala26, IOProxXSF, AWID, FDX-A, FDX-B,
            HIDProx, HIDExt, Pyramid, Viking, Jablotron, Paradox, PAC/Stanley, Keri, Gallagher.
            Data length depends on the type (EM4100 is 5 bytes, HID formats differ).
            """
        case .ibutton:
            """
            Flipper iButton key file.

            Filetype: Flipper iButton key
            Version: 1
            Key type: DS1990
            Data: 01 23 45 67 89 AB CD EF

            Key types: DS1990 (8 bytes, first is family code 01, last is CRC), Cyfral (2 bytes),
            Metakom (4 bytes).
            """
        }
    }
}

public enum ForgeError: Error, CustomStringConvertible {
    case unavailable
    case empty
    case wrongFormat(String)

    public var description: String {
        switch self {
        case .unavailable: L("Payload generation needs an API key in Settings")
        case .empty: L("The model returned no content")
        case .wrongFormat(let why): L("The generated file does not look valid: \(why)")
        }
    }
}

/// Generates Flipper file contents from a natural-language description, using the same model
/// as the chat. Output is validated for the target format before it is offered for writing.
public struct PayloadForge: Sendable {
    private let llm: LLMClient

    public init(llm: LLMClient) { self.llm = llm }

    public func forge(_ kind: PayloadKind, description: String) async throws -> String {
        let system = """
        You write Flipper Zero \(kind.rawValue) files for the user's own device and authorized testing.
        Output ONLY the file contents. No markdown fences, no commentary, no explanation.
        The file must load on the device, so follow the format exactly.

        \(kind.formatReference)
        """
        let reply = try await llm.complete(
            messages: [
                ChatMessage(role: .system, content: system),
                ChatMessage(role: .user, content: description),
            ],
            tools: []
        )
        let content = Self.stripFences(reply.content ?? "")
        guard !content.isEmpty else { throw ForgeError.empty }
        try Self.validate(content, kind: kind)
        return content
    }

    /// Models often wrap output in ``` despite instructions.
    static func stripFences(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(_ content: String, kind: PayloadKind) throws {
        let lines = content.components(separatedBy: "\n")
        switch kind {
        case .badusb:
            let known: Set<String> = [
                "REM", "DELAY", "DEFAULTDELAY", "DEFAULT_DELAY", "STRINGDELAY", "STRING_DELAY",
                "DEFAULTSTRINGDELAY", "DEFAULT_STRING_DELAY", "STRING", "STRINGLN", "REPEAT", "HOLD",
                "RELEASE", "WAIT_FOR_BUTTON_PRESS", "ALTCHAR", "ALTCODE", "ALTSTRING", "CTRL", "CONTROL",
                "ALT", "SHIFT", "GUI", "WINDOWS", "FN", "ENTER", "ESC", "ESCAPE", "TAB", "SPACE",
                "BACKSPACE", "BACK", "DELETE", "INSERT", "HOME", "END", "PAGEUP", "PAGEDOWN", "UP",
                "UPARROW", "DOWN", "DOWNARROW", "LEFT", "LEFTARROW", "RIGHT", "RIGHTARROW", "CAPSLOCK",
                "NUMLOCK", "SCROLLLOCK", "PRINTSCREEN", "PAUSE", "BREAK", "MENU", "APP", "POWER",
                "MUTE", "VOLUME_UP", "VOLUME_DOWN", "PLAY", "PLAY_PAUSE", "STOP", "NEXT_TRACK",
                "PREV_TRACK", "EJECT", "LEFTCLICK", "LEFT_CLICK", "RIGHTCLICK", "RIGHT_CLICK",
                "MIDDLECLICK", "MIDDLE_CLICK", "WHEELCLICK", "WHEEL_CLICK", "MOUSEMOVE", "MOUSE_MOVE",
                "MOUSESCROLL", "MOUSE_SCROLL", "SLEEP", "REFRESH", "LOGOFF", "REBOOT", "EXIT", "ID",
                "BT_ID", "BLE_ID", "MEDIA", "GLOBE", "SYSRQ", "SNAPSHOT", "FORWARD", "BRIGHT_UP",
                "BRIGHT_DOWN", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11",
                "F12", "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24",
            ]
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let head = trimmed.components(separatedBy: " ").first ?? trimmed
                guard known.contains(head.uppercased()) else {
                    throw ForgeError.wrongFormat("unknown command '\(head)'")
                }
            }
        case .subghz, .infrared, .nfc, .rfid, .ibutton:
            guard lines.first?.hasPrefix("Filetype:") == true else {
                throw ForgeError.wrongFormat("must start with a Filetype: header")
            }
            guard content.contains("Version:") else {
                throw ForgeError.wrongFormat("missing Version: line")
            }
        }
    }
}
