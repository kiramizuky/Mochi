import Foundation

// MARK: - Phase 6: LanguageRouter, HealthService, ProactiveEngine, claude_run tool

@main enum Phase6Tests {
    static func main() async throws {
        testLanguageRouterDetect()
        testLanguageRouterInstruction()
        testHealthServiceCheck()
        testHealthServiceSelfRepair()
        testProactiveEngineChips()
        await testClaudeRunTool()
        print("Phase6Tests: all cases passed")
    }
}

// MARK: - Test doubles

final class TestProvider: LLMProvider, @unchecked Sendable {
    let id: String
    let displayName = "Test"
    let defaultModel = "test-1"
    let fallbackModels: [(id: String, label: String)] = [("test-1", "Test")]
    let configured: Bool

    init(id: String = "test-provider", configured: Bool = false) {
        self.id = id
        self.configured = configured
    }

    func isConfigured() -> Bool { configured }
    func listModels() async -> [(id: String, label: String)] { [(defaultModel, displayName)] }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(assistantMessage: LLMMessage(role: .assistant, content: [.text("ok")]),
                    stopReason: .endTurn)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(LLMResponse(assistantMessage: LLMMessage(role: .assistant,
                                                                                content: [.text("ok")]),
                                                        stopReason: .endTurn)))
            continuation.finish()
        }
    }
}

// MARK: - LanguageRouter

func testLanguageRouterDetect() {
    precondition(LanguageRouter.detect("Saya akan rapat besok pukul 15.00 di kantor") == "id")
    precondition(LanguageRouter.detect("I will meet you tomorrow at 3pm in the office") == "en")
    precondition(LanguageRouter.detect("Je vais à une réunion demain à 15 heures") == "fr")
    precondition(LanguageRouter.detect("xqz plm wovo") == "")
    precondition(LanguageRouter.detect("") == "")
    precondition(LanguageRouter.detect("   ") == "")
}

func testLanguageRouterInstruction() {
    precondition(!LanguageRouter.systemInstruction(for: "id").isEmpty)
    precondition(!LanguageRouter.systemInstruction(for: "en").isEmpty)
    precondition(!LanguageRouter.systemInstruction(for: "fr").isEmpty)
    precondition(!LanguageRouter.systemInstruction(for: "es").isEmpty)
    precondition(!LanguageRouter.systemInstruction(for: "de").isEmpty)
    precondition(LanguageRouter.systemInstruction(for: "").isEmpty)
}

// MARK: - HealthService

func testHealthServiceCheck() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-phase6-health-\(UUID().uuidString)", isDirectory: true)
    let audit = AuditLog(url: tmp.appendingPathComponent("audit.jsonl"))
    let health = HealthService.shared
    health.apiKeyOK = { true }
    health.micGranted = { true }
    health.axGranted = { true }
    health.screenGranted = { true }
    health.freeDisk = { true }
    health.audit = { (category: String, action: String, decision: PolicyDecision, detail: String?) in
        audit.record(category: ActionCategory(rawValue: category) ?? .read, action: action, target: "",
                     decision: decision, reason: detail)
    }

    let statuses = health.check()
    precondition(statuses.count == 5, "expected 5 statuses, got \(statuses.count)")
    precondition(statuses.allSatisfy { $0.ok }, "not all ok: \(statuses)")
    precondition(statuses.contains { $0.id == "api_key" && $0.ok })
    precondition(statuses.contains { $0.id == "microphone" && $0.ok })
    precondition(statuses.contains { $0.id == "accessibility" && $0.ok })
    precondition(statuses.contains { $0.id == "screen_capture" && $0.ok })
    precondition(statuses.contains { $0.id == "disk_space" && $0.ok })
    precondition(audit.entries().allSatisfy { $0.decision == "allow" })

    // Satu probe gagal → status tidak ok + audit mencatat deny.
    health.apiKeyOK = { false }
    let failing = health.check()
    precondition(failing.contains { $0.id == "api_key" && !$0.ok })
    precondition(audit.entries().contains { $0.action == "health.check.api_key" && $0.decision == "deny" })
}

func testHealthServiceSelfRepair() {
    let health = HealthService.shared
    health.apiKeyOK = { false } // paksa "belum terkonfigurasi"
    var repair: [(String, String, String, String?)] = []
    health.audit = { (category: String, action: String, decision: PolicyDecision, detail: String?) in
        repair.append((category, action, decision.rawValue, detail))
    }

    // Tidak ada alternatif terkonfigurasi → self-repair ditolak.
    health.selfRepair()
    precondition(repair.contains { $0.1 == "health.self_repair" && $0.2 == "deny" })

    // Daftarkan provider aktif tak-berkunci, lalu alternatif ber-kunci; perbaiki.
    ProviderRegistry.shared.register(TestProvider(id: "test-provider", configured: false))
    ProviderRegistry.shared.register(TestProvider(id: "test-alt", configured: true))
    ProviderRegistry.shared.setActiveProvider(id: "test-provider")
    health.selfRepair()
    let switchedAway = ProviderRegistry.shared.activeProviderId != "test-provider"
    let newActiveConfigured = ProviderRegistry.shared.provider(id: ProviderRegistry.shared.activeProviderId)?.isConfigured() == true
    precondition(switchedAway && newActiveConfigured, "self-repair should switch to configured alternative, got \(ProviderRegistry.shared.activeProviderId)")
    precondition(repair.contains { $0.1 == "health.self_repair" && $0.2 == "allow" })
}

// MARK: - ProactiveEngine

func testProactiveEngineChips() {
    let chips = ProactiveEngine.chips(from: [
        MemoryEntry(id: "a", text: "Rapat besok pukul 15.00 di kantor", updatedAt: .distantPast),
        MemoryEntry(id: "b", text: "Suka kopi hitam tanpa gula", updatedAt: .distantPast),
        MemoryEntry(id: "c", text: "Deadline project Jumat 09.00 pagi", updatedAt: .distantPast),
    ])
    precondition(chips.count == 2, "expected 2 chips, got \(chips.count)")
    precondition(chips.contains { $0.id == "a" })
    precondition(chips.contains { $0.id == "c" })
    precondition(!chips.contains { $0.id == "b" })
    precondition(chips.allSatisfy { !$0.text.isEmpty && !$0.fact.isEmpty })

    // refresh() menyimpan hasil ke instance chips, sama dengan fungsi murni.
    let engine = ProactiveEngine.shared
    let expected = ProactiveEngine.chips(from: MemoryService.shared.all())
    engine.refresh()
    precondition(engine.chips == expected)

    // Tanpa pola waktu / kata kunci → kosong.
    precondition(ProactiveEngine.chips(from: [
        MemoryEntry(id: "x", text: "Saya suka kopi", updatedAt: .distantPast),
    ]).isEmpty)
}

// MARK: - claude_run tool

func testClaudeRunTool() async {
    precondition(ToolExecutor.tools.count == 24)
    precondition(ToolExecutor.tools.map(\.name).last == "node_run_shell")

    guard let def = ToolExecutor.tools.first(where: { $0.name == "claude_run" }) else {
        preconditionFailure("claude_run def missing")
    }
    if case .object(let schema) = def.inputSchema {
        precondition(schema["type"] == .string("object"))
        if case .array(let required) = schema["required"] {
            precondition(required.contains(.string("prompt")))
        } else {
            preconditionFailure("required is not an array")
        }
    } else {
        preconditionFailure("claude_run schema is not an object")
    }

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-phase6-tools-\(UUID().uuidString)", isDirectory: true)
    let audit = AuditLog(url: tmp.appendingPathComponent("audit.jsonl"))
    let executor = ToolExecutor(audit: audit)

    // Tanpa argumen → missing argument, dicatat ke audit.
    let missing = await executor.execute(name: "claude_run", input: .object([:]))
    precondition(missing.isError && missing.output.contains("Missing required argument for claude_run"))
    precondition(audit.entries().contains { $0.action == "claude_run" && $0.decision == "deny" })

    // Hard floor: prompt yang berisi "sudo" ditolak meski mode autopilot.
    let denied = await executor.execute(name: "claude_run",
        input: .object(["prompt": .string("sudo rm -rf /tmp/x")]))
    precondition(denied.isError && denied.output.contains("Blocked by policy"))
    precondition(denied.output.contains("sudo is never allowed"))
    precondition(audit.entries().contains { $0.action == "claude_run" && $0.decision == "deny"
        && $0.reason == "sudo is never allowed" })

    // Prompt aman tidak kena floor (CLI tak terpasang → error CLI, bukan policy).
    let safe = await executor.execute(name: "claude_run",
        input: .object(["prompt": .string("read the README.md and summarize it")]))
    precondition(!safe.output.contains("Blocked by policy"))
    precondition(safe.exitCode != 0 || safe.output.contains("command not found"))
}
