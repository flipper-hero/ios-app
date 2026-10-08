import XCTest
@testable import FlipperKit
import FlipperProto

final class RPCClientTests: XCTestCase {
    private func makeClient(timeout: Duration = .seconds(5),
                            responder: @escaping (PB_Main) -> [PB_Main]) async -> (FlipperRPCClient, MockTransport) {
        let transport = MockTransport()
        transport.responder = responder
        let client = FlipperRPCClient(transport: transport, timeout: timeout)
        await client.start()
        return (client, transport)
    }

    func testPing() async throws {
        let (client, _) = await makeClient { request in
            guard case .systemPingRequest(let ping) = request.content else { return [] }
            var pong = PBSystem_PingResponse(); pong.data = ping.data
            return [reply(to: request, .systemPingResponse(pong))]
        }
        try await client.ping(Data([9, 8, 7]))
    }

    func testDeviceInfoAggregatesParts() async throws {
        let (client, _) = await makeClient { request in
            func part(_ k: String, _ v: String, next: Bool) -> PB_Main {
                var r = PBSystem_DeviceInfoResponse(); r.key = k; r.value = v
                return reply(to: request, hasNext: next, .systemDeviceInfoResponse(r))
            }
            return [part("hardware_name", "Laisear", next: true),
                    part("firmware_commit", "d3f89dfe", next: true),
                    part("firmware_version", "mntm-dev", next: false)]
        }
        let info = try await client.deviceInfo()
        XCTAssertEqual(info["hardware_name"], "Laisear")
        XCTAssertEqual(info["firmware_commit"], "d3f89dfe")
        XCTAssertEqual(info.count, 3)
    }

    func testListSortsDirectoriesFirst() async throws {
        let (client, _) = await makeClient { request in
            func file(_ n: String, dir: Bool, size: UInt32 = 0) -> PBStorage_File {
                var f = PBStorage_File(); f.name = n; f.type = dir ? .dir : .file; f.size = size; return f
            }
            var r = PBStorage_ListResponse()
            r.file = [file("b.sub", dir: false, size: 10), file("nfc", dir: true), file("a.sub", dir: false, size: 5)]
            return [reply(to: request, .storageListResponse(r))]
        }
        let entries = try await client.list(path: "/ext")
        XCTAssertEqual(entries.map(\.name), ["nfc", "a.sub", "b.sub"])
        XCTAssertTrue(entries[0].isDirectory)
    }

    func testReadChecksSizeBeforeTransfer() async throws {
        let (client, transport) = await makeClient { request in
            switch request.content {
            case .storageStatRequest:
                var f = PBStorage_File(); f.size = 10_000_000; f.type = .file
                var r = PBStorage_StatResponse(); r.file = f
                return [reply(to: request, .storageStatResponse(r))]
            default: return []
            }
        }
        do {
            _ = try await client.read(path: "/ext/big.bin", maxBytes: 1024)
            XCTFail("expected refusal")
        } catch FlipperError.rpc {}
        let kinds = transport.requests.map { req -> String in
            if case .storageReadRequest = req.content { return "read" }
            return "other"
        }
        XCTAssertFalse(kinds.contains("read"), "must not start a transfer for oversized files")
    }

    func testReadConcatenatesParts() async throws {
        let (client, _) = await makeClient { request in
            switch request.content {
            case .storageStatRequest:
                var f = PBStorage_File(); f.size = 6; f.type = .file
                var r = PBStorage_StatResponse(); r.file = f
                return [reply(to: request, .storageStatResponse(r))]
            case .storageReadRequest:
                func chunk(_ s: String, next: Bool) -> PB_Main {
                    var f = PBStorage_File(); f.data = Data(s.utf8)
                    var r = PBStorage_ReadResponse(); r.file = f
                    return reply(to: request, hasNext: next, .storageReadResponse(r))
                }
                return [chunk("abc", next: true), chunk("def", next: false)]
            default: return []
            }
        }
        let data = try await client.read(path: "/ext/a.txt")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "abcdef")
    }

    func testRPCErrorStatusBecomesError() async throws {
        let (client, _) = await makeClient { request in
            [reply(to: request, status: .errorStorageNotExist)]
        }
        do {
            _ = try await client.list(path: "/ext/missing")
            XCTFail("expected error")
        } catch FlipperError.rpc(let status) {
            XCTAssertTrue(status.lowercased().contains("notexist"), status)
        }
    }

    func testTimeout() async throws {
        let (client, _) = await makeClient(timeout: .milliseconds(150)) { _ in [] }
        do {
            try await client.ping()
            XCTFail("expected timeout")
        } catch FlipperError.timeout {}
    }

    func testWriteChunksShareCommandIDAndSetHasNext() async throws {
        let (client, transport) = await makeClient { request in
            // Only answer once the final chunk (has_next == false) arrives.
            request.hasNext_p ? [] : [reply(to: request)]
        }
        let payload = Data(repeating: 0x41, count: FlipperLimits.writeChunkSize * 2 + 100)
        try await client.write(path: "/ext/test.txt", data: payload)
        let writes = transport.requests.filter { if case .storageWriteRequest = $0.content { true } else { false } }
        XCTAssertEqual(writes.count, 3)
        XCTAssertEqual(Set(writes.map(\.commandID)).count, 1)
        XCTAssertEqual(writes.map(\.hasNext_p), [true, true, false])
        let total = writes.reduce(0) { sum, m in
            if case .storageWriteRequest(let w) = m.content { return sum + w.file.data.count }
            return sum
        }
        XCTAssertEqual(total, payload.count)
    }

    func testInvalidPathNeverReachesTransport() async throws {
        let (client, transport) = await makeClient { _ in [] }
        do {
            try await client.delete(path: "/ext/../int/secret", recursive: true)
            XCTFail("expected invalid path")
        } catch FlipperError.invalidPath {}
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCallsAreSerialized() async throws {
        let (client, _) = await makeClient { request in
            guard case .systemPingRequest(let ping) = request.content else { return [] }
            var pong = PBSystem_PingResponse(); pong.data = ping.data
            return [reply(to: request, .systemPingResponse(pong))]
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<10 { group.addTask { try await client.ping(Data([UInt8(i)])) } }
            try await group.waitForAll()
        }
    }
}
