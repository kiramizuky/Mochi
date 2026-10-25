import Foundation

// MARK: - Chat / search facade (routes through ProviderRegistry)

@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private let chatStore = ChatStore()

    /// Active provider (Anthropic today; more providers can be registered later).
    private var provider: any LLMProvider { ProviderRegistry.shared.activeProvider }

    /// Chosen in Settings; falls back to the active provider's default when empty.
    private var model: String {
        let m = AppState.shared.claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? provider.defaultModel : m
    }

    /// Fetches available models from the Anthropic API in the order the API returns them
    /// (newest first). Returns an empty array on any error — callers fall back to a static list.
    static func fetchModels(apiKey: String) async -> [(id: String, label: String)] {
        await AnthropicProvider(keyProvider: { apiKey }).listModels()
    }

    func clearConversation() {
        chatStore.clear()
    }

    private let systemPrompt = """
    You are Mochi, Louis's personal AI assistant embedded in the notch of his Mac. \
    You can act on his Mac and on the web through tools: \
    search the web (web_search), fetch a web page (web_fetch), \
    run shell commands (shell_run), read and write files (file_read, file_write), \
    open apps or URLs (app_open), list running apps (app_list), \
    quit an app (app_close), capture an app window (app_screenshot), \
    read the UI of the frontmost app (ax_read), click, type or press keys in it (ax_act), \
    remember facts across sessions (memory_save), and run Claude Code headless for \
    coding tasks (claude_run). \
    Automate macOS apps via AppleScript/JavaScript (automation_run), list and act \
    on visible windows (window_list, window_act). \
    Jalankan node otomatisasi: HTTP request (node_http_request), file system \
    (node_file_system), jadwal (node_cron_schedule), if/else (node_if_else), \
    transformasi JSON (node_json_transform), notifikasi desktop (node_desktop_notification), \
    clipboard (node_clipboard), dan shell (node_run_shell) — semuanya via JavaScriptCore \
    dan native macOS API. \
    Use a tool whenever it genuinely helps: inspect first with a read or a quick command, then act. \
    When asked to open any website or webpage (e.g. Wikipedia), use app_open with the full target URL (e.g. "https://id.wikipedia.org/wiki/Kecerdasan_buatan"). \
    Before any ax_act, call ax_read to see the element indexes. \
    Never ask for permission in prose — confirmations are handled by the app itself. \
    After the last tool call, always give the final result as plain text explaining what you did in the user's language. \
    Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
    No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.
    """

    /// System prompt plus what the app remembers about the user ("" when empty).
    /// Menggunakan RAG semantik dinamis dari VectorMemoryStore berdasarkan query pengguna.
    private func systemPrompt(for query: String = "") -> String {
        let remembered = MemoryService.shared.formatForSystemPrompt()
        let preferences = VectorMemoryStore.shared.preferenceDigest(query: query.isEmpty ? nil : query, maxItems: 6)
        var full = systemPrompt
        if !remembered.isEmpty {
            full += "\n\n" + remembered
        }
        if !preferences.isEmpty {
            full += "\n\n" + preferences
        }
        return full
    }

    // MARK: - Tool executor (shared: askOnce confirmations persist for the session)

    private static let auditLog = AuditLog()

    private lazy var toolExecutor = ToolExecutor(
        audit: Self.auditLog,
        confirmHandler: { action in
            await ClaudeService.askToolApproval(action)
        }
    )

    /// Shows the approval card and waits for a click (auto-deny after 120 s).
    /// If autopilot is ON, auto-approves without user interaction.
    @MainActor
    private static func askToolApproval(_ action: PolicyAction) async -> Bool {
        // Super autonomous: auto-approve when autopilot is ON
        if AppState.shared.autopilotEnabled {
            return true
        }
        let state = AppState.shared
        state.pendingApproval = ApprovalInfo(
            sessionId: "agent",
            tool: action.category.rawValue,
            command: action.command,
            source: .agent
        )
        state.view = .approval
        SoundEngine.shared.play("approval")

        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            state.agentApproval = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if state.agentApproval != nil {
                    state.answerAgentApproval(false)
                }
            }
        }
        return approved
    }

    // MARK: - Chat (multi-turn, agent loop with tools)

    func chat(query: String, context: PromptContext?, state: AppState) async {
        VoiceManager.shared.stopSpeaking()

        // Smart Intent Routing: tentukan tier eksekusi & provider terbaik (Edge SLM vs Cloud LLM)
        let route = SmartIntentRouter.shared.selectExecution(
            for: query,
            activeProvider: provider,
            activeModel: model
        )
        let activeExecutorProvider = route.provider
        let activeExecutorModel = route.model

        guard activeExecutorProvider.isConfigured() || provider.isConfigured() else {
            await showError("API key missing. Open settings.", state: state)
            return
        }

        await MainActor.run {
            state.isGenerating = true
            state.lastActivity = .now
        }
        defer {
            Task { @MainActor in
                state.isGenerating = false
                state.lastActivity = .now
            }
        }

        // Window/file context is attached to the first message only.
        var blocks: [LLMContentBlock] = []
        if chatStore.isEmpty, let context {
            switch context {
            case .window(let app, let title, let url):
                var text = "Context — App: \(app), Window: \(title)"
                if let url { text += ", URL: \(url)" }
                blocks.append(.text(text))
            case .file(let name, let fileURL):
                if let fileURL, let block = Self.fileBlock(url: fileURL) {
                    blocks.append(block)
                }
                blocks.append(.text("File: \(name)"))
            }
        }
        blocks.append(.text(query))
        chatStore.appendUser(blocks)

        // Placeholder bubble — filled progressively while the agent runs.
        let placeholder = ChatMessage(role: .assistant, content: "")
        state.chatHistory.append(placeholder)
        let bubbleId = placeholder.id

        // Bahasa input & RAG Semantik Memori → instruksi tambahan ke system prompt (per-turn).
        let language = LanguageRouter.detect(query)
        var system = systemPrompt(for: query)
        if !language.isEmpty {
            system += "\n\n" + LanguageRouter.systemInstruction(for: language)
        }

        let composer = AgentBubbleComposer(bubbleId: bubbleId, state: state)
        let agent = AgentController(
            provider: activeExecutorProvider,
            system: system,
            executor: toolExecutor,
            enableWebSearch: false
        )

        do {
            let outcome = try await agent.run(
                history: chatStore.all,
                model: activeExecutorModel,
                maxTokens: 4096,
                onEvent: { event in
                    await MainActor.run {
                        state.lastActivity = .now
                        composer.handle(event)
                    }
                }
            )

            var text = outcome.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if outcome.hitStepLimit {
                text += "\n… (stopped after \(AgentController.maxSteps) steps)"
            }
            guard !text.isEmpty else { throw LLMError("No response text.") }

            chatStore.appendAssistant(text: text)
            updateBubble(id: bubbleId, text: text, state: state)
            state.stateOverride = nil
            state.view = .prompt
            VoiceManager.shared.speak(text)
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch {
            // Fallback otomatis ke Cloud LLM jika eksekusi Edge SLM gagal/offline
            if route.tier == .localSLM && activeExecutorProvider.id != self.provider.id && self.provider.isConfigured() {
                AppLog.shared.log("Edge SLM tidak responsif (\(error.localizedDescription)). Melakukan fallback ke Cloud LLM...")
                let fallbackAgent = AgentController(
                    provider: self.provider,
                    system: system,
                    executor: toolExecutor,
                    enableWebSearch: false
                )
                do {
                    let fallbackOutcome = try await fallbackAgent.run(
                        history: chatStore.all,
                        model: self.model,
                        maxTokens: 4096,
                        onEvent: { event in
                            await MainActor.run {
                                state.lastActivity = .now
                                composer.handle(event)
                            }
                        }
                    )
                    var text = fallbackOutcome.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if fallbackOutcome.hitStepLimit {
                        text += "\n… (stopped after \(AgentController.maxSteps) steps)"
                    }
                    guard !text.isEmpty else { throw LLMError("No response text.") }

                    chatStore.appendAssistant(text: text)
                    updateBubble(id: bubbleId, text: text, state: state)
                    state.stateOverride = nil
                    state.view = .prompt
                    VoiceManager.shared.speak(text)
                    NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
                    return
                } catch {
                    // jika fallback cloud juga gagal, lanjut ke penanganan error di bawah
                }
            }

            // Keep any partial text on screen, but drop the failed turn from the
            // sent history so the next attempt re-sends it cleanly.
            chatStore.rollbackLast()
            if let idx = state.chatHistory.firstIndex(where: { $0.id == bubbleId }),
               state.chatHistory[idx].content.isEmpty {
                state.chatHistory.remove(at: idx)
            }
            await showError(error.localizedDescription, state: state)
        }
    }

    private func updateBubble(id: UUID, text: String, state: AppState) {
        guard let idx = state.chatHistory.firstIndex(where: { $0.id == id }) else { return }
        state.chatHistory[idx].content = text
    }

    // MARK: - Structured search (M8 — window attach + web search)

    func search(query: String, context: PromptContext?, state: AppState) async {
        guard provider.isConfigured() else {
            await showError("API key missing. Open settings to configure it.", state: state)
            return
        }

        var blocks: [LLMContentBlock] = []
        switch context {
        case .window(let appName, let title, let url):
            var text = "App: \(appName)\nWindow title: \(title)"
            if let url { text += "\nURL: \(url)" }
            text += "\n\nRequest: \(query)"
            blocks.append(.text(text))
        case .file(let name, let fileURL):
            if let fileURL, let block = Self.fileBlock(url: fileURL) {
                blocks.append(block)
            }
            blocks.append(.text("File: \(name)\n\nRequest: \(query)"))
        case nil:
            blocks.append(.text(query))
        }

        // Best-effort DuckDuckGo context — works on every provider, offline-safe.
        do {
            let results = try await InternetService.search(query, limit: 6)
            if !results.isEmpty {
                blocks.append(.text(InternetService.formatForContext(results, query: query)))
            }
        } catch {
            blocks.append(.text("Web search unavailable: \(error.localizedDescription)"))
        }

        let remembered = MemoryService.shared.formatForSystemPrompt()
        let system = """
        You are an assistant built into the notch of a Mac. Reply in English, short and precise.
        \(remembered)
        Reply ONLY with valid JSON in this exact format:
        {"title":"...","items":[{"label":"...","detail":"...","url":"..."}],"note":"..."}
        Maximum 3 items. "url" is optional. "note" is optional.
        """

        let request = LLMRequest(
            model: model,
            system: system,
            messages: [LLMMessage(role: .user, content: blocks)],
            maxTokens: 1024,
            enableWebSearch: true
        )

        do {
            let response = try await provider.complete(request)
            Self.handleResult(text: response.text, state: state)
        } catch {
            await showError("Search failed: \(error.localizedDescription)", state: state)
        }
    }

    // MARK: - Structured result handler

    private static func handleResult(text: String, state: AppState) {
        // Strip markdown code fences if present, then extract JSON object
        let cleanText: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            cleanText = String(text[start...end])
        } else {
            cleanText = text
        }

        // Try to parse as our JSON format
        if let resultData = cleanText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            let title  = parsed["title"] as? String ?? "Result"
            let note   = parsed["note"] as? String
            var items: [ResultItem] = []
            if let rawItems = parsed["items"] as? [[String: Any]] {
                for item in rawItems.prefix(3) {
                    items.append(ResultItem(
                        label:  item["label"]  as? String ?? "",
                        detail: item["detail"] as? String ?? "",
                        url:    item["url"]    as? String
                    ))
                }
            }
            state.searchResult = SearchResult(title: title, items: items, note: note)
        } else {
            // Fallback: Claude did not return valid JSON. Show raw text and note the issue.
            let lines = cleanText.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(3)
            let rawPreview = lines.joined(separator: " ")
            let preview = rawPreview.count > 120 ? String(rawPreview.prefix(120)) + "…" : rawPreview
            state.searchResult = SearchResult(
                title: "Claude's response (not JSON)",
                items: [ResultItem(label: "Raw response", detail: preview, url: nil)],
                note: "Expected JSON with title/items/note. Got: \(preview)"
            )
        }

        state.stateOverride = nil
        state.view = .result
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
    }

    /// Called when a search (web or file context) fails to produce usable results.
    /// Shows a clear, user-facing message instead of raw internals.
    private static func showSearchIssue(_ reason: String, state: AppState) {
        state.stateOverride = .error
        state.noteMessage = reason
        state.view = .note
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
    }

    private func showError(_ message: String, state: AppState) async {
        state.stateOverride = .error
        state.noteMessage = message
        state.view = .note
    }

    // MARK: - File content block builder

    private static func fileBlock(url: URL) -> LLMContentBlock? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let base64 = data.base64EncodedString()

        switch ext {
        case "pdf":
            return .document(mediaType: "application/pdf", base64: base64)
        case "jpg", "jpeg":
            return .image(mediaType: "image/jpeg", base64: base64)
        case "png":
            return .image(mediaType: "image/png", base64: base64)
        case "gif":
            return .image(mediaType: "image/gif", base64: base64)
        case "webp":
            return .image(mediaType: "image/webp", base64: base64)
        default:
            // Text/code — inline as text if <= 200 KB
            guard data.count <= 200_000,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return .text("File contents:\n\(text)")
        }
    }
}

// MARK: - Bubble composer (streams agent events into one chat bubble)

/// Main-actor only. The agent loop emits `AgentEvent`s from a background
/// context; `chat()` funnels them here via `MainActor.run`, preserving order.
/// Keeps a display buffer mirroring the controller transcript (text + tool lines).
@MainActor
private final class AgentBubbleComposer {
    private let bubbleId: UUID
    private weak var state: AppState?
    private var buffer = ""   // committed text and tool lines
    private var stream = ""   // live deltas of the current step
    private var liveToolStep: String? = nil

    init(bubbleId: UUID, state: AppState) {
        self.bubbleId = bubbleId
        self.state = state
    }

    func handle(_ event: AgentEvent) {
        guard let state else { return }
        switch event {
        case .stepStarted(let step):
            if step > 1 { commit(); render() }
        case .textDelta(let piece):
            stream += piece
            if state.stateOverride == .thinking { state.stateOverride = nil }
            render()
        case .toolStarted(_, let name, let target):
            commit()
            liveToolStep = "→ \(name) \(target): Sedang dijalankan…"
            render()
        case .toolFinished(_, let name, let target, let summary, _):
            liveToolStep = nil
            commit()
            if !buffer.isEmpty { buffer += "\n" }
            buffer += "→ \(name) \(target): \(summary)"
            render()
        case .stepLimitReached:
            liveToolStep = nil
            commit()
            render()
        }
    }

    private func commit() {
        guard !stream.isEmpty else { return }
        if !buffer.isEmpty { buffer += "\n" }
        buffer += stream
        stream = ""
    }

    private var display: String {
        var result = buffer
        if !stream.isEmpty {
            if !result.isEmpty { result += "\n" }
            result += stream
        }
        if let live = liveToolStep {
            if !result.isEmpty { result += "\n" }
            result += live
        }
        return result
    }

    private func render() {
        guard let state,
              let idx = state.chatHistory.firstIndex(where: { $0.id == bubbleId }) else { return }
        state.chatHistory[idx].content = display
    }
}
