import Foundation

/// Minimal line diff for approval prompts.
public enum SimpleDiff {
    public static func render(old: String?, new: String, maxLines: Int = 40) -> String {
        let newLines = new.components(separatedBy: "\n")
        guard let old else {
            let shown = newLines.prefix(maxLines).map { "+ \($0)" }
            let more = newLines.count > maxLines ? ["… \(newLines.count - maxLines) more lines"] : []
            return (["New file, \(newLines.count) lines:"] + shown + more).joined(separator: "\n")
        }
        let oldLines = old.components(separatedBy: "\n")
        if old == new { return "No changes." }
        guard oldLines.count * newLines.count <= 250_000 else {
            return "File changes from \(oldLines.count) to \(newLines.count) lines (too large to diff)."
        }
        // LCS table
        let n = oldLines.count, m = newLines.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = oldLines[i] == newLines[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, oldLines[i] == newLines[j] { i += 1; j += 1 }
            else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] { out.append("+ \(newLines[j])"); j += 1 }
            else { out.append("- \(oldLines[i])"); i += 1 }
        }
        let extra = out.count > maxLines ? ["… \(out.count - maxLines) more changed lines"] : []
        return (out.prefix(maxLines) + extra).joined(separator: "\n")
    }
}
