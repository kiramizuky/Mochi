import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK- ScreenAgent — baca konteks layar aktif untuk LLM (multimodal)

// ScreenAgent membaca konteks aplikasi yang sedang aktif melalui Accessibility
// API, lalu menyajikan ringkasan teks yang dapat dikirim ke LLM sebagai
// konteks "apa yang sedang dilihat pengguna". Opt-in: hanya berjalan saat
// izin Accessibility telah diberikan. Tangkapan layar (screenshot) tersedia
// sebagai opsi melalui AppController.

/// Ringkasan konteks layar saat ini.
struct ScreenContext: Sendable, Equatable {
    var appName: String
    var bundleId: String
    var focusedElement: String?   // teks elemen yang difokuskan
    var title: String?            // judul jendela (jika tersedia)
    var url: String?              // URL browser (jika bisa dibaca)
    var elementSummary: String    // ringkasan elemen teks di layar
    var screenshotAvailable: Bool // apakah screenshot bisa diambil
}

/// Agen pemahaman layar: membaca konteks UI aktif untuk disuntik ke LLM.
final class ScreenAgent: @unchecked Sendable {
    static let shared = ScreenAgent()

    private let ax: any AXClientProtocol
    private let appController: AppController
    private var grantedOverride: Bool?

    init(ax: any AXClientProtocol = SystemAXClient(),
         appController: AppController = AppController(),
         accessibilityGranted: Bool? = nil) {
        self.ax = ax
        self.appController = appController
        self.grantedOverride = accessibilityGranted
    }

    /// Apakah izin Accessibility telah diberikan (prasyarat baca layar).
    var isAccessibilityGranted: Bool { grantedOverride ?? AXIsProcessTrusted() }

    /// Baca konteks layar saat ini. Mengembalikan nil bila izin AX tidak tersedia
    /// atau tidak ada aplikasi frontmost.
    func currentContext() -> ScreenContext? {
        guard isAccessibilityGranted else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let snapshot: AXSnapshot?
        do { snapshot = try ax.snapshot() } catch { snapshot = nil }

        let elements = snapshot?.elements ?? []
        let focused = snapshot?.focused ?? ""
        let labels = elements.prefix(12).map { $0.label }.filter { !$0.isEmpty }
        let elementSummary = labels.isEmpty
            ? "Tidak ada elemen teks yang terbaca di layar."
            : labels.joined(separator: " | ")

        let appName = snapshot?.appName ?? app.localizedName ?? app.bundleIdentifier ?? "Unknown"

        return ScreenContext(
            appName: appName,
            bundleId: app.bundleIdentifier ?? "",
            focusedElement: focused.isEmpty ? nil : focused,
            title: nil,
            url: nil,
            elementSummary: elementSummary,
            screenshotAvailable: true
        )
    }

    /// Ringkasan layar diformat sebagai teks konteks untuk LLM.
    func contextText() -> String? {
        guard let ctx = currentContext() else { return nil }
        var lines: [String] = []
        lines.append("Aplikasi aktif: \(ctx.appName) (\(ctx.bundleId))")
        if let title = ctx.title { lines.append("Judul/fokus: \(title)") }
        lines.append("Elemen layar: \(ctx.elementSummary)")
        lines.append("Tangkapan layar tersedia: \(ctx.screenshotAvailable ? "ya" : "tidak")")
        return lines.joined(separator: "\n")
    }

    /// Ambil screenshot jendela aktif sebagai PNG data (untuk dikirim sebagai image block ke LLM).
    /// Mengembalikan nil bila izin Screen Recording belum diberikan atau gagal.
    func currentScreenshot() async -> Data? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        do {
            let capture = try await appController.capture(app.localizedName ?? app.bundleIdentifier ?? "")
            // capture mengembalikan String path; baca data dari file
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: capture.path)) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
