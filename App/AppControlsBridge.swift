import Foundation
import AgentKit
import FlipperKit

/// Lets the agent reach the app's own settings and actions, so the chat can do what the UI can.
/// Changes that loosen permissions only arrive here after the user approved them in a dialog.
@MainActor
final class AppControlsBridge: AppControls {
    private weak var model: AppModel?
    init(model: AppModel) { self.model = model }

    func settings() async -> AppSettingsSnapshot {
        model?.settingsSnapshot ?? AppSettingsSnapshot(yolo: false, yoloAsksAfterReading: true, autoApproveMedium: false,
                                                       readAloud: false, autoConnect: true, model: "", apiKeyStored: false)
    }
    func setReadAloud(_ enabled: Bool) async { model?.setSpeakReplies(enabled) }
    func setAutoConnect(_ enabled: Bool) async { UserDefaults.standard.set(enabled, forKey: AppModel.autoConnectKey) }
    func setYolo(_ enabled: Bool) async { model?.yolo = enabled }
    func setYoloAsksAfterReading(_ enabled: Bool) async { model?.yoloAsksAfterUntrusted = enabled }
    func setAutoApproveMedium(_ enabled: Bool) async { UserDefaults.standard.set(enabled, forKey: AppModel.autoApproveKey) }
    func setModel(_ model: String) async { UserDefaults.standard.set(model, forKey: AppModel.modelKey) }
    func setEngagement(_ state: EngagementState) async { model?.applyEngagement(state, audit: false) }
    func restartDevice() async throws { try await model?.restartFlipper() }
    func startFirmwareUpdate() async throws -> String {
        guard let model else { throw FlipperError.notConnected }
        return try model.startFirmwareUpdate()
    }
    func firmwareUpdateStatus() async -> String { model?.firmwareUpdate.statusText ?? String(localized: "No update is running.") }
    func cancelFirmwareUpdate() async -> String { model?.firmwareUpdate.cancel() ?? String(localized: "No update is running.") }
}
