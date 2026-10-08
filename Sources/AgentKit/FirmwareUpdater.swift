import Foundation
import FlipperKit

/// What the updater needs from a connected Flipper.
public protocol FlipperUpdating: Sendable {
    func deviceInfo() async throws -> [String: String]
    func powerInfo() async throws -> [String: String]
    func storageInfo(path: String) async throws -> FlipperStorageInfo
    func makeDirectories(path: String) async throws
    func write(path: String, data: Data, progress: (@Sendable (Int, Int) -> Void)?) async throws
    func requestUpdate(manifestPath: String) async throws -> FlipperUpdateResult
    func rebootIntoUpdater() async throws
}

extension FlipperRPCClient: FlipperUpdating {}

/// A validated update package, ready to upload. Contents are never modified: the manifest pins
/// CRCs and option bytes, and the on-device updater checks them.
public struct FirmwareUpdatePackage: Sendable, Equatable {
    public var release: String
    public var folder: String
    public var files: [TarGz.Entry]
    public var target: String

    public var totalBytes: Int { files.reduce(0) { $0 + $1.data.count } }
    public var manifestPath: String { "/ext/update/\(folder)/update.fuf" }

    public enum PackageError: Error, Equatable, CustomStringConvertible {
        case layout(String)
        case missingManifest
        case wrongTarget(package: String, device: String)

        public var description: String {
            switch self {
            case .layout(let why): L("The update package has an unexpected layout: \(why)")
            case .missingManifest: L("The update package has no update.fuf manifest")
            case .wrongTarget(let p, let d): L("The package is for hardware target \(p), this Flipper is target \(d)")
            }
        }
    }

    /// Accepts exactly one top-level folder with plain file names in it.
    public init(release: String, entries: [TarGz.Entry]) throws {
        var folder: String?
        var files: [TarGz.Entry] = []
        for entry in entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2 else { throw PackageError.layout("\(entry.path) is not directly inside one folder") }
            let (dir, name) = (parts[0], parts[1])
            for part in parts where part == ".." || part == "." || part.hasPrefix(".") || part.contains("\\") {
                throw PackageError.layout("unsafe path \(entry.path)")
            }
            guard name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }),
                  dir.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }) else {
                throw PackageError.layout("unexpected characters in \(entry.path)")
            }
            if let folder, folder != dir { throw PackageError.layout("more than one top-level folder") }
            folder = dir
            files.append(TarGz.Entry(path: name, data: entry.data))
        }
        guard let folder, !files.isEmpty else { throw PackageError.layout("empty package") }
        guard let manifest = files.first(where: { $0.path == "update.fuf" }),
              let text = String(data: manifest.data, encoding: .utf8) else { throw PackageError.missingManifest }
        let target = text.components(separatedBy: .newlines)
            .first { $0.hasPrefix("Target:") }
            .map { $0.dropFirst("Target:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        self.release = release
        self.folder = folder
        self.files = files.sorted { lhs, rhs in
            // Manifest last: the folder is only "complete" once it is there.
            if lhs.path == "update.fuf" { return false }
            if rhs.path == "update.fuf" { return true }
            return lhs.path < rhs.path
        }
        self.target = target
    }
}

public enum FirmwareUpdatePhase: Sendable, Equatable {
    case downloading
    case checking
    case uploading(file: String)
    case staging
    case restarting
}

public enum FirmwareUpdateError: Error, Equatable, CustomStringConvertible {
    case noPackage(String)
    case batteryTooLow(Int)
    case notEnoughSpace(needed: Int, free: Int)
    case rejected(String)

    public var description: String {
        switch self {
        case .noPackage(let release): L("No update package found for \(release)")
        case .batteryTooLow(let level): L("Battery is at \(level)%. Charge to at least \(FirmwareUpdater.minimumBattery)% or plug it in first.")
        case .notEnoughSpace(let needed, let free):
            "Not enough space on the SD card: need \(ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)), free \(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file))"
        case .rejected(let why): L("The Flipper rejected the update: \(why)")
        }
    }
}

/// Downloads a release's update package, checks it, uploads it and starts the on-device updater.
public struct FirmwareUpdater: Sendable {
    public static let minimumBattery = 30
    public var session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// The update package asset of the newest release.
    public func latestPackageURL(for distribution: FirmwareDistribution) async throws -> (release: String, url: URL) {
        let api = URL(string: "https://api.github.com/repos/\(distribution.repo)/releases/latest")!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let assets = root["assets"] as? [[String: Any]] else { throw FirmwareUpdateError.noPackage(distribution.name) }
        let asset = assets.first {
            let name = ($0["name"] as? String ?? "").lowercased()
            return name.contains("update") && name.hasSuffix(".tgz") && name.contains("f7")
        }
        guard let link = asset?["browser_download_url"] as? String, let url = URL(string: link),
              url.scheme == "https", url.host()?.hasSuffix("github.com") == true else {
            throw FirmwareUpdateError.noPackage(tag)
        }
        return (tag, url)
    }

    public func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let delegate = DownloadProgress(report: progress)
        let (file, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw CatalogError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try Data(contentsOf: file)
    }

    /// Battery, space and hardware target, before anything is written.
    public static func preflight(_ package: FirmwareUpdatePackage, on flipper: FlipperUpdating) async throws {
        let info = try await flipper.deviceInfo()
        if let device = info["hardware_target"], !package.target.isEmpty, device != package.target {
            throw FirmwareUpdatePackage.PackageError.wrongTarget(package: package.target, device: device)
        }
        let power = try await flipper.powerInfo()
        let charging = (power["charge_state"] ?? power["charge.state"] ?? "") == "charging"
        if let level = Int(power["charge_level"] ?? power["charge.level"] ?? ""), level < minimumBattery, !charging {
            throw FirmwareUpdateError.batteryTooLow(level)
        }
        let storage = try await flipper.storageInfo(path: "/ext")
        let needed = package.totalBytes + package.totalBytes / 5
        if storage.freeSpace < UInt64(needed) {
            throw FirmwareUpdateError.notEnoughSpace(needed: needed, free: Int(storage.freeSpace))
        }
    }

    /// Uploads the package and starts the updater. Progress goes from 0 to 1 over the upload.
    public static func install(_ package: FirmwareUpdatePackage, on flipper: FlipperUpdating,
                               phase: @escaping @Sendable (FirmwareUpdatePhase) -> Void,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        phase(.checking)
        try await preflight(package, on: flipper)
        let folder = "/ext/update/\(package.folder)"
        try await flipper.makeDirectories(path: folder)
        let total = Double(max(package.totalBytes, 1))
        var done = 0
        for file in package.files {
            try Task.checkCancellation()
            phase(.uploading(file: file.path))
            let base = done
            try await flipper.write(path: "\(folder)/\(file.path)", data: file.data, progress: { sent, _ in
                progress(Double(base + sent) / total)
            })
            done += file.data.count
            progress(Double(done) / total)
        }
        phase(.staging)
        if case .rejected(let why) = try await flipper.requestUpdate(manifestPath: package.manifestPath) {
            throw FirmwareUpdateError.rejected(why)
        }
        phase(.restarting)
        try await flipper.rebootIntoUpdater()
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
