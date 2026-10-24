import Foundation

// MARK: - Scheduler tugas otonom (jadwal cron-like)

/// Jadwal eksekusi tugas otonom.
struct ScheduledTask: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var goal: String
    /// "daily" atau "weekly".
    var frequency: String
    /// Jam (0-23) untuk dieksekusi.
    var hour: Int
    /// Menit (0-59) untuk dieksekusi.
    var minute: Int
    /// Hari dalam minggu (1=Minggu … 7=Sabtu), hanya untuk frequency "weekly".
    var weekday: Int = 1
    var enabled: Bool = true
    var lastRun: Date? = nil
    var nextRun: Date? = nil
}

/// Jadwal tugas otonom. Tidak berjalan saat island hidden (0 % CPU).
final class TaskScheduler: @unchecked Sendable {
    static let shared = TaskScheduler()
    private init() {}

    private var timer: DispatchSourceTimer?
    private var lock = NSLock()
    private var schedules: [ScheduledTask] = []

    /// Cek "island hidden" — diinject untuk testability; default false (tidak hidden).
    /// AppDelegate menyetel ini ke AppState.shared.mode == .hidden saat launch.
    var isHidden: () -> Bool = { false }

    /// Dipanggil saat sebuah tugas jadwal jatuh tempo; AppDelegate menyetel ini
    /// untuk menambahkan tugas ke AppState.shared.autonomousTasks.
    var onTaskAdded: ((AutonomousTask) -> Void)?

    /// Daftar jadwal yang tersimpan.
    var all: [ScheduledTask] { lock.withLock { schedules } }

    /// Mulai pemeriksaan jadwal setiap menit.
    func start() {
        guard timer == nil else { return }
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer?.schedule(deadline: .now(), repeating: 60.0)
        timer?.setEventHandler { [weak self] in
            self?.checkDue()
        }
        timer?.resume()
    }

    /// Hentikan pemeriksaan jadwal.
    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Tambah jadwal baru.
    func add(_ schedule: ScheduledTask) {
        lock.withLock {
            schedules.removeAll { $0.id == schedule.id }
            schedules.append(schedule)
        }
    }

    /// Hapus jadwal.
    func remove(id: String) {
        lock.withLock { schedules.removeAll { $0.id == id } }
    }

    /// Aktifkan / nonaktifkan jadwal.
    func setEnabled(id: String, enabled: Bool) {
        lock.withLock {
            if let idx = schedules.firstIndex(where: { $0.id == id }) {
                schedules[idx].enabled = enabled
            }
        }
    }

    // MARK: - Internal

    private func checkDue() {
        // 0 % CPU saat island hidden: jangan periksa jadwal.
        guard !isHidden() else { return }

        let now = Date()
        let due: [ScheduledTask] = lock.withLock {
            schedules.filter { $0.enabled && dueAt($0, now: now) }
        }
        for task in due {
            let newTask = AutonomousTask(
                id: UUID().uuidString,
                goal: task.goal,
                createdAt: now,
                source: "scheduler"
            )
            onTaskAdded?(newTask)
            // Tandai lastRun
            lock.withLock {
                if let idx = schedules.firstIndex(where: { $0.id == task.id }) {
                    schedules[idx].lastRun = now
                    schedules[idx].nextRun = nextRun(after: now, for: schedules[idx])
                }
            }
        }
    }

    func dueAt(_ schedule: ScheduledTask, now: Date) -> Bool {
        // Hindari jalankan dua kali dalam menit yang sama.
        if let last = schedule.lastRun,
           Calendar.current.isDate(last, inSameDayAs: now),
           Calendar.current.component(.hour, from: last) == schedule.hour,
           Calendar.current.component(.minute, from: last) == schedule.minute {
            return false
        }
        let comps = Calendar.current.dateComponents([.hour, .minute, .weekday], from: now)
        guard comps.hour == schedule.hour, comps.minute == schedule.minute else { return false }
        if schedule.frequency == "weekly" {
            return comps.weekday == schedule.weekday
        }
        return schedule.frequency == "daily"
    }

    func nextRun(after now: Date, for schedule: ScheduledTask) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        comps.hour = schedule.hour
        comps.minute = schedule.minute
        comps.second = 0
        var date = Calendar.current.date(from: comps) ?? now
        if date <= now {
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        }
        if schedule.frequency == "weekly" {
            while Calendar.current.component(.weekday, from: date) != schedule.weekday {
                date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
            }
        }
        return date
    }
}

extension Notification.Name {
    static let autonomousTaskAdded = Notification.Name("autonomousTaskAdded")
}
