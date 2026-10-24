import Foundation

// MARK: - Model tugas otonom

/// Status siklus hidup tugas otonom.
enum AutonomousTaskStatus: String, Sendable, Equatable, Codable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

/// Satu langkah dalam rencana tugas otonom.
struct AutonomousStep: Equatable, Sendable {
    var id: String
    var name: String
    var tool: String          // nama tool ToolExecutor, mis. "shell_run", "web_search"
    var input: [String: JSONValue]
    var status: AutonomousTaskStatus = .pending
    var result: String?       // output terakhir tool
    var error: String?        // pesan error terakhir
    var attempts: Int = 0
    var maxAttempts: Int = 3
}

/// Tugas otonom: tujuan tinggi level yang dipecah menjadi langkah-langkah tool,
/// dieksekusi oleh WorkflowEngine tanpa klik pengguna.
struct AutonomousTask: Identifiable, Equatable, Sendable {
    var id: String
    var goal: String
    var status: AutonomousTaskStatus = .pending
    var steps: [AutonomousStep] = []
    var currentStepIndex: Int = 0
    var createdAt: Date
    var updatedAt: Date = .distantPast
    var note: String?         // catatan hasil / error untuk ditampilkan di island
    var source: String = "user" // "user", "scheduler", "proactive"
}
