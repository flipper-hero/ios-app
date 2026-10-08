import Foundation

/// The custom device name lives on the SD card, not in internal storage:
/// /ext/dolphin/name.settings, read by the firmware at boot.
public enum FlipperName {
    public static let path = "/ext/dolphin/name.settings"
    public static let maxLength = 8

    public enum NameError: Error, Equatable, CustomStringConvertible {
        case tooLong(Int)
        case empty
        case invalidCharacters

        public var description: String {
            switch self {
            case .tooLong(let n): L("The name is \(n) characters; the Flipper allows at most \(maxLength).")
            case .empty: L("The name is empty.")
            case .invalidCharacters: L("Use only letters, digits, hyphen and underscore.")
            }
        }
    }

    public static func validate(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NameError.empty }
        guard trimmed.count <= maxLength else { throw NameError.tooLong(trimmed.count) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { throw NameError.invalidCharacters }
        return trimmed
    }

    public static func fileContents(for name: String) -> String {
        "Filetype: Flipper Name File\nVersion: 1\nName: \(name)\n"
    }

    /// Parses the Name: field out of the settings file.
    public static func parse(_ contents: String) -> String? {
        for line in contents.components(separatedBy: .newlines) {
            guard line.hasPrefix("Name:") else { continue }
            let value = line.dropFirst("Name:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

extension FlipperRPCClient {
    /// Custom name currently set on the SD card, if any. The firmware falls back to the
    /// hardware name when the file is absent.
    public func customDeviceName() async throws -> String? {
        guard let data = try? await read(path: FlipperName.path, maxBytes: 1024),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return FlipperName.parse(text)
    }

    /// Writes the name file. The Flipper applies it on the next reboot.
    public func setDeviceName(_ name: String) async throws {
        let valid = try FlipperName.validate(name)
        try? await makeDirectory(path: "/ext/dolphin")
        try await write(path: FlipperName.path, data: Data(FlipperName.fileContents(for: valid).utf8))
    }
}
