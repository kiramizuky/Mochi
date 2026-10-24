import Foundation
import AppKit

// MARK: - Autonomous Night-Shift & Background Worker

public struct NightShiftReport: Codable, Sendable {
    public var timestamp: Date
    public var filesOrganized: Int
    public var diskSpaceFreeGB: Double
    public var details: [String]
    public var summaryText: String
}

public final class NightShiftWorker: @unchecked Sendable {
    public static let shared = NightShiftWorker()

    private let lock = NSLock()
    private var lastRunDate: Date?
    private let logURL: URL

    @MainActor public var latestReport: NightShiftReport?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.logURL = base
            .appendingPathComponent("NotchBuddy", isDirectory: true)
            .appendingPathComponent("night_shift_report.json")

        loadLatestReport()
        setupIdleTrigger()
    }

    private func setupIdleTrigger() {
        IdleDetectionEngine.shared.onIdleThresholdReached = { [weak self] idleSeconds in
            Task {
                await self?.evaluateAndRunNightShift(idleSeconds: idleSeconds)
            }
        }
    }

    /// Evaluasi apakah sudah waktunya menjalankan Night Shift (misal jam 22:00 - 05:00 dan belum dijalankan hari ini).
    public func evaluateAndRunNightShift(idleSeconds: TimeInterval) async {
        let hour = Calendar.current.component(.hour, from: Date())
        let isNightTime = (hour >= 22 || hour <= 5)

        let alreadyRanToday: Bool = lock.withLock {
            if let last = lastRunDate {
                return Calendar.current.isDateInToday(last)
            } else {
                return false
            }
        }

        guard isNightTime && !alreadyRanToday else { return }

        // Jalankan Night Shift SOP
        _ = await executeNightShift()
    }

    /// Menjalankan seluruh SOP Night Shift secara mandiri.
    public func executeNightShift() async -> NightShiftReport {
        var actions: [String] = []
        var organizedCount = 0

        // 1. Rapikan folder Downloads
        let downloadResult = organizeFolder(path: ("~/Downloads" as NSString).expandingTildeInPath)
        organizedCount += downloadResult.count
        actions.append(contentsOf: downloadResult.details)

        // 2. Audit Disk Space
        let freeGB = getFreeDiskSpaceGB()
        actions.append("Kapasitas disk tersedia: \(String(format: "%.1f", freeGB)) GB")

        let summary = "Semalam Coucou merapikan \(organizedCount) file di Downloads dan memastikan ruang disk aman (\(String(format: "%.1f", freeGB)) GB free)."

        let report = NightShiftReport(
            timestamp: Date(),
            filesOrganized: organizedCount,
            diskSpaceFreeGB: freeGB,
            details: actions,
            summaryText: summary
        )

        lock.withLock {
            self.lastRunDate = Date()
        }

        await MainActor.run {
            self.latestReport = report
            // Buat Canvas Artifact untuk briefing pagi
            let artifact = CanvasArtifact(
                title: "Laporan Night-Shift",
                type: .document,
                content: "# Laporan Night-Shift Coucou\n\n\(summary)\n\n### Rincian Tindakan:\n" + actions.map { "- \($0)" }.joined(separator: "\n")
            )
            CanvasManager.shared.currentArtifact = artifact
        }

        saveReport(report)
        return report
    }

    // MARK: - Folder Organizer

    private func organizeFolder(path: String) -> (count: Int, details: [String]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: path) else { return (0, []) }

        var count = 0
        var details: [String] = []

        let categoryMap: [String: [String]] = [
            "Documents": ["pdf", "docx", "xlsx", "pptx", "txt", "csv", "doc"],
            "Images": ["png", "jpg", "jpeg", "svg", "webp", "heic", "gif"],
            "Installers": ["dmg", "pkg", "zip", "tar", "gz"],
            "Code": ["swift", "py", "js", "ts", "json", "sh", "html", "css"]
        ]

        for file in files {
            if file.hasPrefix(".") { continue }
            let fullPath = (path as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }

            let ext = (file as NSString).pathExtension.lowercased()
            for (category, extensions) in categoryMap {
                if extensions.contains(ext) {
                    let targetDir = (path as NSString).appendingPathComponent(category)
                    try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
                    let destPath = (targetDir as NSString).appendingPathComponent(file)
                    do {
                        try fm.moveItem(atPath: fullPath, toPath: destPath)
                        count += 1
                        details.append("Pindahkan '\(file)' ke folder \(category)/")
                    } catch {}
                    break
                }
            }
        }

        return (count, details)
    }

    private func getFreeDiskSpaceGB() -> Double {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeBytes = attrs[.systemFreeSize] as? Int64 {
            return Double(freeBytes) / 1_073_741_824.0
        }
        return 0.0
    }

    private func saveReport(_ report: NightShiftReport) {
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func loadLatestReport() {
        if let data = try? Data(contentsOf: logURL),
           let report = try? JSONDecoder().decode(NightShiftReport.self, from: data) {
            Task { @MainActor in
                self.latestReport = report
            }
        }
    }
}
