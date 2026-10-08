import ActivityKit
import Foundation

/// Shows running emulations and firmware updates on the Lock Screen and in the Dynamic Island.
@MainActor
final class LiveActivityController {
    private typealias FlipperActivity = Activity<FlipperActivityAttributes>
    private var emulation: FlipperActivity?
    private var update: FlipperActivity?
    private var engagement: FlipperActivity?
    private var lastUpdateState: FlipperActivityAttributes.ContentState?

    /// Ends activities left over from a previous run; nothing is running after a fresh launch.
    func endStale() {
        for activity in FlipperActivity.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

#if !FLIPPERHERO_STORE
    func engagementStarted(device: String, note: String) {
        end(engagement)
        engagement = request(kind: .engagement, device: device,
                             state: .init(title: String(localized: "Engagement active"),
                                          detail: note.isEmpty
                                              ? String(localized: "The agent runs actions without asking. Stay in scope.")
                                              : String(localized: "The agent runs actions without asking. Scope: \(note)")))
    }

    func engagementStopped() {
        end(engagement)
        engagement = nil
    }
#endif

    func emulationStarted(device: String, title: String, kind: String) {
        end(emulation)
        emulation = request(kind: .emulation, device: device,
                            state: .init(title: title, detail: String(localized: "\(kind) on \(device). Readers nearby see it until you stop.")))
    }

    func emulationStopped() {
        end(emulation)
        emulation = nil
    }

    func firmwareUpdateChanged(_ state: FirmwareUpdateController.State, text: String, device: String) {
        let content: FlipperActivityAttributes.ContentState
        switch state {
        case .idle:
            return
        case .running(let release, _, let progress):
            // Progress arrives per frame; only whole percent steps are worth an update.
            content = .init(title: String(localized: "Updating to \(release)"), detail: text, progress: (progress * 100).rounded() / 100)
        case .waitingForRestart(let release):
            content = .init(title: String(localized: "Installing \(release)"), detail: text, progress: 1)
        case .finished(let message):
            content = .init(title: String(localized: "Firmware updated"), detail: message, isFinished: true)
        case .failed(let message):
            content = .init(title: String(localized: "Firmware update stopped"), detail: message, isFinished: true)
        }
        guard content != lastUpdateState else { return }
        lastUpdateState = content

        if let update {
            let activity = update
            Task {
                if content.isFinished {
                    await activity.end(.init(state: content, staleDate: nil), dismissalPolicy: .after(.now + 15 * 60))
                } else {
                    await activity.update(.init(state: content, staleDate: nil))
                }
            }
            if content.isFinished { self.update = nil }
        } else if !content.isFinished {
            update = request(kind: .firmwareUpdate, device: device, state: content)
        }
    }

    private func request(kind: FlipperActivityAttributes.Kind, device: String,
                         state: FlipperActivityAttributes.ContentState) -> FlipperActivity? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let attributes = FlipperActivityAttributes(kind: kind, deviceName: device, startedAt: .now)
        do {
            return try FlipperActivity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
        } catch {
            AppLog.error("live activity failed: \(error)")
            return nil
        }
    }

    private func end(_ activity: FlipperActivity?) {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
