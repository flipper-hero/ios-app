import Foundation

/// Validation and normalization for paths sent to the Flipper.
public enum FlipperPath {
    public static let roots = ["/ext", "/int", "/any"]
    public static let maxLength = 255

    /// Returns a normalized absolute path ("." and "//" collapsed) or throws.
    /// ".." is rejected outright instead of being resolved.
    public static func normalize(_ raw: String) throws -> String {
        guard !raw.isEmpty else { throw FlipperError.invalidPath("empty") }
        guard raw.utf8.count <= maxLength else { throw FlipperError.invalidPath("too long") }
        guard raw.hasPrefix("/") else { throw FlipperError.invalidPath("must be absolute") }
        for scalar in raw.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            throw FlipperError.invalidPath("control character")
        }
        var parts: [Substring] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { throw FlipperError.invalidPath("'..' is not allowed") }
            parts.append(part)
        }
        guard let first = parts.first, roots.contains("/" + first) else {
            throw FlipperError.invalidPath("must be under /ext, /int or /any")
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public static func parent(_ path: String) -> String {
        let comps = path.split(separator: "/").dropLast()
        return "/" + comps.joined(separator: "/")
    }

    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}
