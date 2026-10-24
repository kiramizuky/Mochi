import Foundation

// MARK: - Pelaporan crash (tangkap exception, tulis laporan ke Application Support)

/// Satu laporan crash.
struct CrashReport: Identifiable, Equatable, Codable, Sendable {
    var id: String { timestamp }
    var timestamp: String
    var exception: String
    var reason: String
    var callStack: [String]
    var appVersion: String
}

final class CrashReporter: @unchecked Sendable {
    static let shared = CrashReporter()
    private let url: URL
    private let lock = NSLock()
    private(set) var reports: [CrashReport] = []

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        url = base
            .appendingPathComponent("NotchBuddy", isDirectory: true)
            .appendingPathComponent("crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        reports = loadReports()
    }

    /// Pasang penangani exception tak tertangani. Dipanggil saat launch.
    func install() {
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.shared.record(exception: exception)
        }
    }

    /// Catat exception secara manual (untuk uji).
    func record(exception: NSException) {
        let report = CrashReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            exception: exception.name.rawValue,
            reason: exception.reason ?? "no reason",
            callStack: exception.callStackReturnAddresses.map { "\($0)" },
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        )
        lock.lock()
        reports.insert(report, at: 0)
        if reports.count > 50 { reports = Array(reports.prefix(50)) }
        lock.unlock()
        saveReports()
    }

    /// Semua laporan crash (terbaru dulu).
    var all: [CrashReport] {
        lock.lock(); defer { lock.unlock() }
        return reports
    }

    /// Hapus semua laporan.
    func clear() {
        lock.lock()
        reports.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Internal

    private func saveReports() {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        try? data.write(to: url.appendingPathComponent("reports.json"))
    }

    private func loadReports() -> [CrashReport] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("reports.json")),
              let reports = try? JSONDecoder().decode([CrashReport].self, from: data) else {
            return []
        }
        return reports
    }
}
