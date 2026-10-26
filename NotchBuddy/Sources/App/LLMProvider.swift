import Foundation

// MARK: - JSON value

/// Sendable JSON representation used for tool schemas and tool-call inputs.
enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Bridges to objects JSONSerialization can encode.
    var anyValue: Any {
        switch self {
        case .string(let s):  return s
        case .number(let n):  return n
        case .bool(let b):    return b
        case .null:           return NSNull()
        case .array(let a):   return a.map { $0.anyValue }
        case .object(let o):  return o.mapValues { $0.anyValue }
        }
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let a as [Any]:
            self = .array(a.map(JSONValue.init(any:)))
        case let d as [String: Any]:
            self = .object(d.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Object member value (`[String: JSONValue]`), nil for non-objects.
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Bool value, nil for non-bools.
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Array value (`[JSONValue]`), nil for non-arrays.
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Number value, nil for non-numbers.
    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// Object member lookup (`JSONValue.object(...)[key]`), nil for non-objects.
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

// MARK: - Messages

enum LLMRole: String, Sendable {
    case user, assistant
}

enum LLMContentBlock: Sendable, Equatable {
    case text(String)
    case image(mediaType: String, base64: String)
    case document(mediaType: String, base64: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, content: String, isError: Bool)

    var text: String? {
        if case .text(let t) = self { return t }
        return nil
    }
}

struct LLMMessage: Sendable, Equatable {
    var role: LLMRole
    var content: [LLMContentBlock]
}

struct LLMToolDef: Sendable, Equatable {
    var name: String
    var description: String
    var inputSchema: JSONValue
}

enum LLMStopReason: String, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case toolUse = "tool_use"
    case stopSequence = "stop_sequence"
    case unknown
}

struct LLMUsage: Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
}

// MARK: - Request / response

struct LLMRequest: Sendable {
    var model: String
    var system: String
    var messages: [LLMMessage]
    var maxTokens: Int = 4096
    var temperature: Double? = nil
    var tools: [LLMToolDef] = []
    /// Server-side web search where the provider supports it (Anthropic today).
    var enableWebSearch: Bool = false
}

struct LLMResponse: Sendable, Equatable {
    var assistantMessage: LLMMessage
    var stopReason: LLMStopReason
    var usage: LLMUsage?
    /// All text blocks of the assistant turn, concatenated.
    var text: String

    init(assistantMessage: LLMMessage, stopReason: LLMStopReason, usage: LLMUsage? = nil) {
        self.assistantMessage = assistantMessage
        self.stopReason = stopReason
        self.usage = usage
        self.text = assistantMessage.content.compactMap(\.text).joined()
    }
}

enum LLMStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case completed(LLMResponse)
}

struct LLMError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

// MARK: - Provider protocol

protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Model used when the user has not chosen one (or the choice belongs to another provider).
    var defaultModel: String { get }

    /// Static fallback list shown when `listModels()` returns nothing.
    var fallbackModels: [(id: String, label: String)] { get }

    /// Whether an API key is available (does not validate it).
    func isConfigured() -> Bool

    /// Available models (empty array when unavailable — callers fall back to a static list).
    func listModels() async -> [(id: String, label: String)]

    /// One-shot completion (non-streaming).
    func complete(_ request: LLMRequest) async throws -> LLMResponse

    /// Streaming completion. Yields `textDelta` events, then at most one `completed`,
    /// then finishes. Throws `LLMError` on API or transport failures.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}
