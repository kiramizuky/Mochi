import Foundation

// MARK: - OpenAI provider (Chat Completions API, SSE streaming)

struct OpenAIProvider: LLMProvider {
    let id = "openai"
    let displayName = "OpenAI"
    let defaultModel = "gpt-6.1-sol"
    let fallbackModels: [(id: String, label: String)] = [
        ("gpt-6-astra",  "GPT-6 Astra"),
        ("gpt-6.1-sol",  "GPT-6.1 Sol"),
        ("gpt-6-sol",    "GPT-6 Sol"),
        ("gpt-6-luna",   "GPT-6 Luna"),
        ("gpt-5.6-terra", "GPT-5.6 Terra"),
    ]

    /// Injected so this type stays free of app dependencies (and unit-testable).
    private let keyProvider: @Sendable () -> String?

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!

    /// Model-id prefixes that are worth showing in the picker.
    private static let modelPrefixes = ["gpt-", "o1", "o3", "o4", "o5"]
    /// Substrings of non-chat model ids to hide (embeddings, audio, images, …).
    private static let excludedSubstrings = [
        "embedding", "whisper", "tts", "dall-e", "image", "audio",
        "transcribe", "moderation", "realtime", "codex", "search", "transcript",
    ]

    init(keyProvider: @escaping @Sendable () -> String?) {
        self.keyProvider = keyProvider
    }

    // MARK: - LLMProvider

    func isConfigured() -> Bool {
        guard let key = keyProvider() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func listModels() async -> [(id: String, label: String)] {
        guard let key = keyProvider(), !key.isEmpty else { return [] }
        var req = URLRequest(url: Self.modelsEndpoint, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Self.parseModelList(data)
    }

    /// Parses `/v1/models` JSON: keeps our supported prefixes, drops excluded substrings, newest first.
    static func parseModelList(_ data: Data) -> [(id: String, label: String)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }

        var picked: [(id: String, label: String, created: Int)] = []
        for item in items {
            guard let modelId = item["id"] as? String else { continue }
            let lower = modelId.lowercased()
            if excludedSubstrings.contains(where: { lower.contains($0) }) { continue }
            guard modelPrefixes.contains(where: { lower.hasPrefix($0) }) else { continue }
            picked.append((modelId, modelId, item["created"] as? Int ?? 0))
        }
        // Newest first — matches how OpenAI sorts its own docs.
        return picked.sorted { $0.created > $1.created }.map { (id: $0.id, label: $0.label) }
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        var enableSearch = request.enableWebSearch
        var attempt = 0
        while attempt < 2 {
            attempt += 1
            let body = Self.requestBody(request, stream: false, enableWebSearch: enableSearch)
            let urlRequest = try makeURLRequest(body: body, stream: false)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return try Self.parseResponse(data, model: request.model)
            }
            // Some models reject `web_search_options` — retry once without it.
            if attempt < 2, enableSearch, Self.mentionsWebSearch(data) {
                enableSearch = false
                continue
            }
            throw Self.apiError(data, statusCode: status, model: request.model)
        }
        throw LLMError("OpenAI request failed.")
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var enableSearch = request.enableWebSearch
                var attempt = 0
                while attempt < 2 {
                    attempt += 1
                    do {
                        let body = Self.requestBody(request, stream: true, enableWebSearch: enableSearch)
                        let urlRequest = try makeURLRequest(body: body, stream: true)
                        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

                        guard let http = response as? HTTPURLResponse else {
                            throw LLMError("No HTTP response from OpenAI.")
                        }
                        if http.statusCode != 200 {
                            var errData = Data()
                            for try await byte in bytes { errData.append(byte) }
                            // Retry once without web search — before any event is yielded.
                            if attempt < 2, enableSearch, Self.mentionsWebSearch(errData) {
                                enableSearch = false
                                continue
                            }
                            throw Self.apiError(errData, statusCode: http.statusCode, model: request.model)
                        }

                        var parser = SSEParser()
                        for try await line in bytes.lines {
                            for event in try parser.feed(line) {
                                continuation.yield(event)
                            }
                        }
                        // Connection closed without `data: [DONE]` — flush what we have.
                        if let final = parser.finish() {
                            continuation.yield(.completed(final))
                        }
                        continuation.finish()
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish(throwing: LLMError("OpenAI request failed."))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request building

    private func makeURLRequest(body: [String: Any], stream: Bool) throws -> URLRequest {
        guard let key = keyProvider(),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError("API key missing. Open settings.")
        }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Generous streaming idle timeout — long generations pause between chunks.
        req.timeoutInterval = stream ? 120 : 45
        return req
    }

    static func requestBody(_ request: LLMRequest, stream: Bool, enableWebSearch: Bool) -> [String: Any] {
        var messages: [[String: Any]] = []
        let system = request.system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(contentsOf: encodeMessages(request.messages))

        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_completion_tokens": request.maxTokens,
        ]
        if stream {
            body["stream"] = true
            // Usage arrives in a final chunk after `finish_reason`.
            body["stream_options"] = ["include_usage": true]
        }
        if let temperature = request.temperature { body["temperature"] = temperature }

        // OpenAI's built-in web_search tool and our client tool would collide on
        // the name — when server search is on, ship the other eight only.
        let wireTools = enableWebSearch
            ? request.tools.filter { $0.name != "web_search" }
            : request.tools
        if !wireTools.isEmpty {
            body["tools"] = wireTools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.anyValue,
                    ] as [String: Any],
                ]
            }
        }
        if enableWebSearch { body["web_search_options"] = [String: Any]() }
        return body
    }

    static func encodeMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in messages {
            if message.role == .assistant {
                out.append(encodeAssistant(message))
            } else {
                // Tool results ride as their own `tool` messages, before the user text.
                var parts: [Any] = []
                for block in message.content {
                    if case .toolResult(let toolId, let content, _) = block {
                        out.append(["role": "tool", "tool_call_id": toolId, "content": content])
                    } else if let part = encodePart(block) {
                        parts.append(part)
                    }
                }
                if !parts.isEmpty {
                    out.append(["role": "user", "content": userContent(parts)])
                }
            }
        }
        return out
    }

    private static func encodeAssistant(_ message: LLMMessage) -> [String: Any] {
        var text = ""
        var toolCalls: [[String: Any]] = []
        for block in message.content {
            switch block {
            case .text(let t):
                text += t
            case .toolUse(let toolId, let name, let input):
                let argsData = (try? JSONSerialization.data(withJSONObject: input.anyValue)) ?? Data("{}".utf8)
                let args = String(data: argsData, encoding: .utf8) ?? "{}"
                toolCalls.append([
                    "id": toolId,
                    "type": "function",
                    "function": ["name": name, "arguments": args] as [String: Any],
                ])
            default:
                break
            }
        }
        var msg: [String: Any] = ["role": "assistant"]
        if !text.isEmpty {
            msg["content"] = text
        } else if toolCalls.isEmpty {
            msg["content"] = ""
        } else {
            msg["content"] = NSNull()
        }
        if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
        return msg
    }

    private static func encodePart(_ block: LLMContentBlock) -> [String: Any]? {
        switch block {
        case .text(let t):
            return ["type": "text", "text": t]
        case .image(let mediaType, let base64):
            return ["type": "image_url",
                    "image_url": ["url": "data:\(mediaType);base64,\(base64)"]]
        case .document(let mediaType, let base64):
            let filename = mediaType == "application/pdf" ? "document.pdf" : "document.bin"
            return ["type": "file",
                    "file": ["filename": filename,
                             "file_data": "data:\(mediaType);base64,\(base64)"]]
        case .toolUse, .toolResult:
            return nil
        }
    }

    /// A single text part collapses to a plain string (matches OpenAI's usual payloads).
    private static func userContent(_ parts: [Any]) -> Any {
        if parts.count == 1, let dict = parts.first as? [String: Any],
           dict["type"] as? String == "text", let text = dict["text"] as? String {
            return text
        }
        return parts
    }

    // MARK: - Response parsing

    static func parseResponse(_ data: Data, model: String) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first else {
            throw LLMError("Unexpected response from OpenAI.")
        }
        let message = choice["message"] as? [String: Any] ?? [:]
        var content: [LLMContentBlock] = []

        if let value = message["content"] {
            if let text = value as? String, !text.isEmpty {
                content.append(.text(text))
            } else if let parts = value as? [[String: Any]] {
                for part in parts where part["type"] as? String == "text" {
                    if let text = part["text"] as? String, !text.isEmpty {
                        content.append(.text(text))
                    }
                }
            }
        }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for (index, call) in calls.enumerated() {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                content.append(.toolUse(id: toolCallId(call, index: index),
                                        name: name,
                                        input: parseArguments(fn["arguments"] as? String)))
            }
        }
        if content.isEmpty { throw LLMError("No response text.") }

        let stop = mapStopReason(choice["finish_reason"] as? String)
        var usage: LLMUsage?
        if let u = json["usage"] as? [String: Any] {
            usage = LLMUsage(inputTokens: u["prompt_tokens"] as? Int ?? 0,
                             outputTokens: u["completion_tokens"] as? Int ?? 0)
        }
        return LLMResponse(assistantMessage: LLMMessage(role: .assistant, content: content),
                           stopReason: stop, usage: usage)
    }

    private static func toolCallId(_ call: [String: Any], index: Int) -> String {
        if let id = call["id"] as? String, !id.isEmpty { return id }
        return "call_\(index)"
    }

    static func parseArguments(_ raw: String?) -> JSONValue {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return .object([:]) }
        return JSONValue(any: obj)
    }

    static func mapStopReason(_ reason: String?) -> LLMStopReason {
        switch reason {
        case "stop": return .endTurn
        case "length": return .maxTokens
        case "tool_calls", "function_call": return .toolUse
        default: return .unknown
        }
    }

    static func checkHTTP(data: Data, response: URLResponse, model: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError("No HTTP response from OpenAI.")
        }
        guard http.statusCode == 200 else {
            throw apiError(data, statusCode: http.statusCode, model: model)
        }
    }

    /// Maps OpenAI's `{"error":{…}}` payload to a user-facing message.
    static func apiError(_ data: Data, statusCode: Int, model: String) -> LLMError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any] {
            let message = err["message"] as? String ?? ""
            let type = err["type"] as? String ?? ""
            let code = err["code"] as? String ?? ""
            if statusCode == 401 || code == "invalid_api_key" {
                return LLMError("Invalid OpenAI API key. Check Settings.")
            }
            if statusCode == 429 {
                return LLMError("Rate limited by OpenAI — try again in a moment.")
            }
            if statusCode == 404 || code == "model_not_found"
                || (type == "invalid_request_error" && message.lowercased().contains("model")) {
                return LLMError("Model not found: \(model). Pick another one in Settings.")
            }
            if !message.isEmpty { return LLMError(message) }
        }
        return LLMError(String(data: data, encoding: .utf8) ?? "OpenAI request failed (HTTP \(statusCode)).")
    }

    /// True when a failed body indicates the model rejected web search (retryable).
    static func mentionsWebSearch(_ data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8) else { return false }
        return raw.lowercased().contains("web_search")
    }

    // MARK: - SSE parsing

    /// Incremental parser for `text/event-stream` lines from the Chat Completions API.
    /// Kept pure (no I/O) so it can be unit-tested line by line.
    struct SSEParser {
        private(set) var text = ""
        private var stopReason: LLMStopReason = .unknown
        private var inputTokens = 0
        private var outputTokens = 0
        private var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        private(set) var didComplete = false

        /// Returns the events produced by one line; throws on an in-stream `error`.
        mutating func feed(_ line: String) throws -> [LLMStreamEvent] {
            // Stream contract: at most one `completed`, then nothing more.
            guard !didComplete else { return [] }
            guard line.hasPrefix("data:") else { return [] }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { return [] }

            if payload == "[DONE]" {
                didComplete = true
                return [.completed(makeResponse())]
            }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

            if let err = json["error"] as? [String: Any] {
                throw LLMError(err["message"] as? String ?? "OpenAI stream error.")
            }
            if let usage = json["usage"] as? [String: Any] {
                if let prompt = usage["prompt_tokens"] as? Int { inputTokens = prompt }
                if let completion = usage["completion_tokens"] as? Int { outputTokens = completion }
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first else { return [] }

            var events: [LLMStreamEvent] = []
            if let delta = choice["delta"] as? [String: Any] {
                if let piece = delta["content"] as? String, !piece.isEmpty {
                    text += piece
                    events.append(.textDelta(piece))
                }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    accumulate(calls)
                }
            }
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                // Recorded only — the usage chunk arrives after `finish_reason`.
                stopReason = OpenAIProvider.mapStopReason(reason)
            }
            return events
        }

        private mutating func accumulate(_ calls: [[String: Any]]) {
            for call in calls {
                let index = call["index"] as? Int ?? 0
                var entry = toolCalls[index] ?? (id: "", name: "", arguments: "")
                if let callId = call["id"] as? String, !callId.isEmpty { entry.id = callId }
                if let fn = call["function"] as? [String: Any] {
                    if let name = fn["name"] as? String, !name.isEmpty { entry.name = name }
                    if let args = fn["arguments"] as? String { entry.arguments += args }
                }
                toolCalls[index] = entry
            }
        }

        /// Produces the final response when the connection closes without `[DONE]`.
        mutating func finish() -> LLMResponse? {
            guard !didComplete else { return nil }
            didComplete = true
            return makeResponse()
        }

        private func makeResponse() -> LLMResponse {
            var content: [LLMContentBlock] = []
            if !text.isEmpty { content.append(.text(text)) }
            for index in toolCalls.keys.sorted() {
                guard let entry = toolCalls[index], !entry.name.isEmpty else { continue }
                content.append(.toolUse(id: entry.id.isEmpty ? "call_\(index)" : entry.id,
                                        name: entry.name,
                                        input: OpenAIProvider.parseArguments(entry.arguments)))
            }
            let hasUsage = (inputTokens + outputTokens) > 0
            let usage = hasUsage ? LLMUsage(inputTokens: inputTokens, outputTokens: outputTokens) : nil
            return LLMResponse(assistantMessage: LLMMessage(role: .assistant, content: content),
                               stopReason: stopReason, usage: usage)
        }
    }
}
