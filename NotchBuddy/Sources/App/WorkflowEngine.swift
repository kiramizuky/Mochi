import Foundation

// MARK: - Mesin alur kerja otonom (plan → execute → verify)

/// Hasil eksekusi satu langkah.
struct StepResult: Equatable, Sendable {
    var ok: Bool
    var output: String
    var error: String?
}

/// Mesin alur kerja: merencanakan tujuan tinggi level menjadi langkah-langkah tool,
/// mengeksekusinya melalui ToolExecutor (PolicyEngine + AuditLog tetap berlaku),
/// memverifikasi hasil, dan mencoba ulang hingga 3× dengan backoff.
final class WorkflowEngine: @unchecked Sendable {
    static let shared = WorkflowEngine()
    private init() {}

    private let executor = ToolExecutor()
    private let maxAttempts = 3

    /// Rencana langkah dari tujuan (heuristik berbasis kata kunci, deterministic
    /// agar dapat diuji tanpa LLM).
    func plan(goal: String) -> [AutonomousStep] {
        let g = goal.lowercased()
        var steps: [AutonomousStep] = []

        // Tangkap pola umum: "cari X lalu buka Y", "buka X", "tulis file", "jalankan cmd".
        if g.contains("cari") || g.contains("search") || g.contains("cari cara") {
            steps.append(AutonomousStep(
                id: UUID().uuidString,
                name: "web_search",
                tool: "web_search",
                input: ["query": .string(goal)]
            ))
        }
        if g.contains("buka") || g.contains("open") || g.contains("launch") {
            let target = extractTarget(goal)
            if !target.isEmpty {
                steps.append(AutonomousStep(
                    id: UUID().uuidString,
                    name: "app_open",
                    tool: "app_open",
                    input: ["target": .string(target)]
                ))
            }
        }
        if g.contains("tulis") || g.contains("write") || g.contains("buat file") {
            let path = extractPath(goal)
            let content = extractContent(goal)
            if !path.isEmpty {
                steps.append(AutonomousStep(
                    id: UUID().uuidString,
                    name: "file_write",
                    tool: "file_write",
                    input: ["path": .string(path), "content": .string(content)]
                ))
            }
        }
        if g.contains("jalankan") || g.contains("run") || g.contains("exec") || g.contains("shell") {
            let cmd = extractCommand(goal)
            if !cmd.isEmpty {
                steps.append(AutonomousStep(
                    id: UUID().uuidString,
                    name: "shell_run",
                    tool: "shell_run",
                    input: ["command": .string(cmd)]
                ))
            }
        }
        // Default: shell_run dengan goal sebagai perintah jika tidak ada pola lain.
        if steps.isEmpty {
            steps.append(AutonomousStep(
                id: UUID().uuidString,
                name: "shell_run",
                tool: "shell_run",
                input: ["command": .string(goal)]
            ))
        }
        return steps
    }

    /// Merencanakan langkah otonom secara cerdas menggunakan LLM.
    /// Memanfaatkan deskripsi alat di ToolExecutor untuk menyusun urutan langkah terstruktur (DAG linear).
    /// Jika LLM gagal, provider tidak terkonfigurasi, atau response kosong, otomatis fallback ke plan(goal:) deterministik.
    func planAutonomous(
        goal: String,
        provider: (any LLMProvider)? = nil,
        model: String? = nil
    ) async -> [AutonomousStep] {
        let activeProvider = provider ?? ProviderRegistry.shared.activeProvider
        let activeModel = model ?? (UserDefaults.standard.string(forKey: "model") ?? activeProvider.defaultModel)

        guard activeProvider.isConfigured() else {
            return plan(goal: goal)
        }

        let toolsSummary = ToolExecutor.tools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        let plannerSystem = """
        Anda adalah Autonomous Task Planner untuk asisten sistem operasi macOS (Mochi/JARVIS).
        Tugas Anda adalah memecah TUJUAN pengguna menjadi rangkaian langkah tindakan alat yang terstruktur dan aman.

        Daftar alat yang tersedia:
        \(toolsSummary)

        Aturan:
        1. Kembalikan HANYA array JSON valid tanpa penjelasan teks lain dan tanpa formatting markdown (tanpa ```json).
        2. Format tiap elemen:
           {
             "name": "Deskripsi singkat langkah (Bahasa Indonesia)",
             "tool": "nama_alat_persis",
             "input": { ... parameter sesuai skema alat ... }
           }
        3. Pastikan properti "tool" benar-benar cocok dengan salah satu nama alat di atas.
        4. Jika tugas membutuhkan pencarian informasi sebelum aksi, urutkan langkah dengan benar (misal web_search lalu file_write).
        5. Contoh:
           [
             {"name": "Cari informasi di web", "tool": "web_search", "input": {"query": "jadwal peluncuran roket"}},
             {"name": "Simpan hasil ke catatan", "tool": "file_write", "input": {"path": "~/Desktop/jadwal.txt", "content": "..."}}
           ]
        """

        let request = LLMRequest(
            model: activeModel,
            system: plannerSystem,
            messages: [
                LLMMessage(role: .user, content: [.text("Tujuan yang ingin dicapai: \(goal)")])
            ],
            maxTokens: 2048,
            tools: []
        )

        do {
            let response = try await activeProvider.complete(request)
            var raw = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Ekstrak isi JSON jika model membungkus dengan markdown
            if raw.contains("```") {
                let parts = raw.components(separatedBy: "```")
                for part in parts {
                    var candidate = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.hasPrefix("json") {
                        candidate = String(candidate.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if candidate.hasPrefix("[") && candidate.hasSuffix("]") {
                        raw = candidate
                        break
                    }
                }
            }

            guard let data = raw.data(using: .utf8),
                  let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !jsonArray.isEmpty else {
                return plan(goal: goal)
            }

            let validToolNames = Set(ToolExecutor.tools.map { $0.name })
            var steps: [AutonomousStep] = []

            for dict in jsonArray {
                guard let tool = dict["tool"] as? String, validToolNames.contains(tool) else {
                    continue
                }
                let name = (dict["name"] as? String) ?? tool
                let rawInput = (dict["input"] as? [String: Any]) ?? [:]
                let inputValues = rawInput.mapValues { JSONValue(any: $0) }

                steps.append(AutonomousStep(
                    id: UUID().uuidString,
                    name: name,
                    tool: tool,
                    input: inputValues
                ))
            }

            return steps.isEmpty ? plan(goal: goal) : steps
        } catch {
            return plan(goal: goal)
        }
    }

    /// Eksekusi satu langkah melalui ToolExecutor. Hard floor & PolicyEngine tetap berlaku.
    /// Dilengkapi perbaikan mandiri (Self-Correction) jika eksekusi menghasilkan error.
    func execute(
        _ step: AutonomousStep,
        provider: (any LLMProvider)? = nil,
        model: String? = nil
    ) async -> StepResult {
        var attempt = step.attempts
        var last: ToolResult? = nil
        var currentStep = step

        let activeProvider = provider ?? ProviderRegistry.shared.activeProvider
        let activeModel = model ?? (UserDefaults.standard.string(forKey: "model") ?? activeProvider.defaultModel)

        while attempt < step.maxAttempts {
            attempt += 1
            last = await executor.execute(name: currentStep.tool, input: .object(currentStep.input))
            if let res = last, !res.isError {
                return StepResult(ok: true, output: res.output, error: nil)
            }

            // Jika error dan masih ada percobaan tersisa, coba perbaiki input via SelfCorrection
            if attempt < step.maxAttempts && activeProvider.isConfigured() {
                let errMessage = last?.output ?? "Unknown error"
                let corrected = await SelfCorrection.shared.correct(
                    step: currentStep,
                    error: errMessage,
                    provider: activeProvider,
                    model: activeModel,
                    executor: executor
                )
                if !corrected.isError {
                    return StepResult(ok: true, output: corrected.output, error: nil)
                }
                last = corrected
            }

            // Backoff singkat antar percobaan.
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return StepResult(ok: false, output: last?.output ?? "", error: last?.isError == true ? last!.output : "unknown error")
    }

    /// Verifikasi hasil langkah (self-check sederhana: output tidak kosong dan tidak error).
    func verify(_ result: StepResult) -> Bool {
        return result.ok && !result.output.isEmpty
    }

    /// Jalankan seluruh rencana: per langkah execute → verify, retry otomatis & self-correction.
    /// Hentikan pada langkah pertama yang gagal setelah semua percobaan habis.
    func run(
        steps: [AutonomousStep],
        provider: (any LLMProvider)? = nil,
        model: String? = nil,
        onStepProgress: (@Sendable (Int, AutonomousStep, StepResult) async -> Void)? = nil
    ) async -> [StepResult] {
        var results: [StepResult] = []
        for (index, step) in steps.enumerated() {
            var activeStep = step
            activeStep.status = .running
            let result = await execute(activeStep, provider: provider, model: model)
            activeStep.status = result.ok ? .completed : .failed
            activeStep.result = result.output
            activeStep.error = result.error
            results.append(result)

            if let onStepProgress {
                await onStepProgress(index, activeStep, result)
            }

            if !verify(result) { break }
        }
        return results
    }

    // MARK: - Ekstraksi parameter dari teks goal (heuristik)

    private func extractTarget(_ goal: String) -> String {
        // Ambil kata setelah "buka"/"open"/"launch" hingga akhir kalimat.
        let markers = ["buka ", "open ", "launch "]
        for m in markers {
            if let range = goal.lowercased().range(of: m) {
                let after = String(goal[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let endIdx = after.firstIndex { ".,;!?".contains($0) }
                if let endIdx {
                    return String(after[..<endIdx]).trimmingCharacters(in: .whitespaces)
                }
                return after.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func extractPath(_ goal: String) -> String {
        // Pola sederhana: "ke /path/file" atau path dengan "/".
        let scanner = goal.components(separatedBy: " ")
        for token in scanner {
            if token.contains("/") || token.hasPrefix("~") {
                return token.trimmingCharacters(in: .punctuationCharacters)
            }
        }
        return ""
    }

    private func extractContent(_ goal: String) -> String {
        // Ambil teks setelah "dengan isi"/"content"/":".
        for m in ["dengan isi ", "content ", ": "] {
            if let range = goal.lowercased().range(of: m) {
                return String(goal[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func extractCommand(_ goal: String) -> String {
        // Ambil teks setelah "jalankan"/"run"/"exec"/"shell".
        let markers = ["jalankan ", "run ", "exec ", "shell "]
        for m in markers {
            if let range = goal.lowercased().range(of: m) {
                return String(goal[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
