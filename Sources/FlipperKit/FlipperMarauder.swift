#if !FLIPPERHERO_STORE
import Foundation
import FlipperProto

public enum MarauderMode: String, Sendable, CaseIterable {
    case beacon, probe, deauth, pmkid

    var command: String { "sniff\(rawValue)" }
}

public enum MarauderAttack: String, Sendable, CaseIterable {
    case deauth, probe, beacon, rickroll

    var command: String {
        switch self {
        case .deauth: "attack -t deauth"
        case .probe: "attack -t probe"
        case .beacon: "attack -t beacon -r"
        case .rickroll: "attack -t rickroll"
        }
    }
}

public enum MarauderOperation: Sendable, Equatable {
    case commands, accessPoints, stations, ssids
    case scanAccessPoints(seconds: Int), scanStations(seconds: Int)
    case sniff(MarauderMode, seconds: Int)
    case attack(MarauderAttack, targetIndex: Int?, seconds: Int)

    public var auditName: String {
        switch self {
        case .commands: "commands"
        case .accessPoints: "access point list"
        case .stations: "station list"
        case .ssids: "SSID list"
        case .scanAccessPoints(let seconds): "access point scan (\(seconds) s)"
        case .scanStations(let seconds): "station scan (\(seconds) s)"
        case .sniff(let mode, let seconds): "sniff \(mode.rawValue) (\(seconds) s)"
        case .attack(let mode, let index, let seconds):
            if let index {
                "attack \(mode.rawValue) (\(mode == .deauth ? "AP" : "SSID") \(index), \(seconds) s)"
            } else {
                "attack \(mode.rawValue) (\(seconds) s)"
            }
        }
    }
}

extension FlipperRPCClient {
    private static let marauderPath = "/ext/apps/GPIO/marauder_bridge.fap"

    /// Owns one RPC app session for a bounded Marauder operation. The FAP has its own
    /// allowlist and stops a running radio mode if this RPC session disappears.
    public func marauder(_ operation: MarauderOperation) async throws -> String {
        guard !marauderSessionActive else { throw FlipperError.rpc(L("Another Marauder operation is running")) }
        marauderSessionActive = true
        defer { marauderSessionActive = false }
        let started = unsolicitedMessages()
        try await startApp(name: Self.marauderPath, args: "RPC")
        do {
            try await waitForMarauderStart(started)
            let output = try await runMarauder(operation)
            try await exitApp()
            return output
        } catch {
            try? await exitApp()
            throw error
        }
    }

    private func waitForMarauderStart(_ messages: AsyncStream<PB_Main>) async throws {
        let ready = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await message in messages {
                    if case .appStateResponse(let state)? = message.content,
                       state.state == .appStarted { return true }
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(4))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        guard ready else { throw FlipperError.timeout }
    }

    private func sendMarauder(_ command: String) async throws {
        var request = PBApp_DataExchangeRequest()
        request.data = Data(command.utf8)
        _ = try await call(.appDataExchangeRequest(request), timeout: .seconds(10))
    }

    private func collectMarauder(_ command: String, seconds: Int, stop: Bool = false) async throws -> String {
        let messages = unsolicitedMessages(bufferLimit: 256)
        let reader = Task { () throws -> Data in
            var output = Data()
            for await message in messages {
                if case .appDataExchangeRequest(let chunk)? = message.content {
                    guard output.count + chunk.data.count <= 24 * 1024 else {
                        throw FlipperError.frameTooLarge(output.count + chunk.data.count)
                    }
                    output.append(chunk.data)
                }
            }
            return output
        }
        do {
            try await sendMarauder(command)
            try await Task.sleep(for: .seconds(seconds))
            if stop {
                try await sendMarauder("stopscan")
                try await Task.sleep(for: .milliseconds(700))
            }
            reader.cancel()
            let data = try await reader.value
            return Self.cleanMarauderOutput(data)
        } catch {
            reader.cancel()
            if stop { try? await sendMarauder("stopscan") }
            throw error
        }
    }

    private func runMarauder(_ operation: MarauderOperation) async throws -> String {
        switch operation {
        case .commands: return try await collectMarauder("help", seconds: 2)
        case .accessPoints: return try await collectMarauder("list -a", seconds: 2)
        case .stations: return try await collectMarauder("list -c", seconds: 2)
        case .ssids: return try await collectMarauder("list -s", seconds: 2)
        case .scanAccessPoints(let seconds):
            guard (1...30).contains(seconds) else { throw FlipperError.rpc(L("Invalid Marauder parameters")) }
            let scan = try await collectMarauder("scanap", seconds: seconds, stop: true)
            return Self.limitMarauderOutput(scan + "\n" + (try await collectMarauder("list -a", seconds: 2)))
        case .scanStations(let seconds):
            guard (1...30).contains(seconds) else { throw FlipperError.rpc(L("Invalid Marauder parameters")) }
            let scan = try await collectMarauder("scansta", seconds: seconds, stop: true)
            return Self.limitMarauderOutput(scan + "\n" + (try await collectMarauder("list -c", seconds: 2)))
        case .sniff(let mode, let seconds):
            guard (1...30).contains(seconds) else { throw FlipperError.rpc(L("Invalid Marauder parameters")) }
            return try await collectMarauder(mode.command, seconds: seconds, stop: true)
        case .attack(let mode, let index, let seconds):
            guard (1...10).contains(seconds) else { throw FlipperError.rpc(L("Invalid Marauder parameters")) }
            if mode == .deauth || mode == .probe {
                guard let index, (0...99).contains(index) else {
                    throw FlipperError.rpc(L("Invalid Marauder parameters"))
                }
                let selection = try await collectMarauder("select \(mode == .deauth ? "-a" : "-s") \(index)", seconds: 2)
                guard !selection.isEmpty, !selection.lowercased().contains("invalid") else {
                    throw FlipperError.rpc(L("Marauder did not accept the selected target"))
                }
            } else if index != nil {
                throw FlipperError.rpc(L("Invalid Marauder parameters"))
            }
            return try await collectMarauder(mode.command, seconds: seconds, stop: true)
        }
    }

    private static func cleanMarauderOutput(_ data: Data) -> String {
        var output = ""
        var escape = false
        var csi = false
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            if escape {
                escape = false
                if scalar == "[" { csi = true }
                continue
            }
            if csi {
                if ("@"..."~").contains(String(scalar)) { csi = false }
                continue
            }
            if scalar == "\u{1B}" { escape = true }
            else if scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar) {
                output.unicodeScalars.append(scalar)
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func limitMarauderOutput(_ text: String) -> String {
        String(decoding: text.utf8.prefix(24 * 1024), as: UTF8.self)
    }
}
#endif
