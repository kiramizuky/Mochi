import Foundation

// MARK- Feedback loop — pelajaran dari koreksi & penolakan pengguna

/// Jenis masukan dari pengguna yang menjadi pelajaran bagi agen.
enum FeedbackKind: String, Sendable, CaseIterable, Codable {
    case denial    = "denial"    // pengguna menolak panggilan alat
    case correction = "correction" // pengguna menyunting hasil agen
    case edit      = "edit"      // pengguna mengubah input alat
}

/// Satu pelajaran yang tersimpan dari interaksi pengguna.
struct FeedbackEntry: Codable, Sendable, Equatable {
    var id: String
    var kind: FeedbackKind
    var target: String     // nama alat atau prompt yang terkait
    var original: String   // isi asli sebelum koreksi
    var corrected: String  // isi setelah koreksi (kosong untuk denial)
    var lesson: String     // ringkasan pelajaran untuk sistem prompt
    var timestamp: Date
}

/// Mengumpulkan koreksi & penolakan pengguna, mencatatnya ke AuditLog
/// dan menyimpan pelajaran ke MemoryService serta berkas terstruktur,
/// agar kesalahan yang sama tidak terulang.
final class FeedbackLoop: @unchecked Sendable {
    static let shared = FeedbackLoop()

    private let memory: MemoryService
    private let audit: AuditLog
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    private(set) var entries: [FeedbackEntry] = []

    init(memory: MemoryService = .shared,
         audit: AuditLog = AuditLog(),
         url: URL? = nil) {
        let base = url?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.url = (url ?? base
            .appendingPathComponent("NotchBuddy", isDirectory: true)
            .appendingPathComponent("feedback.json"))
        self.memory = memory
        self.audit = audit
        self.entries = Self.load(from: self.url)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Catat masukan pengguna sebagai pelajaran.
    func record(kind: FeedbackKind, target: String, original: String,
                corrected: String, lesson: String) {
        let entry = FeedbackEntry(
            id: UUID().uuidString, kind: kind, target: target,
            original: original, corrected: corrected, lesson: lesson,
            timestamp: Date())
        lock.lock()
        defer { lock.unlock() }

        entries.insert(entry, at: 0)
        if entries.count > 200 { entries = Array(entries.prefix(200)) }

        // Catat ke AuditLog (tidak ada telemetry — hanya catatan lokal).
        audit.record(category: .appControl, action: "feedback.\(kind.rawValue)",
                     target: target, decision: .deny, reason: lesson)

        // Simpan ringkasan pelajaran ke memori jangka panjang (bukan rahasia).
        let fact = "Lesson [\(kind.rawValue)] \(target): \(lesson)"
        try? memory.remember(fact)

        // Simpan berkas terstruktur.
        try? persistLocked()
    }

    /// Semua entri, terbaru dulu.
    func all() -> [FeedbackEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// Pelajaran terbaru (diformat untuk disuntik ke system prompt).
    func lessons(limit: Int = 10) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.prefix(limit).map { e in
            "[\(e.kind.rawValue)] \(e.target): \(e.lesson)"
        }
    }

    /// Hapus semua entri (tes / reset).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries = []
        try? persistLocked()
    }

    // MARK: Persistence

    private func persistLocked() throws {
        let data = try encoder.encode(entries)
        try data.write(to: url, options: Data.WritingOptions.atomic)
    }

    private static func load(from url: URL) -> [FeedbackEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FeedbackEntry].self, from: data)) ?? []
    }
}
