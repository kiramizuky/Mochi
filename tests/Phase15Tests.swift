import Foundation

// MARK- Fase 13.5–13.7: Self-improving + Remote agent bridge

@main enum Phase15Tests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { _ = err.write((s + "\n").data(using: .utf8)!) }
        log("T1 feedback")
        testFeedbackLoopRecordAndLessons()
        log("T1 ok")
        log("T2 feedback-clear")
        testFeedbackLoopClear()
        log("T2 ok")
        log("T3 prompt-register")
        testPromptEvolverRegisterAndBest()
        log("T3 ok")
        log("T4 prompt-evolve")
        testPromptEvolverEvolveOnFailure()
        log("T4 ok")
        log("T5 prompt-healthy")
        testPromptEvolverNoEvolveWhenHealthy()
        log("T5 ok")
        log("T6 bridge-runtask")
        await testRemoteAgentBridgeRunTask()
        log("T6 ok")
        log("T7 bridge-report")
        await testRemoteAgentBridgeReportBadURL()
        log("T7 ok")
        log("Phase15Tests: all cases passed")
    }
}

// MARK- Test doubles

final class FakeProvider: LLMProvider, @unchecked Sendable {
    let id = "fake"
    let displayName = "Fake"
    let defaultModel = "test-1"
    let fallbackModels: [(id: String, label: String)] = [("test-1", "Test")]
    var configured = true
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

final class FakeRunner: @unchecked Sendable {
    var result: OrchestrationResult
    var receivedGoal: String?
    init(result: OrchestrationResult) { self.result = result }
    func run(goal: String, model: String) async -> OrchestrationResult {
        receivedGoal = goal
        return result
    }
}

// MARK- FeedbackLoop

func testFeedbackLoopRecordAndLessons() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-phase15-feedback-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = tmp.appendingPathComponent("feedback.json")
    let loop = FeedbackLoop(memory: MemoryService(url: tmp.appendingPathComponent("memory.json")),
                            audit: AuditLog(url: tmp.appendingPathComponent("audit.jsonl")),
                            url: url)

    loop.record(kind: .denial, target: "shell_run", original: "rm -rf /",
                corrected: "", lesson: "Jangan jalankan rm -rf di root.")
    loop.record(kind: .correction, target: "file_write", original: "salah.txt",
                corrected: "benar.txt", lesson: "Verifikasi path sebelum menulis.")

    precondition(loop.all().count == 2, "harusnya 2 entri, dapet \(loop.all().count)")
    let lessons = loop.lessons()
    precondition(lessons.count == 2, "harusnya 2 lesson, dapet \(lessons.count)")
    precondition(lessons.contains { $0.contains("shell_run") && $0.contains("rm -rf")},
                 "lesson shell_run hilang: \(lessons)")
    precondition(lessons.contains { $0.contains("file_write") && $0.contains("Verifikasi path")},
                 "lesson file_write hilang: \(lessons)")
}

func testFeedbackLoopClear() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-phase15-feedback-clear-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = tmp.appendingPathComponent("feedback.json")
    let loop = FeedbackLoop(memory: MemoryService(url: tmp.appendingPathComponent("memory.json")),
                            audit: AuditLog(url: tmp.appendingPathComponent("audit.jsonl")),
                            url: url)

    loop.record(kind: .denial, target: "x", original: "o", corrected: "c", lesson: "l")
    precondition(loop.all().count == 1, "harusnya 1 sebelum clear")
    loop.clear()
    precondition(loop.all().isEmpty, "harusnya kosong setelah clear")
}

// MARK- PromptEvolver

func testPromptEvolverRegisterAndBest() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-phase15-prompt-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = tmp.appendingPathComponent("prompt_versions.json")
    let evolver = PromptEvolver(url: url)

    let id = evolver.register(prompt: "Anda adalah asisten yang baik.")
    precondition(!id.isEmpty, "id versi tidak boleh kosong")
    precondition(evolver.count == 1, "harusnya 1 versi, dapet \(evolver.count)")

    evolver.recordOutcome(versionId: id, success: true)
    evolver.recordOutcome(versionId: id, success: true)
    evolver.recordOutcome(versionId: id, success: false)

    let best = evolver.currentBest()
    precondition(best?.id == id, "best harusnya versi terdaftar")
    precondition(best?.successCount == 2 && best?.failureCount == 1,
                 "skor salah: \(best?.successCount ?? -1)/\(best?.failureCount ?? -1)")
    precondition(best?.successRate == 2.0/3.0, "successRate harusnya 2/3")
}

func testPromptEvolverEvolveOnFailure() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-phase15-prompt-evolve-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = tmp.appendingPathComponent("prompt_versions.json")
    let evolver = PromptEvolver(url: url)

    let base = "Anda adalah asisten."
    let id = evolver.register(prompt: base)
    // 3 kali gagal, 0 sukses → failure rate 1.0 >= 0.5, trials 3 >= 3
    for _ in 0..<3 { evolver.recordOutcome(versionId: id, success: false) }

    let evolved = evolver.evolve(basePrompt: base)
    precondition(evolved != base, "harusnya evolusi menghasilkan prompt berbeda")
    precondition(evolved.contains("Self-evolved"), "harusnya tandai self-evolved: \(evolved)")
    precondition(evolver.count == 2, "harusnya 2 versi setelah evolusi, dapet \(evolver.count)")
}

func testPromptEvolverNoEvolveWhenHealthy() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-phase15-prompt-healthy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = tmp.appendingPathComponent("prompt_versions.json")
    let evolver = PromptEvolver(url: url)

    let base = "Anda adalah asisten yang sehat."
    let id = evolver.register(prompt: base)
    // 3 kali sukses, 0 gagal → failure rate 0, tidak perlu evolusi
    for _ in 0..<3 { evolver.recordOutcome(versionId: id, success: true) }

    let evolved = evolver.evolve(basePrompt: base)
    precondition(evolved == base, "tidak perlu evolusi saat sehat, dapet: \(evolved)")
    precondition(evolver.count == 1, "tidak boleh menambah versi saat sehat, dapet \(evolver.count)")
}

// MARK- RemoteAgentBridge

func testRemoteAgentBridgeRunTask() async {
    let expected = OrchestrationResult(
        transcript: "Hasil otonom: cari dan buka aplikasi.",
        results: [SpecialistResult(role: .researcher, goal: "cari AI",
                                  output: "Ditemukan 3 sumber.", isError: false)],
        success: true)
    let runner = FakeRunner(result: expected)
    let bridge = RemoteAgentBridge(runTask: { goal, model in await runner.run(goal: goal, model: model) })

    let result = await bridge.run(goal: "cari informasi tentang AI dan buka aplikasi",
                                      model: "test-1")
    precondition(result.success, "harusnya berhasil")
    precondition(result.transcript == expected.transcript, "transcript tidak cocok")
    precondition(runner.receivedGoal == "cari informasi tentang AI dan buka aplikasi",
                 "goal tidak diteruskan: \(runner.receivedGoal ?? "nil")")
}

func testRemoteAgentBridgeReportBadURL() async {
    let expected = OrchestrationResult(
        transcript: "Hasil.", results: [], success: true)
    let runner = FakeRunner(result: expected)
    let bridge = RemoteAgentBridge(runTask: { goal, model in await runner.run(goal: goal, model: model) })

    let ok = await bridge.runAndReport(goal: "coba", model: "test-1",
                                       to: URL(string: "http://127.0.0.1:1/report")!)
    precondition(!ok, "laporan ke URL yang tidak tersedia harus gagal")
}
