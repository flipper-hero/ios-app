import Foundation

/// Byte pipe to a Flipper. Implementations own chunking and flow control.
public protocol FlipperTransport: Sendable {
    /// Raw bytes as they arrive (any chunking).
    var incoming: AsyncStream<Data> { get }
    func send(_ data: Data) async throws
    func close() async
}

/// Optional diagnostics hook. The app sets `sink`; nothing is logged otherwise.
public enum FlipperLog {
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?
    static func log(_ message: @autoclosure () -> String) { sink?(message()) }
}
