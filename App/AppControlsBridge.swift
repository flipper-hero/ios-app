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
    func setModel(_ name: String) async {
        guard let model else { return }
        var settings = model.aiSettings
        settings.model = name
        model.applyAISettings(settings)
    }
    func setProvider(_ provider: AIProvider, baseURL: String?) async throws {
        guard let model else { return }
        var settings = AISettings.load(provider)
        if let baseURL { settings.baseURL = try provider.validatedBaseURL(baseURL).absoluteString }
        model.applyAISettings(settings)
    }
    func listModels() async throws -> [AIModel] {
        guard let model, let key = KeychainStore.read(model.aiProvider.rawValue), !key.isEmpty else {
            throw ProviderError.missingKey
        }
        return try await model.aiSettings.api(key: key).models()
    }
    func testConnection() async throws {
        guard let model, let key = KeychainStore.read(model.aiProvider.rawValue), !key.isEmpty else {
            throw ProviderError.missingKey
        }
        try await model.aiSettings.api(key: key).test(model: model.currentModel)
    }
    func setEngagement(_ state: EngagementState) async { model?.applyEngagement(state, audit: false) }
    func restartDevice() async throws { try await model?.restartFlipper() }
    func startFirmwareUpdate() async throws -> String {
        guard let model else { throw FlipperError.notConnected }
        return try model.startFirmwareUpdate()
    }
    func firmwareUpdateStatus() async -> String { model?.firmwareUpdate.statusText ?? String(localized: "No update is running.") }
    func cancelFirmwareUpdate() async -> String { model?.firmwareUpdate.cancel() ?? String(localized: "No update is running.") }
}
