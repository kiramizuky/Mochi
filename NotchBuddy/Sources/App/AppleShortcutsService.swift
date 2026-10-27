import Foundation
import AppKit

// MARK: - Apple Shortcuts & Siri Deep Integration (Paket 13)

/// Layanan integrasi dua arah dengan Apple Shortcuts dan Siri pada macOS.
/// Memungkinkan Mochi mengeksekusi Shortcut sistem macOS, sekaligus menerima instruksi dari Siri via URL scheme (coucou://).
public final class AppleShortcutsService: @unchecked Sendable {
    public static let shared = AppleShortcutsService()

    private init() {}

    // MARK: - Process Execution Helper

    private func runProcess(executable: String, arguments: [String]) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(returning: (error.localizedDescription, -1))
                }
            }
        }
    }

    // MARK: - 1. List Apple Shortcuts

    /// Mengambil daftar semua Apple Shortcuts yang terpasang di Mac dengan opsi filter kata kunci nama.
    public func listShortcuts(filter: String? = nil) async -> (success: Bool, output: String, shortcuts: [String]) {
        let (output, exitCode) = await runProcess(executable: "/usr/bin/shortcuts", arguments: ["list"])
        guard exitCode == 0 else {
            return (false, "Gagal mengambil daftar Apple Shortcuts (exit code \(exitCode)): \(output)", [])
        }
        var list = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let filter = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            list = list.filter { $0.localizedCaseInsensitiveContains(filter) }
        }

        if list.isEmpty {
            let msg = filter != nil ? "Tidak ditemukan Apple Shortcut dengan kata kunci '\(filter!)'." : "Tidak ada Apple Shortcut yang terpasang."
            return (true, msg, [])
        }

        let formatted = list.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let summary = "Daftar Apple Shortcuts Terpasang (\(list.count)):\n\(formatted)"
        return (true, summary, list)
    }

    /// Mengambil daftar nama shortcut (backward compatibility array).
    public func listShortcuts() async -> [String] {
        let (_, _, list) = await listShortcuts(filter: nil)
        return list
    }

    // MARK: - 2. Run Apple Shortcut

    /// Menjalankan Apple Shortcut tertentu dengan input opsional.
    public func runShortcut(name: String, input: String? = nil) async -> (success: Bool, output: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return (false, "Nama Shortcut tidak boleh kosong.")
        }

        var args = ["run", trimmedName]
        if let input = input, !input.isEmpty {
            args.append(contentsOf: ["-i", input])
        }

        let (output, exitCode) = await runProcess(executable: "/usr/bin/shortcuts", arguments: args)
        if exitCode == 0 {
            let resultMsg = output.isEmpty ? "Shortcut '\(trimmedName)' berhasil dieksekusi." : output
            return (true, resultMsg)
        } else {
            return (false, "Gagal menjalankan shortcut '\(trimmedName)': \(output)")
        }
    }

    // MARK: - 3. Open Shortcuts App

    /// Membuka aplikasi Apple Shortcuts bawaan macOS.
    public func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
        }
    }

    // MARK: - 4. Incoming URL Scheme Dispatcher (coucou:// & mochi://)

    /// Menangani URL scheme yang dipicu dari Siri, Shortcuts, atau browser.
    /// Contoh:
    /// - `coucou://ask?query=Halo`
    /// - `coucou://run?goal=Periksa+keamanan+laptop`
    /// - `coucou://canvas?title=Catatan&content=Isi+Laporan`
    /// - `coucou://sentry?action=away`
    @MainActor
    @discardableResult
    public func handleIncomingURL(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return "URL tidak valid."
        }

        let action = (components.host ?? components.path).lowercased().replacingOccurrences(of: "/", with: "")
        let queryParams = components.queryItems?.reduce(into: [String: String]()) { dict, item in
            dict[item.name.lowercased()] = item.value
        } ?? [:]

        switch action {
        case "ask":
            let query = queryParams["query"] ?? queryParams["q"] ?? ""
            if !query.isEmpty {
                AppState.shared.promptPrefill = query
                AppState.shared.view = .prompt
                AppState.shared.mode = .compact
                return "Prompt dibuka dengan pertanyaan: \"\(query)\""
            }
            return "Harap sertakan parameter ?query=..."

        case "run", "goal":
            let goal = queryParams["goal"] ?? queryParams["task"] ?? queryParams["g"] ?? ""
            if !goal.isEmpty {
                Task {
                    _ = await AutonomousAgent.shared.submit(goal: goal, source: "shortcuts")
                }
                return "Tugas otonom diajukan: \"\(goal)\""
            }
            return "Harap sertakan parameter ?goal=..."

        case "canvas":
            let title = queryParams["title"] ?? "Catatan Siri / Shortcuts"
            let content = queryParams["content"] ?? queryParams["body"] ?? "Tidak ada konten."
            let typeStr = queryParams["type"] ?? "document"
            let artifactType = ArtifactType(rawValue: typeStr) ?? .document

            let artifact = CanvasArtifact(
                id: "shortcuts-\(UUID().uuidString.prefix(6))",
                title: title,
                type: artifactType,
                content: content
            )
            CanvasManager.shared.present(artifact: artifact)
            return "Canvas berhasil ditampilkan: \"\(title)\""

        case "sentry":
            let act = queryParams["action"] ?? queryParams["mode"] ?? "enable"
            if act == "enable" || act == "away" || act == "arm" {
                _ = ProactiveSentryService.shared.enableAwayMode()
                return "Away Sentry Mode berhasil diaktifkan via Shortcuts/Siri."
            } else {
                _ = ProactiveSentryService.shared.disableAwayMode()
                return "Away Sentry Mode dinonaktifkan via Shortcuts/Siri."
            }

        case "autoheal":
            Task {
                _ = await ProactiveSentryService.shared.runAutoHealAudit()
            }
            return "Audit Auto-Healer container & server dipicu via Shortcuts/Siri."

        case "media", "player":
            let act = queryParams["action"] ?? queryParams["a"] ?? "toggle"
            let targetFile = queryParams["target"] ?? queryParams["file"] ?? queryParams["path"]

            if let file = targetFile, !file.isEmpty {
                let res = MediaManagerService.shared.inspectAndPresentMedia(path: file, presentInNotch: true, presentInCanvas: false)
                return res.message
            }

            switch act {
            case "play", "resume":
                MediaManagerService.shared.resumePlayback()
                return "Media play dipicu via Shortcuts/Siri."
            case "pause", "stop":
                MediaManagerService.shared.pausePlayback()
                return "Media pause dipicu via Shortcuts/Siri."
            case "next":
                MediaManagerService.shared.nextTrack()
                return "Media next track dipicu via Shortcuts/Siri."
            case "previous", "prev":
                MediaManagerService.shared.previousTrack()
                return "Media previous track dipicu via Shortcuts/Siri."
            default:
                MediaManagerService.shared.togglePlayPause()
                return "Media toggle play/pause dipicu via Shortcuts/Siri."
            }

        default:
            return "Aksi URL scheme tidak dikenali: '\(action)'"
        }
    }
}

