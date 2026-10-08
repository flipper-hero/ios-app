import Foundation
import FlipperKit

/// What the agent knows about the connected Flipper without having to go looking every turn:
/// firmware, installed apps and what is actually saved on the SD card.
public struct DeviceProfile: Codable, Sendable, Equatable {
    public struct Folder: Codable, Sendable, Equatable {
        public var path: String
        public var fileCount: Int
        public var samples: [String]
    }

    public var deviceName = ""
    public var firmware = ""
    public var firmwareCommit = ""
    public var apiVersion = ""
    public var hardwareUID = ""
    public var freeSpaceBytes: UInt64 = 0
    public var totalSpaceBytes: UInt64 = 0
    /// Installed external apps as "Category/Name".
    public var apps: [String] = []
    public var folders: [Folder] = []
    public var updated = Date()

    /// Folders worth knowing about, in the order they appear in the summary.
    static let scanned = ["/ext/subghz", "/ext/nfc", "/ext/lfrfid", "/ext/infrared", "/ext/ibutton", "/ext/badusb"]
    static let maxApps = 60
    static let maxSamplesPerFolder = 12

    public var isEmpty: Bool { firmware.isEmpty && apps.isEmpty && folders.isEmpty }

    /// Compact, fenced summary for the system prompt. Names come from the device, so they are
    /// sanitized and wrapped like any other untrusted content.
    public func promptSummary(nonce: String) -> String {
        guard !isEmpty else { return "" }
        var lines: [String] = []
        lines.append("Device: \(Untrusted.sanitizeName(deviceName)), firmware \(Untrusted.sanitizeName(firmware)) (\(firmwareCommit)), SDK \(apiVersion)")
        if totalSpaceBytes > 0 {
            let free = ByteCountFormatter.string(fromByteCount: Int64(freeSpaceBytes), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(totalSpaceBytes), countStyle: .file)
            lines.append("SD card: \(free) free of \(total)")
        }
        if !apps.isEmpty {
            lines.append("Installed apps (\(apps.count)): " + apps.map(Untrusted.sanitizeName).joined(separator: ", "))
        }
        for folder in folders where folder.fileCount > 0 {
            let names = folder.samples.map(Untrusted.sanitizeName).joined(separator: ", ")
            let more = folder.fileCount > folder.samples.count ? ", +\(folder.fileCount - folder.samples.count) more" : ""
            lines.append("\(folder.path) (\(folder.fileCount)): \(names)\(more)")
        }
        lines.append("Snapshot taken \(updated.formatted(date: .abbreviated, time: .shortened)); it can be out of date, verify before acting on it.")
        return Untrusted.wrap(lines.joined(separator: "\n"), source: "device inventory", nonce: nonce)
    }
}

/// Builds and caches a `DeviceProfile`. The cache is keyed by hardware UID so several
/// Flippers do not overwrite each other.
public actor DeviceProfileStore {
    private let directory: URL
    private var cache: [String: DeviceProfile] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for uid: String) -> URL {
        directory.appending(path: "profile-\(uid.isEmpty ? "unknown" : uid).json")
    }

    public func cached(uid: String) -> DeviceProfile? {
        if let profile = cache[uid] { return profile }
        guard let data = try? Data(contentsOf: url(for: uid)) else { return nil }
        let profile = try? JSONDecoder().decode(DeviceProfile.self, from: data)
        if let profile { cache[uid] = profile }
        return profile
    }

    public func store(_ profile: DeviceProfile) {
        cache[profile.hardwareUID] = profile
        if let data = try? JSONEncoder().encode(profile) {
            try? data.write(to: url(for: profile.hardwareUID), options: .atomic)
        }
    }

    /// Reads the device. Individual steps are allowed to fail so a missing folder
    /// does not cost us the whole profile.
    public func build(from flipper: FlipperControlling) async -> DeviceProfile {
        var profile = DeviceProfile()
        if let info = try? await flipper.deviceInfo() {
            profile.deviceName = info["hardware_name"] ?? ""
            profile.hardwareUID = info["hardware_uid"] ?? ""
            profile.firmwareCommit = info["firmware_commit"] ?? ""
            profile.apiVersion = "\(info["firmware_api_major"] ?? "0").\(info["firmware_api_minor"] ?? "0")"
            profile.firmware = [info["firmware_origin_fork"], info["firmware_version"]]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        if let storage = try? await flipper.storageInfo(path: "/ext") {
            profile.freeSpaceBytes = storage.freeSpace
            profile.totalSpaceBytes = storage.totalSpace
        }
        if let categories = try? await flipper.list(path: "/ext/apps") {
            for category in categories where category.isDirectory {
                guard profile.apps.count < DeviceProfile.maxApps else { break }
                let path = FlipperPath.join("/ext/apps", category.name)
                guard let entries = try? await flipper.list(path: path) else { continue }
                for entry in entries where entry.name.lowercased().hasSuffix(".fap") {
                    guard profile.apps.count < DeviceProfile.maxApps else { break }
                    profile.apps.append("\(category.name)/\(entry.name.replacingOccurrences(of: ".fap", with: ""))")
                }
            }
        }
        for path in DeviceProfile.scanned {
            guard let entries = try? await flipper.list(path: path) else { continue }
            let files = entries.filter { !$0.isDirectory }
            let folders = entries.filter(\.isDirectory)
            var samples = files.prefix(DeviceProfile.maxSamplesPerFolder).map(\.name)
            if samples.count < DeviceProfile.maxSamplesPerFolder {
                samples += folders.prefix(DeviceProfile.maxSamplesPerFolder - samples.count).map { $0.name + "/" }
            }
            profile.folders.append(.init(path: path, fileCount: entries.count, samples: Array(samples)))
        }
        profile.updated = Date()
        store(profile)
        return profile
    }
}
