import Foundation

// MARK: - Anthropic provider (Messages API, SSE streaming)

struct AnthropicProvider: LLMProvider {
    let id = "anthropic"
    let displayName = "Anthropic"
    let defaultModel = "claude-sonnet-4-6"
    let fallbackModels: [(id: String, label: String)] = [
        ("claude-sonnet-4-6",         "Claude Sonnet 4.6"),
        ("claude-sonnet-5-5",         "Claude Sonnet 5.5"),
        ("claude-opus-5-5",           "Claude Opus 5.5"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
    ]

    /// Injected so this type stays free of app dependencies (and unit-testable).
    private let keyProvider: @Sendable () -> String?

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let modelsEndpoint = URL(string: "https://api.anthropic.com/v1/models?limit=100")
    private static let apiVersion = "2023-06-01"
    private static let webSearchBeta = "web-search-2025-03-05"

    init(keyProvider: @escaping @Sendable () -> String?) {
        self.keyProvider = keyProvider
    }

    // MARK: - LLMProvider

    func isConfigured() -> Bool {
        guard let key = keyProvider() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func listModels() async -> [(id: String, label: String)] {
        guard let key = keyProvider(), !key.isEmpty,
              let url = Self.modelsEndpoint else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["display_name"] as? String else { return nil }
            return (id: id, label: name)
        }
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let body = Self.requestBody(request, stream: false)
        let urlRequest = try makeURLRequest(body: body, enableWebSearch: request.enableWebSearch, stream: false)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try Self.checkHTTP(data: data, response: response, model: request.model)
        return try Self.parseResponse(data, model: request.model)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = Self.requestBody(request, stream: true)
                    let urlRequest = try makeURLRequest(body: body, enableWebSearch: request.enableWebSearch, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError("No HTTP response from Anthropic.")
                    }
                    if http.statusCode != 200 {
                        var errData = Data()
                        for try await byte in bytes { errData.append(byte) }
                        throw Self.apiError(errData, statusCode: http.statusCode, model: request.model)
                    }

                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        for event in try parser.feed(line) {
                            continuation.yield(event)
                        }
                    }
                    // Connection closed without `message_stop` — flush what we have.
                    if let final = parser.finish() {
                        continuation.yield(.completed(final))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request building

    private func makeURLRequest(body: [String: Any], enableWebSearch: Bool, stream: Bool) throws -> URLRequest {
        guard let key = keyProvider(),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError("API key missing. Open settings.")
        }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if enableWebSearch {
            req.setValue(Self.webSearchBeta, forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Generous streaming idle timeout — long generations pause between chunks.
        req.timeoutInterval = stream ? 120 : 45
        return req
    }

    static func requestBody(_ request: LLMRequest, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": encodeMessages(request.messages),
            "stream": stream,
        ]
        if let temperature = request.temperature { body["temperature"] = temperature }

        var tools: [[String: Any]] = request.tools.map { tool in
            ["name": tool.name, "description": tool.description, "input_schema": tool.inputSchema.anyValue]
        }
        if request.enableWebSearch {
            // The server tool owns the name "web_search" — drop a client-side tool
            // with the same name or the API rejects the request (duplicate tool).
            tools.removeAll { ($0["name"] as? String) == "web_search" }
            tools.append(["type": "web_search_20250305", "name": "web_search", "max_uses": 5])
        }
        if !tools.isEmpty { body["tools"] = tools }
        return body
    }

    static func encodeMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        messages.map { ["role": $0.role.rawValue, "content": encodeBlocks($0.content)] }
    }

    static func encodeBlocks(_ blocks: [LLMContentBlock]) -> [[String: Any]] {
        blocks.map { (block: LLMContentBlock) -> [String: Any] in
            switch block {
            case .text(let t):
                return ["type": "text", "text": t]
            case .image(let mediaType, let base64):
                return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": base64]]
            case .document(let mediaType, let base64):
                return ["type": "document", "source": ["type": "base64", "media_type": mediaType, "data": base64]]
            case .toolUse(let toolId, let name, let input):
                return ["type": "tool_use", "id": toolId, "name": name, "input": input.anyValue]
            case .toolResult(let toolId, let content, let isError):
                return ["type": "tool_result", "tool_use_id": toolId, "content": content, "is_error": isError]
            }
        }
    }

    // MARK: - Response parsing

    static func parseResponse(_ data: Data, model: String) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw LLMError("Unexpected response from Anthropic.")
        }
        let blocks: [LLMContentBlock] = content.compactMap(parseBlock)
        let stop = (json["stop_reason"] as? String).flatMap(LLMStopReason.init(rawValue:)) ?? .unknown
        var usage: LLMUsage?
        if let u = json["usage"] as? [String: Any] {
            usage = LLMUsage(inputTokens: u["input_tokens"] as? Int ?? 0,
                             outputTokens: u["output_tokens"] as? Int ?? 0)
        }
        if blocks.isEmpty {
            throw LLMError("No response text.")
        }
        return LLMResponse(assistantMessage: LLMMessage(role: .assistant, content: blocks),
                           stopReason: stop, usage: usage)
    }

    private static func parseBlock(_ dict: [String: Any]) -> LLMContentBlock? {
        switch dict["type"] as? String {
        case "text":
            guard let text = dict["text"] as? String else { return nil }
            return .text(text)
        case "tool_use", "server_tool_use":
            guard let toolId = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            let input = dict["input"].map(JSONValue.init(any:)) ?? .object([:])
            return .toolUse(id: toolId, name: name, input: input)
        default:
            // Web-search result / citation blocks are surfaced through their text blocks.
            return nil
        }
    }

    static func checkHTTP(data: Data, response: URLResponse, model: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError("No HTTP response from Anthropic.")
        }
        guard http.statusCode == 200 else {
            throw apiError(data, statusCode: http.statusCode, model: model)
        }
    }

    /// Maps Anthropic's `{"type":"error","error":{…}}` payload to a user-facing message.
    static func apiError(_ data: Data, statusCode: Int, model: String) -> LLMError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let message = err["message"] as? String {
            let type = err["type"] as? String ?? ""
            if type == "not_found_error" {
                return LLMError("Model not found: \(model). Pick another one in Settings.")
            }
            if type == "authentication_error" || statusCode == 401 {
                return LLMError("Invalid Anthropic API key. Check Settings.")
            }
            if type == "rate_limit_error" || statusCode == 429 {
                return LLMError("Rate limited by Anthropic — try again in a moment.")
            }
            return LLMError(message)
        }
        return LLMError(String(data: data, encoding: .utf8) ?? "Anthropic request failed (HTTP \(statusCode)).")
    }

    // MARK: - SSE parsing

    /// Incremental parser for `text/event-stream` lines from the Messages API.
    /// Kept pure (no I/O) so it can be unit-tested line by line.
    struct SSEParser {
        private(set) var text = ""
        private var stopReason: LLMStopReason = .unknown
        private var inputTokens = 0
        private var outputTokens = 0
        private(set) var didComplete = false

        /// In-progress `tool_use` block, keyed by content-block index.
        private struct ToolAcc {
            var id: String
            var name: String
            var json = ""
        }
        private var toolAccs: [Int: ToolAcc] = [:]

        /// Returns the events produced by one line; throws on an `error` event.
        mutating func feed(_ line: String) throws -> [LLMStreamEvent] {
            // Stream contract: at most one `completed`, then nothing more.
            guard !didComplete else { return [] }
            guard line.hasPrefix("data:") else { return [] }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

            switch json["type"] as? String {
            case "content_block_start":
                guard let index = json["index"] as? Int,
                      let block = json["content_block"] as? [String: Any] else { return [] }
                let bType = block["type"] as? String ?? ""
                if (bType == "tool_use" || bType == "server_tool_use"),
                   let toolId = block["id"] as? String,
                   let name = block["name"] as? String {
                    toolAccs[index] = ToolAcc(id: toolId, name: name)
                }
                return []

            case "content_block_delta":
                guard let delta = json["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { return [] }
                switch deltaType {
                case "text_delta":
                    guard let piece = delta["text"] as? String, !piece.isEmpty else { return [] }
                    text += piece
                    return [.textDelta(piece)]
                case "input_json_delta":
                    guard let index = json["index"] as? Int,
                          var acc = toolAccs[index],
                          let piece = delta["partial_json"] as? String, !piece.isEmpty else { return [] }
                    acc.json += piece
                    toolAccs[index] = acc
                    return []
                default:
                    return []
                }

            case "message_start":
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                }
                return []

            case "message_delta":
                if let delta = json["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String, !reason.isEmpty {
                    stopReason = LLMStopReason(rawValue: reason) ?? .unknown
                }
                if let usage = json["usage"] as? [String: Any],
                   let out = usage["output_tokens"] as? Int {
                    outputTokens = out
                }
                return []

            case "message_stop":
                didComplete = true
                return [.completed(makeResponse())]

            case "error":
                let err = json["error"] as? [String: Any]
                throw LLMError(err?["message"] as? String ?? "Anthropic stream error.")

            default:
                return []
            }
        }

        /// Produces the final response when the connection closes without `message_stop`.
        mutating func finish() -> LLMResponse? {
            guard !didComplete else { return nil }
            didComplete = true
            return makeResponse()
        }

        private func makeResponse() -> LLMResponse {
            var content: [LLMContentBlock] = text.isEmpty ? [] : [.text(text)]
            for index in toolAccs.keys.sorted() {
                guard let acc = toolAccs[index] else { continue }
                let input: JSONValue
                if let data = acc.json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) {
                    input = JSONValue(any: obj)
                } else {
                    input = .object([:])
                }
                content.append(.toolUse(id: acc.id, name: acc.name, input: input))
            }
            let hasUsage = (inputTokens + outputTokens) > 0
            let usage = hasUsage ? LLMUsage(inputTokens: inputTokens, outputTokens: outputTokens) : nil
            return LLMResponse(assistantMessage: LLMMessage(role: .assistant, content: content),
                               stopReason: stopReason, usage: usage)
        }
    }
}
