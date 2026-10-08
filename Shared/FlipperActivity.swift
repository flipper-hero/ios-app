import ActivityKit
import AppIntents
import Foundation

// Compiled into the app and the widget extension. The widget only renders; the intents'
// work runs in the app process, which is where the Bluetooth connection lives.

/// Live Activity for things that keep running while the phone is in your pocket:
/// an emulation on the Flipper, a firmware update or an armed engagement.
struct FlipperActivityAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable {
        case emulation, firmwareUpdate, engagement
    }

    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        /// 0...1 while a firmware update transfers, nil otherwise.
        var progress: Double?
        var isFinished = false
    }

    var kind: Kind
    var deviceName: String
    var startedAt: Date
}

/// Stops the emulation or app running on the Flipper. Shown as the Live Activity's button
/// and available in Shortcuts and Siri.
struct StopFlipperAppIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Flipper App"
    static let description = IntentDescription("Stops the emulation or app that is running on your Flipper.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "")
        #else
        try await ShortcutRunner.run(tool: "stop_app", intent: self)
        return .result(dialog: "Stopped.")
        #endif
    }
}

/// Cancels a firmware update while it is still downloading or uploading.
struct CancelFirmwareUpdateIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel Flipper Firmware Update"
    static let description = IntentDescription("Cancels a firmware update before it is installed.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "")
        #else
        let message = try await ShortcutRunner.cancelFirmwareUpdate(intent: self)
        return .result(dialog: "\(message)")
        #endif
    }
}

/// Ends engagement mode from the Lock Screen. Disarming is always free, so no confirmation.
struct DisarmEngagementIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Disarm Engagement Mode"
    static let description = IntentDescription("Ends engagement mode; the agent asks again.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(dialog: "")
        #else
        ShortcutRunner.disarmEngagement()
        return .result(dialog: "Engagement mode is off.")
        #endif
    }
}
