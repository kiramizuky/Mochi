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

        let steps = engine.plan(goal: goal)
        let results = await engine.run(steps: steps)

        let success = results.allSatisfy { $0.ok }
        let outputs = results.map { $0.output }.joined(separator: "\n")
        let errors = results.compactMap { $0.error }.joined(separator: "\n")

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
                ? "Selesai: \(goal)\n\(outputs)"
                : "Gagal sebagian: \(goal)\n\(errors.isEmpty ? outputs : errors)"
            AppState.shared.chatHistory.append(ChatMessage(role: .assistant, content: reply))
        }

        lockQueue.sync {
            if runningTaskId == taskId { runningTaskId = nil }
        }

        return taskId
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
