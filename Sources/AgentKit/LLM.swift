import Foundation

public enum ChatRole: String, Codable, Sendable { case system, user, assistant, tool }

public struct ToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    /// Raw JSON string exactly as the model produced it.
    public var arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}

public struct ChatMessage: Sendable, Equatable {
    public var role: ChatRole
    public var content: String?
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    /// JPEG data sent alongside `content`, for models that accept images.
    public var images: [Data]

    public init(role: ChatRole, content: String?, toolCalls: [ToolCall] = [], toolCallID: String? = nil,
                images: [Data] = []) {
        self.role = role; self.content = content; self.toolCalls = toolCalls
        self.toolCallID = toolCallID; self.images = images
    }
}

public protocol LLMClient: Sendable {
    func complete(messages: [ChatMessage], tools: [ToolSpec]) async throws -> ChatMessage
}

public enum LLMError: Error, Equatable, CustomStringConvertible {
    case http(Int, String)
    case malformed(String)
    public var description: String {
        switch self {
        case .http(let code, let message): L("Model API error \(code): \(message)")
        case .malformed(let why): L("Unexpected model response: \(why)")
        }
    }
}

/// OpenAI-compatible chat completions with tool calling, as served by OpenRouter.
public struct OpenRouterClient: LLMClient {
    public var apiKey: String
    public var model: String
    public var endpoint: URL
    public var session: URLSession

    public init(apiKey: String, model: String,
                endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                session: URLSession = .shared) {
        self.apiKey = apiKey; self.model = model; self.endpoint = endpoint; self.session = session
    }

    func makeRequestBody(messages: [ChatMessage], tools: [ToolSpec]) throws -> Data {
        let wireMessages: [[String: Any]] = messages.map { m in
            var d: [String: Any] = ["role": m.role.rawValue]
            if !m.images.isEmpty {
                var parts: [[String: Any]] = []
                if let c = m.content, !c.isEmpty { parts.append(["type": "text", "text": c]) }
                for image in m.images {
                    let mime = image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                    parts.append(["type": "image_url",
                                  "image_url": ["url": "data:\(mime);base64,\(image.base64EncodedString())"]])
                }
                d["content"] = parts
            } else if let c = m.content {
                d["content"] = c
            } else if m.role == .assistant {
                d["content"] = NSNull()
            }
            if !m.toolCalls.isEmpty {
                d["tool_calls"] = m.toolCalls.map {
                    ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any]
                }
            }
            if let id = m.toolCallID { d["tool_call_id"] = id }
            return d
        }
        var body: [String: Any] = ["model": model, "messages": wireMessages, "temperature": 0.2]
        if !tools.isEmpty {
            let encoder = JSONEncoder()
            body["tools"] = try tools.map { spec -> [String: Any] in
                let params = try JSONSerialization.jsonObject(with: encoder.encode(spec.parameters))
                return ["type": "function", "function": ["name": spec.name, "description": spec.description, "parameters": params]]
            }
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func parseResponse(_ data: Data) throws -> ChatMessage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformed("not JSON")
        }
        guard let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw LLMError.malformed("no choices")
        }
        let calls: [ToolCall] = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["id"] as? String, let fn = raw["function"] as? [String: Any],
                  let name = fn["name"] as? String else { return nil }
            return ToolCall(id: id, name: name, arguments: fn["arguments"] as? String ?? "{}")
        }
        return ChatMessage(role: .assistant, content: message["content"] as? String, toolCalls: calls)
    }

    public func complete(messages: [ChatMessage], tools: [ToolSpec]) async throws -> ChatMessage {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("FlipperHero", forHTTPHeaderField: "X-Title")
        request.httpBody = try makeRequestBody(messages: messages, tools: tools)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "request failed"
            throw LLMError.http(status, message)
        }
        return try Self.parseResponse(data)
    }
}
