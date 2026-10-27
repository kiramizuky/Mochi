import Foundation

// MARK: - Google Gemini provider (generativelanguage API, SSE streaming)

struct GeminiProvider: LLMProvider {
    let id = "gemini"
    let displayName = "Google Gemini"
    let defaultModel = "gemini-3.6-flash"
    let fallbackModels: [(id: String, label: String)] = [
        ("gemini-3.6-flash",       "Gemini 3.6 Flash"),
        ("gemini-3.5-flash-lite",  "Gemini 3.5 Flash Lite"),
        ("gemini-3.1-flash-lite",  "Gemini 3.1 Flash Lite"),
        ("gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview)"),
        ("gemini-2.5-flash",       "Gemini 2.5 Flash"),
    ]

    private let keyProvider: @Sendable () -> String?

    private static let base = "https://generativelanguage.googleapis.com/v1beta"

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
        guard let url = URL(string: "\(Self.base)/models?pageSize=1000") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Self.parseModelList(data)
    }

    /// Parses the `:listModels` JSON: only models supporting generateContent, bare ids.
    static func parseModelList(_ data: Data) -> [(id: String, label: String)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["models"] as? [[String: Any]] else { return [] }

        var picked: [(id: String, label: String)] = []
        for item in items {
            guard let raw = item["name"] as? String else { continue }
            let methods = item["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { continue }
            // API returns "models/gemini-x" — the rest of the code wants the bare id.
            let modelId = raw.hasPrefix("models/") ? String(raw.dropFirst("models/".count)) : raw
            guard !modelId.isEmpty else { continue }
            picked.append((id: modelId, label: modelId))
        }
        return picked
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        var useSearch = request.enableWebSearch
        var attempt = 0
        while attempt < 2 {
            attempt += 1
            let url = try endpoint(model: request.model, stream: false)
            let urlRequest = try makeURLRequest(url: url,
                                                body: Self.requestBody(request, enableGoogleSearch: useSearch),
                                                stream: false)
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return try Self.parseResponse(data)
            }
            if attempt < 2, useSearch, Self.mentionsSearch(data) {
                useSearch = false
                continue
            }
            throw Self.apiError(data, statusCode: status, model: request.model)
        }
        throw LLMError("Gemini request failed.")
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var useSearch = request.enableWebSearch
                var attempt = 0
                while attempt < 2 {
                    attempt += 1
                    do {
                        let url = try endpoint(model: request.model, stream: true)
                        let urlRequest = try makeURLRequest(url: url,
                                                            body: Self.requestBody(request, enableGoogleSearch: useSearch),
                                                            stream: true)
                        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                        guard let http = response as? HTTPURLResponse else {
                            throw LLMError("No HTTP response from Gemini.")
                        }
                        if http.statusCode != 200 {
                            var errData = Data()
                            for try await byte in bytes { errData.append(byte) }
                            if attempt < 2, useSearch, Self.mentionsSearch(errData) {
                                useSearch = false
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
                continuation.finish(throwing: LLMError("Gemini request failed."))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Endpoints / request

    private func endpoint(model: String, stream: Bool) throws -> URL {
        // Model ids can contain chars that must survive a URL path.
        let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let action = stream ? "streamGenerateContent?alt=sse" : "generateContent"
        guard let url = URL(string: "\(Self.base)/models/\(encoded):\(action)") else {
            throw LLMError("Invalid model id: \(model)")
        }
        return url
    }

    private func makeURLRequest(url: URL, body: [String: Any], stream: Bool) throws -> URLRequest {
        guard let key = keyProvider(),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError("API key missing. Open settings.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = stream ? 120 : 45
        return req
    }

    static func requestBody(_ request: LLMRequest, enableGoogleSearch: Bool) -> [String: Any] {
        var body: [String: Any] = [:]

        let system = request.system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }

        // Gemini needs tool *names* on functionResponse parts — map ids back via a scan.
        var nameById: [String: String] = [:]
        for message in request.messages {
            for block in message.content {
                if case .toolUse(let toolId, let name, _) = block {
                    nameById[toolId] = name
                }
            }
        }

        var contents: [[String: Any]] = []
        for message in request.messages {
            guard message.role == .user || message.role == .assistant else { continue }
            let role = message.role == .user ? "user" : "model"
            var parts: [Any] = []
            for block in message.content {
                switch block {
                case .text(let t):
                    parts.append(["text": t])
                case .image(let mediaType, let base64):
                    parts.append(["inlineData": ["mimeType": mediaType, "data": base64]])
                case .document(let mediaType, let base64):
                    parts.append(["inlineData": ["mimeType": mediaType, "data": base64]])
                case .toolUse(_, let name, let input):
                    let call: [String: Any] = ["name": name, "args": input.anyValue]
                    parts.append(["functionCall": call])
                case .toolResult(let toolId, let content, let isError):
                    let name = nameById[toolId]
                        ?? "Function result for \(toolId)"
                    // Gemini requires the payload inside a `response` object.
                    // Top-level functionResponse ONLY accepts `name` and `response`.
                    var responseObj: [String: Any] = ["content": content]
                    if isError {
                        responseObj["error"] = true
                    }
                    let resp: [String: Any] = [
                        "name": name,
                        "response": responseObj,
                    ]
                    parts.append(["functionResponse": resp])
                }
            }
            if !parts.isEmpty {
                contents.append(["role": role, "parts": parts])
            }
        }
        body["contents"] = contents

        var generation: [String: Any] = ["maxOutputTokens": request.maxTokens]
        if let temperature = request.temperature { generation["temperature"] = temperature }
        body["generationConfig"] = generation

        // Tools XOR search — Gemini rejects mixing them in one request.
        if !request.tools.isEmpty {
            let declarations: [[String: Any]] = request.tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": Self.sanitizeSchemaForGemini(tool.inputSchema.anyValue),
                ]
            }
            body["tools"] = [["functionDeclarations": declarations]]
        } else if enableGoogleSearch {
            body["tools"] = [["googleSearch": [String: Any]()]]
        }
        return body
    }

    /// Membersihkan skema OpenAPI agar selalu valid sesuai spesifikasi Google Gemini API.
    /// Gemini mewajibkan field `items` untuk semua property bertipe `array` / `ARRAY`.
    static func sanitizeSchemaForGemini(_ schema: Any) -> Any {
        guard var dict = schema as? [String: Any] else {
            if let arr = schema as? [Any] {
                return arr.map { sanitizeSchemaForGemini($0) }
            }
            return schema
        }

        // 1. Cek apakah bertipe array, dan pastikan field `items` tersedia
        if let typeStr = dict["type"] as? String, typeStr.lowercased() == "array" {
            if dict["items"] == nil {
                dict["items"] = ["type": "string"]
            } else if let itemsObj = dict["items"] {
                dict["items"] = sanitizeSchemaForGemini(itemsObj)
            }
        }

        // 2. Rekursif sanitasi sub-properties
        if let properties = dict["properties"] as? [String: Any] {
            var newProps: [String: Any] = [:]
            for (key, val) in properties {
                newProps[key] = sanitizeSchemaForGemini(val)
            }
            dict["properties"] = newProps
        }

        return dict
    }

    // MARK: - Response parsing

    static func parseResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let errPayload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let err = errPayload["error"] as? [String: Any] {
                throw LLMError(err["message"] as? String ?? "Gemini request failed.")
            }
            throw LLMError("Unexpected response from Gemini.")
        }
        if let err = json["error"] as? [String: Any] {
            throw LLMError(err["message"] as? String ?? "Gemini request failed.")
        }

        var content: [LLMContentBlock] = []
        var stop: LLMStopReason = .unknown
        var usage: LLMUsage?

        if let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first {
            if let parts = first["content"] as? [String: Any], let list = parts["parts"] as? [[String: Any]] {
                for part in list {
                    if let text = part["text"] as? String, !text.isEmpty {
                        content.append(.text(text))
                    } else if let call = part["functionCall"] as? [String: Any],
                              let name = call["name"] as? String {
                        let args = call["args"] ?? [String: Any]()
                        content.append(.toolUse(id: "fc_\(content.count)", name: name,
                                                input: JSONValue(any: args)))
                    }
                }
            }
            if let reason = first["finishReason"] as? String {
                stop = mapStopReason(reason)
            }
        }
        if let meta = json["usageMetadata"] as? [String: Any] {
            usage = LLMUsage(inputTokens: meta["promptTokenCount"] as? Int ?? 0,
                             outputTokens: meta["candidatesTokenCount"] as? Int ?? 0)
        }
        if content.isEmpty { throw LLMError("No response text.") }
        // Same override as the streaming path: "STOP" + functionCall ⇒ tool use.
        if content.contains(where: { if case .toolUse = $0 { return true } else { return false } }) {
            stop = .toolUse
        }
        return LLMResponse(assistantMessage: LLMMessage(role: .assistant, content: content),
                           stopReason: stop, usage: usage)
    }

    static func mapStopReason(_ reason: String) -> LLMStopReason {
        switch reason {
        case "STOP": return .endTurn
        case "MAX_TOKENS": return .maxTokens
        default: return .unknown
        }
    }

    static func apiError(_ data: Data, statusCode: Int, model: String) -> LLMError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any] {
            let message = err["message"] as? String ?? ""
            let status = err["status"] as? String ?? ""
            if statusCode == 401 || status == "UNAUTHENTICATED" {
                return LLMError("Invalid Google API key. Check Settings.")
            }
            if statusCode == 429 || status == "RESOURCE_EXHAUSTED" {
                return LLMError("Rate limited by Gemini — try again in a moment.")
            }
            if statusCode == 404 || status == "NOT_FOUND" {
                return LLMError("Model not found: \(model). Pick another one in Settings.")
            }
            if !message.isEmpty { return LLMError(message) }
        }
        return LLMError(String(data: data, encoding: .utf8) ?? "Gemini request failed (HTTP \(statusCode)).")
    }

    static func mentionsSearch(_ data: Data) -> Bool {
        guard let raw = String(data: data, encoding: .utf8) else { return false }
        return raw.lowercased().contains("search")
    }

    // MARK: - SSE parsing

    /// Gemini streams one JSON chunk per `data:` line; each chunk carries incremental
    /// text parts plus optional usageMetadata / error payloads.
    struct SSEParser {
        private var text = ""
        private var stopReason: LLMStopReason = .unknown
        private var inputTokens = 0
        private var outputTokens = 0
        private var toolCalls: [(id: String, name: String, args: JSONValue)] = []
        private(set) var didComplete = false

        mutating func feed(_ line: String) throws -> [LLMStreamEvent] {
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
                throw LLMError(err["message"] as? String ?? "Gemini stream error.")
            }

            var events: [LLMStreamEvent] = []
            if let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first {
                if let content = first["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let piece = part["text"] as? String, !piece.isEmpty {
                            text += piece
                            events.append(.textDelta(piece))
                        } else if let call = part["functionCall"] as? [String: Any],
                                  let name = call["name"] as? String {
                            toolCalls.append(("fc_\(toolCalls.count)", name,
                                              JSONValue(any: call["args"] ?? [String: Any]())))
                        }
                    }
                }
                if let reason = first["finishReason"] as? String, !reason.isEmpty {
                    stopReason = GeminiProvider.mapStopReason(reason)
                }
            }
            if let meta = json["usageMetadata"] as? [String: Any] {
                // Later chunks overwrite earlier counts — they are cumulative totals.
                if let prompt = meta["promptTokenCount"] as? Int { inputTokens = prompt }
                if let completion = meta["candidatesTokenCount"] as? Int { outputTokens = completion }
            }
            return events
        }

        mutating func finish() -> LLMResponse? {
            guard !didComplete else { return nil }
            didComplete = true
            return makeResponse()
        }

        private func makeResponse() -> LLMResponse {
            var content: [LLMContentBlock] = []
            if !text.isEmpty { content.append(.text(text)) }
            for call in toolCalls {
                content.append(.toolUse(id: call.id, name: call.name, input: call.args))
            }
            // Gemini reports finishReason "STOP" even for functionCall responses —
            // the tool loop keys off stopReason, so override when tools are present.
            let stop = toolCalls.isEmpty ? stopReason : .toolUse
            let hasUsage = (inputTokens + outputTokens) > 0
            let usage = hasUsage ? LLMUsage(inputTokens: inputTokens, outputTokens: outputTokens) : nil
            return LLMResponse(assistantMessage: LLMMessage(role: .assistant, content: content),
                               stopReason: stop, usage: usage)
        }
    }
}
