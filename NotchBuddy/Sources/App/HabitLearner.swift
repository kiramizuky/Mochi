import Foundation

// MARK- HabitLearner — deteksi kebiasaan pengguna (rutinitas waktu + hari)

// Belajar dari tindakan berulang pengguna dan menghasilkan saran otomatisasi
// (workflow) ketika pola waktu + hari cukup kuat. Semua data di memori; tidak
// ada jaringan / dependensi pihak ketiga. "Sekarang" dapat di-inject untuk tes.
struct HabitEntry: Sendable, Equatable {
    var action: String        // mis. "buka Mail", "cek email", "tulis file"
    var category: String      // "app", "shell", "web", "file", "chat"
    var timestamp: Date
    var dayOfWeek: Int        // 1 (Minggu) ... 7 (Sabtu)
    var hour: Int             // 0 ... 23
}

/// Saran otomatisasi yang dihasilkan dari kebiasaan terdeteksi.
struct HabitSuggestion: Identifiable, Equatable, Sendable {
    var id: String
    var title: String         // "Biasanya kamu buka Mail jam 09:00, mau saya siapkan?"
    var action: String        // tindakan yang disarankan
    var category: String
    var confidence: Double    // 0 ... 1
}

/// Belajar dari tindakan berulang pengguna dan menghasilkan saran otomatisasi
/// (workflow) ketika pola waktu + hari terdeteksi.
final class HabitLearner: @unchecked Sendable {
    static let shared = HabitLearner()

    private let lock = NSLock()
    private var entries: [HabitEntry] = []
    /// "Sekarang" dapat di-inject untuk tes (default Date()).
    var now: () -> Date = Date.init

    init() {}

    /// Catat satu tindakan pengguna (dipanggil setelah eksekusi alat / tujuan selesai).
    func record(action: String, category: String = "app") {
        let date = now()
        let cal = Calendar.current
        let entry = HabitEntry(
            action: action,
            category: category,
            timestamp: date,
            dayOfWeek: cal.component(.weekday, from: date),
            hour: cal.component(.hour, from: date)
        )
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        if entries.count > 200 {
            entries = Array(entries.suffix(200))
        }
    }

    /// Daftar saran otomatisasi dari kebiasaan yang cukup kuat (≥3 kali
    /// kemunculan pada hari + jam yang sama).
    func suggestions(minConfidence: Double = 0.5) -> [HabitSuggestion] {
        lock.lock()
        defer { lock.unlock() }
        let date = now()
        let cal = Calendar.current
        let todayDow = cal.component(.weekday, from: date)
        let nowHour = cal.component(.hour, from: date)

        var groups: [String: [HabitEntry]] = [:]
        for e in entries {
            let key = "\(e.category)|\(e.action)|\(e.dayOfWeek)|\(e.hour)"
            groups[key, default: []].append(e)
        }

        var suggestions: [HabitSuggestion] = []
        for (key, group) in groups {
            guard group.count >= 3 else { continue }
            let confidence = min(Double(group.count) / 10.0, 1.0)
            guard confidence >= minConfidence else { continue }

            let first = group[0]
            let isNow = first.dayOfWeek == todayDow && first.hour == nowHour

            let title: String
            if isNow {
                title = "Biasanya kamu \(first.action.lowercased()) jam \(first.hour):00, mau saya siapkan?"
            } else {
                title = "Kamu rutin \(first.action.lowercased()) setiap \(weekdayName(first.dayOfWeek)) jam \(first.hour):00, buat otomatisasi?"
            }

            suggestions.append(HabitSuggestion(
                id: key,
                title: title,
                action: first.action,
                category: first.category,
                confidence: confidence
            ))
        }
        return suggestions.sorted { $0.confidence > $1.confidence }
    }

    private func weekdayName(_ d: Int) -> String {
        switch d {
        case 1: return "Minggu"
        case 2: return "Senin"
        case 3: return "Selasa"
        case 4: return "Rabu"
        case 5: return "Kamis"
        case 6: return "Jumat"
        case 7: return "Sabtu"
        default: return "\(d)"
        }
    }

    /// Hapus semua entri (tes / reset).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries = []
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}
