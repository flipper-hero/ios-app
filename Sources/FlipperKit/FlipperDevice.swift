import Foundation
import FlipperProto

/// Apps on the Flipper that can be driven over RPC, with the loader name the firmware expects.
public enum FlipperApp: String, Sendable, CaseIterable {
    case subGhz = "Sub-GHz"
    case infrared = "Infrared"
    case rfid = "125 kHz RFID"
    case nfc = "NFC"
    case iButton = "iButton"
    case badKeyboard = "Bad KB"

    /// File extension the app expects, used to reject obviously wrong files before touching hardware.
    public var fileExtension: String {
        switch self {
        case .subGhz: "sub"
        case .infrared: "ir"
        case .rfid: "rfid"
        case .nfc: "nfc"
        case .iButton: "ibtn"
        case .badKeyboard: "txt"
        }
    }
}

extension FlipperRPCClient {
    /// Opens `app` in RPC mode and loads `path`. The caller must call `exitApp()` afterwards.
    private func openInRPCMode(_ app: FlipperApp, path: String) async throws {
        let normalized = try FlipperPath.normalize(path)
        guard normalized.lowercased().hasSuffix("." + app.fileExtension) else {
            throw FlipperError.invalidPath("\(app.rawValue) expects a .\(app.fileExtension) file")
        }
        _ = try await stat(path: normalized) // fails early if the file is missing

        var start = PBApp_StartRequest()
        start.name = app.rawValue
        start.args = "RPC"
        _ = try await call(.appStartRequest(start), timeout: .seconds(30))

        var load = PBApp_AppLoadFileRequest()
        load.path = normalized
        do {
            _ = try await call(.appLoadFileRequest(load), timeout: .seconds(30))
        } catch {
            try? await exitApp()
            throw error
        }
    }

    public func exitApp() async throws {
        _ = try await call(.appExitRequest(PBApp_AppExitRequest()), timeout: .seconds(15))
    }

    /// Loads a file and emulates it until `stop()` on the returned handle is called, or the timeout expires.
    /// Used for NFC, RFID and iButton, where loading alone starts emulation.
    public func emulate(_ app: FlipperApp, path: String) async throws {
        try await openInRPCMode(app, path: path)
    }

    /// Loads a signal and transmits it once (press, short hold, release), then closes the app.
    /// `button` selects a named button for Infrared remotes; Sub-GHz ignores it.
    public func transmitOnce(_ app: FlipperApp, path: String, button: String = "",
                             hold: Duration = .milliseconds(400)) async throws {
        try await openInRPCMode(app, path: path)
        do {
            var press = PBApp_AppButtonPressRequest()
            press.args = button
            _ = try await call(.appButtonPressRequest(press), timeout: .seconds(20))
            try await Task.sleep(for: hold)
            _ = try await call(.appButtonReleaseRequest(PBApp_AppButtonReleaseRequest()), timeout: .seconds(20))
        } catch {
            try? await exitApp()
            throw error
        }
        try await exitApp()
    }

    /// Opens Bad KB with a script loaded. The script is NOT started: the firmware still requires
    /// a press on the Flipper itself, which we deliberately do not automate.
    public func loadBadKeyboardScript(path: String) async throws {
        let normalized = try FlipperPath.normalize(path)
        _ = try await stat(path: normalized)
        var start = PBApp_StartRequest()
        start.name = FlipperApp.badKeyboard.rawValue
        start.args = normalized
        _ = try await call(.appStartRequest(start), timeout: .seconds(30))
    }

    /// Last error reported by the running app, if any.
    public func appError() async throws -> String? {
        let parts = try await call(.appGetErrorRequest(PBApp_GetErrorRequest()))
        guard case .appGetErrorResponse(let response)? = parts.first?.content, response.code != 0 else { return nil }
        return response.text.isEmpty ? "error code \(response.code)" : response.text
    }
}

extension FlipperRPCClient {
    /// Beeps, blinks and vibrates so the user can locate the device.
    public func playAlert() async throws {
        _ = try await call(.systemPlayAudiovisualAlertRequest(PBSystem_PlayAudiovisualAlertRequest()))
    }
}

extension FlipperRPCClient {
    /// Restarts the Flipper into its normal firmware. The device drops the link while
    /// answering, so a lost connection or timeout here means the request was received.
    public func reboot() async throws {
        try await reboot(into: .os)
    }

    /// Restarts into the given mode. `.update` starts the on-device updater.
    public func reboot(into mode: PBSystem_RebootRequest.RebootMode) async throws {
        var request = PBSystem_RebootRequest()
        request.mode = mode
        do {
            _ = try await call(.systemRebootRequest(request), timeout: .seconds(5))
        } catch FlipperError.timeout {
        } catch FlipperError.notConnected {
        }
    }
}

public enum FlipperUpdateResult: Sendable, Equatable {
    case ok
    case rejected(String)
}

extension FlipperRPCClient {
    /// Asks the firmware to validate and stage an update package already on the SD card.
    public func requestUpdate(manifestPath: String) async throws -> FlipperUpdateResult {
        var request = PBSystem_UpdateRequest()
        request.updateManifest = try FlipperPath.normalize(manifestPath)
        let parts = try await call(.systemUpdateRequest(request), timeout: .seconds(60))
        guard case .systemUpdateResponse(let response)? = parts.first?.content else {
            throw FlipperError.unexpectedResponse
        }
        return response.code == .ok ? .ok : .rejected("\(response.code)")
    }

    /// Restarts into the updater, which installs the staged package and reboots again.
    public func rebootIntoUpdater() async throws {
        try await reboot(into: .update)
    }
}
