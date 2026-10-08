import Foundation

/// The well-known Flipper firmware distributions, recognised from what the device reports
/// in `firmware_origin_fork`, with the repository used to look up the newest release.
public struct FirmwareDistribution: Sendable, Equatable {
    public var name: String
    public var repo: String
    public var notes: String

    public var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases")! }
}

public enum FirmwareCatalog {
    public static let known: [FirmwareDistribution] = [
        .init(name: "Momentum", repo: "Next-Flip/Momentum-Firmware",
              notes: L("Feature-rich fork with asset packs and extra apps")),
        .init(name: "Unleashed", repo: "DarkFlippers/unleashed-firmware",
              notes: L("Region-unlocked fork, large protocol set")),
        .init(name: "RogueMaster", repo: "RogueMaster/flipperzero-firmware-wPlugins",
              notes: L("Unleashed-based, ships a very large app bundle")),
        .init(name: "Xtreme", repo: "Flipper-XFW/Xtreme-Firmware",
              notes: L("Predecessor of Momentum, archived")),
        .init(name: "Official", repo: "flipperdevices/flipperzero-firmware",
              notes: L("Stock firmware from Flipper Devices")),
    ]

    /// Matches `firmware_origin_fork` (and falls back to the version string) against the catalog.
    public static func identify(fork: String?, version: String?) -> FirmwareDistribution? {
        let haystack = [fork, version].compactMap { $0 }.joined(separator: " ").lowercased()
        guard !haystack.isEmpty else { return nil }
        if let direct = known.first(where: { haystack.contains($0.name.lowercased()) }) { return direct }
        // Momentum reports versions like "mntm-dev"; Unleashed uses "unlshd".
        if haystack.contains("mntm") { return known.first { $0.name == "Momentum" } }
        if haystack.contains("unlshd") || haystack.contains("unleashed") { return known.first { $0.name == "Unleashed" } }
        if haystack.contains("rm ") || haystack.contains("roguemaster") { return known.first { $0.name == "RogueMaster" } }
        return nil
    }
}

public struct FirmwareStatus: Sendable, Equatable {
    public var distribution: FirmwareDistribution
    public var installedVersion: String
    public var latestRelease: String?
    /// nil when the installed build is a dev build and cannot be compared to a release tag.
    public var updateAvailable: Bool?

    public init(distribution: FirmwareDistribution, installedVersion: String, latestRelease: String?,
                updateAvailable: Bool?) {
        self.distribution = distribution; self.installedVersion = installedVersion
        self.latestRelease = latestRelease; self.updateAvailable = updateAvailable
    }

    public var summary: String {
        guard let latest = latestRelease else { return "\(distribution.name) \(installedVersion)" }
        switch updateAvailable {
        case true?: return L("\(distribution.name) \(installedVersion); \(latest) is available")
        case false?: return L("\(distribution.name) \(installedVersion) is the newest release")
        default: return L("\(distribution.name) \(installedVersion) (dev build); newest release is \(latest)")
        }
    }
}

/// Looks up the newest published release of a firmware distribution.
public struct FirmwareUpdateChecker: Sendable {
    public var session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func latestRelease(for distribution: FirmwareDistribution) async throws -> String? {
        let url = URL(string: "https://api.github.com/repos/\(distribution.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["tag_name"] as? String) ?? (root["name"] as? String)
    }

    public func status(fork: String?, version: String?) async -> FirmwareStatus? {
        guard let distribution = FirmwareCatalog.identify(fork: fork, version: version) else { return nil }
        let installed = version ?? "unknown"
        let latest = try? await latestRelease(for: distribution)
        return FirmwareStatus(distribution: distribution, installedVersion: installed,
                              latestRelease: latest, updateAvailable: Self.compare(installed, latest))
    }

    /// Dev builds carry no release tag, so a comparison would be misleading. Returns nil for those.
    static func compare(_ installed: String, _ latest: String?) -> Bool? {
        guard let latest, !latest.isEmpty else { return nil }
        let normalizedInstalled = installed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalizedInstalled.isEmpty, normalizedInstalled != "unknown" else { return nil }
        for marker in ["dev", "dirty", "local", "rc"] where normalizedInstalled.contains(marker) { return nil }
        let normalizedLatest = latest.trimmingCharacters(in: .whitespaces).lowercased()
        func digits(_ s: String) -> String { s.drop { !$0.isNumber }.description }
        if normalizedInstalled == normalizedLatest { return false }
        if digits(normalizedInstalled) == digits(normalizedLatest), !digits(normalizedLatest).isEmpty { return false }
        return true
    }
}
