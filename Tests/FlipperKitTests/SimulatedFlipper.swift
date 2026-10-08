import Foundation
@testable import FlipperKit
import FlipperProto

/// A small Flipper on the other end of `MockTransport`: an in-memory SD card plus the app and
/// system commands the client uses. It answers with real protobuf messages, so tests exercise
/// the actual `FlipperRPCClient` code paths instead of a protocol fake.
final class SimulatedFlipper: @unchecked Sendable {
    let transport = MockTransport()
    private let lock = NSLock()
    private var _files: [String: Data] = [:]
    private var _dirs: Set<String> = ["/ext"]
    private var writes: [UInt32: (path: String, data: Data)] = [:]
    /// Status to answer for a given kind of request, to simulate failures.
    var failures: [String: PB_CommandStatus] = [:]
    var updateResult: PBSystem_UpdateResponse.UpdateResultCode = .ok
    var appErrorText = ""

    var files: [String: Data] { lock.withLock { _files } }
    var dirs: Set<String> { lock.withLock { _dirs } }
    var requests: [PB_Main] { transport.requests }

    init(files: [String: String] = [:]) {
        for (path, text) in files {
            _files[path] = Data(text.utf8)
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > 1 { _dirs.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        }
        transport.responder = { [unowned self] request in lock.withLock { respond(to: request) } }
    }

    func client(timeout: Duration = .seconds(2)) async -> FlipperRPCClient {
        let client = FlipperRPCClient(transport: transport, timeout: timeout)
        await client.start()
        return client
    }

    /// Short names of what arrived, e.g. "appStart Sub-GHz RPC", for asserting sequences.
    var log: [String] {
        requests.compactMap { message in
            switch message.content {
            case .storageStatRequest(let r): "stat \(r.path)"
            case .storageListRequest(let r): "list \(r.path)"
            case .storageReadRequest(let r): "read \(r.path)"
            case .storageWriteRequest(let r): "write \(r.path)"
            case .storageMkdirRequest(let r): "mkdir \(r.path)"
            case .storageDeleteRequest(let r): "delete \(r.path)\(r.recursive ? " recursive" : "")"
            case .storageRenameRequest(let r): "rename \(r.oldPath) \(r.newPath)"
            case .storageInfoRequest(let r): "info \(r.path)"
            case .appStartRequest(let r): "appStart \(r.name) \(r.args)"
            case .appLoadFileRequest(let r): "appLoad \(r.path)"
            case .appButtonPressRequest(let r): "appPress \(r.args)"
            case .appButtonReleaseRequest: "appRelease"
            case .appExitRequest: "appExit"
            case .appGetErrorRequest: "appError"
            case .systemRebootRequest(let r): "reboot \(r.mode)"
            case .systemUpdateRequest(let r): "update \(r.updateManifest)"
            case .systemPlayAudiovisualAlertRequest: "alert"
            default: nil
            }
        }
    }

    private func status(_ kind: String) -> PB_CommandStatus { failures[kind] ?? .ok }

    private func answer(_ request: PB_Main, _ kind: String, _ content: PB_Main.OneOf_Content? = nil) -> [PB_Main] {
        let s = status(kind)
        return [reply(to: request, status: s, s == .ok ? content : nil)]
    }

    private func respond(to request: PB_Main) -> [PB_Main] {
        switch request.content {
        case .storageStatRequest(let r):
            if let data = _files[r.path] {
                var file = PBStorage_File(); file.type = .file; file.size = UInt32(data.count)
                var response = PBStorage_StatResponse(); response.file = file
                return answer(request, "stat", .storageStatResponse(response))
            }
            if _dirs.contains(r.path) {
                var file = PBStorage_File(); file.type = .dir
                var response = PBStorage_StatResponse(); response.file = file
                return answer(request, "stat", .storageStatResponse(response))
            }
            return [reply(to: request, status: .errorStorageNotExist)]

        case .storageReadRequest(let r):
            guard let data = _files[r.path] else { return [reply(to: request, status: .errorStorageNotExist)] }
            // The firmware sends files in 512-byte parts.
            var parts: [PB_Main] = []
            var offset = 0
            repeat {
                let end = min(offset + 512, data.count)
                var file = PBStorage_File(); file.data = data.subdata(in: offset..<end)
                var response = PBStorage_ReadResponse(); response.file = file
                parts.append(reply(to: request, hasNext: end < data.count, .storageReadResponse(response)))
                offset = end
            } while offset < data.count
            return parts

        case .storageWriteRequest(let r):
            var pending = writes[request.commandID] ?? (r.path, Data())
            pending.data.append(r.file.data)
            if request.hasNext_p { writes[request.commandID] = pending; return [] }
            writes[request.commandID] = nil
            if status("write") == .ok { _files[pending.path] = pending.data }
            return answer(request, "write")

        case .storageMkdirRequest(let r):
            if _dirs.contains(r.path) { return [reply(to: request, status: .errorStorageExist)] }
            _dirs.insert(r.path)
            return answer(request, "mkdir")

        case .storageDeleteRequest(let r):
            _files = _files.filter { !($0.key == r.path || (r.recursive && $0.key.hasPrefix(r.path + "/"))) }
            _dirs.remove(r.path)
            return answer(request, "delete")

        case .storageRenameRequest(let r):
            guard let data = _files.removeValue(forKey: r.oldPath) else {
                return [reply(to: request, status: .errorStorageNotExist)]
            }
            _files[r.newPath] = data
            return answer(request, "rename")

        case .storageInfoRequest:
            var response = PBStorage_InfoResponse(); response.totalSpace = 1000; response.freeSpace = 400
            return answer(request, "info", .storageInfoResponse(response))

        case .storageListRequest(let r):
            let prefix = r.path + "/"
            var response = PBStorage_ListResponse()
            for (path, data) in _files where path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/") {
                var f = PBStorage_File(); f.name = String(path.dropFirst(prefix.count)); f.size = UInt32(data.count)
                response.file.append(f)
            }
            for dir in _dirs where dir.hasPrefix(prefix) && !dir.dropFirst(prefix.count).contains("/") {
                var f = PBStorage_File(); f.name = String(dir.dropFirst(prefix.count)); f.type = .dir
                response.file.append(f)
            }
            return answer(request, "list", .storageListResponse(response))

        case .appStartRequest: return answer(request, "appStart")
        case .appLoadFileRequest: return answer(request, "appLoad")
        case .appButtonPressRequest: return answer(request, "appPress")
        case .appButtonReleaseRequest: return answer(request, "appRelease")
        case .appExitRequest: return answer(request, "appExit")
        case .appGetErrorRequest:
            var response = PBApp_GetErrorResponse()
            response.code = appErrorText.isEmpty ? 0 : 3
            response.text = appErrorText
            return answer(request, "appError", .appGetErrorResponse(response))
        case .systemRebootRequest: return answer(request, "reboot")
        case .systemPlayAudiovisualAlertRequest: return answer(request, "alert")
        case .systemUpdateRequest:
            var response = PBSystem_UpdateResponse(); response.code = updateResult
            return answer(request, "update", .systemUpdateResponse(response))
        default:
            return [reply(to: request)]
        }
    }
}
