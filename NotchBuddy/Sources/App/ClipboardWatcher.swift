import Foundation
import AppKit

// MARK: - Smart Clipboard Watcher (0% CPU, Pasteboard ChangeCount Tracking)
// Memantau perubahan clipboard macOS secara pasif, mengabaikan passwords/secrets,
// dan mengklasifikasikan konten (Error, URL, JSON, Kode, SQL) untuk tindakan proaktif.

public enum ClipboardContentType: String, Sendable, CaseIterable {
    case errorTrace    // Terminal / compiler / runtime stack trace
    case url           // Tautan web (Web, YouTube, GitHub)
    case rawJSON       // Format JSON terstruktur
    case codeSnippet   // Cuplikan kode pemrograman
    case sqlQuery      // Query SQL
    case plainText     // Teks umum
    case concealed     // Password / secret (diabaikan)
}

public struct ClipboardEvent: Sendable, Equatable {
    public let content: String
    public let type: ClipboardContentType
    public let suggestedChipTitle: String
    public let suggestedActionGoal: String
}

public final class ClipboardWatcher: @unchecked Sendable {
    public static let shared = ClipboardWatcher()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "id.pcstudio.mochi.clipboardwatcher", qos: .utility)
    private let lock = NSLock()
    private var isRunning = false

    /// Handler pengujian atau delegasi eksternal
    public var onClipboardEvent: (@Sendable (ClipboardEvent) -> Void)?

    private init() {
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        stop()
    }

    /// Memulai pemantauan clipboard.
    public func start(intervalSeconds: Double = 1.0) {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        lastChangeCount = pasteboard.changeCount

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds)
        t.setEventHandler { [weak self] in
            self?.checkPasteboard()
        }
        t.resume()
        self.timer = t
        self.isRunning = true
    }

    /// Menghentikan pemantauan clipboard.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        timer?.cancel()
        timer = nil
        isRunning = false
    }

    // MARK: - Core Check

    public func checkPasteboard() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // 1. Filter Keamanan: Abaikan jika clipboard mengandung tipe password / secret
        guard !isConcealedOrTransient() else { return }

        // 2. Ambil teks clipboard
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Batasi ukuran teks maksimal 50.000 karakter agar tidak memberatkan memori
        guard text.count <= 50_000 else { return }

        // 3. Klasifikasikan konten
        let event = classify(text)
        guard event.type != .plainText && event.type != .concealed else { return }

        dispatchClipboardEvent(event)
    }

    /// Memeriksa apakah konten berasal dari Password Manager atau bersifat transient.
    public func isConcealedOrTransient() -> Bool {
        guard let types = pasteboard.types else { return false }
        let concealedIdentifiers = [
            "org.nspasteboard.ConcealedType",
            "com.agilebits.onepassword",
            "de.petermaurer.TransientPasteboardType",
            "com.typeit4me.clipping",
            "Pasteboard generator type"
        ]
        for t in types {
            if concealedIdentifiers.contains(t.rawValue) {
                return true
            }
        }
        return false
    }

    // MARK: - Classification Logic

    public func classify(_ text: String) -> ClipboardEvent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // 1. Error / Stack Trace / Compiler Diagnostic
        let errorMarkers = [
            "error:", "exception:", "fatal error:", "traceback (most recent call last):",
            "sigsegv", "npm err!", "build failed", "syntaxerror", "referenceerror",
            "typeerror", "nullpointerexception", "undefined is not a function",
            "failed to compile", "command phasec failed", "cannot find symbol"
        ]
        let isError = errorMarkers.contains { lower.contains($0) }
        if isError {
            let snippet = trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
            return ClipboardEvent(
                content: trimmed,
                type: .errorTrace,
                suggestedChipTitle: "🚨 Error Terdeteksi: Analisis & Perbaiki?",
                suggestedActionGoal: "Analisis pesan error berikut dari clipboard dan jelaskan penyebab serta solusinya:\n\n\(snippet)"
            )
        }

        // 2. URL Tautan Web
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if lower.contains("youtube.com") || lower.contains("youtu.be") {
                return ClipboardEvent(
                    content: trimmed,
                    type: .url,
                    suggestedChipTitle: "🎬 Video YouTube: Ringkas Poin Utama?",
                    suggestedActionGoal: "Buatkan ringkasan intisari dan poin-poin penting dari URL video: \(trimmed)"
                )
            }
            if lower.contains("github.com") || lower.contains("gitlab.com") {
                return ClipboardEvent(
                    content: trimmed,
                    type: .url,
                    suggestedChipTitle: "🐙 GitHub: Review PR / Masalah?",
                    suggestedActionGoal: "Review dan jelaskan ringkasan perubahan pada tautan GitHub ini: \(trimmed)"
                )
            }
            return ClipboardEvent(
                content: trimmed,
                type: .url,
                suggestedChipTitle: "🌐 Tautan Disalin: Buka & Ringkas Web?",
                suggestedActionGoal: "Cari tahu dan buat ringkasan intisari dari halaman web: \(trimmed)"
            )
        }

        // 3. JSON Mentah
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if let data = trimmed.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return ClipboardEvent(
                    content: trimmed,
                    type: .rawJSON,
                    suggestedChipTitle: "📋 JSON Disalin: Format & Validasi?",
                    suggestedActionGoal: "Format dan rapikan struktur JSON dari clipboard dengan indentasi 2 spasi."
                )
            }
        }

        // 4. SQL Query
        let sqlMarkers = ["select ", "insert into ", "update ", "delete from ", "create table ", "alter table "]
        let isSql = sqlMarkers.contains { lower.hasPrefix($0) } || (lower.contains("select ") && lower.contains(" from "))
        if isSql {
            return ClipboardEvent(
                content: trimmed,
                type: .sqlQuery,
                suggestedChipTitle: "🗄️ SQL Disalin: Optimasi & Cek Query?",
                suggestedActionGoal: "Analisis dan berikan saran optimasi untuk query SQL berikut:\n\n\(trimmed)"
            )
        }

        // 5. Cuplikan Kode Pemrograman (Swift, Python, JS/TS, Rust, Go)
        let codeKeywords = [
            "func ", "def ", "class ", "struct ", "import ", "const ", "let ",
            "public func", "private func", "async throws", "return ", "@main",
            "package ", "fn ", "impl ", "interface "
        ]
        let matchCount = codeKeywords.filter { lower.contains($0) }.count
        let lineCount = trimmed.components(separatedBy: "\n").count
        if matchCount >= 2 || (matchCount >= 1 && lineCount >= 3) {
            return ClipboardEvent(
                content: trimmed,
                type: .codeSnippet,
                suggestedChipTitle: "💻 Kode Disalin: Review & Optimasi?",
                suggestedActionGoal: "Review kode dari clipboard ini untuk mendeteksi bug, optimasi performa, dan clean code:\n\n\(trimmed)"
            )
        }

        return ClipboardEvent(
            content: trimmed,
            type: .plainText,
            suggestedChipTitle: "",
            suggestedActionGoal: ""
        )
    }

    // MARK: - Dispatching

    private func dispatchClipboardEvent(_ event: ClipboardEvent) {
        if let onClipboardEvent {
            onClipboardEvent(event)
        }

        SensoryEventHub.shared.registerProactiveTrigger(
            id: "clip_\(UUID().uuidString.prefix(8))",
            title: event.suggestedChipTitle,
            goal: event.suggestedActionGoal,
            priority: event.type == .errorTrace ? .high : .medium
        )
    }
}

