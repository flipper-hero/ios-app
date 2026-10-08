import Foundation
import FlipperProto

/// Sends PB.Main requests over a transport and matches responses by command id.
/// Calls are serialized: the Flipper RPC session is single-threaded.
public actor FlipperRPCClient {
    private struct Pending {
        var parts: [PB_Main] = []
        /// Nil while a pipelined request has been sent but nobody awaits it yet.
        var continuation: CheckedContinuation<[PB_Main], Error>?
        var timeoutTask: Task<Void, Never>?
    }

    /// Yields once when the transport's byte stream ends (link lost or closed).
    public nonisolated let closed: AsyncStream<Void>
    private nonisolated let closedContinuation: AsyncStream<Void>.Continuation
    private let transport: FlipperTransport
    private let defaultTimeout: Duration
    private var decoder = FrameDecoder()
    private var readerTask: Task<Void, Never>?
    private var nextID: UInt32 = 1
    private var pending: [UInt32: Pending] = [:]
    /// Results of pipelined requests that finished before they were awaited.
    private var completed: [UInt32: Result<[PB_Main], Error>] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Subscribers for messages the Flipper sends on its own (screen frames use command id 0).
    private var unsolicitedSubscribers: [UUID: AsyncStream<PB_Main>.Continuation] = [:]

    /// Messages that do not answer a pending request. Each call returns an independent stream.
    public func unsolicitedMessages() -> AsyncStream<PB_Main> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PB_Main>.makeStream(bufferingPolicy: .bufferingNewest(4))
        unsolicitedSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        unsolicitedSubscribers.removeValue(forKey: id)
    }

    public init(transport: FlipperTransport, timeout: Duration = .seconds(20)) {
        self.transport = transport
        self.defaultTimeout = timeout
        var continuation: AsyncStream<Void>.Continuation!
        self.closed = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.closedContinuation = continuation
    }

    public func start() {
        guard readerTask == nil else { return }
        let stream = transport.incoming
        readerTask = Task { [weak self] in
            for await chunk in stream {
                await self?.handle(chunk)
            }
            await self?.failAll(FlipperError.notConnected)
            self?.closedContinuation.yield()
            self?.closedContinuation.finish()
        }
    }

    public func stop() async {
        readerTask?.cancel()
        readerTask = nil
        failAll(FlipperError.notConnected)
        await transport.close()
    }

    // MARK: - Core request/response

    /// - Parameter progress: called after each request frame went out, with (sent, total) frames.
    ///   Long transfers use it to report progress; cancelling the calling task stops sending.
    public func call(
        _ contents: [PB_Main.OneOf_Content],
        timeout: Duration? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [PB_Main] {
        precondition(!contents.isEmpty, "at least one request message is required")
        await acquire()
        defer { release() }

        let id = takeID()

        var frames: [Data] = []
        for (index, content) in contents.enumerated() {
            var message = PB_Main()
            message.commandID = id
            message.hasNext_p = index < contents.count - 1
            message.content = content
            frames.append(try FrameCodec.encode(message))
        }

        let limit = timeout ?? defaultTimeout
        let total = frames.count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    await self?.finish(id, .failure(FlipperError.timeout))
                }
                pending[id] = Pending(continuation: continuation, timeoutTask: timeoutTask)
                Task { [transport, weak self] in
                    do {
                        for (index, frame) in frames.enumerated() {
                            // Stop feeding a request that was cancelled or already failed.
                            guard await self?.isPending(id) == true else { return }
                            try await transport.send(frame)
                            progress?(index + 1, total)
                        }
                    } catch {
                        await self?.finish(id, .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.finish(id, .failure(CancellationError())) }
        }
    }

    private func isPending(_ id: UInt32) -> Bool { pending[id] != nil }

    private func takeID() -> UInt32 {
        let id = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        return id
    }

    /// Sends independent single-message requests back to back and waits for all answers.
    /// The Flipper handles them in order, so a short sequence such as a button press costs one
    /// round trip instead of one per message.
    public func callPipelined(_ contents: [PB_Main.OneOf_Content], timeout: Duration? = nil) async throws {
        await acquire()
        defer { release() }
        let limit = timeout ?? defaultTimeout
        var ids: [UInt32] = []
        var data = Data()
        for content in contents {
            let id = takeID()
            var message = PB_Main()
            message.commandID = id
            message.content = content
            data.append(try FrameCodec.encode(message))
            ids.append(id)
        }
        defer {
            for id in ids {
                completed.removeValue(forKey: id)
                pending.removeValue(forKey: id)?.timeoutTask?.cancel()
            }
        }
        for id in ids {
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: limit)
                await self?.finish(id, .failure(FlipperError.timeout))
            }
            pending[id] = Pending(continuation: nil, timeoutTask: timeoutTask)
        }
        try await transport.send(data)
        for id in ids { _ = try await response(for: id) }
    }

    private func response(for id: UInt32) async throws -> [PB_Main] {
        if let result = completed.removeValue(forKey: id) { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            if let result = completed.removeValue(forKey: id) {
                continuation.resume(with: result)
            } else if pending[id] != nil {
                pending[id]?.continuation = continuation
            } else {
                continuation.resume(throwing: FlipperError.notConnected)
            }
        }
    }

    public func call(_ content: PB_Main.OneOf_Content, timeout: Duration? = nil) async throws -> [PB_Main] {
        try await call([content], timeout: timeout)
    }

    // MARK: - Internals

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func handle(_ chunk: Data) {
        do {
            for message in try decoder.append(chunk) { dispatch(message) }
        } catch {
            decoder = FrameDecoder()
            failAll(error)
        }
    }

    private func dispatch(_ message: PB_Main) {
        let id = message.commandID
        guard var entry = pending[id] else {
            for subscriber in unsolicitedSubscribers.values { subscriber.yield(message) }
            return
        }
        if message.commandStatus != .ok {
            finish(id, .failure(FlipperError.rpc("\(message.commandStatus)")))
            return
        }
        entry.parts.append(message)
        if message.hasNext_p {
            pending[id] = entry
        } else {
            finish(id, .success(entry.parts))
        }
    }

    private func finish(_ id: UInt32, _ result: Result<[PB_Main], Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel()
        if let continuation = entry.continuation {
            continuation.resume(with: result)
        } else {
            completed[id] = result
        }
    }

    private func failAll(_ error: Error) {
        for id in Array(pending.keys) { finish(id, .failure(error)) }
        if error as? FlipperError == .notConnected {
            for subscriber in unsolicitedSubscribers.values { subscriber.finish() }
            unsolicitedSubscribers.removeAll()
        }
    }

    // MARK: - Screen stream reference counting

    private var screenStreamUsers = 0

    /// Starts the firmware's screen stream for the first user; later users share it.
    public func acquireScreenStream() async throws {
        screenStreamUsers += 1
        guard screenStreamUsers == 1 else { return }
        do {
            _ = try await call(.guiStartScreenStreamRequest(PBGui_StartScreenStreamRequest()))
        } catch FlipperError.rpc(let status) where status.contains("VirtualDisplayAlreadyStarted") || status.contains("virtualDisplayAlreadyStarted") {
            // Left running by an earlier session; that is fine.
        } catch {
            screenStreamUsers -= 1
            throw error
        }
    }

    /// Stops the stream when the last user is done.
    public func releaseScreenStream() async {
        guard screenStreamUsers > 0 else { return }
        screenStreamUsers -= 1
        guard screenStreamUsers == 0 else { return }
        _ = try? await call(.guiStopScreenStreamRequest(PBGui_StopScreenStreamRequest()))
    }
}
