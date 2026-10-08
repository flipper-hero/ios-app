import Foundation
import FlipperProto

public struct FlipperDirEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var size: UInt32
    public init(name: String, isDirectory: Bool, size: UInt32) {
        self.name = name; self.isDirectory = isDirectory; self.size = size
    }
}

public struct FlipperStorageInfo: Sendable, Equatable {
    public var totalSpace: UInt64
    public var freeSpace: UInt64
    public init(totalSpace: UInt64, freeSpace: UInt64) {
        self.totalSpace = totalSpace; self.freeSpace = freeSpace
    }
}

public enum FlipperLimits {
    public static let writeChunkSize = 512
    public static let defaultMaxReadBytes = 64 * 1024
}

extension FlipperRPCClient {
    public func ping(_ payload: Data = Data([1, 2, 3, 4])) async throws {
        var request = PBSystem_PingRequest()
        request.data = payload
        let parts = try await call(.systemPingRequest(request))
        guard case .systemPingResponse(let response)? = parts.first?.content, response.data == payload else {
            throw FlipperError.unexpectedResponse
        }
    }

    public func deviceInfo() async throws -> [String: String] {
        let parts = try await call(.systemDeviceInfoRequest(PBSystem_DeviceInfoRequest()))
        var info: [String: String] = [:]
        for part in parts {
            if case .systemDeviceInfoResponse(let entry)? = part.content { info[entry.key] = entry.value }
        }
        return info
    }

    public func powerInfo() async throws -> [String: String] {
        let parts = try await call(.systemPowerInfoRequest(PBSystem_PowerInfoRequest()))
        var info: [String: String] = [:]
        for part in parts {
            if case .systemPowerInfoResponse(let entry)? = part.content { info[entry.key] = entry.value }
        }
        return info
    }

    public func storageInfo(path: String = "/ext") async throws -> FlipperStorageInfo {
        var request = PBStorage_InfoRequest()
        request.path = try FlipperPath.normalize(path)
        let parts = try await call(.storageInfoRequest(request))
        guard case .storageInfoResponse(let response)? = parts.first?.content else {
            throw FlipperError.unexpectedResponse
        }
        return FlipperStorageInfo(totalSpace: response.totalSpace, freeSpace: response.freeSpace)
    }

    public func list(path: String) async throws -> [FlipperDirEntry] {
        var request = PBStorage_ListRequest()
        request.path = try FlipperPath.normalize(path)
        let parts = try await call(.storageListRequest(request))
        var entries: [FlipperDirEntry] = []
        for part in parts {
            if case .storageListResponse(let response)? = part.content {
                for file in response.file {
                    entries.append(FlipperDirEntry(name: file.name, isDirectory: file.type == .dir, size: file.size))
                }
            }
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func stat(path: String) async throws -> FlipperDirEntry {
        var request = PBStorage_StatRequest()
        request.path = try FlipperPath.normalize(path)
        let parts = try await call(.storageStatRequest(request))
        guard case .storageStatResponse(let response)? = parts.first?.content else {
            throw FlipperError.unexpectedResponse
        }
        return FlipperDirEntry(
            name: FlipperPath.lastComponent(request.path),
            isDirectory: response.file.type == .dir,
            size: response.file.size
        )
    }

    /// Refuses files larger than `maxBytes` (checked via stat before any data is transferred).
    public func read(path: String, maxBytes: Int = FlipperLimits.defaultMaxReadBytes) async throws -> Data {
        let normalized = try FlipperPath.normalize(path)
        let info = try await stat(path: normalized)
        guard !info.isDirectory else { throw FlipperError.invalidPath("is a directory") }
        guard Int(info.size) <= maxBytes else {
            throw FlipperError.rpc("file is \(info.size) bytes, limit is \(maxBytes)")
        }
        var request = PBStorage_ReadRequest()
        request.path = normalized
        let parts = try await call(.storageReadRequest(request), timeout: .seconds(60))
        var data = Data()
        for part in parts {
            if case .storageReadResponse(let response)? = part.content { data.append(response.file.data) }
        }
        return data
    }

    public func write(path: String, data: Data) async throws {
        try await write(path: path, data: data, progress: nil)
    }

    /// Writes a file in chunks. `progress` reports bytes sent so far and the total.
    /// The timeout grows with the size so large uploads over Bluetooth are not cut off.
    public func write(path: String, data: Data, progress: (@Sendable (Int, Int) -> Void)?) async throws {
        let normalized = try FlipperPath.normalize(path)
        let size = FlipperLimits.writeChunkSize
        var contents: [PB_Main.OneOf_Content] = []
        var offset = 0
        repeat {
            let end = min(offset + size, data.count)
            var file = PBStorage_File()
            file.data = data.subdata(in: offset ..< end)
            var request = PBStorage_WriteRequest()
            request.path = normalized
            request.file = file
            contents.append(.storageWriteRequest(request))
            offset = end
        } while offset < data.count
        let seconds = 60 + data.count / 2048
        let total = data.count
        _ = try await call(contents, timeout: .seconds(seconds), progress: progress.map { report in
            { sent, frames in report(min(sent * size, total), total) }
        })
    }

    /// Creates `path` and any missing parents. Existing folders are fine.
    public func makeDirectories(path: String) async throws {
        let normalized = try FlipperPath.normalize(path)
        var current = ""
        for component in normalized.split(separator: "/") {
            current += "/" + component
            guard current.split(separator: "/").count > 1 else { continue } // /ext itself always exists
            do {
                try await makeDirectory(path: current)
            } catch FlipperError.rpc(let status) where status.lowercased().contains("exist") {
                continue
            }
        }
    }

    public func makeDirectory(path: String) async throws {
        var request = PBStorage_MkdirRequest()
        request.path = try FlipperPath.normalize(path)
        _ = try await call(.storageMkdirRequest(request))
    }

    public func delete(path: String, recursive: Bool = false) async throws {
        var request = PBStorage_DeleteRequest()
        request.path = try FlipperPath.normalize(path)
        request.recursive = recursive
        _ = try await call(.storageDeleteRequest(request))
    }

    public func rename(from: String, to: String) async throws {
        var request = PBStorage_RenameRequest()
        request.oldPath = try FlipperPath.normalize(from)
        request.newPath = try FlipperPath.normalize(to)
        _ = try await call(.storageRenameRequest(request))
    }

    public func startApp(name: String, args: String = "") async throws {
        var request = PBApp_StartRequest()
        request.name = name
        request.args = args
        _ = try await call(.appStartRequest(request))
    }
}
