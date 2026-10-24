import Foundation

// MARK- Proaktif — memori jangka panjang dipublikasikan sebagai chip yang bisa diklik

// Chip yang muncul di island: asumsi/ingatan dari memori (mis. janji dengan waktu)
// yang bisa diklik untuk segera menanyakannya lagi ke asisten.
struct ProactiveChip: Identifiable, Equatable, Sendable {
    var id: String
    var text: String   // teks yang ditampil
    var fact: String   // fakta asli (jadi prefill prompt saat diklik)
}

/// Deteksi pola waktu / janji dari entri memori → chip. Tanpa notifikasi berisik;
/// chip diam di island sampai pengguna klik.
final class ProactiveEngine: @unchecked Sendable {
    static let shared = ProactiveEngine()
    private init() {}

    /// Learner kebiasaan (rutinitas waktu + hari) yang dipanggil saat refresh.
    let learner = HabitLearner.shared

    var chips: [ProactiveChip] = []

    /// Hitung ulang chip dari memori + kebiasaan (diambil oleh pemanggil untuk
    /// disimpan ke AppState: launch, view prompt terbuka, dan setelah
    /// memory_save).
    func refresh() {
        var all = Self.chips(from: MemoryService.shared.all())
        let habit = habitChips(from: learner.suggestions())
        all.append(contentsOf: habit)
        self.chips = all
    }

    /// Catat kebiasaan pengguna agar learner bisa mendeteksi rutinitas.
    func recordHabit(action: String, category: String = "app") {
        learner.record(action: action, category: category)
    }

    /// Konversi saran kebiasaan → chip agar bisa ditampilkan di island.
    func habitChips(from suggestions: [HabitSuggestion]) -> [ProactiveChip] {
        suggestions.map { s in
            ProactiveChip(id: s.id, text: s.title, fact: s.action)
        }
    }

    static func chips(from entries: [MemoryEntry]) -> [ProactiveChip] {
        guard let timeRegex = try? NSRegularExpression(pattern: #"\b\d{1,2}[:.]\d{2}\b"#) else { return [] }
        let keywords = ["besok", "tomorrow", "meeting", "rapat", "janji", "appointment", "deadline", "jatuh tempo"]

        return entries.compactMap { entry in
            let t = entry.text.lowercased()
            let hasTime = timeRegex.firstMatch(in: entry.text,
                                               range: NSRange(entry.text.startIndex..., in: entry.text)) != nil
            let hasKeyword = keywords.contains { t.contains($0) }
            guard hasTime || hasKeyword else { return nil }
            let display = entry.text.count > 60 ? String(entry.text.prefix(60)) + "…" : entry.text
            return ProactiveChip(id: entry.id, text: display, fact: entry.text)
        }
    }
}
