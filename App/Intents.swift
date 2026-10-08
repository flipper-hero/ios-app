import AppIntents
import AgentKit
import FlipperKit

// Siri and Shortcuts. Every action runs the same tool the agent would use, with the same
// validation, risk check, blocked paths and audit log. When a tool needs approval, the
// Siri or Shortcuts confirmation takes the place of the in-app dialog.

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case noKnownFlipper
    case unreachable(String)
    case busy
    case cancelled
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noKnownFlipper: "Connect to your Flipper in FlipperHero once first."
        case .unreachable(let name): "Could not reach \(name). Is it on, nearby and Bluetooth enabled?"
        case .busy: "The agent is still working on something else."
        case .cancelled: "Cancelled."
        case .failed(let message): "\(message)"
        }
    }
}

@MainActor
enum ShortcutRunner {
    /// Connects if needed and runs one tool. Returns the tool's output.
    @discardableResult
    static func run<Intent: AppIntent>(tool: String, arguments: [String: String] = [:],
                                       intent: Intent) async throws -> String {
        let model = AppModel.shared
        try await model.ensureConnected()
        let result = await model.runShortcut(tool: tool, arguments: arguments) { request in
            await confirm(request, intent: intent)
        }
        switch result.kind {
        case .ok: return result.content
        case .denied: throw ShortcutError.cancelled
        case .error, .blocked: throw ShortcutError.failed(result.content)
        }
    }

    /// Cancelling must work even while the Flipper is restarting and not connected.
    static func cancelFirmwareUpdate<Intent: AppIntent>(intent: Intent) async throws -> String {
        let model = AppModel.shared
        guard model.isConnected else { return model.firmwareUpdate.cancel() }
        return try await run(tool: "cancel_firmware_update", intent: intent)
    }

#if !FLIPPERHERO_STORE
    /// Disarming needs no device and no confirmation, so it never touches the shortcut flow.
    static func disarmEngagement() {
        Task { @MainActor in AppModel.shared.applyEngagement(.inactive, audit: true) }
    }
#endif

    private static func confirm<Intent: AppIntent>(_ request: ApprovalRequest, intent: Intent) async -> Bool {
        // Summary and reason are already localized; joining them needs no grammar of its own.
        let dialog = IntentDialog("\(request.summary)?\n\(request.reasons.joined(separator: "\n"))")
        do {
            if #available(iOS 18.0, *) {
                try await intent.requestConfirmation(actionName: .run, dialog: dialog)
            } else {
                try await intent.requestConfirmation()
            }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Intents

struct AskFlipperHeroIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask FlipperHero"
    static let description = IntentDescription("Sends a request to the FlipperHero agent and returns its answer.")
    static let openAppWhenRun = true

    @Parameter(title: "Request", requestValueDialog: "What should the agent do?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await AppModel.shared.ask(request)
        return .result(value: answer, dialog: "\(answer)")
    }
}

struct FlipperBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Flipper Battery"
    static let description = IntentDescription("Tells you how charged your Flipper is.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        try await model.ensureConnected()
        let battery = try await model.readBattery()
        return .result(value: battery, dialog: "\(model.deviceDisplayName) is at \(battery).")
    }
}

struct EmulateCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Emulate Card or Key"
    static let description = IntentDescription(
        "Emulates a saved NFC card, 125 kHz tag or iButton key on your Flipper until you stop it.")

    @Parameter(title: "Card or key")
    var card: SavedCard

    static var parameterSummary: some ParameterSummary { Summary("Emulate \(\.$card)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await ShortcutRunner.run(tool: card.tool, arguments: ["path": card.id], intent: self)
        return .result(dialog: "Emulating \(card.name). Stop it from the Lock Screen or say “Stop Flipper App”.")
    }
}

struct TransmitSignalIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Signal"
    static let description = IntentDescription("Sends a saved Sub-GHz signal or infrared command once.")

    @Parameter(title: "Signal")
    var signal: SavedSignal

    @Parameter(title: "Infrared button", description: "Only for infrared remotes, for example Power.")
    var button: String?

    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$signal) \(\.$button)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var arguments = ["path": signal.id]
        if let button, !button.isEmpty { arguments["button"] = button }
        try await ShortcutRunner.run(tool: signal.tool, arguments: arguments, intent: self)
        return .result(dialog: "Sent \(signal.name).")
    }
}

struct FlipperHeroShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskFlipperHeroIntent(),
                    phrases: ["Ask \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Ask the Agent", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: FlipperBatteryIntent(),
                    phrases: ["\(.applicationName) battery", "How charged is my Flipper in \(.applicationName)"],
                    shortTitle: "Battery", systemImageName: "battery.75percent")
        AppShortcut(intent: EmulateCardIntent(),
                    phrases: ["Emulate a card with \(.applicationName)", "Emulate \(\.$card) with \(.applicationName)"],
                    shortTitle: "Emulate", systemImageName: "wave.3.right")
        AppShortcut(intent: TransmitSignalIntent(),
                    phrases: ["Send a signal with \(.applicationName)", "Send \(\.$signal) with \(.applicationName)"],
                    shortTitle: "Send Signal", systemImageName: "antenna.radiowaves.left.and.right")
        AppShortcut(intent: StopFlipperAppIntent(),
                    phrases: ["Stop the Flipper app with \(.applicationName)"],
                    shortTitle: "Stop", systemImageName: "stop.circle")
    }
}

// MARK: - Saved files as Shortcut parameters

/// A file in one of the Flipper's standard folders, identified by its full path.
protocol SavedFlipperFile: AppEntity where ID == String {
    /// Folder, required extension and the tool that uses files from it.
    static var folders: [(path: String, ext: String, tool: String, label: String)] { get }
    init(id: String)
}

extension SavedFlipperFile {
    var name: String { ((id as NSString).lastPathComponent as NSString).deletingPathExtension }
    private var folder: (path: String, ext: String, tool: String, label: String)? {
        Self.folders.first { id.hasPrefix($0.path + "/") && id.lowercased().hasSuffix($0.ext) }
    }
    var tool: String { folder?.tool ?? "" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(folder?.label ?? "")")
    }
    static func accepts(_ path: String) -> Bool {
        folders.contains { path.hasPrefix($0.path + "/") && path.lowercased().hasSuffix($0.ext) }
    }
    static func entities(for identifiers: [String]) -> [Self] {
        identifiers.filter(accepts).map(Self.init(id:))
    }
    static func suggested(matching text: String? = nil) async -> [Self] {
        await AppModel.shared.savedFiles(in: folders.map(\.path)).filter(accepts).map(Self.init(id:))
            .filter { text == nil || $0.name.localizedCaseInsensitiveContains(text!) }
    }
}

// AppIntents metadata needs a concrete query per entity, so these stay small and separate.
struct SavedCardQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SavedCard] { SavedCard.entities(for: identifiers) }
    func suggestedEntities() async throws -> [SavedCard] { await SavedCard.suggested() }
    func entities(matching string: String) async throws -> [SavedCard] { await SavedCard.suggested(matching: string) }
}

struct SavedSignalQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SavedSignal] { SavedSignal.entities(for: identifiers) }
    func suggestedEntities() async throws -> [SavedSignal] { await SavedSignal.suggested() }
    func entities(matching string: String) async throws -> [SavedSignal] { await SavedSignal.suggested(matching: string) }
}

struct SavedCard: SavedFlipperFile {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Card or Key"
    static let defaultQuery = SavedCardQuery()
    static let folders = [
        (path: "/ext/nfc", ext: ".nfc", tool: "emulate_nfc", label: "NFC"),
        (path: "/ext/lfrfid", ext: ".rfid", tool: "emulate_rfid", label: "125 kHz RFID"),
        (path: "/ext/ibutton", ext: ".ibtn", tool: "emulate_ibutton", label: "iButton"),
    ]
    let id: String
}

struct SavedSignal: SavedFlipperFile {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Signal"
    static let defaultQuery = SavedSignalQuery()
    static let folders = [
        (path: "/ext/subghz", ext: ".sub", tool: "transmit_subghz", label: "Sub-GHz"),
        (path: "/ext/infrared", ext: ".ir", tool: "transmit_infrared", label: "Infrared"),
    ]
    let id: String
}
