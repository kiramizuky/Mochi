import Foundation
import AppKit

// MARK: - Ambient Context Observer
// Mendeteksi aplikasi aktif di macOS dan memicu rekomendasi proaktif cerdas ke Notch.

public final class AmbientContextObserver: @unchecked Sendable {
    public static let shared = AmbientContextObserver()

    private var workspaceObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var lastAppBundle: String = ""
    private var isObserving = false

    private init() {}

    /// Memulai observasi perpindahan aplikasi aktif pengguna.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isObserving else { return }
        isObserving = true

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.handleAppActivated(app)
        }

        // Panggil evaluasi awal untuk aplikasi aktif saat ini
        if let currentApp = NSWorkspace.shared.frontmostApplication {
            handleAppActivated(currentApp)
        }
    }

    /// Menghentikan observasi.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isObserving else { return }
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        isObserving = false
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        let bundleId = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? "App"

        if bundleId == lastAppBundle && !bundleId.isEmpty { return }
        lastAppBundle = bundleId

        // Jangan reaktif jika Coucou sendiri yang aktif
        if bundleId == Bundle.main.bundleIdentifier { return }

        Task { @MainActor in
            self.generateContextualSuggestions(appName: appName, bundleId: bundleId)
        }
    }

    @MainActor
    private func generateContextualSuggestions(appName: String, bundleId: String) {
        let lowerName = appName.lowercased()
        let lowerBundle = bundleId.lowercased()

        var contextChips: [ProactiveChip] = []

        if lowerName.contains("excel") || lowerBundle.contains("excel") || lowerName.contains("numbers") {
            contextChips = [
                ProactiveChip(
                    id: "ambient_excel_rekap",
                    text: "📊 Rekap data sheet",
                    fact: "Analisis dan buat ringkasan data dari worksheet Excel aktif"
                ),
                ProactiveChip(
                    id: "ambient_excel_clean",
                    text: "🧹 Cek anomali sel",
                    fact: "Periksa sheet Excel aktif dan temukan sel kosong atau nilai anomali"
                ),
                ProactiveChip(
                    id: "ambient_excel_word",
                    text: "📑 Ekspor ke Word",
                    fact: "Salin ringkasan data tabel Excel aktif ke dokumen Microsoft Word berformat"
                )
            ]
        } else if lowerName.contains("word") || lowerBundle.contains("word") || lowerName.contains("pages") {
            contextChips = [
                ProactiveChip(
                    id: "ambient_word_polish",
                    text: "📝 Rapikan format & ejaan",
                    fact: "Periksa dan rapikan tata bahasa serta struktur dokumen Word yang sedang dibuka"
                ),
                ProactiveChip(
                    id: "ambient_word_summary",
                    text: "📌 Buat Executive Summary",
                    fact: "Buatkan ringkasan eksekutif 3 poin untuk dokumen Word ini"
                ),
                ProactiveChip(
                    id: "ambient_word_sop",
                    text: "📋 Format ke standar SOP",
                    fact: "Format dokumen Word aktif ini menggunakan template SOP terstruktur"
                )
            ]
        } else if lowerName.contains("code") || lowerName.contains("xcode") || lowerName.contains("cursor") || lowerName.contains("terminal") {
            contextChips = [
                ProactiveChip(
                    id: "ambient_code_git",
                    text: "🔍 Review Git Changes",
                    fact: "Periksa git status dan jelaskan ringkasan perubahan kode terbaru"
                ),
                ProactiveChip(
                    id: "ambient_code_test",
                    text: "🧪 Run Project Tests",
                    fact: "Jalankan unit test pada proyek yang sedang dibuka dan laporkan hasilnya"
                )
            ]
        } else if lowerName.contains("safari") || lowerName.contains("chrome") || lowerName.contains("arc") || lowerName.contains("browser") {
            contextChips = [
                ProactiveChip(
                    id: "ambient_browser_summary",
                    text: "🌐 Ringkas Halaman Web",
                    fact: "Baca dan buat intisari dari artikel pada browser yang sedang aktif"
                ),
                ProactiveChip(
                    id: "ambient_browser_save",
                    text: "💾 Simpan ke Memori",
                    fact: "Simpan poin penting dari halaman web aktif ini ke memori personal saya"
                )
            ]
        } else if lowerName.contains("mail") || lowerName.contains("outlook") {
            contextChips = [
                ProactiveChip(
                    id: "ambient_mail_reply",
                    text: "✉️ Draft Balasan Sopan",
                    fact: "Bantu buatkan draf balasan profesional dan ramah untuk email aktif ini"
                )
            ]
        }

        // Padukan dengan chip kebiasaan dan memori
        ProactiveEngine.shared.refresh()
        var currentChips = ProactiveEngine.shared.chips

        // Masukkan chip kontekstual di posisi paling depan
        if !contextChips.isEmpty {
            currentChips.insert(contentsOf: contextChips, at: 0)
        }

        AppState.shared.proactiveChips = currentChips
    }
}
