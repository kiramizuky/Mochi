import Foundation

// MARK: - Chat store

/// Multi-turn conversation history sent to the LLM provider (notch chat).
/// Text-only, provider-agnostic. Thread-safe.
final class ChatStore: @unchecked Sendable {
    private var messages: [LLMMessage] = []
    private let lock = NSLock()

    var isEmpty: Bool { lock.withLock { messages.isEmpty } }
    var count: Int { lock.withLock { messages.count } }
    var all: [LLMMessage] { lock.withLock { messages } }

    func appendUser(_ blocks: [LLMContentBlock]) {
        lock.withLock { messages.append(LLMMessage(role: .user, content: blocks)) }
    }

    func appendAssistant(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock { messages.append(LLMMessage(role: .assistant, content: [.text(trimmed)])) }
    }

    /// Drops the last turn (used when a request fails mid-flight).
    func rollbackLast() {
        lock.withLock { if !messages.isEmpty { messages.removeLast() } }
    }

    func clear() {
        lock.withLock { messages = [] }
    }
}
