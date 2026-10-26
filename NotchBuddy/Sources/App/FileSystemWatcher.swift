import Foundation
import AppKit

// MARK: - File System Watcher Daemon (FSEvents / DispatchSource for Autonomous Proactivity)
// Memantau folder strategis (~/Downloads, ~/Desktop) dengan 0% CPU saat diam,
// mengidentifikasi berkas baru, dan memicu rekomendasi proaktif cerdas ke Notch.

public enum WatchedFileType: String, Sendable, CaseIterable {
    case invoice         // PDF faktur, kwitansi, invoice
    case document        // PDF umum, DOCX, PPTX, Markdown
    case dataSpreadsheet // CSV, Excel, Numbers, JSON
    case screenshot      // Tangkapan layar di Desktop
    case image           // Foto/Gambar umum
    case archive         // ZIP, DMG, PKG, TAR.GZ
    case code            // Berkas sumber pemrograman
    case other
}

public struct WatchedFileEvent: Sendable, Equatable {
    public let url: URL
    public let filename: String
    public let fileType: WatchedFileType
    public let suggestedActionText: String
    public let suggestedGoal: String
}

public final class FileSystemWatcher: @unchecked Sendable {
    public static let shared = FileSystemWatcher()

    private let queue = DispatchQueue(label: "id.pcstudio.mochi.fswatcher", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileDescriptors: [Int32] = []
    private var knownFiles: [URL: Set<String>] = [:]
    private var debounceWorkItems: [URL: DispatchWorkItem] = [:]
    private let lock = NSLock()
    private var isRunning = false

    /// Handler pengujian atau delegasi eksternal
    public var onFileEvent: (@Sendable (WatchedFileEvent) -> Void)?

    private init() {}

    deinit {
        stop()
    }

    /// Memulai pemantauan folder default (~/Downloads dan ~/Desktop).
    public func start(watchedDirectories: [URL]? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        let fileManager = FileManager.default
        let dirs: [URL]
        if let custom = watchedDirectories {
            dirs = custom
        } else {
            var targets: [URL] = []
            if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                targets.append(downloads)
            }
            if let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first {
                targets.append(desktop)
            }
            dirs = targets
        }

        for dir in dirs {
            watchDirectory(dir)
        }

        isRunning = true
    }

    /// Menghentikan pemantauan dan membebaskan semua file descriptor.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        for item in debounceWorkItems.values {
            item.cancel()
        }
        debounceWorkItems.removeAll()

        for source in sources {
            source.cancel()
        }
        sources.removeAll()

        for fd in fileDescriptors {
            close(fd)
        }
        fileDescriptors.removeAll()
        knownFiles.removeAll()

        isRunning = false
    }

    // MARK: - Directory Watcher Registration

    private func watchDirectory(_ dirURL: URL) {
        let path = dirURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        // Catat daftar berkas awal agar tidak memicu notifikasi untuk berkas lama
        if let initialItems = try? FileManager.default.contentsOfDirectory(atPath: path) {
            knownFiles[dirURL] = Set(initialItems)
        } else {
            knownFiles[dirURL] = []
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.handleDirectoryChanged(dirURL)
        }

        source.setCancelHandler {
            close(fd)
        }

        sources.append(source)
        fileDescriptors.append(fd)
        source.resume()
    }

    // MARK: - Change Processing & Debouncing

    private func handleDirectoryChanged(_ dirURL: URL) {
        lock.lock()
        // Batalkan debounce work item sebelumnya jika ada burst write (misal unduhan sedang berlangsung)
        debounceWorkItems[dirURL]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.scanNewFiles(in: dirURL)
        }
        debounceWorkItems[dirURL] = workItem
        lock.unlock()

        // Debounce 1.5 detik agar unduhan selesai dan file temporary hilang
        queue.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func scanNewFiles(in dirURL: URL) {
        let fileManager = FileManager.default
        guard let currentItems = try? fileManager.contentsOfDirectory(atPath: dirURL.path) else { return }
        let currentSet = Set(currentItems)

        lock.lock()
        let previousSet = knownFiles[dirURL] ?? []
        knownFiles[dirURL] = currentSet
        lock.unlock()

        let newItems = currentSet.subtracting(previousSet)
        guard !newItems.isEmpty else { return }

        for filename in newItems {
            // Saring berkas sementara atau tersembunyi
            guard isValidFile(filename) else { continue }
            let fileURL = dirURL.appendingPathComponent(filename)

            // Pastikan berkas benar-benar ada dan bukan direktori
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }

            // Klasifikasi berkas & buat event proaktif
            let event = classifyFile(url: fileURL, filename: filename)
            dispatchProactiveEvent(event)
        }
    }

    private func isValidFile(_ filename: String) -> Bool {
        if filename.hasPrefix(".") { return false }
        if filename.hasSuffix(".crdownload") || filename.hasSuffix(".download") || filename.hasSuffix(".tmp") || filename.hasSuffix(".part") {
            return false
        }
        return true
    }

    // MARK: - Classification & Proactive Mapping

    public func classifyFile(url: URL, filename: String) -> WatchedFileEvent {
        let lower = filename.lowercased()
        let ext = url.pathExtension.lowercased()

        // 1. Faktur / Invoice / Bukti Bayar
        let invoiceKeywords = ["invoice", "faktur", "tagihan", "receipt", "kwitansi", "payment", "slip", "bill"]
        let isInvoice = ext == "pdf" && invoiceKeywords.contains(where: { lower.contains($0) })
        if isInvoice {
            return WatchedFileEvent(
                url: url,
                filename: filename,
                fileType: .invoice,
                suggestedActionText: "📄 Faktur Terdeteksi: Arsipkan ke Keuangan?",
                suggestedGoal: "Pindahkan dan rapikan berkas \(url.path) ke folder Keuangan dan buat catatan rekapnya."
            )
        }

        // 2. Data / Spreadsheet
        if ["csv", "xlsx", "xls", "numbers", "json"].contains(ext) {
            return WatchedFileEvent(
                url: url,
                filename: filename,
                fileType: .dataSpreadsheet,
                suggestedActionText: "📊 Data Baru: Analisis & Rekap Statistik?",
                suggestedGoal: "Analisis berkas data di \(url.path) dan tampilkan ringkasan metrik statistik pentingnya."
            )
        }

        // 3. Tangkapan Layar (Screenshot)
        let isScreenshot = (lower.contains("screen shot") || lower.contains("screenshot") || lower.contains("tangkapan layar")) && ["png", "jpg", "jpeg", "webp"].contains(ext)
        if isScreenshot {
            return WatchedFileEvent(
                url: url,
                filename: filename,
                fileType: .screenshot,
                suggestedActionText: "🖼️ Screenshot Baru: Analisis Visual & OCR?",
                suggestedGoal: "Baca dan jelaskan isi tangkapan layar di \(url.path) menggunakan penglihatan multimodal."
            )
        }

        // 4. Dokumen Teks & Bacaan
        if ["pdf", "docx", "pptx", "txt", "md"].contains(ext) {
            return WatchedFileEvent(
                url: url,
                filename: filename,
                fileType: .document,
                suggestedActionText: "📖 Dokumen Baru: Buat Ringkasan Isi?",
                suggestedGoal: "Baca berkas dokumen di \(url.path) dan susun ringkasan eksekutif poin-poin utamanya."
            )
        }

        // 5. Arsip / Installer
        if ["zip", "dmg", "pkg", "tar", "gz"].contains(ext) {
            return WatchedFileEvent(
                url: url,
                filename: filename,
                fileType: .archive,
                suggestedActionText: "📦 Arsip Terunduh: Ekstrak Berkas?",
                suggestedGoal: "Ekstrak arsip \(url.path) ke direktori tujuan yang teratur."
            )
        }

        // 6. Berkas Kode Pemrograman
        if ["swift", "py", "js", "ts", "rs", "go", "java", "cpp", "c", "html", "css"].contains(ext) {
            return WatchedFileEvent(
                url: url,
                filename: filename,
                fileType: .code,
                suggestedActionText: "💻 Kode Baru: Review & Uji Kode?",
                suggestedGoal: "Periksa kode di \(url.path), review struktur dan pastikan tidak ada kesalahan sintaks."
            )
        }

        // Default: berkas lainnya
        return WatchedFileEvent(
            url: url,
            filename: filename,
            fileType: .other,
            suggestedActionText: "📎 Berkas Baru: Buka atau Rapikan \(filename)?",
            suggestedGoal: "Buka dan periksa berkas \(url.path)."
        )
    }

    // MARK: - Dispatching to Notch / UI

    private func dispatchProactiveEvent(_ event: WatchedFileEvent) {
        if let onFileEvent {
            onFileEvent(event)
        }

        SensoryEventHub.shared.registerProactiveTrigger(
            id: "fswatch_\(UUID().uuidString.prefix(8))",
            title: event.suggestedActionText,
            goal: event.suggestedGoal,
            priority: event.fileType == .invoice ? .high : .medium
        )
    }
}

