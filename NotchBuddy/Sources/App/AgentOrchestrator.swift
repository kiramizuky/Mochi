import Foundation

// MARK: - Agent roles (setiap agen spesialis punya system prompt + subset alat)

/// Peran agen spesialis dalam orkestrasi multi-agen.
enum AgentRole: String, Sendable, CaseIterable, Hashable {
    case coder       = "coder"
    case researcher  = "researcher"
    case operatorAgent = "operator"
    case writer      = "writer"
    case analyst     = "analyst"

    /// System prompt khusus peran — mengarah perilaku LLM untuk tugas tersebut.
    var systemPrompt: String {
        switch self {
        case .coder:
            return "Anda adalah agen programmer. Tulis, edit, dan baca file; jalankan perintah shell. Jawab dalam Bahasa Indonesia, singkat, dan gunakan alat yang tersedia."
        case .researcher:
            return "Anda adalah agen peneliti. Cari informasi di web, ambil halaman, dan ringkas temuan. Jawab dalam Bahasa Indonesia, sertakan sumber URL jika tersedia."
        case .operatorAgent:
            return "Anda adalah agen operator sistem. Buka/tutup aplikasi, jalankan perintah shell, dan daftarkan aplikasi yang berjalan. Jawab dalam Bahasa Indonesia."
        case .writer:
            return "Anda adalah agen penulis. Susun ulang informasi menjadi teks yang jelas dan terstruktur. Jawab dalam Bahasa Indonesia."
        case .analyst:
            return "Anda adalah agen analis. Kumpulkan data, hitung statistik, dan buat kesimpulan dari hasil penelitian. Jawab dalam Bahasa Indonesia."
        }
    }

    /// Nama-nama alat yang diizinkan untuk peran ini (dibatasi agar agen tidak melampaui wewenang).
    var allowedTools: [String] {
        switch self {
        case .coder:
            return ["file_read", "file_write", "shell_run", "node_file_system", "node_run_shell", "canvas_present_artifact"]
        case .researcher:
            return ["web_search", "web_fetch", "app_screenshot", "canvas_present_artifact"]
        case .operatorAgent:
            return [
                "app_open", "app_close", "app_list", "shell_run",
                "office_read_selection", "office_read_table", "office_write_text",
                "office_list_sheets", "office_read_sheet", "office_write_formatted", "office_replace_template",
                "screen_verify_goal", "memory_save_preference", "memory_vector_search",
                "playbook_list", "playbook_run", "canvas_present_artifact"
            ]
        case .writer:
            return ["office_write_formatted", "office_replace_template", "office_write_text", "memory_vector_search", "canvas_present_artifact"]
        case .analyst:
            return [
                "web_search", "web_fetch", "ax_read",
                "office_read_selection", "office_read_table", "office_list_sheets", "office_read_sheet",
                "screen_verify_goal", "memory_vector_search", "playbook_list", "playbook_run", "canvas_present_artifact"
            ]
        }
    }
}

/// Satu sub-tugas yang dipecahkan dari goal utama.
struct SubTask: Sendable, Equatable, Hashable {
    var id: String
    var goal: String
    var role: AgentRole
    var status: SubTaskStatus = .pending
    var result: String? = nil
    var error: String? = nil
}

enum SubTaskStatus: String, Sendable, Equatable {
    case pending, running, completed, failed
}

/// Hasil satu sub-tugas dari agen spesialis.
struct SpecialistResult: Sendable, Equatable {
    var role: AgentRole
    var goal: String
    var output: String
    var isError: Bool
}

/// Hasil orkestrasi keseluruhan.
struct OrchestrationResult: Sendable, Equatable {
    var transcript: String
    var results: [SpecialistResult]
    var success: Bool
    var artifact: CanvasArtifact?

    init(transcript: String, results: [SpecialistResult], success: Bool, artifact: CanvasArtifact? = nil) {
        self.transcript = transcript
        self.results = results
        self.success = success
        self.artifact = artifact
    }
}

/// Event orkestrasi untuk UI / logging.
enum OrchestratorEvent: Sendable, Equatable {
    case decomposition([SubTask])
    case specialistStarted(role: AgentRole, goal: String)
    case specialistFinished(role: AgentRole, goal: String, output: String, isError: Bool)
    case synthesized(String)
}

// MARK: - Agen orkestratur (dekomposisi goal → agen spesialis → sintesis)

/// Koordinasi sekelompok agen spesialis untuk menyelesaikan satu goal tinggi level
/// tanpa klik pengguna. Dekomposisi deterministic agar dapat diuji tanpa LLM;
/// eksekusi spesialis menggunakan AgentController + LLMProvider yang di-inject
/// via init (tes dapat menyuntik provider palsu).
final class AgentOrchestrator: @unchecked Sendable {
    static let shared = AgentOrchestrator(provider: AnthropicProvider(keyProvider: { KeychainStore.shared.get("anthropic-api-key") }),
                                          executor: ToolExecutor())

    let provider: any LLMProvider
    let executor: ToolExecutor

    private let messageBus = MessageBus.shared

    init(provider: any LLMProvider, executor: ToolExecutor = ToolExecutor()) {
        self.provider = provider
        self.executor = executor
    }

    /// Jalankan goal melalui agen spesialis.
    func run(
        goal: String,
        model: String,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void = { _ in }
    ) async -> OrchestrationResult {
        // Dekomposisi tugas secara dinamis via LLM (fallback ke heuristik jika gagal/offline)
        let tasks = await decomposeWithLLM(goal: goal, model: model)
        guard !tasks.isEmpty else {
            let empty = OrchestrationResult(
                transcript: "Tidak ada tugas yang bisa dipecahkan dari: \(goal)",
                results: [], success: false, artifact: nil)
            await onEvent(.synthesized(empty.transcript))
            return empty
        }

        await onEvent(.decomposition(tasks))
        await messageBus.publish(topic: MessageBus.Topic.taskDecomposed, payload: tasks)

        // Laporkan awal tugas Swarm di notch
        await MainActor.run {
            AppState.shared.activePlaybookProgress = "🐝 Swarm: Menjalankan \(tasks.count) sub-tugas..."
        }

        var results: [SpecialistResult] = []
        var allOk = true

        for (index, task) in tasks.enumerated() {
            await MainActor.run {
                if let idx = AppState.shared.autonomousTasks.firstIndex(where: { $0.id == task.id }) {
                    var t = AppState.shared.autonomousTasks[idx]
                    t.status = .running
                    t.updatedAt = .now
                    AppState.shared.autonomousTasks[idx] = t
                }
                AppState.shared.activePlaybookProgress = "🐝 Swarm [\(index + 1)/\(tasks.count)]: [\(task.role.rawValue.capitalized)] \(task.goal.prefix(32))..."
            }

            await onEvent(.specialistStarted(role: task.role, goal: task.goal))
            await messageBus.publish(topic: MessageBus.Topic.taskAssigned, payload: task)

            let output = await runSpecialist(role: task.role, goal: task.goal, model: model, prior: results)
            let isError = output == nil || output!.hasPrefix("ERROR:")
            let text = output ?? "Gagal menjalankan tugas melalui \(task.role.rawValue)."

            let result = SpecialistResult(role: task.role, goal: task.goal, output: text, isError: isError)
            results.append(result)
            if isError { allOk = false }

            await MainActor.run {
                if let idx = AppState.shared.autonomousTasks.firstIndex(where: { $0.id == task.id }) {
                    var t = AppState.shared.autonomousTasks[idx]
                    t.status = isError ? .failed : .completed
                    t.note = isError ? text : (text.isEmpty ? "selesai tanpa output" : text)
                    t.updatedAt = .now
                    AppState.shared.autonomousTasks[idx] = t
                }
            }

            await onEvent(.specialistFinished(role: task.role, goal: task.goal, output: text, isError: isError))
            await messageBus.publish(topic: isError ? MessageBus.Topic.taskFailed : MessageBus.Topic.taskCompleted, payload: result)
        }

        let synthesis = Self.synthesize(goal: goal, results: results)
        await onEvent(.synthesized(synthesis))
        await messageBus.publish(topic: MessageBus.Topic.synthesisReady, payload: synthesis)

        // Deteksi dan presentasikan Artifact ke Canvas Studio jika memenuhi kriteria
        var detectedArtifact: CanvasArtifact? = nil
        if let artifact = Self.detectArtifact(from: synthesis, goal: goal) {
            detectedArtifact = artifact
            await MainActor.run {
                CanvasManager.shared.present(artifact: artifact)
                AppState.shared.activePlaybookProgress = "Canvas: \(artifact.title)"
            }
        } else {
            await MainActor.run {
                AppState.shared.activePlaybookProgress = nil
            }
        }

        let transcript = results.map { "• [\($0.role.rawValue)] \($0.output)" }.joined(separator: "\n")
        return OrchestrationResult(
            transcript: synthesis.isEmpty ? transcript : synthesis,
            results: results,
            success: allOk,
            artifact: detectedArtifact
        )
    }

    // MARK: - Dynamic LLM Decomposer

    /// Memecah goal secara dinamis menggunakan LLM dengan format JSON terstruktur,
    /// dan otomatis fallback ke aturan heuristik jika LLM gagal atau offline.
    func decomposeWithLLM(goal: String, model: String = "") async -> [SubTask] {
        let chosenModel = model.isEmpty ? (UserDefaults.standard.string(forKey: "model") ?? provider.defaultModel) : model
        let systemPrompt = """
        Anda adalah Chief AI Swarm Orchestrator. Tugas Anda adalah menganalisis tujuan pengguna dan memecahnya menjadi 1 hingga 4 sub-tugas independen atau berurutan yang akan dikerjakan oleh tim agen spesialis.
        
        Peran spesialis yang tersedia:
        - researcher: Mencari informasi di internet, web scraping, riset referensi
        - analyst: Menganalisis data, kalkulasi, evaluasi tren, verifikasi hasil
        - coder: Menulis kode, membaca/mengubah file script, mengeksekusi shell
        - writer: Menulis laporan, menyusun dokumen rapi (Markdown/Word), merangkum konten
        - operator: Mengontrol aplikasi sistem macOS, automasi office/playbook

        Format balasan: Balas HANYA dalam format array JSON valid tanpa penjelasan tambahan dan tanpa markdown formatting:
        [
          {"role": "researcher", "goal": "cari informasi terkini tentang X"},
          {"role": "analyst", "goal": "analisis kelebihan dan kekurangan X"},
          {"role": "writer", "goal": "buat laporan eksekutif terstruktur"}
        ]
        """

        let request = LLMRequest(
            model: chosenModel,
            system: systemPrompt,
            messages: [LLMMessage(role: .user, content: [.text("Tujuan: \(goal)")])],
            maxTokens: 1024,
            temperature: 0.1
        )

        do {
            let response = try await provider.complete(request)
            if let parsed = Self.parseDecompositionJSON(response.text), !parsed.isEmpty {
                return parsed
            }
        } catch {
            // Jika LLM gagal/offline, fallback ke heuristik default
        }

        return Self.defaultDecompose(goal)
    }

    /// Ekstraksi dan parsing string JSON dari respons LLM menjadi array SubTask yang aman.
    static func parseDecompositionJSON(_ rawText: String) -> [SubTask]? {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let startRange = text.range(of: "["),
           let endRange = text.range(of: "]", options: .backwards),
           startRange.lowerBound < endRange.upperBound {
            text = String(text[startRange.lowerBound..<endRange.upperBound])
        }
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var tasks: [SubTask] = []
        for item in array {
            guard let roleStr = item["role"] as? String,
                  let taskGoal = item["goal"] as? String,
                  !taskGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let role = AgentRole(rawValue: roleStr.lowercased()) ?? .coder
            tasks.append(SubTask(id: UUID().uuidString, goal: taskGoal, role: role))
        }
        return tasks.isEmpty ? nil : tasks
    }

    // MARK: - Canvas Artifact Detection

    /// Menganalisis teks sintesis untuk mengenali diagram, tabel data, kode, atau dokumen terstruktur.
    static func detectArtifact(from text: String, goal: String) -> CanvasArtifact? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return nil }

        let cleanGoal = goal.replacingOccurrences(of: "\n", with: " ")
        let shortGoal = cleanGoal.count > 35 ? String(cleanGoal.prefix(35)) + "…" : cleanGoal

        // 1. Diagram (Mermaid / Graph)
        if trimmed.contains("```mermaid") || trimmed.contains("graph TD") || trimmed.contains("flowchart LR") || trimmed.contains("sequenceDiagram") {
            return CanvasArtifact(
                title: "Diagram: \(shortGoal)",
                type: .chart,
                content: trimmed
            )
        }

        // 2. Tabel Data (Markdown table syntax)
        if trimmed.contains("|") && trimmed.contains("---") {
            return CanvasArtifact(
                title: "Tabel: \(shortGoal)",
                type: .table,
                content: trimmed
            )
        }

        // 3. Kode / Skrip pemrograman
        if trimmed.contains("```swift") || trimmed.contains("```python") || trimmed.contains("```sh") ||
           trimmed.contains("```javascript") || trimmed.contains("```json") || (trimmed.hasPrefix("```") && trimmed.hasSuffix("```")) {
            return CanvasArtifact(
                title: "Kode: \(shortGoal)",
                type: .code,
                content: trimmed
            )
        }

        // 4. Dokumen Analisis / Laporan Terstruktur (Markdown heading, list panjang, atau multi-paragraf)
        let lines = trimmed.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if trimmed.contains("# ") || trimmed.contains("## ") || lines.count >= 4 {
            return CanvasArtifact(
                title: "Laporan: \(shortGoal)",
                type: .document,
                content: trimmed
            )
        }

        return nil
    }

    // MARK: - Default decomposer (heuristik berbasis kata kunci, deterministic)

    /// Pecah goal menjadi daftar SubTask dengan peran spesialis. Deterministik,
    /// tidak perlu LLM — dapat diuji langsung.
    static func defaultDecompose(_ goal: String) -> [SubTask] {
        let g = goal.lowercased()
        var tasks: [SubTask] = []

        func add(_ goalPart: String, _ role: AgentRole) {
            tasks.append(SubTask(id: UUID().uuidString, goal: goalPart, role: role))
        }

        if g.contains("cari") || g.contains("search") || g.contains("research") || g.contains("cari cara") {
            add("Cari informasi tentang: \(goal)", .researcher)
        }
        if g.contains("buka") || g.contains("open") || g.contains("launch") || g.contains("jalankan aplikasi") {
            add("Buka atau jalankan aplikasi terkait: \(goal)", .operatorAgent)
        }
        if g.contains("tulis") || g.contains("write") || g.contains("buat file") || g.contains("edit") {
            add("Tulis atau edit file terkait: \(goal)", .coder)
        }
        if g.contains("jalankan") || g.contains("run ") || g.contains("shell") || g.contains("perintah") {
            add("Jalankan perintah shell terkait: \(goal)", .operatorAgent)
        }
        if g.contains("ringkas") || g.contains("summarize") || g.contains("laporan") || g.contains("susun") {
            add("Ringkas dan susun hasil terkait: \(goal)", .writer)
        }
        if g.contains("analisis") || g.contains("analyze") || g.contains("statistik") || g.contains("data") {
            add("Analisis data terkait: \(goal)", .analyst)
        }

        if tasks.isEmpty {
            add(goal, .coder)
        }
        return tasks
    }

    // MARK: - Default specialist runner (AgentController + LLMProvider instance)

    func runSpecialist(role: AgentRole, goal: String, model: String = "", prior: [SpecialistResult] = []) async -> String? {
        let chosenModel = model.isEmpty ? (UserDefaults.standard.string(forKey: "model") ?? "claude-sonnet-4-6") : model
        let context = prior.map { "• [\($0.role.rawValue)] \($0.output)" }.joined(separator: "\n")
        let fullGoal = context.isEmpty ? goal : "Konteks hasil sebelumnya:\n\(context)\n\nTugas saat ini: \(goal)"

        let system = role.systemPrompt + "\nAlat yang diizinkan: \(role.allowedTools.isEmpty ? "tidak ada" : role.allowedTools.joined(separator: ", "))."
        let controller = AgentController(
            provider: provider,
            system: system,
            executor: executor,
            tools: ToolExecutor.tools.filter { def in role.allowedTools.contains(def.name) },
            enableWebSearch: false
        )

        let history: [LLMMessage] = [
            LLMMessage(role: .user, content: [.text(fullGoal)])
        ]

        do {
            let outcome = try await controller.run(
                history: history,
                model: chosenModel,
                onEvent: { _ in }
            )
            return outcome.transcript.isEmpty ? nil : outcome.transcript
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    // MARK: - Sintesis

    private static func synthesize(goal: String, results: [SpecialistResult]) -> String {
        let ok = results.filter { !$0.isError }
        let err = results.filter { $0.isError }
        var parts: [String] = []
        if !ok.isEmpty {
            parts.append("Hasil untuk \"\(goal)\":")
            parts.append(contentsOf: ok.map { "• \($0.output)" })
        }
        if !err.isEmpty {
            parts.append("Beberapa tugas gagal:")
            parts.append(contentsOf: err.map { "✗ [\($0.role.rawValue)] \($0.output)" })
        }
        return parts.joined(separator: "\n")
    }
}
