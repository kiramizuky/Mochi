import Foundation

// MARK: - Groq Provider (OpenAI-compatible Chat Completions, SSE streaming, Multi-Key Auto-Rotation)

struct GroqProvider: LLMProvider {
    let id = "groq"
    let displayName = "Groq"
    let defaultModel = "openai/gpt-oss-120b"
    let fallbackModels: [(id: String, label: String)] = [
        ("openai/gpt-oss-120b", "GPT-OSS 120B (Groq)"),
        ("qwen/qwen3.8-27b", "Qwen 3.8 27B (Groq)"),
        ("openai/gpt-oss-20b", "GPT-OSS 20B (Groq)"),
        ("allam-2-7b", "ALLaM 2 7B (Groq)"),
        ("meta-llama/llama-prompt-guard-2-86m", "Llama Prompt Guard 86M"),
        ("llama-3.3-70b-versatile", "Llama 3.3 70B Versatile"),
        ("llama-3.1-8b-instant", "Llama 3.1 8B Instant"),
    ]

    /// Injected so this type stays free of hardcoded dependencies and supports Multi-Key pool.
    private let keyProvider: @Sendable () -> String?

    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private static let modelsEndpoint = URL(string: "https://api.groq.com/openai/v1/models")!

    init(keyProvider: @escaping @Sendable () -> String?) {
        self.keyProvider = keyProvider
    }

    // MARK: - LLMProvider

    func isConfigured() -> Bool {
        guard let key = keyProvider() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func listModels() async -> [(id: String, label: String)] {
        guard let key = keyProvider(), !key.isEmpty else { return fallbackModels }
        var req = URLRequest(url: Self.modelsEndpoint, timeoutInterval: 10)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return fallbackModels }
        let parsed = Self.parseModelList(data)
        return parsed.isEmpty ? fallbackModels : parsed
    }

    static func parseModelList(_ data: Data) -> [(id: String, label: String)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }

        var picked: [(id: String, label: String, created: Int)] = []
        for item in items {
            guard let modelId = item["id"] as? String else { continue }
            let lower = modelId.lowercased()
            if lower.contains("whisper") || lower.contains("tts") || lower.contains("orpheus") || lower.contains("safeguard") {
                continue
            }
            picked.append((modelId, modelId, item["created"] as? Int ?? 0))
        }
        return picked.sorted { $0.created > $1.created }.map { (id: $0.id, label: $0.label) }
    }

    // MARK: - One-Shot Completion with Multi-Key Failover

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        var lastError: Error?
        let maxRetries = 3

        for _ in 1...maxRetries {
            guard let key = keyProvider(), !key.isEmpty else {
                throw LLMError("Groq API key is missing or not configured.")
            }

            let body = Self.requestBody(request, stream: false)
            var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: 60)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = body

            do {
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                if status == 200 {
                    ProviderRegistry.shared.reportSuccess(providerId: "groq", keySecret: key)
                    return try Self.parseResponse(data, model: request.model)
                } else if status == 429 {
                    // Rate limit hit: rotate key and retry
                    ProviderRegistry.shared.reportFailure(providerId: "groq", keySecret: key, isRateLimit: true)
                    continue
                } else {
                    ProviderRegistry.shared.reportFailure(providerId: "groq", keySecret: key, isRateLimit: false)
                    throw Self.apiError(data, statusCode: status, model: request.model)
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? LLMError("Groq request failed after key rotation retries.")
    }

    // MARK: - Streaming with Multi-Key Failover

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var streamedAnyChunk = false
                let maxRetries = 3

                for attempt in 1...maxRetries {
                    guard let key = keyProvider(), !key.isEmpty else {
                        continuation.finish(throwing: LLMError("Groq API key is missing."))
                        return
                    }

                    let body = Self.requestBody(request, stream: true)
                    var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: 60)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = body

                    do {
                        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                        if status == 429 && !streamedAnyChunk && attempt < maxRetries {
                            // Rotate key on 429 before streaming started
                            ProviderRegistry.shared.reportFailure(providerId: "groq", keySecret: key, isRateLimit: true)
                            continue
                        }

                        guard status == 200 else {
                            ProviderRegistry.shared.reportFailure(providerId: "groq", keySecret: key, isRateLimit: status == 429)
                            continuation.finish(throwing: LLMError("Groq API error HTTP \(status)"))
                            return
                        }

                        ProviderRegistry.shared.reportSuccess(providerId: "groq", keySecret: key)

                        var accumulatedText = ""
                        var stopReason: LLMStopReason = .unknown

                        for try await line in bytes.lines {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard trimmed.hasPrefix("data:") else { continue }
                            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let choices = json["choices"] as? [[String: Any]],
                                  let choice = choices.first else { continue }

                            if let delta = choice["delta"] as? [String: Any],
                               let content = delta["content"] as? String, !content.isEmpty {
                                streamedAnyChunk = true
                                accumulatedText.append(content)
                                continuation.yield(.textDelta(content))
                            }

                            if let finish = choice["finish_reason"] as? String {
                                switch finish {
                                case "stop": stopReason = .endTurn
                                case "length": stopReason = .maxTokens
                                default: break
                                }
                            }
                        }

                        let assistantMsg = LLMMessage(role: .assistant, content: [.text(accumulatedText)])
                        let finalResponse = LLMResponse(assistantMessage: assistantMsg, stopReason: stopReason)
                        continuation.yield(.completed(finalResponse))
                        continuation.finish()
                        return
                    } catch {
                        if !streamedAnyChunk && attempt < maxRetries {
                            ProviderRegistry.shared.reportFailure(providerId: "groq", keySecret: key, isRateLimit: false)
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    static func requestBody(_ request: LLMRequest, stream: Bool) -> Data {
        var messagesArray: [[String: Any]] = []

        if !request.system.isEmpty {
            messagesArray.append(["role": "system", "content": request.system])
        }

        for msg in request.messages {
            let roleStr = msg.role == .user ? "user" : "assistant"
            let text = msg.content.compactMap(\.text).joined(separator: "\n")
            messagesArray.append(["role": roleStr, "content": text])
        }

        var dict: [String: Any] = [
            "model": request.model,
            "messages": messagesArray,
            "stream": stream,
            "max_tokens": request.maxTokens,
        ]

        if let temp = request.temperature {
            dict["temperature"] = temp
        }

        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    static func parseResponse(_ data: Data, model: String) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError("Failed to parse Groq response.")
        }

        let finish = choice["finish_reason"] as? String
        let stopReason: LLMStopReason = finish == "length" ? .maxTokens : .endTurn
        let assistantMsg = LLMMessage(role: .assistant, content: [.text(content)])
        return LLMResponse(assistantMessage: assistantMsg, stopReason: stopReason)
    }

    static func apiError(_ data: Data, statusCode: Int, model: String) -> LLMError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let message = err["message"] as? String {
            return LLMError("Groq (\(statusCode)): \(message)")
        }
        return LLMError("Groq returned HTTP \(statusCode)")
    }
}
