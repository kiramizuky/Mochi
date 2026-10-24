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

    /// Eksekusi satu langkah melalui ToolExecutor. Hard floor & PolicyEngine tetap berlaku.
    func execute(_ step: AutonomousStep) async -> StepResult {
        var attempt = step.attempts
        var last: ToolResult? = nil
        while attempt < step.maxAttempts {
            attempt += 1
            last = await executor.execute(name: step.tool, input: .object(step.input))
            if !last!.isError {
                return StepResult(ok: true, output: last!.output, error: nil)
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

    /// Jalankan seluruh rencana: per langkah execute → verify, retry otomatis.
    /// Hentikan pada langkah pertama yang gagal setelah semua percobaan habis.
    func run(steps: [AutonomousStep]) async -> [StepResult] {
        var results: [StepResult] = []
        for step in steps {
            let result = await execute(step)
            results.append(result)
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
