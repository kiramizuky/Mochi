import Foundation

// MARK: - Agen otonom (loop otomatis tanpa klik)

/// Agen otonom: terima tujuan dari chip proaktif / jadwal / perintah suara,
/// buat rencana via WorkflowEngine, eksekusi, dan laporkan hasil ke chat island.
final class AutonomousAgent: @unchecked Sendable {
    static let shared = AutonomousAgent()
    private init() {}

    private let engine = WorkflowEngine.shared
    private var runningTaskId: String? = nil
    private let lockQueue = DispatchQueue(label: "autonomous.agent")

    /// Apakah mode otonom aktif (diaktifkan via onboarding / Settings).
    var enabled: Bool {
        MainActor.assumeIsolated { AppState.shared.autonomousEnabled }
    }

    /// Terima tujuan baru. Jika ada tugas yang sedang berjalan, ditolak.
    func submit(goal: String, source: String = "user") async -> String {
        guard enabled else {
            // Mode otonom mati: abaikan diam-diam.
            return ""
        }
        let taskId: String? = lockQueue.sync {
            guard runningTaskId == nil else { return nil }
            let id = UUID().uuidString
            runningTaskId = id
            return id
        }
        guard let taskId else { return "" }

        let task = AutonomousTask(
            id: taskId,
            goal: goal,
            createdAt: .now,
            source: source
        )
        // Catat kebiasaan agar HabitLearner bisa mendeteksi rutinitas pengguna.
        ProactiveEngine.shared.recordHabit(action: goal, category: source)

        await MainActor.run {
            AppState.shared.autonomousTasks.append(task)
            AppState.shared.stateOverride = .thinking
            AppState.shared.view = .prompt
        }

        // Periksa apakah query membutuhkan Multi-Agent Swarm (kolaborasi antar-spesialis)
        if Self.shouldUseSwarm(for: goal) {
            let orchestration = await AgentOrchestrator.shared.run(goal: goal, model: "")
            let success = orchestration.success
            let transcript = orchestration.transcript

            await MainActor.run {
                if let idx = AppState.shared.autonomousTasks.firstIndex(where: { $0.id == taskId }) {
                    var t = AppState.shared.autonomousTasks[idx]
                    t.status = success ? .completed : .failed
                    t.note = transcript
                    t.updatedAt = .now
                    AppState.shared.autonomousTasks[idx] = t
                }
                AppState.shared.stateOverride = nil
                AppState.shared.view = .prompt

                var reply = success
                    ? "🐝 Swarm Selesai: \(goal)\n\(transcript)"
                    : "⚠️ Swarm Gagal Sebagian: \(goal)\n\(transcript)"
                if let artifact = orchestration.artifact {
                    reply += "\n\n📄 Hasil interaktif telah disajikan di Canvas Studio (\(artifact.type.displayName): \(artifact.title))."
                }
                AppState.shared.chatHistory.append(ChatMessage(role: .assistant, content: reply))
            }

            lockQueue.sync {
                if runningTaskId == taskId { runningTaskId = nil }
            }
            return taskId
        }

        // 1. Rencanakan langkah secara otonom via LLM Planner (dengan fallback cerdas)
        let steps = await engine.planAutonomous(goal: goal)

        await MainActor.run {
            if let idx = AppState.shared.autonomousTasks.firstIndex(where: { $0.id == taskId }) {
                AppState.shared.autonomousTasks[idx].steps = steps
                AppState.shared.autonomousTasks[idx].updatedAt = .now
            }
        }

        // 2. Jalankan langkah-langkah dengan pemantauan status per langkah
        let results = await engine.run(steps: steps) { stepIndex, updatedStep, stepResult in
            await MainActor.run {
                if let idx = AppState.shared.autonomousTasks.firstIndex(where: { $0.id == taskId }) {
                    if stepIndex < AppState.shared.autonomousTasks[idx].steps.count {
                        AppState.shared.autonomousTasks[idx].steps[stepIndex] = updatedStep
                        AppState.shared.autonomousTasks[idx].currentStepIndex = stepIndex
                        AppState.shared.autonomousTasks[idx].updatedAt = .now
                    }
                }
            }
        }

        let success = results.allSatisfy { $0.ok }
        let outputs = results.map { $0.output }.joined(separator: "\n")
        let errors = results.compactMap { $0.error }.joined(separator: "\n")

        // Jika output terstruktur dokumen/tabel/kode, buka di Canvas Studio
        let detectedArtifact = success ? AgentOrchestrator.detectArtifact(from: outputs, goal: goal) : nil
        let canvasNote: String
        if let artifact = detectedArtifact {
            await MainActor.run {
                CanvasManager.shared.present(artifact: artifact)
            }
            canvasNote = "\n\n📄 Hasil telah disajikan di Canvas Studio (\(artifact.type.displayName): \(artifact.title))."
        } else {
            canvasNote = ""
        }

        await MainActor.run {
            if let idx = AppState.shared.autonomousTasks.firstIndex(where: { $0.id == taskId }) {
                var t = AppState.shared.autonomousTasks[idx]
                t.status = success ? .completed : .failed
                t.note = success ? outputs : (errors.isEmpty ? outputs : errors)
                t.updatedAt = .now
                AppState.shared.autonomousTasks[idx] = t
            }
            AppState.shared.stateOverride = nil
            AppState.shared.view = .prompt
            // Tambah pesan asisten ke chat history agar user melihat hasil.
            let reply = success
                ? "Selesai: \(goal)\n\(outputs)\(canvasNote)"
                : "Gagal sebagian: \(goal)\n\(errors.isEmpty ? outputs : errors)"
            AppState.shared.chatHistory.append(ChatMessage(role: .assistant, content: reply))
        }

        lockQueue.sync {
            if runningTaskId == taskId { runningTaskId = nil }
        }

        return taskId
    }

    /// Mengecek apakah suatu query/tujuan memerlukan koordinasi Multi-Agent Swarm (kolaborasi spesialis).
    static func shouldUseSwarm(for goal: String) -> Bool {
        let g = goal.lowercased()
        let swarmKeywords = [
            "swarm", "tim agen", "spesialis", "multi-agent",
            "riset dan analisis", "bandingkan dan susun", "analisis dan buatkan laporan",
            "lakukan studi", "teliti dan rangkum", "investigasi dan tulis dokumen"
        ]
        return swarmKeywords.contains(where: { g.contains($0) })
    }

    /// Batalkan tugas otonom yang sedang berjalan (jika ada).
    func cancel() {
        lockQueue.sync { runningTaskId = nil }
    }

    /// Apakah ada tugas otonom yang sedang berjalan.
    var isRunning: Bool {
        lockQueue.sync { runningTaskId != nil }
    }
}
