import Foundation

// MARK- Phase 13: Super Autonomous AI Assistant

// Uji MessageBus, AgentOrchestrator (dekomposisi + orkestrasi), CheckpointManager,
// dan SelfCorrection dengan provider palsu agar deterministik tanpa LLM sebenarnya.

@main enum Phase13Tests {
    static func main() async throws {
        await testMessageBus()
        testDecomposeDeterministic()
        await testOrchestrationRun()
        testCheckpointManager()
        await testSelfCorrection()
        print("Phase13Tests: all cases passed")
    }
}

// MARK- Test double: LLM provider palsu

final class FakeProvider: LLMProvider, @unchecked Sendable {
    let id = "fake"
    let displayName = "Fake"
    let defaultModel = "test-1"
    let fallbackModels: [(id: String, label: String)] = [("test-1", "Test")]
    var configured = true

    /// Penangani `complete` yang dapat ditetapkan per tes.
    var completeHandler: ((LLMRequest) async throws -> LLMResponse)?

    func isConfigured() -> Bool { configured }
    func listModels() async -> [(id: String, label: String)] { [(defaultModel, displayName)] }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        if let handler = completeHandler { return try await handler(request) }
        let text = request.messages.last?.content.compactMap(\.text).joined() ?? ""
        return LLMResponse(
            assistantMessage: LLMMessage(role: .assistant, content: [.text("jawab palsu: \(text)")]),
            stopReason: .endTurn)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let resp = try await complete(request)
                    continuation.yield(.completed(resp))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK- MessageBus

func testMessageBus() async {
    let bus = MessageBus.shared
    var received1 = [String]()
    var received2 = [String]()

    let t1 = await bus.subscribe(topic: .taskCompleted) { payload in
        if let s = payload as? String { received1.append(s) }
    }
    let _ = await bus.subscribe(topic: .taskCompleted) { payload in
        if let s = payload as? String { received2.append(s) }
    }
    let c1 = await bus.subscriberCount(topic: .taskCompleted)
    precondition(c1 == 2, "harusnya 2 pelanggan, dapet \(c1)")

    await bus.publish(topic: .taskCompleted, payload: "hello")
    try? await Task.sleep(nanoseconds: 150_000_000)
    precondition(received1 == ["hello"], "received1: \(received1)")
    precondition(received2 == ["hello"], "received2: \(received2)")

    await bus.unsubscribe(token: t1, topic: .taskCompleted)
    await bus.publish(topic: .taskCompleted, payload: "world")
    try? await Task.sleep(nanoseconds: 150_000_000)
    precondition(received1 == ["hello"], "received1 setelah unsub: \(received1)")
    precondition(received2 == ["hello", "world"], "received2 setelah unsub: \(received2)")

    let c2 = await bus.subscriberCount(topic: .taskCompleted)
    precondition(c2 == 1, "harusnya 1 pelanggan, dapet \(c2)")
}

// MARK- AgentOrchestrator: dekomposisi deterministik

func testDecomposeDeterministic() {
    // "cari informasi dan buka aplikasi" → researcher + operator
    let tasks = AgentOrchestrator.defaultDecompose("cari informasi tentang AI dan buka aplikasi")
    precondition(tasks.count >= 2, "harusnya ≥2 subtugas, dapet \(tasks.count)")
    precondition(tasks.contains { $0.role == .researcher }, "harus ada researcher")
    precondition(tasks.contains { $0.role == .operatorAgent }, "harus ada operator")

    // Goal tanpa pola → default coder 1 tugas
    let plain = AgentOrchestrator.defaultDecompose("halo semuanya")
    precondition(plain.count == 1, "default harusnya 1 tugas, dapet \(plain.count)")
    precondition(plain.first?.role == .coder, "default harusnya coder")
}

// MARK- AgentOrchestrator: orchestrasi dengan provider palsu

func testOrchestrationRun() async {
    let fake = FakeProvider()
    // Setiap spesialis mengembalikan teks jawaban (bukan tool use).
    fake.completeHandler = { request in
        let text = request.messages.last?.content.compactMap(\.text).joined() ?? ""
        return LLMResponse(
            assistantMessage: LLMMessage(role: .assistant, content: [.text("hasil spesialis untuk: \(text)")]),
            stopReason: .endTurn)
    }

    let orchestrator = AgentOrchestrator(provider: fake, executor: ToolExecutor())
    let result = await orchestrator.run(
        goal: "cari informasi tentang AI dan tulis laporan ringkas",
        model: "test-1")

    precondition(result.results.count >= 2, "harusnya ≥2 hasil spesialis, dapet \(result.results.count)")
    precondition(result.success, "harusnya berhasil")
    precondition(result.transcript.contains("researcher") || result.transcript.contains("coder") || result.transcript.contains("writer"),
                 "transcript harus menyebutkan peran: \(result.transcript)")
}

// MARK- CheckpointManager

func testCheckpointManager() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-phase13-checkpoint-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let mgr = CheckpointManager(directory: tmp)

    let task = AutonomousTask(
        id: "t1", goal: "uji checkpoin", status: .running,
        currentStepIndex: 1, createdAt: .now, updatedAt: .now, note: "catatan", source: "scheduler")
    let steps: [AutonomousStep] = [
        AutonomousStep(id: "s1", name: "echo", tool: "shell_run",
                       input: ["command": .string("echo halo")], status: .completed,
                       result: "halo", error: nil, attempts: 1, maxAttempts: 3),
    ]

    mgr.save(taskId: "t1", task: task, steps: steps)
    precondition(mgr.has(taskId: "t1"), "checkpoin harus ada setelah save")
    precondition(mgr.list().contains("t1"), "list harus mengandung t1")

    let loaded = mgr.load(taskId: "t1")
    precondition(loaded != nil, "load harus mengembalikan data")
    precondition(loaded?.task.id == "t1", "task id tidak cocok: \(loaded?.task.id ?? "nil")")
    precondition(loaded?.task.status == .running, "status harus running")
    precondition(loaded?.steps.count == 1, "harusnya 1 langkah, dapet \(loaded?.steps.count ?? -1)")
    precondition(loaded?.steps.first?.result == "halo", "hasil langkah harus 'halo'")

    mgr.delete(taskId: "t1")
    precondition(!mgr.has(taskId: "t1"), "checkpoin harus dihapus")
    precondition(mgr.list().isEmpty, "list harus kosong setelah hapus")

    // clearAll (isi dulu baru bersihkan)
    mgr.save(taskId: "t2", task: task, steps: steps)
    mgr.clearAll()
    precondition(mgr.list().isEmpty, "list harus kosong setelah clearAll")
}

// MARK- SelfCorrection

func testSelfCorrection() async {
    let fake = FakeProvider()
    // Saat diminta memperbaiki input alat yang gagal, kembalikan JSON input yang diperbaiki.
    fake.completeHandler = { request in
        let text = request.messages.last?.content.compactMap(\.text).joined() ?? ""
        if text.contains("Panggilan alat gagal") {
            let json = #"{"command":"echo diperbaiki"}"#
            return LLMResponse(
                assistantMessage: LLMMessage(role: .assistant, content: [.text(json)]),
                stopReason: .endTurn)
        }
        return LLMResponse(
            assistantMessage: LLMMessage(role: .assistant, content: [.text("jawab palsu")]),
            stopReason: .endTurn)
    }

    let step = AutonomousStep(
        id: "s1", name: "echo", tool: "shell_run",
        input: ["command": .string("echo salah")], status: .failed,
        result: nil, error: "command not found", attempts: 1, maxAttempts: 3)

    // Executor dengan kebijakan shell autopilot agar perbaikan tidak diblokir
    // oleh askOnce (defaultModes sudah diubah oleh AppState.init di tes sebelumnya).
    var modes = PolicyEngine.defaultModes
    modes[.shell] = .autopilot
    let executor = ToolExecutor(policy: PolicyEngine(modes: modes))

    let result = await SelfCorrection.shared.correct(
        step: step, error: "command not found",
        provider: fake, model: "test-1", executor: executor)

    precondition(!result.isError, "perbaikan harus berhasil, error: \(result.output)")
    precondition(result.output.contains("diperbaiki"), "output harus mengandung input yang diperbaiki, dapet: \(result.output)")
}
