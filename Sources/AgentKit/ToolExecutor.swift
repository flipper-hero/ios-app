import Foundation
import FlipperKit

public struct ToolResult: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case ok, error, denied, blocked }
    public var content: String
    public var kind: Kind
    /// PNG images to show the model, for example a capture of the Flipper's screen.
    public var images: [Data] = []
    public var isError: Bool { kind != .ok }
    public static func ok(_ text: String, images: [Data] = []) -> ToolResult { .init(content: text, kind: .ok, images: images) }
    public static func error(_ text: String, kind: Kind = .error) -> ToolResult { .init(content: text, kind: kind) }
}

/// Runs model tool calls: validate, assess risk, ask the user, execute, audit.
/// Never throws; every failure becomes an error result the model can read.
public actor ToolExecutor {
    public static let maxReadBytes = 16 * 1024

    private let flipper: FlipperControlling
    private let forge: PayloadForge?
    private let profileStore: DeviceProfileStore?
    private let appControls: AppControls?
    private let firmwareChecker: FirmwareUpdateChecker?
    private let fapHub: FapHubClient?
    private let gitHub: GitHubClient?
    private let gate: ApprovalGate
    private let audit: AuditSink
    private let settings: @Sendable () -> ApprovalSettings
    /// How an approval is recorded in the audit log: `.approved` in the app, `.shortcut` for Siri and Shortcuts.
    private let approvedAs: AuditRecord.Decision
    public nonisolated let nonce: String
    private var tainted = false

    public init(flipper: FlipperControlling, gate: ApprovalGate, audit: AuditSink,
                forge: PayloadForge? = nil, profileStore: DeviceProfileStore? = nil,
                fapHub: FapHubClient? = nil, gitHub: GitHubClient? = nil,
                appControls: AppControls? = nil, firmwareChecker: FirmwareUpdateChecker? = nil,
                settings: @escaping @Sendable () -> ApprovalSettings = { ApprovalSettings() },
                approvedAs: AuditRecord.Decision = .approved,
                nonce: String = UUID().uuidString.prefix(8).lowercased()) {
        self.flipper = flipper; self.gate = gate; self.audit = audit; self.forge = forge
        self.profileStore = profileStore; self.fapHub = fapHub; self.gitHub = gitHub
        self.appControls = appControls; self.firmwareChecker = firmwareChecker
        self.settings = settings; self.approvedAs = approvedAs; self.nonce = nonce
    }

    /// Content prepared during approval, reused at execution so the user approves exactly what is written.
    private var forged: [String: String] = [:]
    private var downloaded: [String: Data] = [:]
    /// Images produced by the tool that is currently running.
    private var pendingImages: [Data] = []

    /// Captures the screen, attaches it as an image for the model and returns a short text note.
    private func attachScreen() async throws -> String {
        let frame = try await flipper.captureScreen(timeout: .seconds(5))
        tainted = true
        guard let png = ScreenRenderer.png(frame) else { return "Captured the screen, but could not render it." }
        pendingImages.append(png)
        let size = frame.displaySize
        return "Screen captured (\(size.width)x\(size.height) px), attached as an image."
    }

    /// SDK version of the connected device, needed so catalog builds match the running firmware.
    private func deviceAPIVersion() async throws -> String {
        let info = try await flipper.deviceInfo()
        let major = info["firmware_api_major"] ?? "0"
        let minor = info["firmware_api_minor"] ?? "0"
        return "\(major).\(minor)"
    }

    private func findApp(_ query: String) async throws -> (CatalogApp, FapHubClient, String) {
        guard let fapHub else { throw CatalogError.notFound(query) }
        let api = try await deviceAPIVersion()
        let results = try await fapHub.search(query, api: api)
        let match = results.first { $0.alias.caseInsensitiveCompare(query) == .orderedSame }
            ?? results.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            ?? results.first
        guard let match else { throw CatalogError.notFound(query) }
        return (match, fapHub, api)
    }

    public var isTainted: Bool { tainted }

    /// Call when the user sends a new message; their words re-establish trust.
    public func newUserTurn() { tainted = false }

    /// Set by the session so a refresh can push the new inventory into the system prompt.
    public var onProfileRefreshed: (@Sendable (DeviceProfile) -> Void)?
    public func setProfileRefreshHandler(_ handler: @escaping @Sendable (DeviceProfile) -> Void) {
        onProfileRefreshed = handler
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        let invocation: ToolInvocation
        do {
            invocation = try ToolInvocation(name: call.name, arguments: call.arguments)
        } catch {
            await audit.record(.init(tool: call.name, summary: "invalid call", risk: nil, decision: .invalid,
                                     succeeded: false, detail: "\(error)"))
            return .error("\(error)")
        }

        let assessment = RiskAssessor.assess(invocation)
        if assessment.level == .blocked {
            await audit.record(.init(tool: invocation.toolName, summary: invocation.summary, risk: .blocked,
                                     decision: .blocked, succeeded: false, detail: assessment.reasons.joined(separator: "; ")))
            return .error("Blocked by safety policy: \(assessment.reasons.joined(separator: "; ")). Do not retry or look for a workaround; tell the user.", kind: .blocked)
        }

        let current = settings()
        // Capability-gated tools refuse to run until the operator armed engagement mode.
        if let capability = invocation.armedCapability, !current.engagement.armed(capability) {
            let name = invocation.toolName
            await audit.record(.init(tool: name, summary: invocation.summary, risk: assessment.level,
                                     decision: .blocked, succeeded: false, detail: "capability not armed"))
            return .error("'\(name)' is not available: engagement mode is not armed for this capability. "
                + "Tell the operator to arm it (Settings > Engagement mode, or approve set_engagement_mode) and stop retrying until then.")
        }

        var decision = AuditRecord.Decision.auto
        let consent = invocation.requiresExplicitConsent
        if consent || ApprovalPolicy.requiresApproval(assessment, settings: current, tainted: tainted) {
            let request = ApprovalRequest(
                tool: invocation.toolName, summary: invocation.summary, risk: assessment.level,
                reasons: assessment.reasons, diff: await previewDiff(invocation), afterUntrustedContent: tainted,
                isPermissionChange: consent
            )
            guard await gate.decide(request) else {
                await audit.record(.init(tool: invocation.toolName, summary: invocation.summary, risk: assessment.level,
                                         decision: .denied, succeeded: false, detail: "denied by user"))
                return .error("The user denied this action. Do not repeat it; ask what they want instead.", kind: .denied)
            }
            decision = approvedAs
        } else if current.engagement.active, current.engagement.profile.autoApprovals, assessment.level >= .medium {
            decision = .engaged
        } else if current.yolo && assessment.level >= .medium {
            decision = .yolo
        }

        do {
            pendingImages = []
            let output = try await run(invocation)
            await audit.record(.init(tool: invocation.toolName, summary: invocation.summary, risk: assessment.level,
                                     decision: decision, succeeded: true, detail: ""))
            defer { pendingImages = [] }
            return .ok(output, images: pendingImages)
        } catch {
            await audit.record(.init(tool: invocation.toolName, summary: invocation.summary, risk: assessment.level,
                                     decision: decision, succeeded: false, detail: "\(error)"))
            return .error("\(error)")
        }
    }

    // MARK: - Execution

    private func run(_ invocation: ToolInvocation) async throws -> String {
        switch invocation {
        case .getDeviceInfo:
            let info = try await flipper.deviceInfo()
            let keys = ["hardware_name", "hardware_model", "hardware_region_provisioned", "firmware_origin_fork",
                        "firmware_version", "firmware_commit", "firmware_branch", "firmware_build_date", "protobuf_version_major",
                        "protobuf_version_minor"]
            var lines = keys.compactMap { key in info[key].map { "\(key): \(Untrusted.sanitizeName($0))" } }
            if let pending = try? await flipper.customDeviceName(), pending != info["hardware_name"] {
                lines.append("pending_name: \(Untrusted.sanitizeName(pending)) (shown after the next restart)")
            }
            return lines.joined(separator: "\n")

        case .getPowerInfo:
            let info = try await flipper.powerInfo()
            let keys = ["charge_level", "charge_state", "battery_health", "battery_voltage",
                        "battery_current", "battery_temp", "capacity_remain", "capacity_full",
                        "charge.level", "charge.state", "battery.health"]
            var lines = keys.compactMap { key in info[key].map { "\(key): \(Untrusted.sanitizeName($0))" } }
            if let level = info["charge_level"] ?? info["charge.level"] {
                let state = info["charge_state"] ?? info["charge.state"] ?? "unknown"
                lines.insert("summary: battery \(Untrusted.sanitizeName(level))%, \(Untrusted.sanitizeName(state))", at: 0)
            }
            return lines.isEmpty ? info.sorted { $0.key < $1.key }.prefix(12).map { "\($0.key): \(Untrusted.sanitizeName($0.value))" }.joined(separator: "\n") : lines.joined(separator: "\n")

        case .getStorageInfo(let path):
            let info = try await flipper.storageInfo(path: path)
            return "total: \(info.totalSpace) bytes\nfree: \(info.freeSpace) bytes"

        case .listDirectory(let path):
            let entries = try await flipper.list(path: path)
            tainted = true
            let lines = entries.prefix(200).map { e in
                e.isDirectory ? "[dir] \(Untrusted.sanitizeName(e.name))" : "[file] \(Untrusted.sanitizeName(e.name)) (\(e.size) bytes)"
            }
            var text = lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
            if entries.count > 200 { text += "\n… \(entries.count - 200) more entries" }
            return Untrusted.wrap(text, source: path, nonce: nonce)

        case .readFile(let path):
            let data = try await flipper.read(path: path, maxBytes: Self.maxReadBytes)
            tainted = true
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                let head = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                return Untrusted.wrap("binary file, \(data.count) bytes, first bytes: \(head)", source: path, nonce: nonce)
            }
            return Untrusted.wrap(text, source: path, nonce: nonce)

        case .createDirectory(let path):
            try await flipper.makeDirectory(path: path)
            return "Created folder \(path)"

        case .writeFile(let path, let content):
            try await flipper.write(path: path, data: Data(content.utf8))
            return "Wrote \(content.utf8.count) bytes to \(path)"

        case .rename(let from, let to):
            try await flipper.rename(from: from, to: to)
            return "Moved \(from) to \(to)"

        case .launchApp(let name, let args):
            try await flipper.startApp(name: name, args: args)
            return "Started app \(name)"

        case .delete(let path, let recursive):
            try await flipper.delete(path: path, recursive: recursive)
            return "Deleted \(path)"

        case .transmitSubGhz(let path):
            try await flipper.transmitOnce(.subGhz, path: path, button: "", hold: .milliseconds(400))
            return "Transmitted \(path) once"

        case .transmitInfrared(let path, let button):
            try await flipper.transmitOnce(.infrared, path: path, button: button, hold: .milliseconds(250))
            return "Sent \(button.isEmpty ? "the remote" : button) from \(path)"

        case .emulateNFC(let path):
            try await flipper.emulate(.nfc, path: path)
            return "Emulating \(path). It keeps running until you call stop_app."

        case .emulateRFID(let path):
            try await flipper.emulate(.rfid, path: path)
            return "Emulating \(path). It keeps running until you call stop_app."

        case .emulateIButton(let path):
            try await flipper.emulate(.iButton, path: path)
            return "Emulating \(path). It keeps running until you call stop_app."

        case .loadBadKeyboardScript(let path):
            try await flipper.loadBadKeyboardScript(path: path)
            return "Bad KB is open with \(path) loaded. Press Run on the Flipper to execute it."

        case .stopApp:
            try await flipper.exitApp()
            return "Closed the app on the Flipper"

        case .forgePayload(let kind, let description, let path):
            let content: String
            if let cached = forged.removeValue(forKey: path) {
                content = cached
            } else {
                guard let forge else { throw ForgeError.unavailable }
                content = try await forge.forge(kind, description: description)
            }
            try await flipper.write(path: path, data: Data(content.utf8))
            return "Wrote \(content.utf8.count) bytes to \(path)"

        case .searchFapHub(let query):
            guard let fapHub else { throw CatalogError.notFound(query) }
            let api = try await deviceAPIVersion()
            let results = try await fapHub.search(query, api: api)
            guard !results.isEmpty else { return "No apps found for '\(query)' (firmware SDK \(api))" }
            return results.map {
                "\(Untrusted.sanitizeName($0.name)) [\($0.alias)] v\($0.version) - \(Untrusted.sanitizeName($0.summary))"
            }.joined(separator: "\n")

        case .installFapHubApp(let query):
            let (app, client, api) = try await findApp(query)
            let data: Data
            if let cached = downloaded.removeValue(forKey: app.versionID) {
                data = cached
            } else {
                data = try await client.downloadBuild(versionID: app.versionID, api: api)
            }
            let categories = (try? await client.categories(api: api)) ?? [:]
            let folder = categories[app.categoryID] ?? "Tools"
            let name = app.alias.isEmpty ? app.name : app.alias
            let target = "/ext/apps/\(folder)/\(name).fap"
            try? await flipper.makeDirectory(path: "/ext/apps/\(folder)")
            try await flipper.write(path: target, data: data)
            return "Installed \(app.name) v\(app.version) (\(data.count) bytes) to \(target)"

        case .searchGitHub(let query, let ext):
            guard let gitHub else { throw CatalogError.malformed }
            let hits = try await gitHub.searchCode(query, fileExtension: ext.isEmpty ? nil : ext)
            tainted = true
            guard !hits.isEmpty else { return "Nothing found on GitHub for '\(query)'" }
            let text = hits.map { "\(Untrusted.sanitizeName($0.repository)): \(Untrusted.sanitizeName($0.path))\n  \($0.rawURL)" }
                .joined(separator: "\n")
            return Untrusted.wrap(text, source: "github search", nonce: nonce)

        case .downloadResource(let url, let path):
            guard let gitHub else { throw CatalogError.malformed }
            let data: Data
            if let cached = downloaded.removeValue(forKey: url) {
                data = cached
            } else {
                data = try await gitHub.fetchRaw(url)
            }
            try await flipper.write(path: path, data: data)
            return "Wrote \(data.count) bytes from \(url) to \(path)"

        case .refreshDeviceKnowledge:
            guard let profileStore else { throw CatalogError.malformed }
            let profile = await profileStore.build(from: flipper)
            onProfileRefreshed?(profile)
            tainted = true
            return profile.promptSummary(nonce: nonce)

        case .checkFirmware:
            guard let firmwareChecker else { throw CatalogError.malformed }
            let info = try await flipper.deviceInfo()
            guard let status = await firmwareChecker.status(fork: info["firmware_origin_fork"],
                                                             version: info["firmware_version"]) else {
                return "Unknown firmware distribution (fork \(Untrusted.sanitizeName(info["firmware_origin_fork"] ?? "?")), version \(Untrusted.sanitizeName(info["firmware_version"] ?? "?")))."
            }
            return "\(status.summary)\nReleases: \(status.distribution.releasesURL.absoluteString)\n\(status.distribution.notes)"

        case .restartDevice:
            guard let appControls else { throw CatalogError.malformed }
            try await appControls.restartDevice()
            return "The Flipper is restarting. The app reconnects on its own; further device actions fail until then."

        case .getAuditLog(let limit):
            let entries = await audit.recent(limit: limit)
            guard !entries.isEmpty else { return "The audit log is empty." }
            tainted = true
            let text = entries.map { record in
                let time = record.date.formatted(date: .abbreviated, time: .shortened)
                return "\(time) \(record.tool) [\(record.decision.rawValue), \(record.succeeded ? "ok" : "failed")] \(Untrusted.sanitizeName(record.summary))"
            }.joined(separator: "\n")
            return Untrusted.wrap(text, source: "audit log", nonce: nonce)

        case .getAppSettings:
            guard let appControls else { throw CatalogError.malformed }
            let s = await appControls.settings()
            return """
            yolo_mode: \(s.yolo)
            yolo_asks_after_reading_device_content: \(s.yoloAsksAfterReading)
            auto_approve_medium: \(s.autoApproveMedium)
            engagement_mode: \(s.engagementActive ? "armed (\(s.engagementSummary))" : "off")
            read_replies_aloud: \(s.readAloud)
            auto_connect_on_launch: \(s.autoConnect)
            model: \(s.model)
            api_key_stored: \(s.apiKeyStored)
            """

        case .setReadAloud(let on):
            guard let appControls else { throw CatalogError.malformed }
            await appControls.setReadAloud(on)
            return on ? "Replies are read aloud now." : "Replies are no longer read aloud."

        case .setAutoConnect(let on):
            guard let appControls else { throw CatalogError.malformed }
            await appControls.setAutoConnect(on)
            return on ? "The app connects to the last Flipper on launch." : "Auto-connect is off."

        case .setYoloMode(let on):
            guard let appControls else { throw CatalogError.malformed }
            await appControls.setYolo(on)
            return on ? "YOLO mode is on for this session." : "YOLO mode is off; risky actions ask again."

        case .setYoloAsksAfterReading(let on):
            guard let appControls else { throw CatalogError.malformed }
            await appControls.setYoloAsksAfterReading(on)
            return on ? "YOLO mode asks again after device content was read." : "YOLO mode no longer asks after device content was read."

        case .setAutoApproveMedium(let on):
            guard let appControls else { throw CatalogError.malformed }
            await appControls.setAutoApproveMedium(on)
            return on ? "Medium-risk actions no longer ask." : "Medium-risk actions ask again."

        case .setModel(let model):
            guard let appControls else { throw CatalogError.malformed }
            await appControls.setModel(model)
            return "The next chat uses \(model)."

        case .installFirmwareUpdate:
            guard let appControls else { throw CatalogError.malformed }
            return try await appControls.startFirmwareUpdate()

        case .firmwareUpdateStatus:
            guard let appControls else { throw CatalogError.malformed }
            return await appControls.firmwareUpdateStatus()

        case .cancelFirmwareUpdate:
            guard let appControls else { throw CatalogError.malformed }
            return await appControls.cancelFirmwareUpdate()

        case .lookAtScreen:
            return try await attachScreen()

        case .pressButtons(let keys, let lookAfter):
            for step in keys {
                try await flipper.press(step.key, long: step.long)
                try await Task.sleep(for: .milliseconds(120))
            }
            let pressed = keys.map { $0.long ? "long \($0.key.rawValue)" : $0.key.rawValue }.joined(separator: ", ")
            guard lookAfter else { return "Pressed \(pressed)." }
            try await Task.sleep(for: .milliseconds(250))
            return "Pressed \(pressed). " + (try await attachScreen())

        case .setDeviceName(let name):
            try await flipper.setDeviceName(name)
            return "Renamed to \(name). The Flipper shows the new name after a restart."

        case .alertDevice:
            try await flipper.playAlert()
            return "The Flipper is beeping and blinking"

        case .badUsbExecute(let path):
            // The Bad KB app lands on its work view when opened with a file; the OK input
            // event is the firmware's own start/stop control (bad_usb_scene_work_on_event).
            try await flipper.loadBadKeyboardScript(path: path)
            try await Task.sleep(for: .milliseconds(700))
            try await flipper.press(.ok, long: false)
            try await Task.sleep(for: .milliseconds(400))
            let state = try await attachScreen()
            return "Sent Run to Bad KB for \(path). \(state) Check the capture: if the script is not running, use press_buttons to select Run."

        case .gpioConfigure(let pin, let output, let pullUp):
            try await flipper.gpioSetMode(pin: pin, output: output, pullUp: pullUp)
            if output {
                return "GPIO \(pin.rawValue) is now an output."
            }
            let pull: String
            if let pullUp { pull = pullUp ? "pull-up" : "pull-down" } else { pull = "no pull" }
            return "GPIO \(pin.rawValue) is now an input with \(pull)."

        case .gpioRead(let pin):
            let level = try await flipper.gpioRead(pin: pin)
            return "GPIO \(pin.rawValue) reads \(level ? "high" : "low")."

        case .gpioWrite(let pin, let level):
            try await flipper.gpioWrite(pin: pin, level: level)
            return "GPIO \(pin.rawValue) is driven \(level ? "high" : "low")."

        case .rawRPC(let request):
            let response = try await flipper.rawRPC(jsonRequest: request)
            tainted = true
            return Untrusted.wrap(response, source: "raw rpc", nonce: nonce)

        case .setEngagementMode(let enabled, let profile):
            guard let appControls else { throw CatalogError.malformed }
            let state = EngagementState(active: enabled, profile: profile, startedAt: enabled ? Date() : nil)
            await appControls.setEngagement(state)
            if enabled {
                return "Engagement mode is armed (\(profile.summary)). \(profile.note.isEmpty ? "" : "Scope: \(profile.note). ")"
                    + "The banner shows it and everything is audited."
            }
            return "Engagement mode is off. Normal approval rules apply again."

        case .generateEngagementReport(let limit):
            let records = await audit.recent(limit: limit)
            tainted = true
            let report = EngagementReport.markdown(records: records, engagement: settings().engagement)
            return Untrusted.wrap(report, source: "engagement report", nonce: nonce)
        }
    }

    private func previewDiff(_ invocation: ToolInvocation) async -> String? {
        switch invocation {
        case .writeFile(let path, let content):
            if let info = try? await flipper.stat(path: path), !info.isDirectory, info.size <= Self.maxReadBytes,
               let data = try? await flipper.read(path: path, maxBytes: Self.maxReadBytes),
               let old = String(data: data, encoding: .utf8) {
                return SimpleDiff.render(old: old, new: content)
            }
            return SimpleDiff.render(old: nil, new: content)
        case .installFapHubApp(let query):
            guard let (app, client, api) = try? await findApp(query),
                  let data = try? await client.downloadBuild(versionID: app.versionID, api: api) else { return nil }
            downloaded[app.versionID] = data
            return "\(app.name) v\(app.version) by the official catalog\n\(app.summary)\n\(data.count) bytes"

        case .downloadResource(let url, _):
            guard let gitHub, let data = try? await gitHub.fetchRaw(url) else { return nil }
            downloaded[url] = data
            if let text = String(data: data, encoding: .utf8), !data.contains(0) {
                return SimpleDiff.render(old: nil, new: text, maxLines: 40)
            }
            return "Binary file, \(data.count) bytes"

        case .forgePayload(let kind, let description, let path):
            guard let forge, let content = try? await forge.forge(kind, description: description) else { return nil }
            forged[path] = content
            let existing = try? await flipper.read(path: path, maxBytes: Self.maxReadBytes)
            return SimpleDiff.render(old: existing.flatMap { String(data: $0, encoding: .utf8) },
                                     new: content, maxLines: 60)

        case .delete(let path, _):
            guard let info = try? await flipper.stat(path: path) else { return nil }
            return info.isDirectory ? "Folder \(Untrusted.sanitizeName(info.name))" : "File \(Untrusted.sanitizeName(info.name)), \(info.size) bytes"
        default:
            return nil
        }
    }
}
