import Foundation

/// What the operator grants when engagement mode is armed. The agent can ask for these,
/// but only the human arm dialog (or an approved `set_engagement_mode` call) applies them.
public struct EngagementProfile: Sendable, Equatable, Codable {
    /// Medium- and high-risk actions run without a per-action prompt. Blocked actions stay blocked.
    public var autoApprovals: Bool
    /// Unlocks `rpc_raw`: the agent can call any device command from the protobuf surface,
    /// including ones that bypass the usual path protections.
    public var rawRPC: Bool
    /// Unlocks `badusb_execute`: the agent starts Bad KB scripts itself instead of only loading them.
    public var autoBadKB: Bool
    /// The operator's scope note, shown in the banner and injected into the agent's system prompt.
    public var note: String

    public init(autoApprovals: Bool = true, rawRPC: Bool = false, autoBadKB: Bool = false, note: String = "") {
        self.autoApprovals = autoApprovals
        self.rawRPC = rawRPC
        self.autoBadKB = autoBadKB
        self.note = Self.cleanNote(note)
    }

    /// Short machine-readable summary for settings, audit and prompts.
    public var summary: String {
        var parts: [String] = []
        if autoApprovals { parts.append("auto_approvals") }
        if rawRPC { parts.append("raw_rpc") }
        if autoBadKB { parts.append("auto_badusb") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }

    /// The scope note reaches the model, so it is fenced like any other free text.
    static func cleanNote(_ note: String) -> String {
        String(String(Untrusted.sanitizeName(note).prefix(200)))
    }
}

/// Session-only arming state. Never persisted: a restart always returns to disarmed.
public struct EngagementState: Sendable, Equatable, Codable {
    public var active: Bool
    public var profile: EngagementProfile
    public var startedAt: Date?

    public init(active: Bool = false, profile: EngagementProfile = EngagementProfile(), startedAt: Date? = nil) {
        self.active = active
        self.profile = profile
        self.startedAt = startedAt
    }

    public static let inactive = EngagementState()

    public func armed(_ capability: KeyPath<EngagementProfile, Bool>) -> Bool {
        active && profile[keyPath: capability]
    }
}
