import Foundation
import Observation
import UIKit
import FlipperKit
import AgentKit

/// Runs a firmware update in the background: download, check, upload, stage, restart,
/// then confirms the new version once the Flipper is back.
@MainActor @Observable
final class FirmwareUpdateController {
    enum State: Equatable {
        case idle
        case running(release: String, phase: FirmwareUpdatePhase, progress: Double)
        case waitingForRestart(release: String)
        case finished(String)
        case failed(String)
    }

    private(set) var state: State = .idle { didSet { onChange?(state, statusText) } }
    /// Called on every state change, for the Live Activity.
    @ObservationIgnored var onChange: ((State, String) -> Void)?
    private var task: Task<Void, Never>?
    private let updater = FirmwareUpdater()

    var isBusy: Bool {
        switch state {
        case .running, .waitingForRestart: true
        default: false
        }
    }

    var statusText: String {
        switch state {
        case .idle: return String(localized: "No update is running.")
        case .running(let release, let phase, let progress):
            let percent = Int(progress * 100)
            switch phase {
            case .downloading: return String(localized: "Downloading \(release), \(percent)%")
            case .checking: return String(localized: "Checking the Flipper before installing \(release)")
            case .uploading(let file): return String(localized: "Uploading \(release) to the Flipper, \(percent)% (\(file))")
            case .staging: return String(localized: "Handing \(release) to the updater")
            case .restarting: return String(localized: "Restarting the Flipper into the updater")
            }
        case .waitingForRestart(let release):
            return String(localized: "The Flipper is installing \(release) on its own and will restart. This takes a few minutes.")
        case .finished(let message): return message
        case .failed(let message): return String(localized: "Update failed: \(message)")
        }
    }

    /// Starts the update. `client` and `distribution` come from the connected device.
    func start(client: FlipperRPCClient, distribution: FirmwareDistribution,
               onRestart: @escaping @MainActor () -> Void) throws -> String {
        guard !isBusy else { return statusText }
        state = .running(release: distribution.name, phase: .downloading, progress: 0)
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let (release, url) = try await updater.latestPackageURL(for: distribution)
                self.state = .running(release: release, phase: .downloading, progress: 0)
                let data = try await updater.download(url) { value in
                    Task { @MainActor [weak self] in self?.report(release: release, phase: .downloading, progress: value) }
                }
                let package = try FirmwareUpdatePackage(release: release, entries: TarGz.extract(data))
                AppLog.info("firmware package \(package.folder): \(package.files.count) files, \(package.totalBytes) bytes")
                try await FirmwareUpdater.install(package, on: client, phase: { phase in
                    Task { @MainActor [weak self] in
                        if phase == .restarting { onRestart() }
                        self?.report(release: release, phase: phase, progress: nil)
                    }
                }, progress: { value in
                    Task { @MainActor [weak self] in self?.report(release: release, phase: nil, progress: value) }
                })
                self.state = .waitingForRestart(release: release)
            } catch is CancellationError {
                self.state = .failed(String(localized: "cancelled"))
            } catch {
                AppLog.error("firmware update failed: \(error)")
                self.state = .failed("\(error)")
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
        return String(localized: "Started updating \(distribution.name) in the background. It downloads, uploads about 12 MB over Bluetooth (15 to 25 minutes), then the Flipper installs it and restarts.")
    }

    private func report(release: String, phase: FirmwareUpdatePhase?, progress: Double?) {
        guard case .running(_, let currentPhase, let currentProgress) = state else { return }
        state = .running(release: release, phase: phase ?? currentPhase, progress: progress ?? currentProgress)
    }

    /// Cancels while downloading or uploading. Once the Flipper has the update staged, it is too late.
    @discardableResult
    func cancel() -> String {
        switch state {
        case .running(let release, let phase, _) where phase != .staging && phase != .restarting:
            task?.cancel()
            return String(localized: "Cancelled the update to \(release). Nothing was installed.")
        case .running, .waitingForRestart:
            return String(localized: "Too late to cancel: the Flipper's updater already has the new firmware and installs it on its own.")
        default:
            return String(localized: "No update is running.")
        }
    }

    /// Called after reconnecting, to confirm the version that is now running.
    func deviceReconnected(firmwareVersion: String?) {
        guard case .waitingForRestart(let release) = state else { return }
        if let version = firmwareVersion, version.lowercased().contains(release.lowercased()) {
            state = .finished(String(localized: "Installed \(release). The Flipper is running \(version)."))
        } else {
            state = .finished(String(localized: "The Flipper is back and reports \(firmwareVersion ?? String(localized: "an unknown version")). Expected \(release)."))
        }
    }
}
