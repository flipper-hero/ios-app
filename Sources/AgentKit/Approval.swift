import Foundation

public struct ApprovalSettings: Sendable, Equatable {
    /// Skip the prompt for medium-risk actions.
    public var autoApproveMedium = false
    /// Skip the prompt for high-risk actions too. Blocked actions stay blocked.
    public var yolo = false
    /// In YOLO mode, still ask when the action follows content the agent read from the Flipper.
    public var yoloAsksAfterUntrusted = true
    /// Armed engagement mode. Pre-authorizes a capability set for the session.
    public var engagement = EngagementState()

    public init(autoApproveMedium: Bool = false, yolo: Bool = false, yoloAsksAfterUntrusted: Bool = true,
                engagement: EngagementState = EngagementState()) {
        self.autoApproveMedium = autoApproveMedium
        self.yolo = yolo
        self.yoloAsksAfterUntrusted = yoloAsksAfterUntrusted
        self.engagement = engagement
    }
}

public struct ApprovalRequest: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public var tool: String
    public var summary: String
    public var risk: RiskLevel
    public var reasons: [String]
    public var diff: String?
    /// The action was requested after the model read content from the Flipper in this turn.
    public var afterUntrustedContent: Bool
    /// The agent asks to loosen its own permissions; the UI presents this as a permission dialog.
    public var isPermissionChange: Bool

    public init(tool: String, summary: String, risk: RiskLevel, reasons: [String],
                diff: String? = nil, afterUntrustedContent: Bool = false, isPermissionChange: Bool = false) {
        self.tool = tool; self.summary = summary; self.risk = risk; self.reasons = reasons
        self.diff = diff; self.afterUntrustedContent = afterUntrustedContent
        self.isPermissionChange = isPermissionChange
    }
}

public protocol ApprovalGate: Sendable {
    func decide(_ request: ApprovalRequest) async -> Bool
}

public enum ApprovalPolicy {
    public static func requiresApproval(_ assessment: RiskAssessment, settings: ApprovalSettings, tainted: Bool) -> Bool {
        requiresApproval(assessment.level, settings: settings, tainted: tainted)
    }

    public static func requiresApproval(_ level: RiskLevel, settings: ApprovalSettings, tainted: Bool) -> Bool {
        // Armed engagement mode: the operator pre-approved this session's actions up front.
        // Blocked levels never pass, and capability-gated tools are checked separately by the executor.
        if level != .blocked, settings.engagement.active, settings.engagement.profile.autoApprovals {
            return false
        }
        switch level {
        case .low: return false
        case .blocked: return true
        case .medium, .high:
            if settings.yolo { return tainted && settings.yoloAsksAfterUntrusted }
            return level == .high || !settings.autoApproveMedium || tainted
        }
    }
}
