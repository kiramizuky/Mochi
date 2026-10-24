import Foundation

// MARK: - Local SLM Provider (Apple Silicon MLX / Ollama / LM Studio)
// Menyediakan eksekusi model lokal on-device, 100% gratis, offline-safe, dan latensi ultra-rendah.

final class LocalSLMProvider: LLMProvider, @unchecked Sendable {
    let id: String = "local_mlx"
    let displayName: String = "Local MLX / Ollama"
    let defaultModel: String = "qwen2.5:7b"

    let fallbackModels: [(id: String, label: String)] = [
        ("qwen2.5:7b", "Qwen 2.5 7B (Recommended)"),
        ("llama3.2:3b", "Llama 3.2 3B (Fast)"),
        ("deepseek-r1:7b", "DeepSeek R1 7B (Reasoning)"),
        ("mistral:7b", "Mistral 7B"),
    ]

    private let endpoint: URL

    init(baseURL: String = "http://127.0.0.1:11434") {
        self.endpoint = URL(string: baseURL) ?? URL(string: "http://127.0.0.1:11434")!
    }

    func isConfigured() -> Bool {
        // Model lokal tidak memerlukan API key berbayar
        return true
    }

    func listModels() async -> [(id: String, label: String)] {
        let tagsURL = endpoint.appendingPathComponent("api/tags")
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 2.0

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return fallbackModels
        }

        let fetched = models.compactMap { m -> (id: String, label: String)? in
            guard let name = m["name"] as? String else { return nil }
            return (id: name, label: "Local: \(name)")
        }

        return fetched.isEmpty ? fallbackModels : fetched
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let chatURL = endpoint.appendingPathComponent("api/chat")
        var urlReq = URLRequest(url: chatURL)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 60.0

        // Siapkan pesan Ollama format
        var messagesPayload: [[String: Any]] = []
        if !request.system.isEmpty {
            messagesPayload.append(["role": "system", "content": request.system])
        }

        for msg in request.messages {
            let roleStr = msg.role == .user ? "user" : "assistant"
            let textContent = msg.content.compactMap(\.text).joined(separator: "\n")
            messagesPayload.append(["role": roleStr, "content": textContent])
        }

        let payload: [String: Any] = [
            "model": request.model.isEmpty ? defaultModel : request.model,
            "messages": messagesPayload,
            "stream": false
        ]

        urlReq.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: urlReq)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Local server error"
            throw LLMError("Local MLX/Ollama error: \(msg)")
        }

        guard let resJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageObj = resJson["message"] as? [String: Any],
              let content = messageObj["content"] as? String else {
            throw LLMError("Gagal mem-parsing balasan dari local server.")
        }

        let assistantMsg = LLMMessage(role: .assistant, content: [.text(content)])
        return LLMResponse(assistantMessage: assistantMsg, stopReason: .endTurn)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let res = try await complete(request)
                    continuation.yield(.textDelta(res.text))
                    continuation.yield(.completed(res))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
