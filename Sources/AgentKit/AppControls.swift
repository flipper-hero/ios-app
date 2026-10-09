import Foundation

/// The app settings as the agent may see them. Credentials are reduced to "is one stored".
public struct AppSettingsSnapshot: Sendable, Equatable {
    public var yolo: Bool
    public var yoloAsksAfterReading: Bool
    public var autoApproveMedium: Bool
    public var readAloud: Bool
    public var autoConnect: Bool
    public var model: String
    public var apiKeyStored: Bool
    public var provider: String
    public var apiBaseURL: String
    public var engagementActive: Bool
    public var engagementSummary: String

    public init(yolo: Bool, yoloAsksAfterReading: Bool, autoApproveMedium: Bool, readAloud: Bool,
                autoConnect: Bool, model: String, apiKeyStored: Bool,
                provider: String = "openrouter", apiBaseURL: String = "https://openrouter.ai/api/v1",
                engagementActive: Bool = false, engagementSummary: String = "off") {
        self.yolo = yolo
        self.yoloAsksAfterReading = yoloAsksAfterReading
        self.autoApproveMedium = autoApproveMedium
        self.readAloud = readAloud
        self.autoConnect = autoConnect
        self.model = model
        self.apiKeyStored = apiKeyStored
        self.provider = provider
        self.apiBaseURL = apiBaseURL
        self.engagementActive = engagementActive
        self.engagementSummary = engagementSummary
    }
}

/// App-level functions the agent can reach, so everything the UI offers is also available in chat.
/// Changes that loosen the agent's own permissions only ever happen after the executor obtained
/// explicit consent from the user; implementations apply them without asking again.
public protocol AppControls: Sendable {
    func settings() async -> AppSettingsSnapshot
    func setReadAloud(_ enabled: Bool) async
    func setAutoConnect(_ enabled: Bool) async
    func setYolo(_ enabled: Bool) async
    func setYoloAsksAfterReading(_ enabled: Bool) async
    func setAutoApproveMedium(_ enabled: Bool) async
    func setModel(_ model: String) async
    func setProvider(_ provider: AIProvider, baseURL: String?) async throws
    func listModels() async throws -> [AIModel]
    func testConnection() async throws
    /// Arms or disarms engagement mode. Arming only ever arrives here after the executor
    /// obtained explicit consent from the operator; implementations apply it without asking again.
    func setEngagement(_ state: EngagementState) async
    /// Restarts the Flipper. The app is expected to reconnect on its own afterwards.
    func restartDevice() async throws
    /// Starts installing the newest release of the detected firmware in the background.
    /// Returns a short description of what is happening.
    func startFirmwareUpdate() async throws -> String
    /// Human-readable state of a running or finished firmware update.
    func firmwareUpdateStatus() async -> String
    /// Cancels a running update if it has not reached the Flipper's updater yet.
    func cancelFirmwareUpdate() async -> String
}
