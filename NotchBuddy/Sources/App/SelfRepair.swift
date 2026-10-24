import Foundation

// MARK: - Self-repair (perluas HealthService)

/// Self-repair otomatis: jika provider aktif invalid → pindah ke alternatif;
/// jika izin hilang → arahkan ke Settings; jika tool error berulang → coba alternatif.
final class SelfRepair: @unchecked Sendable {
    static let shared = SelfRepair()
    private init() {}

    /// Periksa dan perbaiki kondisi umum. Mengembalikan daftar tindakan yang diambil.
    func repair() -> [String] {
        var actions: [String] = []

        // 1. Provider aktif tidak terkonfigurasi → pindah ke alternatif ber-kunci.
        if !HealthService.shared.apiKeyOK() {
            let alternatives = ProviderRegistry.shared.available.filter { $0.isConfigured() }
            if let replacement = alternatives.first(where: { $0.id != ProviderRegistry.shared.activeProviderId }) {
                ProviderRegistry.shared.setActiveProvider(id: replacement.id)
                actions.append("Pindah provider aktif ke \(replacement.id) karena kunci sebelumnya kosong.")
            }
        }

        // 2. Izin mikrofon / Accessibility / Screen Recording hilang → catat ke audit.
        // (Tidak dapat memaksa izin dari dalam aplikasi; hanya mencatat agar user mengetahui.)
        if !HealthService.shared.micGranted() {
            AuditLog().record(category: .appControl, action: "self_repair.mic", target: "",
                              decision: .deny, reason: "Mikrofon belum diizinkan — arahkan ke System Settings.")
            actions.append("Mikrofon belum diizinkan.")
        }
        if !HealthService.shared.axGranted() {
            AuditLog().record(category: .appControl, action: "self_repair.accessibility", target: "",
                              decision: .deny, reason: "Accessibility belum diizinkan — arahkan ke System Settings.")
            actions.append("Accessibility belum diizinkan.")
        }
        if !HealthService.shared.screenGranted() {
            AuditLog().record(category: .appControl, action: "self_repair.screen", target: "",
                              decision: .deny, reason: "Tangkap layar belum diizinkan — arahkan ke System Settings.")
            actions.append("Tangkap layar belum diizinkan.")
        }

        // 3. Ruang disk hampir penuh → catat peringatan.
        if !HealthService.shared.freeDisk() {
            AuditLog().record(category: .appControl, action: "self_repair.disk", target: "",
                              decision: .deny, reason: "Ruang disk hampir penuh.")
            actions.append("Ruang disk hampir penuh.")
        }

        return actions
    }

    /// Jalankan self-repair dan publikasikan hasil ke island (note message).
    func repairAndReport() {
        let actions = repair()
        if !actions.isEmpty {
            Task { @MainActor in
                AppState.shared.noteMessage = actions.joined(separator: " ")
                AppState.shared.view = .note
            }
        }
    }
}
