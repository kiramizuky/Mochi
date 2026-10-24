import Foundation
import AVFoundation
import ApplicationServices
import CoreGraphics

// MARK: - Kesehatan aplikasi + self-repair ringan

/// Satu indikator kesehatan (tampil di Settings, dan dicatat ke AuditLog).
struct HealthStatus: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var ok: Bool
    var detail: String
}

/// Cek kesehatan app (API key, izin mikrofon/Accessibility/Screen Recording, ruang disk)
/// dan self-repair sederhana. Semua probe diinject via closure agar dapat diuji
/// tanpa memicu izin sistem sebenarnya.
final class HealthService: @unchecked Sendable {
    static let shared = HealthService()
    private init() {}

    /// Probe — default memakai sistem sebenarnya; tests menyuntikkan sendiri.
    var apiKeyOK: () -> Bool = { ProviderRegistry.shared.activeProvider.isConfigured() }
    var micGranted: () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var axGranted: () -> Bool = { AXIsProcessTrusted() }
    var screenGranted: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var freeDisk: () -> Bool = {
        let bytes = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap { $0.volumeAvailableCapacityForImportantUsage } ?? -1
        return bytes > 0
    }

    /// Audit sink: (category, action, decision, detail). Default mencatat ke AuditLog.
    var audit: (String, String, PolicyDecision, String?) -> Void = { category, action, decision, detail in
        AuditLog().record(category: ActionCategory(rawValue: category) ?? .read,
                          action: action, target: "", decision: decision, reason: detail)
    }

    /// Cek semua indikator; setiap hasil dicatat ke AuditLog (`.read` — selalu lolos policy).
    func check() -> [HealthStatus] {
        let probes: [(id: String, label: String, ok: Bool, detail: String)] = [
            ("api_key", "API key", apiKeyOK(),
             apiKeyOK() ? "terkonfigurasi" : "belum diatur (Settings → pilih provider)"),
            ("microphone", "Mikrofon", micGranted(),
             micGranted() ? "diizinkan" : "belum diizinkan (Settings → pilih provider)"),
            ("accessibility", "Accessibility", axGranted(),
             axGranted() ? "diizinkan" : "belum diizinkan (macOS → Privacy & Security)"),
            ("screen_capture", "Tangkap layar", screenGranted(),
             screenGranted() ? "diizinkan" : "belum diizinkan (macOS → Privacy & Security)"),
            ("disk_space", "Ruang disk", freeDisk(),
             freeDisk() ? "tersedia" : "penuh hampir — ruang lain akan dibutuhkan"),
        ]
        return probes.map { p in
            let status = HealthStatus(id: p.id, label: p.label, ok: p.ok, detail: p.detail)
            audit("read", "health.check.\(p.id)", p.ok ? .allow : .deny, p.detail)
            return status
        }
    }

    /// Self-repair sederhana: jika provider aktif tidak terkonfigurasi, pindah ke
    /// provider lain yang sudah memiliki kunci di Keychain. Hasilnya dicatat AuditLog.
    func selfRepair() {
        guard !apiKeyOK() else { return }
        let alternatives = ProviderRegistry.shared.available.filter { $0.isConfigured() }
        guard let replacement = alternatives.first(where: { $0.id != ProviderRegistry.shared.activeProviderId }) else {
            audit("app_control", "health.self_repair", .deny, "tidak ada provider alternatif dengan kunci")
            return
        }
        ProviderRegistry.shared.setActiveProvider(id: replacement.id)
        audit("app_control", "health.self_repair", .allow,
              "pindah provider aktif ke \(replacement.id) karena kunci sebelumnya kosong")
    }
}
