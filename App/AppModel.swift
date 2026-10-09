import AppIntents
import Foundation
import Observation
import FlipperKit
import AgentKit

struct ChatEntry: Identifiable {
    enum Kind { case user, assistant, tool, error }
    enum ToolStatus { case running, ok, error, denied, blocked }
    let id = UUID()
    var kind: Kind
    var text: String
    var tool = ""
    var status = ToolStatus.ok
    var output = ""
    var image: Data?
}

struct PendingApproval: Identifiable {
    let id = UUID()
    let request: ApprovalRequest
    fileprivate let continuation: CheckedContinuation<Bool, Never>?
}

/// Thread-safe snapshot of the approval flags for the executor, which runs off the main actor.
final class PolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var asksAfterUntrusted = true
    private var engagement = EngagementState.inactive
    func set(enabled: Bool, asksAfterUntrusted: Bool, engagement: EngagementState) {
        lock.withLock {
            self.enabled = enabled
            self.asksAfterUntrusted = asksAfterUntrusted
            self.engagement = engagement
        }
    }
    var snapshot: (enabled: Bool, asksAfterUntrusted: Bool, engagement: EngagementState) {
        lock.withLock { (enabled, asksAfterUntrusted, engagement) }
    }
}

struct ShortcutGate: ApprovalGate {
    let confirm: @Sendable (ApprovalRequest) async -> Bool
    func decide(_ request: ApprovalRequest) async -> Bool { await confirm(request) }
}

final class UIApprovalGate: ApprovalGate, @unchecked Sendable {
    private let present: @Sendable (ApprovalRequest, CheckedContinuation<Bool, Never>) -> Void
    init(present: @escaping @Sendable (ApprovalRequest, CheckedContinuation<Bool, Never>) -> Void) { self.present = present }
    func decide(_ request: ApprovalRequest) async -> Bool {
        await withCheckedContinuation { present(request, $0) }
    }
}

@MainActor @Observable
final class AppModel {
    /// One model for the whole process, so Siri and Shortcuts drive the same connection as the UI.
    static let shared = AppModel()

    enum Connection: Equatable {
        case idle, scanning, connecting(String), connected(String), failed(String)
    }

    nonisolated static let autoApproveKey = "autoApproveMedium"
    nonisolated static let autoConnectKey = "autoConnect"
    nonisolated static let speakRepliesKey = "speakReplies"
    nonisolated static let knownDevicesKey = "knownFlipperIDs"
    nonisolated static let lastDeviceKey = "lastFlipperID"
    nonisolated static let lastDeviceNameKey = "lastFlipperName"
    nonisolated static let lastHardwareUIDKey = "lastFlipperUID"

    var connection: Connection = .idle
    var selectedTab = AppModel.initialTab
    var devices: [DiscoveredFlipper] = []
    var bluetooth: BLEStatus = .unknown
    var deviceInfo: [String: String] = [:]
    var power: [String: String] = [:]
    var storage: FlipperStorageInfo?
    var statusError: String?
    var firmware: FirmwareStatus?
    let firmwareUpdate = FirmwareUpdateController()
    var renameError: String?
    var chat: [ChatEntry] = []
    var isBusy = false
    var pendingApproval: PendingApproval?
    var auditRecords: [AuditRecord] = []

    let speaker = Speaker()
    private let liveActivities = LiveActivityController()

    private init() {
        liveActivities.endStale()
        firmwareUpdate.onChange = { [weak self] state, text in
            guard let self else { return }
            liveActivities.firmwareUpdateChanged(state, text: text, device: deviceDisplayName)
        }
    }

    private static var initialTab: Int {
        #if DEBUG
        Int(ProcessInfo.processInfo.environment["FH_TAB"] ?? "") ?? 0
        #else
        0
        #endif
    }

    var deviceDisplayName: String {
        switch connection {
        case .connected(let name), .connecting(let name): name
        default: lastDeviceName ?? String(localized: "Your Flipper")
        }
    }
    private(set) var speakReplies = UserDefaults.standard.bool(forKey: AppModel.speakRepliesKey)

    func setSpeakReplies(_ enabled: Bool) {
        speakReplies = enabled
        UserDefaults.standard.set(enabled, forKey: Self.speakRepliesKey)
        if !enabled { speaker.stop() }
    }

    var aiProvider = AIProvider(rawValue: UserDefaults.standard.string(forKey: AISettings.providerKey) ?? "") ?? .openrouter
    private var aiSettingsRevision = 0
    var aiSettings: AISettings {
        _ = aiSettingsRevision
        return AISettings.load(aiProvider)
    }
    var currentModel: String { aiSettings.model }
    func selectProvider(_ provider: AIProvider) {
        aiProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: AISettings.providerKey)
        aiSettingsRevision += 1
        session = nil
        retiredSession = nil
        // An agent preference change finishes the current turn on the old session.
        if !isBusy { newChat() }
    }
    func applyAISettings(_ settings: AISettings) {
        settings.persist()
        aiProvider = settings.provider
        aiSettingsRevision += 1
        session = nil
        retiredSession = nil
        if !isBusy { newChat() }
    }

    var settingsSnapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            yolo: yolo, yoloAsksAfterReading: yoloAsksAfterUntrusted,
            autoApproveMedium: UserDefaults.standard.bool(forKey: Self.autoApproveKey),
            readAloud: speakReplies,
            autoConnect: UserDefaults.standard.object(forKey: Self.autoConnectKey) as? Bool ?? true,
            model: currentModel, apiKeyStored: hasAPIKey && !isDemo,
            provider: aiProvider.rawValue, apiBaseURL: aiSettings.baseURL,
            engagementActive: engagement.active,
            engagementSummary: engagement.active ? engagement.profile.summary : "off"
        )
    }

    /// Session-only on purpose: never persisted, so a restart always returns to safe defaults.
    var yolo = false { didSet { syncPolicy() } }
    var yoloAsksAfterUntrusted = true { didSet { syncPolicy() } }
    var engagement = EngagementState.inactive { didSet { syncPolicy() } }
    private let policyBox = PolicyBox()
    private func syncPolicy() {
        policyBox.set(enabled: yolo, asksAfterUntrusted: yoloAsksAfterUntrusted, engagement: engagement)
    }

    /// Applies arming from either the arm dialog (audited) or an approved agent request
    /// (already audited by the executor). Disarming is always free.
    /// The store edition keeps this inert: nothing in it can arm.
    func applyEngagement(_ state: EngagementState, audit: Bool) {
        guard state != engagement else { return }
        engagement = state
#if !FLIPPERHERO_STORE
        if audit {
            let invocation = ToolInvocation.setEngagementMode(enabled: state.active, profile: state.profile)
            let risk = RiskAssessor.assess(invocation)
            Task { await self.audit.record(.init(
                tool: invocation.toolName, summary: invocation.summary, risk: risk.level,
                decision: .approved, succeeded: true, detail: "from Settings")) }
        }
        if state.active {
            liveActivities.engagementStarted(device: deviceDisplayName, note: state.profile.note)
        } else {
            liveActivities.engagementStopped()
        }
        Task { await session?.updateEngagement(state) }
#endif
    }

    /// False after a manual disconnect, so the app does not fight the user within this session.
    private var autoConnectAllowed = true
    private var autoAttempts = 0
    private var connectingDeviceIsNew = false
    /// Set while the Flipper restarts on our request, so the drop is expected and we reconnect.
    private var rebootPending = false
    /// The previous session, kept so a reconnect continues the conversation instead of forgetting it.
    private var retiredSession: AgentSession?
    var nameChangePending = false
    private static let maxAutoAttempts = 3

    private var lastDeviceID: UUID? {
        UserDefaults.standard.string(forKey: Self.lastDeviceKey).flatMap(UUID.init(uuidString:))
    }
    var lastDeviceName: String? { UserDefaults.standard.string(forKey: Self.lastDeviceNameKey) }
    var autoConnectActive: Bool {
        autoConnectAllowed && lastDeviceID != nil
            && (UserDefaults.standard.object(forKey: Self.autoConnectKey) as? Bool ?? true)
    }

    private(set) var client: FlipperRPCClient?
    private var ble: FlipperBLE?
    private var session: AgentSession?
    private var sessionAISettings: AISettings?
    private var tasks: [Task<Void, Never>] = []
    private let audit = FileAuditLog(url: URL.applicationSupportDirectory.appending(path: "audit.jsonl"))
    private let profileStore = DeviceProfileStore(
        directory: URL.applicationSupportDirectory.appending(path: "profiles"))
    private(set) var profile: DeviceProfile?

    var isConnected: Bool { if case .connected = connection { true } else { false } }

    /// Devices we have connected to before. Used to show the pairing hint only when it is useful.
    private var knownDevices: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.knownDevicesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.knownDevicesKey) }
    }

    func isKnown(_ device: DiscoveredFlipper) -> Bool { knownDevices.contains(device.id.uuidString) }

    /// True while connecting to a Flipper this phone has not paired with yet.
    var isPairingNewDevice: Bool {
        guard case .connecting = connection else { return false }
        return connectingDeviceIsNew
    }

    /// Battery as a single line, tolerating firmware that names the keys differently.
    var batterySummary: String? {
        // The firmware sends underscore keys over RPC; the dotted form appears in other paths.
        let level = power["charge_level"] ?? power["charge.level"]
        guard let level, !level.isEmpty else { return nil }
        let state = power["charge_state"] ?? power["charge.state"]
        if let state, !state.isEmpty, state != "discharging" {
            let label = switch state {
            case "charging": String(localized: "charging")
            case "charged": String(localized: "charged")
            default: state
            }
            return "\(level) % (\(label))"
        }
        return "\(level) %"
    }

    // MARK: Bluetooth

    /// Called once at app launch: look for the last Flipper if auto-connect applies.
    func start() {
        if autoConnectActive { startScan() }
    }

    private func autoConnectIfFound(in list: [DiscoveredFlipper]) {
        guard autoConnectActive || rebootPending, autoAttempts < Self.maxAutoAttempts, let id = lastDeviceID,
              let device = list.first(where: { $0.id == id }) else { return }
        switch connection {
        case .idle, .scanning, .failed: break
        case .connecting, .connected: return
        }
        autoAttempts += 1
        AppLog.info("auto-connecting to \(device.name) (attempt \(autoAttempts))")
        connection = .connecting(device.name)
        Task { await connect(device, manual: false) }
    }

    func startScan() {
        let ble = self.ble ?? FlipperBLE()
        if self.ble == nil {
            self.ble = ble
            tasks.append(Task { [weak self] in
                for await list in ble.devices {
                    self?.devices = list
                    self?.autoConnectIfFound(in: list)
                }
            })
            tasks.append(Task { [weak self] in
                for await status in ble.status { self?.bluetooth = status }
            })
        }
        if !isConnected { connection = .scanning }
        ble.startScan()
    }

    func stopScan() {
        ble?.stopScan()
        if connection == .scanning { connection = .idle }
    }

    func connect(_ device: DiscoveredFlipper, manual: Bool = true) async {
        guard let ble else { return }
        if manual {
            autoConnectAllowed = true
            autoAttempts = 0
        }
        connectingDeviceIsNew = !isKnown(device)
        connection = .connecting(device.name)
        do {
            let transport = try await ble.connect(to: device.id)
            let client = FlipperRPCClient(transport: transport)
            await client.start()
            try await client.ping()
            self.client = client
            tasks.append(Task { [weak self] in
                for await _ in client.closed { self?.connectionLost() }
            })
            connection = .connected(device.name)
            autoAttempts = 0
            UserDefaults.standard.set(device.id.uuidString, forKey: Self.lastDeviceKey)
            UserDefaults.standard.set(device.name, forKey: Self.lastDeviceNameKey)
            knownDevices.insert(device.id.uuidString)
            connectingDeviceIsNew = false
            if rebootPending { nameChangePending = false }
            rebootPending = false
            await refreshStatus()
        } catch {
            AppLog.error("connect failed: \(error)")
            connection = .failed("\(error)")
            startScan()
        }
    }

    func disconnect() async {
        autoConnectAllowed = false
        denyPendingApproval()
        liveActivities.emulationStopped()
        applyEngagement(.inactive, audit: false)
        await client?.stop()
        ble?.disconnect()
        client = nil
        retiredSession = session ?? retiredSession
        session = nil
        connection = .idle
    }

    private func connectionLost() {
        guard isConnected else { return }
        denyPendingApproval()
        liveActivities.emulationStopped()
        applyEngagement(.inactive, audit: false)
        client = nil
        retiredSession = session ?? retiredSession
        session = nil
        if rebootPending {
            connection = .failed(String(localized: "The Flipper is restarting, reconnecting..."))
            autoAttempts = 0
        } else {
            connection = .failed(String(localized: "Connection to the Flipper was lost"))
        }
        if autoConnectActive || rebootPending { startScan() }
    }

    func startFirmwareUpdate() throws -> String {
        guard let client else { throw FlipperError.notConnected }
        guard let distribution = firmware?.distribution
                ?? FirmwareCatalog.identify(fork: deviceInfo["firmware_origin_fork"], version: deviceInfo["firmware_version"]) else {
            throw FirmwareUpdateError.noPackage(String(localized: "this firmware (unknown distribution)"))
        }
        return try firmwareUpdate.start(client: client, distribution: distribution) { [weak self] in
            // The link drops when the Flipper enters the updater; treat it like any restart we asked for.
            self?.rebootPending = true
        }
    }

    /// Restarts the Flipper and reconnects once it is back, even if auto-connect is off.
    func restartFlipper() async throws {
        guard let client else { throw FlipperError.notConnected }
        rebootPending = true
        AppLog.info("restarting the Flipper")
        try await client.reboot()
    }

    func refreshStatus() async {
        guard let client else { return }
        statusError = nil
        do {
            deviceInfo = try await client.deviceInfo()
            power = try await client.powerInfo()
            AppLog.debug("power keys: \(power.keys.sorted())")
            storage = try await client.storageInfo(path: "/ext")
        } catch {
            // Keep whatever we had and say why it is stale instead of showing a silent dash.
            statusError = "\(error)"
            AppLog.error("refreshStatus failed: \(error)")
        }
        await loadProfile()
        await checkFirmware()
        firmwareUpdate.deviceReconnected(firmwareVersion: deviceInfo["firmware_version"])
    }

    private func checkFirmware() async {
        let fork = deviceInfo["firmware_origin_fork"]
        let version = deviceInfo["firmware_version"]
        firmware = await FirmwareUpdateChecker().status(fork: fork, version: version)
    }

    /// Writes the new name to the SD card. The Flipper picks it up on its next restart.
    func rename(to name: String) async {
        guard let client else { return }
        renameError = nil
        do {
            try await client.setDeviceName(name)
            nameChangePending = true
            await rescanDevice()
        } catch {
            renameError = "\(error)"
        }
    }

    /// Shows the cached inventory straight away, then refreshes it in the background.
    private func loadProfile() async {
        guard let client else { return }
        let uid = deviceInfo["hardware_uid"] ?? ""
        UserDefaults.standard.set(uid, forKey: Self.lastHardwareUIDKey)
        if profile == nil, let cached = await profileStore.cached(uid: uid) { profile = cached }
        Task { [weak self, profileStore] in
            let fresh = await profileStore.build(from: client)
            await MainActor.run {
                self?.profile = fresh
                Task { await self?.session?.updateProfile(fresh) }
            }
            // Lets Siri offer the saved cards and signals by name.
            FlipperHeroShortcuts.updateAppShortcutParameters()
        }
    }

    func rescanDevice() async {
        guard let client else { return }
        profile = await profileStore.build(from: client)
        if let profile { await session?.updateProfile(profile) }
    }

    // MARK: Approval

    func resolveApproval(_ approved: Bool) {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        pending.continuation?.resume(returning: approved)
    }

    func denyPendingApproval() { resolveApproval(false) }

    // MARK: Agent

    private(set) var isDemo = false

    var hasAPIKey: Bool {
        _ = aiSettingsRevision
        return isDemo || !(KeychainStore.read(aiProvider.rawValue) ?? "").isEmpty
    }

    func newChat() {
        denyPendingApproval()
        session = nil
        retiredSession = nil
        chat = []
    }

    private func ensureSession() async throws -> AgentSession {
        if let session, sessionAISettings == aiSettings { return session }
        let changedProvider = sessionAISettings?.provider != nil && sessionAISettings?.provider != aiProvider
        if changedProvider { retiredSession = nil }
        guard let client else { throw FlipperError.notConnected }
        guard let key = KeychainStore.read(aiProvider.rawValue), !key.isEmpty else { throw ProviderError.missingKey }
        let model = currentModel
        let gate = UIApprovalGate { [weak self] request, continuation in
            Task { @MainActor in
                guard let self else { continuation.resume(returning: false); return }
                self.pendingApproval = PendingApproval(request: request, continuation: continuation)
            }
        }
        guard !model.isEmpty else { throw ProviderError.missingModel }
        let llm = try aiSettings.api(key: key).client(model: model)
        let executor = makeExecutor(client: client, gate: gate, forge: PayloadForge(llm: llm))
        let carried = await retiredSession?.messages ?? []
        retiredSession = nil
        let created = AgentSession(llm: llm, executor: executor, profile: profile, history: carried,
                                   engagement: engagement)
        Task { await executor.setProfileRefreshHandler { [weak self] fresh in
            Task { @MainActor in
                self?.profile = fresh
                await self?.session?.updateProfile(fresh)
            }
        } }
        session = created
        sessionAISettings = aiSettings
        return created
    }

    private func makeExecutor(client: FlipperRPCClient, gate: ApprovalGate, forge: PayloadForge?,
                              approvedAs: AuditRecord.Decision = .approved) -> ToolExecutor {
        ToolExecutor(
            flipper: client, gate: gate, audit: audit, forge: forge, profileStore: profileStore,
            fapHub: FapHubClient(), gitHub: GitHubClient(),
            appControls: AppControlsBridge(model: self), firmwareChecker: FirmwareUpdateChecker(),
            settings: { [policyBox] in
                let flags = policyBox.snapshot
                return ApprovalSettings(
                    autoApproveMedium: UserDefaults.standard.bool(forKey: AppModel.autoApproveKey),
                    yolo: flags.enabled, yoloAsksAfterUntrusted: flags.asksAfterUntrusted,
                    engagement: flags.engagement
                )
            },
            approvedAs: approvedAs
        )
    }

    func send(_ text: String, images: [Data] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, !isBusy else { return }
        chat.append(ChatEntry(kind: .user, text: trimmed.isEmpty ? String(localized: "(photo)") : trimmed, image: images.first))
        isBusy = true
        defer { isBusy = false }
        do {
            let session = try await ensureSession()
            let answer = try await session.send(trimmed, images: images) { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            }
            chat.append(ChatEntry(kind: .assistant, text: answer))
            if speakReplies { speaker.speak(answer) }
        } catch {
            chat.append(ChatEntry(kind: .error, text: "\(error)"))
        }
    }

    private func apply(_ event: AgentEvent) {
        switch event {
        case .toolStarted(let name, let summary):
            chat.append(ChatEntry(kind: .tool, text: summary, tool: name, status: .running))
        case .toolFinished(let name, _, let arguments, let result):
            noteToolOutcome(name: name, arguments: arguments, result: result)
            guard let i = chat.lastIndex(where: { $0.kind == .tool && $0.tool == name && $0.status == .running }) else { return }
            chat[i].status = switch result.kind {
            case .ok: .ok
            case .error: .error
            case .denied: .denied
            case .blocked: .blocked
            }
            chat[i].output = Self.preview(result.content)
        }
    }

    private static let emulationTools = [
        "emulate_nfc": String(localized: "NFC card"),
        "emulate_rfid": String(localized: "125 kHz tag"),
        "emulate_ibutton": String(localized: "iButton key"),
    ]

    /// Keeps the Live Activity in step with what runs on the Flipper, whoever started it.
    private func noteToolOutcome(name: String, arguments: String, result: ToolResult) {
        if let kind = Self.emulationTools[name], result.kind == .ok {
            let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
            let path = args?["path"] as? String ?? ""
            let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            liveActivities.emulationStarted(device: deviceDisplayName, title: String(localized: "Emulating \(file)"), kind: kind)
        } else if name == "stop_app" {
            liveActivities.emulationStopped()
        }
    }

    // MARK: Siri and Shortcuts

    /// Connects to the last Flipper if needed. Works from a background launch because a known
    /// Flipper is connected by identifier, without scanning.
    func ensureConnected(timeout: Duration = .seconds(20)) async throws {
        if isConnected { return }
        guard let id = lastDeviceID else { throw ShortcutError.noKnownFlipper }
        let deadline = ContinuousClock.now + timeout
        startScan()
        while bluetooth != .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        if case .connecting = connection {
            // Auto-connect is already on it.
        } else {
            autoConnectAllowed = true
            await connect(DiscoveredFlipper(id: id, name: lastDeviceName ?? "Flipper", rssi: 0), manual: false)
        }
        while !isConnected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        guard isConnected else { throw ShortcutError.unreachable(lastDeviceName ?? "Flipper") }
    }

    /// Runs one tool for Siri or Shortcuts through a fresh executor with the same policy as the chat.
    /// Approvals come from the system confirmation and are audited as `shortcut`.
    func runShortcut(tool: String, arguments: [String: String],
                     confirm: @escaping @Sendable (ApprovalRequest) async -> Bool) async -> ToolResult {
        guard let client else { return .error(String(localized: "Not connected to a Flipper.")) }
        let json = (try? JSONSerialization.data(withJSONObject: arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let executor = makeExecutor(client: client, gate: ShortcutGate(confirm: confirm), forge: nil,
                                    approvedAs: .shortcut)
        let result = await executor.execute(ToolCall(id: UUID().uuidString, name: tool, arguments: json))
        noteToolOutcome(name: tool, arguments: json, result: result)
        return result
    }

    /// Sends a request to the agent as if typed in the chat and returns the answer.
    func ask(_ text: String) async throws -> String {
        selectedTab = 3
        guard !isBusy else { throw ShortcutError.busy }
        try await ensureConnected()
        let before = chat.count
        await send(text)
        guard chat.count > before, let last = chat.last else { throw ShortcutError.failed(String(localized: "The agent did not answer.")) }
        if last.kind == .error { throw ShortcutError.failed(last.text) }
        return last.text
    }

    func readBattery() async throws -> String {
        guard let client else { throw ShortcutError.noKnownFlipper }
        power = try await client.powerInfo()
        guard let summary = batterySummary else { throw ShortcutError.failed(String(localized: "The Flipper did not report its battery.")) }
        return summary
    }

    /// Files for Shortcut parameters: live from the Flipper when connected, otherwise from the
    /// last inventory, which only holds a sample of each folder.
    func savedFiles(in folders: [String]) async -> [String] {
        if let client {
            var paths: [String] = []
            for folder in folders {
                guard let entries = try? await client.list(path: folder) else { continue }
                paths += entries.filter { !$0.isDirectory }.map { FlipperPath.join(folder, $0.name) }
            }
            return paths
        }
        var known = profile
        if known == nil, let uid = UserDefaults.standard.string(forKey: Self.lastHardwareUIDKey) {
            known = await profileStore.cached(uid: uid)
        }
        return (known?.folders ?? []).filter { folders.contains($0.path) }.flatMap { folder in
            folder.samples.filter { !$0.hasSuffix("/") }.map { FlipperPath.join(folder.path, $0) }
        }
    }

    /// Strips the safety fences and shortens tool output for display.
    private static func preview(_ content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("<<<") }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 700 ? String(text.prefix(700)) + "\n..." : text
    }

    #if DEBUG
    /// Seeds sample data so the UI can be reviewed in the simulator without a Flipper or API key.
    func loadDemo(withApproval: Bool) {
        isDemo = true
        connection = .connected("Laisear")
        deviceInfo = ["hardware_name": "Laisear", "firmware_origin_fork": "Momentum", "firmware_version": "mntm-012",
                      "firmware_commit": "d3f89dfe"]
        power = ["charge.level": "87"]
        firmware = FirmwareCatalog.identify(fork: "Momentum", version: "mntm-012").map {
            FirmwareStatus(distribution: $0, installedVersion: "mntm-012", latestRelease: "mntm-012", updateAvailable: false)
        }
        storage = FlipperStorageInfo(totalSpace: 31_000_000_000, freeSpace: 24_600_000_000)
        chat = [
            ChatEntry(kind: .user, text: "What is in the NFC folder on my SD card?"),
            ChatEntry(kind: .tool, text: "List /ext/nfc", tool: "list_directory", status: .ok,
                      output: "[dir] Transit\n[file] Hotel_Room_204.nfc (1204 bytes)\n[file] Office_Badge.nfc (1180 bytes)\n[file] Garage_Tag.nfc (996 bytes)"),
            ChatEntry(kind: .assistant, text: "**/ext/nfc** has 3 cards and a folder:\n\n- `Hotel_Room_204.nfc`\n- `Office_Badge.nfc`\n- `Garage_Tag.nfc`\n- folder `Transit`\n\nShould I look at one of them more closely?"),
            ChatEntry(kind: .user, text: "Create a backup folder, then delete Garage_Tag"),
            ChatEntry(kind: .tool, text: "Create folder /ext/backup", tool: "create_directory", status: .ok, output: "Created folder /ext/backup"),
            ChatEntry(kind: .tool, text: "Delete /ext/nfc/Garage_Tag.nfc", tool: "delete", status: .denied,
                      output: "The user denied this action."),
            ChatEntry(kind: .tool, text: "Write 40 bytes to /int/boot.cfg", tool: "write_file", status: .blocked,
                      output: "Blocked by safety policy: protected path (internal storage)."),
            ChatEntry(kind: .assistant, text: "`/ext/backup` is created. You declined the delete, so `Garage_Tag.nfc` is untouched."),
        ]
        if ProcessInfo.processInfo.environment["FH_DEMO_ACTIVITY"] == "1" {
            noteToolOutcome(name: "emulate_nfc", arguments: #"{"path":"/ext/nfc/Office_Badge.nfc"}"#,
                            result: .ok("Emulating"))
        }
#if !FLIPPERHERO_STORE
        if ProcessInfo.processInfo.environment["FH_DEMO_ENGAGED"] == "1" {
            engagement = EngagementState(active: true,
                                         profile: EngagementProfile(note: "demo, authorized"),
                                         startedAt: .now)
        }
#endif
        if withApproval {
            let invocation = ToolInvocation.setYoloMode(true)
            let risk = RiskAssessor.assess(invocation)
            pendingApproval = PendingApproval(
                request: ApprovalRequest(tool: invocation.toolName, summary: invocation.summary, risk: risk.level,
                                         reasons: risk.reasons, isPermissionChange: invocation.requiresExplicitConsent),
                continuation: nil)
        }
    }
    #endif

    func loadAudit() async {
        auditRecords = await audit.load().reversed()
    }
}
