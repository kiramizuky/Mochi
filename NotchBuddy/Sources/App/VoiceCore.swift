import Foundation

// MARK: - Push-to-talk state machine (pure — unit tested without a mic)

enum PTTStatus: Equatable, Sendable {
    case idle
    case requesting      // waiting for mic + speech permissions
    case listening       // audio engine running, collecting transcript
    case denied          // permissions refused
    case failed(String)  // audio/recognition error
}

enum PTTEvent: Equatable, Sendable {
    case press
    case permissionsGranted
    case permissionsDenied
    case audioError(String)
    case transcriptFinal(String)
    case release
    case reset
}

enum PTTReducer {
    /// Single source of truth for PTT transitions. Unknown (event, state)
    /// pairs are ignored so late async events can never corrupt the state.
    static func reduce(_ status: PTTStatus, _ event: PTTEvent) -> PTTStatus {
        switch (status, event) {
        case (.idle, .press), (.denied, .press), (.failed, .press):
            return .requesting
        case (.requesting, .permissionsGranted):
            return .listening
        case (.requesting, .permissionsDenied):
            return .denied
        case (.requesting, .release):
            // Permission dialog still open when the user lets go.
            return .idle
        case (.listening, .audioError(let message)):
            return .failed(message)
        case (.listening, .transcriptFinal):
            return .idle
        case (.listening, .release):
            return .idle
        case (_, .reset):
            return .idle
        default:
            return status
        }
    }
}

// MARK: - Text normalization (pure — unit tested)

enum VoiceText {

    /// Turn assistant markdown into something pleasant to speak:
    /// drop code fences, unwrap links/emphasis, flatten whitespace,
    /// cap at `maxLength` characters on a word boundary.
    static func speechText(from markdown: String, maxLength: Int = 700) -> String {
        var s = markdown

        // Remove fenced code blocks entirely (``` … ```).
        while let start = s.range(of: "```") {
            guard let end = s.range(of: "```", range: start.upperBound..<s.endIndex) else {
                s = String(s[..<start.lowerBound])
                break
            }
            s = String(s[..<start.lowerBound]) + String(s[end.upperBound...])
        }

        s = replacing(#"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", in: s)   // images → alt
        s = replacing(#"\[([^\]]+)\]\([^)]*\)"#, with: "$1", in: s)     // links → label
        s = replacing(#"(?m)^#{1,6}\s+"#, with: "", in: s)             // headings
        s = replacing(#"(?m)^\s*[-*+]\s+"#, with: "", in: s)           // bullets
        s = replacing(#"(?m)^\s*\d+\.\s+"#, with: "", in: s)           // numbered lists
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "~~", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        s = replacing(#"\*(\S[^*]*\S)\*"#, with: "$1", in: s)          // *emphasis*
        s = s.replacingOccurrences(of: #"[\r\n\t]+"#, with: " ",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "  +", with: " ",
                                   options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.count > maxLength,
           let cut = s.prefix(maxLength).lastIndex(of: " ") {
            s = String(s[..<cut]).trimmingCharacters(in: .whitespaces) + "…"
        } else if s.count > maxLength {
            s = String(s.prefix(maxLength)) + "…"
        }
        return s
    }

    /// Mengubah respons asisten menjadi teks audio yang enak didengar dan lengkap:
    /// - Membaca seluruh penjelasan jika memungkinkan (tidak dipotong 1-2 kalimat).
    /// - Menghilangkan blok kode (``` ... ```) dan baris kode teknis/terminal.
    /// - Menghilangkan URL mentah (https://...), UUID, memory address (0x...), path file sistem (/Users/...).
    /// - Menghilangkan format tabel markdown (|---|---|) dan simbol tanpa arti.
    /// - Jika hanya berupa eksekusi tool (tanpa teks manusia), mengucapkan laporan ramah.
    static func spokenResponse(from markdown: String, maxLength: Int = 4000) -> String {
        var s = markdown

        // 1. Hapus multiline code blocks (``` ... ```) sepenuhnya dari audio
        while let start = s.range(of: "```") {
            guard let end = s.range(of: "```", range: start.upperBound..<s.endIndex) else {
                s = String(s[..<start.lowerBound])
                break
            }
            s = String(s[..<start.lowerBound]) + " " + String(s[end.upperBound...])
        }

        let rawLines = s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !rawLines.isEmpty else { return "" }

        // 2. Filter baris log tool ('→ ...' atau '[Tool ...]')
        let toolLines = rawLines.filter { $0.hasPrefix("→") || $0.hasPrefix("[Tool") || $0.hasPrefix("[tool_") }
        let nonToolLines = rawLines.filter { !$0.hasPrefix("→") && !$0.hasPrefix("[Tool") && !$0.hasPrefix("[tool_") }

        // Jika hanya ada baris eksekusi tool tanpa teks manusia, buat laporan manusiawi
        if nonToolLines.isEmpty {
            if let firstTool = toolLines.first {
                return humanizeToolLine(firstTool)
            }
            return ""
        }

        // 3. Filter baris teknis yang tidak bermakna jika diucapkan:
        // - Garis pemisah tabel markdown (|---|---|)
        // - Baris yang hanya berisi URL mentah
        // - Baris perintah shell atau import kode
        var filteredLines: [String] = []
        let codePrefixes = ["import ", "export ", "#include ", "package ", "curl ", "npm ", "pnpm ", "yarn ", "pip ", "brew ", "sudo ", "git "]

        for line in nonToolLines {
            let lower = line.lowercased()

            // Abaikan garis separator tabel markdown
            if line.contains("|") && line.replacingOccurrences(of: #"[\|\-\:\s]"#, with: "", options: .regularExpression).isEmpty {
                continue
            }

            // Abaikan baris yang hanya berisi URL mentah
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
                continue
            }

            // Abaikan baris perintah kode/terminal langsung
            if codePrefixes.contains(where: { lower.hasPrefix($0) }) {
                continue
            }

            // Rapikan baris tabel: hilangkan garis pembatas '|'
            var cleanLine = line
            if cleanLine.hasPrefix("|") && cleanLine.hasSuffix("|") {
                let columns = cleanLine.split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                cleanLine = columns.joined(separator: ", ")
            }

            filteredLines.append(cleanLine)
        }

        guard !filteredLines.isEmpty else {
            if let firstTool = toolLines.first {
                return humanizeToolLine(firstTool)
            }
            return ""
        }

        // 4. Proses pembersihan teks dalam konten
        var text = filteredLines.joined(separator: "\n")

        // Gambar markdown: ![alt](url) -> alt
        text = replacing(#"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", in: text)
        // Link markdown: [teks](url) -> teks
        text = replacing(#"\[([^\]]+)\]\([^)]*\)"#, with: "$1", in: text)

        // URL mentah di tengah kalimat -> "tautan terkait"
        text = replacing(#"(?i)\bhttps?://[^\s<>"'()]+"#, with: "tautan terkait", in: text)
        text = replacing(#"(?i)\bwww\.[^\s<>"'()]+"#, with: "tautan terkait", in: text)

        // UUID (8-4-4-4-12 hex)
        text = replacing(#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, with: "", in: text)

        // Memory addresses / Hex values (0x...)
        text = replacing(#"\b0x[0-9a-fA-F]+\b"#, with: "", in: text)

        // Hex hashes panjang (commit hash dsb)
        text = replacing(#"\b[0-9a-fA-F]{24,64}\b"#, with: "", in: text)

        // Path direktori Unix panjang (/Users/mymac/...)
        text = replacing(#"(?:\/[\w\.\-]+){3,}"#, with: "", in: text)

        // Headings markdown (# Heading)
        text = replacing(#"(?m)^#{1,6}\s+"#, with: "", in: text)

        // Bullet points di awal baris (- atau * atau + atau •)
        text = replacing(#"(?m)^\s*[-*+•]\s+"#, with: "", in: text)

        // Numbered list (1. atau 1) ) -> "1, "
        text = replacing(#"(?m)^\s*(\d+)[\.\)]\s+"#, with: "$1, ", in: text)

        // Hapus simbol kurung kosong dari fungsi (misal: "myFunc()" -> "myFunc")
        text = text.replacingOccurrences(of: "()", with: "")
        text = text.replacingOccurrences(of: "[]", with: "")
        text = text.replacingOccurrences(of: "{}", with: "")

        // Format markdown biasa
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "~~", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "|", with: " ")
        text = replacing(#"\*(\S[^*]*\S)\*"#, with: "$1", in: text)

        // Simbol pembatas berulang tanpa makna (===, ---, ***, ___, ━━━━)
        text = replacing(#"[=\-_*~#>\/\\\|━─]{2,}"#, with: " ", in: text)

        // Tag HTML
        text = replacing(#"<[^>]+>"#, with: "", in: text)

        // 5. Susun paragraf dengan tanda baca jeda alami
        let paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var finalParagraphs: [String] = []
        for p in paragraphs {
            var para = p
            if let last = para.last, !".!?:,".contains(last) {
                para.append(".")
            }
            finalParagraphs.append(para)
        }

        var speech = finalParagraphs.joined(separator: " ")
        speech = speech.replacingOccurrences(of: #"[\r\t]+"#, with: " ", options: .regularExpression)
        speech = speech.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        speech = speech.replacingOccurrences(of: #"\.{2,}"#, with: "...", options: .regularExpression)
        speech = speech.replacingOccurrences(of: #"\s+([,.:!?])"#, with: "$1", options: .regularExpression)
        speech = speech.trimmingCharacters(in: .whitespacesAndNewlines)

        // 6. Batasi jika melebihi batas maksimal panjang audio (potong pada kalimat terakhir)
        if speech.count > maxLength {
            let prefix = String(speech.prefix(maxLength))
            if let lastSentenceEnd = prefix.range(of: #"[.!?]\s"#, options: [.regularExpression, .backwards]) {
                speech = String(prefix[..<lastSentenceEnd.upperBound]).trimmingCharacters(in: .whitespaces)
            } else if let cut = prefix.lastIndex(of: " ") {
                speech = String(prefix[..<cut]).trimmingCharacters(in: .whitespaces) + "..."
            } else {
                speech = prefix + "..."
            }
        }

        return speech
    }

    /// Alias untuk kompatibilitas mundur
    static func speechSummary(from markdown: String) -> String {
        return spokenResponse(from: markdown)
    }

    /// Mengubah baris tool teknis menjadi kalimat laporan manusiawi
    private static func humanizeToolLine(_ line: String) -> String {
        let lower = line.lowercased()
        if lower.contains("app_open") {
            if lower.contains("wikipedia") {
                return "Berhasil membuka halaman Wikipedia untuk Anda."
            } else if lower.contains("http://") || lower.contains("https://") {
                return "Berhasil membuka halaman website yang Anda minta."
            } else {
                return "Aplikasi berhasil dibuka."
            }
        } else if lower.contains("web_search") {
            return "Pencarian informasi di web telah selesai."
        } else if lower.contains("file_write") || lower.contains("office_write") {
            return "Dokumen berhasil disimpan."
        } else if lower.contains("shell_run") {
            return "Perintah sistem berhasil dijalankan."
        } else if lower.contains("gui_click") || lower.contains("gui_") {
            return "Aksi pada antarmuka berhasil dieksekusi."
        } else if lower.contains("canvas_present") {
            return "Dokumen telah ditampilkan di Canvas Studio."
        }
        return "Tugas berhasil diselesaikan."
    }

    /// Membersihkan URL panjang dan simbol agar enak didengar
    private static func cleanSpokenText(_ text: String) -> String {
        var s = text
        // Ganti URL https://... menjadi "tautan terkait"
        s = s.replacingOccurrences(of: #"https?://[^\s]+"#, with: "halaman terkait", options: .regularExpression)
        // Hilangkan format teknis kurung dan markdown
        s = s.replacingOccurrences(of: #"[<>{}[\]\(\)]"#, with: "", options: .regularExpression)
        return s
    }

    /// Wake-word match, forgiving about case and accents ("Mochi", "MOCHÎ").
    static func containsWakeWord(_ text: String, word: String = "mochi") -> Bool {
        let options: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]
        return text.range(of: word, options: options) != nil
    }

    /// Mengekstrak perintah setelah wake word ("mochi" / "jarvis").
    /// Contoh:
    /// - "Mochi, tolong buka Safari" -> "tolong buka Safari"
    /// - "Jarvis carikan info AI" -> "carikan info AI"
    /// - "Mochi" -> nil (hanya kata panggilan)
    static func extractCommand(from text: String, wakeWords: [String] = ["mochi", "jarvis"]) -> String? {
        let options: String.CompareOptions = [.diacriticInsensitive, .caseInsensitive]
        for word in wakeWords {
            if let range = text.range(of: word, options: options) {
                let after = text[range.upperBound...]
                var cmd = after.trimmingCharacters(in: .whitespacesAndNewlines)
                cmd = cmd.trimmingCharacters(in: CharacterSet(charactersIn: ",:;-!? \t\r\n"))
                if cmd.count >= 2 {
                    return cmd
                }
            }
        }
        return nil
    }

    /// Mengecek apakah ucapan pengguna tampak belum selesai (misalnya berakhir dengan kata hubung/preposisi)
    static func isSentenceIncomplete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let words = trimmed.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.:;!?\"'()")) }
            .filter { !$0.isEmpty }

        guard let lastWord = words.last else { return true }

        // Jika hanya 1 kata pendek (kecuali kata panggilan), beri waktu bicara lanjutan
        if words.count < 2 && lastWord.count < 3 {
            return true
        }

        let hangingWords: Set<String> = [
            // Bahasa Indonesia
            "dan", "atau", "yang", "untuk", "tentang", "mengenai", "di", "ke", "dari",
            "dengan", "karena", "tapi", "tetapi", "bila", "jika", "kalau", "lalu",
            "kemudian", "pada", "seperti", "supaya", "agar", "yaitu", "yakni", "adalah",
            "bahwa", "sebab", "oleh", "ketika", "saat", "apakah", "bagaimana", "mengapa",
            // English
            "and", "or", "that", "which", "to", "for", "about", "in", "on", "at", "from",
            "with", "because", "but", "if", "when", "then", "like", "the", "a", "an",
            "is", "are", "was", "were", "of", "how", "what", "why", "where", "who"
        ]

        return hangingWords.contains(lastWord)
    }

    /// Finalize a recognition transcript: nil when there is nothing to send.
    static func finalizeTranscript(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func replacing(_ pattern: String, with template: String, in s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
