import Foundation

// MARK: - App automation (AppleScript / JavaScript for Automation)

/// Jalankan skrip otomatisasi aplikasi melalui `osascript` (AppleScript atau
/// JavaScript for Automation). Skrip ditulis ke file temp lalu dieksekusi —
/// input pengguna **tidak** dilempar ke shell, sehingga tidak ada injeksi shell.
enum AppAutomation {
    enum Language: Sendable, Equatable {
        case applescript
        case javascript
    }

    static func run(_ script: String, language: Language = .applescript,
                    timeout: TimeInterval = 15) throws -> String {
        // Tuliskan skrip ke file temp agar input pengguna tidak pernah sentuh shell.
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("jarvis-automation-\(UUID().uuidString).scpt")
        try script.data(using: .utf8)?.write(to: url)

        let langFlag: String
        switch language {
        case .applescript: langFlag = "AppleScript"
        case .javascript:  langFlag = "JavaScript"
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-l", langFlag, url.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        let outPipe = task.standardOutput as! Pipe
        let errPipe = task.standardError as! Pipe

        do { try task.run() } catch {
            throw AppAutomationError.failed("Cannot start osascript: \(error.localizedDescription)")
        }

        // Timeout
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            if task.isRunning { task.terminate() }
        }

        task.waitUntilExit()
        try? fm.removeItem(at: url)

        guard task.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw AppAutomationError.failed("osascript exit \(task.terminationStatus): \(msg)")
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Office Suite Automation

    /// Baca teks yang sedang diseleksi pada aplikasi Office atau aplikasi aktif.
    static func readOfficeSelection(app: String? = nil) throws -> String {
        let targetApp = app?.trimmingCharacters(in: .whitespacesAndNewlines)
        let script: String

        if let targetApp, !targetApp.isEmpty {
            let lower = targetApp.lowercased()
            if lower.contains("word") {
                script = """
                tell application "Microsoft Word"
                    if not (exists active document) then return "Tidak ada dokumen aktif di Word."
                    return (content of text object of selection) as text
                end tell
                """
            } else if lower.contains("excel") {
                script = """
                tell application "Microsoft Excel"
                    if not (exists active workbook) then return "Tidak ada workbook aktif di Excel."
                    return (string value of selection) as text
                end tell
                """
            } else if lower.contains("pages") {
                script = """
                tell application "Pages"
                    if not (exists front document) then return "Tidak ada dokumen terbuka di Pages."
                    return (selected text of front document) as text
                end tell
                """
            } else if lower.contains("textedit") {
                script = """
                tell application "TextEdit"
                    if not (exists front document) then return "Tidak ada dokumen terbuka di TextEdit."
                    return (text of front document) as text
                end tell
                """
            } else {
                script = """
                tell application "\(targetApp)" to activate
                tell application "System Events"
                    keystroke "c" using command down
                end tell
                delay 0.1
                return the clipboard
                """
            }
        } else {
            // Frontmost active application
            script = """
            set frontApp to ""
            tell application "System Events"
                set frontApp to name of first application process whose frontmost is true
            end tell
            
            if frontApp contains "Word" then
                tell application "Microsoft Word"
                    if exists active document then
                        return (content of text object of selection) as text
                    end if
                end tell
            else if frontApp contains "Excel" then
                tell application "Microsoft Excel"
                    if exists active workbook then
                        return (string value of selection) as text
                    end if
                end tell
            end if
            
            tell application "System Events"
                keystroke "c" using command down
            end tell
            delay 0.1
            return the clipboard
            """
        }

        return try run(script)
    }

    /// Baca tabel / range spreadsheet dari Excel, Numbers, atau aplikasi aktif.
    static func readOfficeTable(app: String? = nil, range: String? = nil) throws -> String {
        let targetApp = app?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "excel"
        let rangeParam = range?.trimmingCharacters(in: .whitespacesAndNewlines)

        let script: String
        if targetApp.contains("numbers") {
            script = """
            tell application "Numbers"
                if not (exists front document) then return "Tidak ada dokumen aktif di Numbers."
                tell front document
                    tell active sheet
                        tell first table
                            set outList to {}
                            repeat with r from 1 to count of rows
                                set rowVals to {}
                                repeat with c from 1 to count of columns
                                    set cellVal to value of cell c of row r
                                    if cellVal is missing value then set cellVal to ""
                                    set end of rowVals to (cellVal as text)
                                end repeat
                                set AppleScript's text item delimiters to "\\t"
                                set end of outList to (rowVals as text)
                            end repeat
                            set AppleScript's text item delimiters to linefeed
                            return outList as text
                        end tell
                    end tell
                end tell
            end tell
            """
        } else {
            // Default Microsoft Excel
            let rangeClause: String
            if let rangeParam, !rangeParam.isEmpty {
                rangeClause = "range \"\(rangeParam)\" of active sheet"
            } else {
                rangeClause = "used range of active sheet"
            }

            script = """
            tell application "Microsoft Excel"
                if not (exists active workbook) then return "Tidak ada workbook aktif di Excel."
                tell active workbook
                    set rawData to (string value of \(rangeClause))
                    return rawData as text
                end tell
            end tell
            """
        }

        return try run(script)
    }

    /// Menulis atau menyisipkan teks ke dalam dokumen Office aktif.
    static func writeOfficeText(text: String, app: String? = nil, mode: String = "insert") throws -> String {
        let targetApp = app?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAppend = mode.lowercased() == "append"
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if let targetApp, !targetApp.isEmpty {
            let lower = targetApp.lowercased()
            if lower.contains("word") {
                if isAppend {
                    script = """
                    tell application "Microsoft Word"
                        if not (exists active document) then return "Tidak ada dokumen aktif di Word."
                        tell text object of active document
                            insert text "\(escapedText)" at end
                        end tell
                        return "Teks berhasil ditambahkan di akhir dokumen Word."
                    end tell
                    """
                } else {
                    script = """
                    tell application "Microsoft Word"
                        if not (exists active document) then return "Tidak ada dokumen aktif di Word."
                        set content of text object of selection to "\(escapedText)"
                        return "Teks berhasil disisipkan pada kursor Word."
                    end tell
                    """
                }
            } else if lower.contains("textedit") {
                if isAppend {
                    script = """
                    tell application "TextEdit"
                        if not (exists front document) then make new document
                        make new paragraph at end of text of front document with data ("\(escapedText)" & linefeed)
                        return "Teks ditambahkan di TextEdit."
                    end tell
                    """
                } else {
                    script = """
                    set the clipboard to "\(escapedText)"
                    tell application "TextEdit" to activate
                    tell application "System Events" to keystroke "v" using command down
                    return "Teks ditempelkan di TextEdit."
                    """
                }
            } else {
                script = """
                set the clipboard to "\(escapedText)"
                tell application "\(targetApp)" to activate
                delay 0.1
                tell application "System Events" to keystroke "v" using command down
                return "Teks ditempelkan ke \(targetApp)."
                """
            }
        } else {
            script = """
            set frontApp to ""
            tell application "System Events"
                set frontApp to name of first application process whose frontmost is true
            end tell
            
            if frontApp contains "Word" then
                tell application "Microsoft Word"
                    if exists active document then
                        set content of text object of selection to "\(escapedText)"
                        return "Teks berhasil disisipkan ke Word."
                    end if
                end tell
            end if
            
            set the clipboard to "\(escapedText)"
            tell application "System Events" to keystroke "v" using command down
            return "Teks ditempelkan ke aplikasi aktif (" & frontApp & ")."
            """
        }

        return try run(script)
    }

    // MARK: - Multi-Sheet Excel Automation

    /// Mendapatkan daftar seluruh nama sheet/tab di workbook Excel atau Numbers aktif.
    static func listExcelSheets(app: String? = nil) throws -> [String] {
        let targetApp = app?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "excel"

        let script: String
        if targetApp.contains("numbers") {
            script = """
            tell application "Numbers"
                if not (exists front document) then return ""
                tell front document
                    set sheetNames to name of every sheet
                    set AppleScript's text item delimiters to "|||"
                    return sheetNames as text
                end tell
            end tell
            """
        } else {
            script = """
            tell application "Microsoft Excel"
                if not (exists active workbook) then return ""
                tell active workbook
                    set sheetNames to name of every worksheet
                    set AppleScript's text item delimiters to "|||"
                    return sheetNames as text
                end tell
            end tell
            """
        }

        let output = try run(script)
        if output.isEmpty { return [] }
        return output.components(separatedBy: "|||").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Membaca data dari worksheet tertentu berdasarkan nama sheet.
    static func readExcelSheetData(sheetName: String, range: String? = nil, app: String? = nil) throws -> String {
        let targetApp = app?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "excel"
        let rangeParam = range?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeSheet = sheetName.replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if targetApp.contains("numbers") {
            script = """
            tell application "Numbers"
                if not (exists front document) then return "Tidak ada dokumen aktif di Numbers."
                tell front document
                    if not (exists sheet "\(safeSheet)") then return "Sheet '\\(safeSheet)' tidak ditemukan."
                    tell sheet "\(safeSheet)"
                        if (count of tables) = 0 then return "Tidak ada tabel pada sheet '\\(safeSheet)'."
                        tell first table
                            set outList to {}
                            repeat with r from 1 to count of rows
                                set rowVals to {}
                                repeat with c from 1 to count of columns
                                    set cellVal to value of cell c of row r
                                    if cellVal is missing value then set cellVal to ""
                                    set end of rowVals to (cellVal as text)
                                end repeat
                                set AppleScript's text item delimiters to "\\t"
                                set end of outList to (rowVals as text)
                            end repeat
                            set AppleScript's text item delimiters to linefeed
                            return outList as text
                        end tell
                    end tell
                end tell
            end tell
            """
        } else {
            let rangeClause: String
            if let rangeParam, !rangeParam.isEmpty {
                rangeClause = "range \"\(rangeParam)\" of worksheet \"\(safeSheet)\""
            } else {
                rangeClause = "used range of worksheet \"\(safeSheet)\""
            }

            script = """
            tell application "Microsoft Excel"
                if not (exists active workbook) then return "Tidak ada workbook aktif di Excel."
                tell active workbook
                    try
                        set rawData to (string value of \(rangeClause))
                        return rawData as text
                    on error errMsg
                        return "Gagal membaca sheet '\\(safeSheet)': " & errMsg
                    end try
                end tell
            end tell
            """
        }

        return try run(script)
    }

    // MARK: - Word Structured Document & Templating

    /// Menghasilkan dokumen Word berformat terstruktur (Title, Subtitle, Sections dengan Heading dan Konten).
    static func writeWordFormatted(title: String, subtitle: String? = nil, sections: [(heading: String, body: String)], app: String? = nil) throws -> String {
        var docText = "\(title.uppercased())\n"
        if let sub = subtitle, !sub.isEmpty {
            docText += "\(sub)\n"
        }
        docText += String(repeating: "=", count: 40) + "\n\n"

        for sec in sections {
            docText += "## \(sec.heading.uppercased())\n"
            docText += "\(sec.body)\n\n"
        }

        return try writeOfficeText(text: docText, app: app ?? "Microsoft Word", mode: "append")
    }

    /// Mengganti placeholder format `{{KEY}}` di dokumen Word aktif dengan nilai yang ditentukan.
    static func replaceWordPlaceholders(replacements: [String: String], app: String? = nil) throws -> String {
        guard !replacements.isEmpty else { return "Tidak ada variabel pengganti." }

        var scripts: [String] = []
        for (key, val) in replacements {
            let safeKey = "{{\(key)}}".replacingOccurrences(of: "\"", with: "\\\"")
            let safeVal = val.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")

            let step = """
            set findObj to find object of text object of active document
            tell findObj
                clear formatting
                set forward to true
                set text to "\(safeKey)"
                set match case to false
                set match whole word to false
                tell its replacement
                    clear formatting
                    set text to "\(safeVal)"
                end tell
                execute find replace replace all
            end tell
            """
            scripts.append(step)
        }

        let combinedScript = """
        tell application "Microsoft Word"
            if not (exists active document) then return "Tidak ada dokumen aktif di Word."
            \(scripts.joined(separator: "\n"))
            return "Placeholder berhasil diganti (\(replacements.count) variabel)."
        end tell
        """

        return try run(combinedScript)
    }
}

enum AppAutomationError: Error, Equatable, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let m): return "Automation error: \(m)"
        }
    }
}
