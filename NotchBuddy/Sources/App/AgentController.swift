import Foundation

// MARK: - Agent loop (stream → tools → stream, up to maxSteps)

/// Progress events surfaced to the UI while the loop runs.
enum AgentEvent: Sendable, Equatable {
    case stepStarted(Int)
    case textDelta(String)
    case toolStarted(step: Int, name: String, target: String)
    case toolFinished(step: Int, name: String, target: String, summary: String, isError: Bool)
    case stepLimitReached(Int)
}

struct AgentOutcome: Sendable, Equatable {
    /// Everything worth keeping: streamed text per step plus one `→ tool …` line per call.
    var transcript: String
    var steps: Int
    var hitStepLimit: Bool
}

/// Foundation-only agent loop: no AppState, no UI — fully unit-testable.
/// Conversation history is built locally per run; the caller keeps its own
/// store text-only and saves `transcript` on success.
struct AgentController: Sendable {
    static let maxSteps = 12

    private let provider: any LLMProvider
    private let system: String
    private let tools: [LLMToolDef]
    private let executor: ToolExecutor
    private let enableWebSearch: Bool

    init(provider: any LLMProvider,
         system: String,
         executor: ToolExecutor,
         tools: [LLMToolDef] = ToolExecutor.tools,
         enableWebSearch: Bool = true) {
        self.provider = provider
        self.system = system
        self.executor = executor
        self.tools = tools
        self.enableWebSearch = enableWebSearch
    }

    func run(history: [LLMMessage],
             model: String,
             maxTokens: Int = 4096,
             onEvent: @escaping @Sendable (AgentEvent) async -> Void) async throws -> AgentOutcome {
        var turn = history
        var parts: [String] = []
        var lastStep = 0

        for step in 1...Self.maxSteps {
            lastStep = step
            await onEvent(.stepStarted(step))

            let request = LLMRequest(
                model: model,
                system: system,
                messages: turn,
                maxTokens: maxTokens,
                tools: tools,
                enableWebSearch: enableWebSearch
            )

            var streamed = ""
            var final: LLMResponse? = nil
            for try await event in provider.stream(request) {
                switch event {
                case .textDelta(let piece):
                    streamed += piece
                    await onEvent(.textDelta(piece))
                case .completed(let response):
                    final = response
                }
            }
            guard let response = final else {
                throw LLMError("Stream ended without a response.")
            }

            let toolUses = response.assistantMessage.content.compactMap { block -> (id: String, name: String, input: JSONValue)? in
                if case .toolUse(let id, let name, let input) = block { return (id, name, input) }
                return nil
            }

            // No tool call → this is the final answer.
            if toolUses.isEmpty {
                let rawText = response.text.isEmpty ? streamed : response.text
                let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    if !parts.isEmpty {
                        return AgentOutcome(transcript: joined(parts), steps: step, hitStepLimit: false)
                    }
                    throw LLMError("The model returned an empty response.")
                }
                parts.append(text)
                return AgentOutcome(transcript: joined(parts), steps: step, hitStepLimit: false)
            }

            // Model text that preceded the tool call is part of the transcript.
            let stepText = response.text.isEmpty ? streamed : response.text
            if !stepText.isEmpty { parts.append(stepText) }

            turn.append(response.assistantMessage)

            var results: [LLMContentBlock] = []
            var images: [ToolImage] = []
            for use in toolUses {
                let target = ToolExecutor.targetDescription(name: use.name, input: use.input)
                await onEvent(.toolStarted(step: step, name: use.name, target: target))

                let result = await executor.execute(name: use.name, input: use.input)
                let summary = ToolExecutor.summary(of: result)
                await onEvent(.toolFinished(step: step, name: use.name, target: target,
                                            summary: summary, isError: result.isError))

                parts.append("→ \(use.name) \(target): \(summary)")
                results.append(.toolResult(id: use.id, content: result.output, isError: result.isError))
                if let image = result.image { images.append(image) }
            }
            turn.append(LLMMessage(role: .user, content: results))
            // Screenshots ride as their own user message: tool_result content
            // is a plain string, so an image block cannot live inside it.
            turn.append(contentsOf: Self.followUpMessages(images: images))
        }

        await onEvent(.stepLimitReached(Self.maxSteps))
        return AgentOutcome(transcript: joined(parts), steps: lastStep, hitStepLimit: true)
    }

    private func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// One user message per screenshot, appended right after the tool results.
    static func followUpMessages(images: [ToolImage]) -> [LLMMessage] {
        images.map { image in
            LLMMessage(role: .user, content: [
                .text("Screenshot from app_screenshot:"),
                .image(mediaType: image.mediaType, base64: image.base64),
            ])
        }
    }
}
