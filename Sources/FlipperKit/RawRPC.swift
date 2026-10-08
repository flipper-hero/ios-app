import Foundation
import FlipperProto

extension FlipperRPCClient {
    public func rawRPC(jsonRequest: String) async throws -> String {
        try await rawRPC(jsonRequest: jsonRequest, timeout: .seconds(20))
    }

    /// Sends one protobuf request assembled from the model's JSON and returns the responses as JSON.
    /// Only the `content` field is taken from the request; command id and framing stay ours.
    /// Engagement mode capability `raw_rpc` gates who may call this.
    public func rawRPC(jsonRequest: String, timeout: Duration) async throws -> String {
        let trimmed = jsonRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 16 * 1024 else {
            throw FlipperError.rpc("request larger than 16 KB")
        }
        let parsed = try PB_Main(jsonString: trimmed)
        guard parsed.content != nil else {
            throw FlipperError.rpc("request must set a 'content' field, e.g. {\"content\":{\"systemPingRequest\":{}}}")
        }
        let parts = try await call(parsed.content!, timeout: timeout)
        var out = ""
        for (index, part) in parts.prefix(50).enumerated() {
            if index > 0 { out += "\n" }
            out += (try? part.jsonString()) ?? "{\"commandStatus\":\"ERROR_INTERNAL\"}"
            if out.utf8.count > 16 * 1024 {
                out += "\n[truncated]"
                break
            }
        }
        return out
    }
}
