import Foundation

public struct AuditRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Decision: String, Codable, Sendable { case auto, yolo, engaged, approved, denied, blocked, invalid, shortcut }
    public var id = UUID()
    public var date = Date()
    public var tool: String
    public var summary: String
    public var risk: RiskLevel?
    public var decision: Decision
    public var succeeded: Bool
    public var detail: String

    public init(id: UUID = UUID(), date: Date = Date(), tool: String, summary: String,
                risk: RiskLevel? = nil, decision: Decision, succeeded: Bool, detail: String) {
        self.id = id
        self.date = date
        self.tool = tool
        self.summary = summary
        self.risk = risk
        self.decision = decision
        self.succeeded = succeeded
        self.detail = detail
    }
}

public protocol AuditSink: Sendable {
    func record(_ record: AuditRecord) async
    /// Newest last.
    func recent(limit: Int) async -> [AuditRecord]
}

public actor InMemoryAuditLog: AuditSink {
    public private(set) var records: [AuditRecord] = []
    public init() {}
    public func record(_ record: AuditRecord) { records.append(record) }
    public func recent(limit: Int) -> [AuditRecord] { Array(records.suffix(limit)) }
}

/// Append-only JSON Lines file.
public actor FileAuditLog: AuditSink {
    private let url: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public init(url: URL) { self.url = url }

    public func record(_ record: AuditRecord) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    public func recent(limit: Int) -> [AuditRecord] { Array(load().suffix(limit)) }

    public func load() -> [AuditRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(AuditRecord.self, from: Data($0)) }
    }
}
