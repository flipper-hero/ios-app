#if !FLIPPERHERO_STORE
import Foundation

/// Turns the audit log into a markdown engagement report: the timeline an operator
/// can hand to a client or keep as evidence of what was done and who approved it.
public enum EngagementReport {
    public static func markdown(records: [AuditRecord], engagement: EngagementState, generatedAt: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("# Engagement report")
        lines.append("")
        lines.append("- Generated: \(generatedAt.formatted(date: .abbreviated, time: .standard))")
        if engagement.active, let started = engagement.startedAt {
            lines.append("- Engagement armed: \(started.formatted(date: .abbreviated, time: .standard)) (\(engagement.profile.summary))")
            if !engagement.profile.note.isEmpty { lines.append("- Scope note: \(escape(engagement.profile.note))") }
        }
        if let first = records.first?.date {
            lines.append("- Entries: \(records.count), \(first.formatted(date: .abbreviated, time: .standard)) to"
                         + " \(records.last?.date.formatted(date: .abbreviated, time: .standard) ?? "")")
        } else {
            lines.append("- Entries: 0")
        }

        var byDecision: [AuditRecord.Decision: Int] = [:]
        var failures = 0
        for record in records {
            byDecision[record.decision, default: 0] += 1
            if !record.succeeded { failures += 1 }
        }
        lines.append("- Outcome: \(failures) failed of \(records.count)")
        let decisions = byDecision.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
        if !decisions.isEmpty { lines.append("- Decisions: \(decisions)") }

        lines.append("")
        lines.append("| Time | Tool | Risk | Decision | Result | Summary |")
        lines.append("|---|---|---|---|---|---|")
        for record in records {
            let time = record.date.formatted(date: .abbreviated, time: .standard)
            let risk = record.risk.map { "\($0)" } ?? "-"
            let result = record.succeeded ? "ok" : "failed"
            let summary = escape(record.detail.isEmpty ? record.summary : "\(record.summary) [\(record.detail)]")
            lines.append("| \(time) | \(escape(record.tool)) | \(risk) | \(record.decision.rawValue) | \(result) | \(summary) |")
        }
        lines.append("")
        lines.append("Approvals were enforced in code; the decision column shows how each action was authorized.")
        return lines.joined(separator: "\n")
    }

    /// Keeps the markdown table intact even when summaries contain pipes or newlines.
    static func escape(_ text: String) -> String {
        Untrusted.sanitizeName(text.replacingOccurrences(of: "|", with: "\\|"))
    }
}
#endif
