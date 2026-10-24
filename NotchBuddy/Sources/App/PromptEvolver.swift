import Foundation

// MARK- Prompt evolver — perbaiki sistem prompt otomatis dari riwayat sukses/gagal

/// Satu versi sistem prompt dengan catatan hasilnya.
struct PromptVersion: Codable, Sendable, Equatable {
    var id: String
    var prompt: String
    var successCount: Int = 0
    var failureCount: Int = 0
    var createdAt: Date = .now

    var totalTrials: Int { successCount + failureCount }
    var successRate: Double {
        totalTrials == 0 ? 0 : Double(successCount) / Double(totalTrials)
    }
}

/// Evolusi sistem prompt agen berdasarkan riwayat sukses/gagal.
/// Versi dengan tingkat sukses tertinggi dipertahankan sebagai prompt aktif.
final class PromptEvolver: @unchecked Sendable {
    static let shared = PromptEvolver()

    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    private(set) var versions: [PromptVersion] = []

    init(url: URL? = nil) {
        let base = url?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.url = (url ?? base
            .appendingPathComponent("NotchBuddy", isDirectory: true)
            .appendingPathComponent("prompt_versions.json"))
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        self.versions = Self.load(from: self.url)
    }

    /// Daftarkan versi prompt baru. Mengembalikan id versi.
    @discardableResult
    func register(prompt: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return registerUnlocked(prompt: prompt)
    }

    /// Daftarkan versi prompt baru tanpa mengunci (dipakai saat evolve sudah
    /// memegang kunci, mencegah deadlock pada NSLock non-reentrant).
    private func registerUnlocked(prompt: String) -> String {
        let id = UUID().uuidString
        let version = PromptVersion(id: id, prompt: prompt)
        versions.insert(version, at: 0)
        try? persistLocked()
        return id
    }

    /// Catat hasil satu eksekusi untuk versi prompt.
    func recordOutcome(versionId: String, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = versions.firstIndex(where: { $0.id == versionId }) else { return }
        if success { versions[idx].successCount += 1 }
        else { versions[idx].failureCount += 1 }
        try? persistLocked()
    }

    /// Versi terbaik (tingkat sukses tertinggi, minimal 1 uji coba).
    func currentBest() -> PromptVersion? {
        lock.lock(); defer { lock.unlock() }
        return currentBestUnlocked()
    }

    /// Versi terbaik tanpa mengunci (dipakai saat evolve sudah memegang kunci).
    private func currentBestUnlocked() -> PromptVersion? {
        return versions
            .filter { $0.totalTrials >= 1 }
            .max { a, b in
                let ra = a.successRate, rb = b.successRate
                if ra == rb { return a.createdAt < b.createdAt }
                return ra < rb
            }
    }

    /// Evolusi: jika tingkat kegagalan tinggi (>= 50% dan >= 3 uji coba),
    /// tambahkan instruksi perbaikan ke prompt dasar dan daftarkan sebagai versi baru.
    /// Mengembalikan prompt yang sebaiknya dipakai (terbaik atau hasil evolusi).
    func evolve(basePrompt: String, failureThreshold: Double = 0.5,
                minTrials: Int = 3) -> String {
        lock.lock(); defer { lock.unlock() }

        let recent = versions.suffix(minTrials * 2)
        let trials = recent.reduce(0) { $0 + $1.totalTrials }
        let failures = recent.reduce(0) { $0 + $1.failureCount }
        let failureRate = trials == 0 ? 0 : Double(failures) / Double(trials)

    guard failureRate >= failureThreshold, trials >= minTrials else {
        return currentBestUnlocked()?.prompt ?? basePrompt
    }

        // Instruksi perbaikan: hindari pola yang gagal dari versi terburuk.
        let worst = versions
            .filter { $0.totalTrials >= 1 }
            .min { a, b in a.successRate < b.successRate }
        let hint = worst.map { " Hindari pendekatan seperti: \($0.prompt.prefix(80))." } ?? ""

        let evolved = basePrompt + "\n\n[Self-evolved: tingkat kegagalan tinggi terdeteksi. Perbaiki berdasarkan pelanggaran kebijakan sebelumnya.]\(hint)"
        let _ = registerUnlocked(prompt: evolved)
        return evolved
    }

    /// Jumlah versi terdaftar.
    var count: Int { lock.lock(); defer { lock.unlock() }; return versions.count }

    /// Hapus semua versi (tes / reset).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        versions = []
        try? persistLocked()
    }

    // MARK: Persistence

    private func persistLocked() throws {
        let data = try encoder.encode(versions)
        try data.write(to: url, options: Data.WritingOptions.atomic)
    }

    private static func load(from url: URL) -> [PromptVersion] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PromptVersion].self, from: data)) ?? []
    }
}
