import Foundation
import FlipperKit
@testable import AgentKit

actor FakeFlipper: FlipperControlling {
    var files: [String: Data] = [:]
    var dirs: Set<String> = ["/ext"]
    private(set) var calls: [String] = []

    init(files: [String: String] = [:]) {
        for (path, content) in files { self.files[path] = Data(content.utf8) }
    }

    func seed(_ path: String, bytes: Data) { files[path] = bytes }

    func deviceInfo() async throws -> [String: String] {
        calls.append("deviceInfo")
        return ["hardware_name": "Laisear", "firmware_commit": "d3f89dfe", "unrelated": "x"]
    }
    func powerInfo() async throws -> [String: String] { calls.append("powerInfo"); return ["charge.level": "87"] }
    func storageInfo(path: String) async throws -> FlipperStorageInfo {
        calls.append("storageInfo"); return .init(totalSpace: 100, freeSpace: 40)
    }
    /// Mirrors the real device: returns files in this folder plus any implied subfolders.
    func list(path: String) async throws -> [FlipperDirEntry] {
        calls.append("list \(path)")
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var entries: [FlipperDirEntry] = []
        var seenDirs: Set<String> = []
        for (full, data) in files where full.hasPrefix(prefix) {
            let rest = String(full.dropFirst(prefix.count))
            if let slash = rest.firstIndex(of: "/") {
                let dir = String(rest[rest.startIndex..<slash])
                if seenDirs.insert(dir).inserted {
                    entries.append(FlipperDirEntry(name: dir, isDirectory: true, size: 0))
                }
            } else {
                entries.append(FlipperDirEntry(name: rest, isDirectory: false, size: UInt32(data.count)))
            }
        }
        for dir in dirs where dir.hasPrefix(prefix) {
            let rest = String(dir.dropFirst(prefix.count))
            if !rest.isEmpty, !rest.contains("/"), seenDirs.insert(rest).inserted {
                entries.append(FlipperDirEntry(name: rest, isDirectory: true, size: 0))
            }
        }
        return entries.sorted { $0.name < $1.name }
    }
    func stat(path: String) async throws -> FlipperDirEntry {
        if let data = files[path] { return .init(name: FlipperPath.lastComponent(path), isDirectory: false, size: UInt32(data.count)) }
        if dirs.contains(path) { return .init(name: FlipperPath.lastComponent(path), isDirectory: true, size: 0) }
        throw FlipperError.rpc("not exist")
    }
    func read(path: String, maxBytes: Int) async throws -> Data {
        calls.append("read \(path)")
        guard let data = files[path] else { throw FlipperError.rpc("not exist") }
        guard data.count <= maxBytes else { throw FlipperError.rpc("too large") }
        return data
    }
    func write(path: String, data: Data) async throws { calls.append("write \(path)"); files[path] = data }
    func makeDirectory(path: String) async throws { calls.append("mkdir \(path)"); dirs.insert(path) }
    func delete(path: String, recursive: Bool) async throws {
        calls.append("delete \(path)")
        files = files.filter { !($0.key == path || (recursive && $0.key.hasPrefix(path + "/"))) }
    }
    func rename(from: String, to: String) async throws {
        calls.append("rename \(from) \(to)")
        if let d = files.removeValue(forKey: from) { files[to] = d }
    }
    func startApp(name: String, args: String) async throws { calls.append("startApp \(name) \(args)") }
    func transmitOnce(_ app: FlipperApp, path: String, button: String, hold: Duration) async throws {
        calls.append("transmit \(app.rawValue) \(path) \(button)")
    }
    func emulate(_ app: FlipperApp, path: String) async throws { calls.append("emulate \(app.rawValue) \(path)") }
    func loadBadKeyboardScript(path: String) async throws { calls.append("badusb \(path)") }
    func exitApp() async throws { calls.append("exitApp") }
    func playAlert() async throws { calls.append("alert") }
    private(set) var pendingName: String?
    func setDeviceName(_ name: String) async throws { calls.append("setName \(name)"); pendingName = name }
    func customDeviceName() async throws -> String? { pendingName }

    var screen = FlipperScreenFrame(buffer: Data(repeating: 0, count: 1024))
    private(set) var presses: [String] = []
    func captureScreen(timeout: Duration) async throws -> FlipperScreenFrame { calls.append("capture"); return screen }
    func press(_ key: FlipperKey, long: Bool) async throws { presses.append(long ? "long_\(key.rawValue)" : key.rawValue) }
    func gpioSetMode(pin: FlipperGPIOPin, output: Bool, pullUp: Bool?) async throws {
        calls.append("gpio mode \(pin.rawValue) \(output ? "output" : "input")")
    }
    func gpioRead(pin: FlipperGPIOPin) async throws -> Bool {
        calls.append("gpio read \(pin.rawValue)")
        return true
    }
    func gpioWrite(pin: FlipperGPIOPin, level: Bool) async throws {
        calls.append("gpio write \(pin.rawValue) \(level ? "high" : "low")")
    }
    private(set) var rawRequests: [String] = []
    func rawRPC(jsonRequest: String) async throws -> String {
        calls.append("rawRPC")
        rawRequests.append(jsonRequest)
        return #"{"commandStatus":"OK"}"#
    }
}

/// Returns a canned payload so forge tests do not need a network call.
final class StubLLM: LLMClient, @unchecked Sendable {
    let content: String
    init(content: String) { self.content = content }
    func complete(messages: [ChatMessage], tools: [ToolSpec]) async throws -> ChatMessage {
        ChatMessage(role: .assistant, content: content)
    }
}

final class ScriptedGate: ApprovalGate, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ApprovalRequest] = []
    var answer: Bool
    init(answer: Bool) { self.answer = answer }
    var requests: [ApprovalRequest] { lock.withLock { _requests } }
    func decide(_ request: ApprovalRequest) async -> Bool {
        lock.withLock { _requests.append(request) }
        return answer
    }
}

final class ScriptedLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [ChatMessage]
    private(set) var seenMessages: [[ChatMessage]] = []
    init(_ script: [ChatMessage]) { self.script = script }
    func complete(messages: [ChatMessage], tools: [ToolSpec]) async throws -> ChatMessage {
        lock.withLock {
            seenMessages.append(messages)
            return script.isEmpty ? ChatMessage(role: .assistant, content: "done") : script.removeFirst()
        }
    }
}

func toolCall(_ name: String, _ args: String = "{}", id: String = UUID().uuidString) -> ChatMessage {
    ChatMessage(role: .assistant, content: nil, toolCalls: [ToolCall(id: id, name: name, arguments: args)])
}
