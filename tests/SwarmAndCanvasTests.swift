import Foundation

// MARK: - Fake Swarm LLM Provider untuk Pengujian End-to-End

private final class FakeSwarmLLMProvider: LLMProvider, @unchecked Sendable {
    let id: String = "fake-swarm"
    let displayName: String = "Fake Swarm LLM"
    let defaultModel: String = "fake-model"
    let fallbackModels: [(id: String, label: String)] = [("fake-model", "Fake Model")]

    var callCount = 0

    func isConfigured() -> Bool { true }
    func listModels() async -> [(id: String, label: String)] { fallbackModels }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        callCount += 1

        // Jika request sistem adalah Chief AI Swarm Orchestrator, kembalikan JSON dekomposisi
        if request.system.contains("Chief AI Swarm Orchestrator") {
            let json = """
            [
              {"role": "researcher", "goal": "Cari data perbandingan database"},
              {"role": "writer", "goal": "Susun tabel komparasi"}
            ]
            """
            return LLMResponse(
                assistantMessage: LLMMessage(role: .assistant, content: [.text(json)]),
                stopReason: .endTurn
            )
        }

        // Jika peran adalah writer, kembalikan tabel markdown
        if request.system.contains("agen penulis") {
            let tableOutput = """
            # Hasil Analisis Database
            Berikut adalah perbandingan performa:

            | Database | Kecepatan | Ukuran File |
            | --- | --- | --- |
            | SQLite | 120 ms | 2.4 MB |
            | DuckDB | 45 ms | 5.1 MB |
            """
            return LLMResponse(
                assistantMessage: LLMMessage(role: .assistant, content: [.text(tableOutput)]),
                stopReason: .endTurn
            )
        }

        // Respon default untuk researcher
        let defaultText = "Ditemukan 2 kandidat utama: SQLite dan DuckDB dengan dokumentasi lengkap."
        return LLMResponse(
            assistantMessage: LLMMessage(role: .assistant, content: [.text(defaultText)]),
            stopReason: .endTurn
        )
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let resp = try await self.complete(request)
                    continuation.yield(.textDelta(resp.text))
                    continuation.yield(.completed(resp))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Unit Tests

@main
struct SwarmAndCanvasTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { _ = err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan SwarmAndCanvasTests...")

        // T1: Pure JSON Decomposition Parsing
        log("T1: testJSONDecompositionParsingPure")
        testJSONDecompositionParsingPure()
        log("T1 OK ✅")

        // T2: Markdown Wrapped JSON Decomposition Parsing
        log("T2: testJSONDecompositionParsingWithMarkdownCodeBlock")
        testJSONDecompositionParsingWithMarkdownCodeBlock()
        log("T2 OK ✅")

        // T3: Invalid JSON Decomposition Parsing Fallback
        log("T3: testJSONDecompositionParsingInvalidFallback")
        testJSONDecompositionParsingInvalidFallback()
        log("T3 OK ✅")

        // T4: Artifact Detection Types
        log("T4: testArtifactDetectionTypes")
        testArtifactDetectionTypes()
        log("T4 OK ✅")

        // T5: AutonomousAgent ShouldUseSwarm Keywords
        log("T5: testAutonomousAgentShouldUseSwarm")
        testAutonomousAgentShouldUseSwarm()
        log("T5 OK ✅")

        // T6: End-to-End Fake LLM Swarm Orchestration with Canvas Presentation
        log("T6: testSwarmOrchestrationWithFakeLLM")
        await testSwarmOrchestrationWithFakeLLM()
        log("T6 OK ✅")

        log("🎉 SEMUA TEST Swarm & Canvas Artifacts LULUS DENGAN SUKSES!")
    }

    // MARK: - Test Cases

    static func testJSONDecompositionParsingPure() {
        let json = """
        [
          {"role": "researcher", "goal": "Cari data perbandingan Swift vs Rust"},
          {"role": "analyst", "goal": "Hitung performa dan efisiensi memori"},
          {"role": "writer", "goal": "Buat laporan eksekutif lengkap"}
        ]
        """
        let tasks = AgentOrchestrator.parseDecompositionJSON(json)
        assert(tasks != nil, "Parsing JSON murni gagal")
        assert(tasks?.count == 3, "Harus menghasilkan 3 subtask, dapat: \(tasks?.count ?? 0)")
        assert(tasks?[0].role == .researcher, "Task 1 harus researcher")
        assert(tasks?[1].role == .analyst, "Task 2 harus analyst")
        assert(tasks?[2].role == .writer, "Task 3 harus writer")
        assert(tasks?[0].goal == "Cari data perbandingan Swift vs Rust", "Goal task 1 tidak cocok")
    }

    static func testJSONDecompositionParsingWithMarkdownCodeBlock() {
        let responseWithMarkdown = """
        Tentu, ini adalah dekomposisi tugas yang saya rencanakan:
        ```json
        [
          {"role": "coder", "goal": "Tulis script benchmark disk I/O"},
          {"role": "operator", "goal": "Jalankan script di terminal dan tangkap log"}
        ]
        ```
        Tim spesialis siap memulai eksekusi.
        """
        let tasks = AgentOrchestrator.parseDecompositionJSON(responseWithMarkdown)
        assert(tasks != nil, "Parsing markdown-wrapped JSON gagal")
        assert(tasks?.count == 2, "Harus menghasilkan 2 subtask, dapat: \(tasks?.count ?? 0)")
        assert(tasks?[0].role == .coder, "Task 1 harus coder")
        assert(tasks?[1].role == .operatorAgent, "Task 2 harus operator")
    }

    static func testJSONDecompositionParsingInvalidFallback() {
        let invalidJSON = "Maaf, saya tidak bisa memecah tugas ini menjadi JSON."
        let tasks = AgentOrchestrator.parseDecompositionJSON(invalidJSON)
        assert(tasks == nil, "JSON tidak valid harus menghasilkan nil")

        let emptyArray = "[]"
        let emptyTasks = AgentOrchestrator.parseDecompositionJSON(emptyArray)
        assert(emptyTasks == nil, "Array JSON kosong harus menghasilkan nil")
    }

    static func testArtifactDetectionTypes() {
        let goal = "Analisis dan Visualisasi Performa"

        // 1. Table Detection
        let tableText = """
        Berikut adalah ringkasan performa sistem:
        | Fitur | CPU (%) | Memori |
        | --- | --- | --- |
        | Notch Idle | 0.0% | 42 MB |
        | Voice Active | 2.1% | 58 MB |
        """
        let tableArtifact = AgentOrchestrator.detectArtifact(from: tableText, goal: goal)
        assert(tableArtifact != nil, "Tabel markdown harus terdeteksi")
        assert(tableArtifact?.type == .table, "Tipe harus .table, dapat: \(String(describing: tableArtifact?.type))")

        // 2. Chart / Mermaid Detection
        let chartText = """
        ```mermaid
        flowchart TD
            A[Perception] --> B(Intent Router)
            B --> C{Execution Tier}
            C --> D[Edge SLM]
            C --> E[Cloud LLM]
        ```
        """
        let chartArtifact = AgentOrchestrator.detectArtifact(from: chartText, goal: goal)
        assert(chartArtifact != nil, "Diagram mermaid harus terdeteksi")
        assert(chartArtifact?.type == .chart, "Tipe harus .chart, dapat: \(String(describing: chartArtifact?.type))")

        // 3. Code Detection
        let codeText = """
        ```swift
        import SwiftUI

        struct CompanionView: View {
            var body: some View {
                Text("Coucou Super Autonomous")
            }
        }
        ```
        """
        let codeArtifact = AgentOrchestrator.detectArtifact(from: codeText, goal: goal)
        assert(codeArtifact != nil, "Kode script harus terdeteksi")
        assert(codeArtifact?.type == .code, "Tipe harus .code, dapat: \(String(describing: codeArtifact?.type))")

        // 4. Document Detection
        let docText = """
        # Laporan Riset Multi-Agen Coucou
        ## Ringkasan Eksekutif
        Sistem otonom Coucou telah berhasil ditingkatkan ke JARVIS-level.
        Berikut adalah poin-poin utama pengembangan:
        - Pemantau clipboard pasif zero-overhead.
        - Deteksi dan klasifikasi berkas otomatis.
        - Orkestrasi multi-agen swarm dan integrasi Canvas Studio.
        """
        let docArtifact = AgentOrchestrator.detectArtifact(from: docText, goal: goal)
        assert(docArtifact != nil, "Dokumen terstruktur harus terdeteksi")
        assert(docArtifact?.type == .document, "Tipe harus .document, dapat: \(String(describing: docArtifact?.type))")

        // 5. Short Plain Text -> Nil
        let plainText = "Halo, selamat pagi!"
        let plainArtifact = AgentOrchestrator.detectArtifact(from: plainText, goal: goal)
        assert(plainArtifact == nil, "Teks pendek tanpa struktur tidak boleh menjadi artifact")
    }

    static func testAutonomousAgentShouldUseSwarm() {
        let swarmGoals = [
            "Tolong jalankan swarm untuk riset dan analisis framework Swift",
            "Gunakan tim agen untuk investigasi dan tulis dokumen perbandingan",
            "Bandingkan dan susun laporan performa database",
            "Lakukan studi pasar tentang asisten AI otonom"
        ]
        for g in swarmGoals {
            assert(AutonomousAgent.shouldUseSwarm(for: g), "Harus mengenali '\(g)' sebagai tugas swarm")
        }

        let nonSwarmGoals = [
            "Buka aplikasi Safari",
            "Mute volume suara",
            "Ambil screenshot layar",
            "Rapikan file di desktop"
        ]
        for g in nonSwarmGoals {
            assert(!AutonomousAgent.shouldUseSwarm(for: g), "Tidak boleh mendeteksi '\(g)' sebagai swarm")
        }
    }

    static func testSwarmOrchestrationWithFakeLLM() async {
        let fakeProvider = FakeSwarmLLMProvider()
        let orchestrator = AgentOrchestrator(provider: fakeProvider)

        let result = await orchestrator.run(goal: "Bandingkan SQLite vs DuckDB", model: "fake-model")

        assert(result.success, "Orchestration harus sukses")
        assert(result.results.count == 2, "Harus mengeksekusi 2 subtask spesialis, dapat: \(result.results.count)")
        assert(result.artifact != nil, "Harus menghasilkan CanvasArtifact otomatis")
        assert(result.artifact?.type == .table, "Artifact harus berupa tabel data karena mengandung tabel markdown")
        assert(result.artifact?.title.contains("Tabel:") == true, "Judul artifact harus berawalan Tabel:")
    }
}

