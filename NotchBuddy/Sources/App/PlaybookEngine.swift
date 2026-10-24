import Foundation

// MARK: - Playbook Step
struct PlaybookStep: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var description: String
    var role: AgentRole
    var toolName: String?
    var toolInput: [String: String] = [:]
    var promptTemplate: String? = nil
    var isDestructive: Bool = false
}

// MARK: - Job Playbook (SOP & Structured Workflow)
struct JobPlaybook: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var description: String
    var category: String
    var steps: [PlaybookStep]
}

// MARK: - Playbook Execution Result
struct PlaybookStepResult: Sendable, Equatable {
    var stepId: String
    var title: String
    var output: String
    var isSuccess: Bool
}

struct PlaybookExecutionResult: Sendable, Equatable {
    var playbookId: String
    var playbookName: String
    var isSuccess: Bool
    var summary: String
    var stepResults: [PlaybookStepResult]
}

// MARK: - Playbook Engine
final class PlaybookEngine: @unchecked Sendable {
    static let shared = PlaybookEngine()

    private let lock = NSLock()
    private var customPlaybooks: [JobPlaybook] = []

    private init() {}

    // MARK: - Built-in Presets

    var allPlaybooks: [JobPlaybook] {
        lock.withLock {
            [
                Self.rekapOfficePlaybook,
                Self.auditDownloadsPlaybook,
                Self.researchTrendsPlaybook,
            ] + customPlaybooks
        }
    }

    static let rekapOfficePlaybook = JobPlaybook(
        id: "rekap_office",
        name: "Rekap Data Dokumen Office",
        description: "Membaca tabel dari Excel aktif, menganalisis statistik agregat, dan menuliskan ringkasan ke Word/dokumen teks.",
        category: "Office",
        steps: [
            PlaybookStep(
                id: "read_excel",
                title: "Baca Tabel Excel Aktif",
                description: "Mengambil data tabel dan cell yang sedang terbuka di Microsoft Excel.",
                role: .operatorAgent,
                toolName: "office_read_table",
                toolInput: [:]
            ),
            PlaybookStep(
                id: "analyze_data",
                title: "Analisis Agregat & Tren",
                description: "Menghitung total, rata-rata, dan anomali utama dari data.",
                role: .analyst,
                promptTemplate: "Analisis data tabel berikut secara ringkas dan profesional: {read_excel}"
            ),
            PlaybookStep(
                id: "write_summary",
                title: "Tuliskan Ringkasan ke Dokumen",
                description: "Menuliskan laporan hasil analisa ke aplikasi pengolah kata atau text editor aktif.",
                role: .operatorAgent,
                toolName: "office_write_text",
                toolInput: ["text": "{analyze_data}"]
            )
        ]
    )

    static let auditDownloadsPlaybook = JobPlaybook(
        id: "audit_downloads",
        name: "Audit & Organisasi Folder Downloads",
        description: "Memeriksa file di ~/Downloads dan mengelompokkannya secara terstruktur.",
        category: "System",
        steps: [
            PlaybookStep(
                id: "scan_downloads",
                title: "Pindai File Downloads",
                description: "Melihat daftar file yang ada di direktori Downloads.",
                role: .operatorAgent,
                toolName: "shell_run",
                toolInput: ["command": "ls -l ~/Downloads | tail -n 25"]
            ),
            PlaybookStep(
                id: "plan_organization",
                title: "Rencanakan Pengelompokan",
                description: "Menentukan kategori file (Dokumen, Gambar, Installer, Arsip).",
                role: .analyst,
                promptTemplate: "Rencanakan pengelompokan rapi untuk file berikut: {scan_downloads}"
            )
        ]
    )

    static let researchTrendsPlaybook = JobPlaybook(
        id: "research_trends",
        name: "Riset Tren Web & Ekstraksi Eksekutif",
        description: "Melakukan penelusuran topik di internet dan menyusun executive summary berpoin.",
        category: "Research",
        steps: [
            PlaybookStep(
                id: "search_topic",
                title: "Penelusuran Web",
                description: "Mencari sumber berita dan artikel terkait topik yang diminta.",
                role: .researcher,
                toolName: "web_search",
                toolInput: ["query": "{topic}"]
            ),
            PlaybookStep(
                id: "synthesize_report",
                title: "Susun Laporan Eksekutif",
                description: "Merangkum poin penting menjadi ringkasan yang jelas dan bernilai tinggi.",
                role: .writer,
                promptTemplate: "Berdasarkan hasil penelusuran ini: {search_topic}, buat ringkasan eksekutif berpoin dalam Bahasa Indonesia yang profesional."
            )
        ]
    )

    // MARK: - Execute Playbook

    func run(playbookId: String, context: [String: String], toolExecutor: ToolExecutor) async -> PlaybookExecutionResult {
        guard let pb = allPlaybooks.first(where: { $0.id == playbookId }) else {
            return PlaybookExecutionResult(
                playbookId: playbookId,
                playbookName: "Unknown",
                isSuccess: false,
                summary: "Playbook dengan ID '\(playbookId)' tidak ditemukan.",
                stepResults: []
            )
        }

        var outputs: [String: String] = context
        var results: [PlaybookStepResult] = []

        for (idx, step) in pb.steps.enumerated() {
            let progressStr = "[\(idx + 1)/\(pb.steps.count)] \(step.title)"
            await MainActor.run {
                AppState.shared.activePlaybookProgress = "\(pb.name): \(progressStr)"
                AppState.shared.stateOverride = .working
            }

            var stepOutput = ""
            var success = true

            if let tool = step.toolName {
                var resolvedInput: [String: JSONValue] = [:]
                for (k, v) in step.toolInput {
                    var resolvedV = v
                    for (outKey, outVal) in outputs {
                        resolvedV = resolvedV.replacingOccurrences(of: "{\(outKey)}", with: outVal)
                    }
                    resolvedInput[k] = .string(resolvedV)
                }

                let toolRes = await toolExecutor.execute(name: tool, input: .object(resolvedInput))
                stepOutput = toolRes.output
                success = !toolRes.isError
            } else if let promptTpl = step.promptTemplate {
                var resolvedPrompt = promptTpl
                for (outKey, outVal) in outputs {
                    resolvedPrompt = resolvedPrompt.replacingOccurrences(of: "{\(outKey)}", with: outVal)
                }

                let specialistOut = await AgentOrchestrator.shared.runSpecialist(role: step.role, goal: resolvedPrompt)
                let text = specialistOut ?? "Gagal menjalankan tugas spesialis \(step.role.rawValue)"
                stepOutput = text
                success = specialistOut != nil && !text.hasPrefix("ERROR:")
            }

            outputs[step.id] = stepOutput
            results.append(PlaybookStepResult(stepId: step.id, title: step.title, output: stepOutput, isSuccess: success))

            if !success {
                break
            }
        }

        let allOk = results.allSatisfy { $0.isSuccess } && results.count == pb.steps.count
        let finalSummary = allOk
            ? "✓ Playbook '\(pb.name)' berhasil diselesaikan (\(results.count) langkah)."
            : "⚠️ Playbook '\(pb.name)' terhenti pada langkah: \(results.last?.title ?? "N/A")."

        await MainActor.run {
            AppState.shared.activePlaybookProgress = nil
            AppState.shared.stateOverride = nil

            if allOk, let lastOutput = results.last?.output, !lastOutput.isEmpty {
                let artifactType: ArtifactType = pb.id.contains("office") ? .table : .document
                let artifact = CanvasArtifact(
                    title: "Hasil \(pb.name)",
                    type: artifactType,
                    content: lastOutput
                )
                CanvasManager.shared.present(artifact: artifact)
            }
        }

        return PlaybookExecutionResult(
            playbookId: pb.id,
            playbookName: pb.name,
            isSuccess: allOk,
            summary: finalSummary,
            stepResults: results
        )
    }

    func register(playbook: JobPlaybook) {
        lock.withLock {
            customPlaybooks.removeAll { $0.id == playbook.id }
            customPlaybooks.append(playbook)
        }
    }
}
