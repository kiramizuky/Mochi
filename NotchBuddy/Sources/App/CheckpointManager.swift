import Foundation

// MARK- Checkpoint manager (simpan & pulihkan status tugas otonom di disk)

// Manajer checkpoin: menyimpan status AutonomousTask + langkah-langkah ke file JSON
// di Application Support/NotchBuddy/checkpoints/. Jika Coucou crashes atau
// reboot selama tugas otonom berjalan panjang, tugas bisa dilanjutkan dari
// checkpoin terakhir invece dari mulai dari nol.
final class CheckpointManager: @unchecked Sendable {
    static let shared = CheckpointManager()

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = base
            .appendingPathComponent("NotchBuddy", isDirectory: true)
            .appendingPathComponent("checkpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
    }

    /// Path file checkpoin untuk satu tugas.
    private func url(for taskId: String) -> URL {
        directory.appendingPathComponent("\(taskId).json")
    }

    /// Simpan status tugas + langkah-langkah ke disk.
    func save(taskId: String, task: AutonomousTask, steps: [AutonomousStep]) {
        var dict: [String: Any] = [
            "task": [
                "id": task.id,
                "goal": task.goal,
                "status": task.status.rawValue,
                "currentStepIndex": task.currentStepIndex,
                "createdAt": task.createdAt.timeIntervalSince1970,
                "updatedAt": task.updatedAt.timeIntervalSince1970,
                "note": task.note as Any,
                "source": task.source,
            ],
            "steps": steps.map { step in
                [
                    "id": step.id,
                    "name": step.name,
                    "tool": step.tool,
                    "input": step.input.mapValues { $0.anyValue },
                    "status": step.status.rawValue,
                    "result": step.result as Any,
                    "error": step.error as Any,
                    "attempts": step.attempts,
                    "maxAttempts": step.maxAttempts,
                ]
            },
            "savedAt": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: url(for: taskId), options: .atomic)
    }

    /// Muat tugas + langkah dari disk, atau nil jika tidak ada / korup.
    func load(taskId: String) -> (task: AutonomousTask, steps: [AutonomousStep])? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(for: taskId)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let task = task(from: json["task"] as? [String: Any]) else { return nil }
        let stepsArray = json["steps"] as? [[String: Any]] ?? []
        let steps = stepsArray.compactMap { step(from: $0) }
        return (task, steps)
    }

    /// Hapus checkpoin satu tugas (setelah tugas selesai / dibatalkan).
    func delete(taskId: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(for: taskId))
    }

    /// Daftar semua ID tugas yang punya checkpoin di disk.
    func list() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { $0.pathExtension == "json" ? $0.deletingPathExtension().lastPathComponent : nil }
    }

    /// Apakah checkpoin untuk tugas sudah ada di disk.
    func has(taskId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: url(for: taskId).path)
    }

    /// Hapus semua checkpoin (membersihkan riwayat lama).
    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: - Decode helpers

    private func task(from dict: [String: Any]?) -> AutonomousTask? {
        guard let d = dict,
              let id = d["id"] as? String,
              let goal = d["goal"] as? String,
              let statusRaw = d["status"] as? String,
              let status = AutonomousTaskStatus(rawValue: statusRaw) else { return nil }
        let currentStepIndex = d["currentStepIndex"] as? Int ?? 0
        let createdAt = Date(timeIntervalSince1970: d["createdAt"] as? TimeInterval ?? 0)
        let updatedAt = Date(timeIntervalSince1970: d["updatedAt"] as? TimeInterval ?? 0)
        let note = d["note"] as? String
        let source = d["source"] as? String ?? "user"
        return AutonomousTask(
            id: id, goal: goal, status: status, steps: [],
            currentStepIndex: currentStepIndex, createdAt: createdAt,
            updatedAt: updatedAt, note: note, source: source)
    }

    private func step(from dict: [String: Any]?) -> AutonomousStep? {
        guard let d = dict,
              let id = d["id"] as? String,
              let name = d["name"] as? String,
              let tool = d["tool"] as? String,
              let statusRaw = d["status"] as? String,
              let status = AutonomousTaskStatus(rawValue: statusRaw) else { return nil }
        let input = (d["input"] as? [String: Any]).map { $0.mapValues(JSONValue.init(any:)) } ?? [:]
        let result = d["result"] as? String
        let error = d["error"] as? String
        let attempts = d["attempts"] as? Int ?? 0
        let maxAttempts = d["maxAttempts"] as? Int ?? 3
        return AutonomousStep(
            id: id, name: name, tool: tool, input: input, status: status,
            result: result, error: error, attempts: attempts, maxAttempts: maxAttempts)
    }
}
