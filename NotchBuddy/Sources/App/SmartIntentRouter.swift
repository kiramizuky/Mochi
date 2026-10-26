import Foundation

// MARK: - Smart Intent Router (Edge vs Cloud Hybrid Orchestration)

public enum ExecutionTier: String, Sendable, CaseIterable {
    case localSLM = "local_edge"           // On-device MLX/Local: <50ms, gratis, privasi penuh
    case cloudLLM = "cloud_advanced"       // Claude Sonnet / GPT-4o: multi-step complex reasoning
    case autonomousWorkflow = "autonomous_workflow" // Multi-step autonomous planning & execution
}

public struct RoutedExecution: Sendable, Equatable {
    public let providerId: String
    public let model: String
    public let tier: ExecutionTier
    public let reason: String

    public init(providerId: String, model: String, tier: ExecutionTier, reason: String) {
        self.providerId = providerId
        self.model = model
        self.tier = tier
        self.reason = reason
    }
}

public final class SmartIntentRouter: @unchecked Sendable {
    public static let shared = SmartIntentRouter()
    private init() {}

    /// Menentukan tier eksekusi terbaik berdasarkan sifat perintah dan ketersediaan koneksi.
    public func resolveTier(for query: String) -> ExecutionTier {
        let q = query.lowercased()

        // 1. Jika pengguna secara eksplisit meminta local atau offline
        if q.contains("offline") || q.contains("secara lokal") || q.contains("on-device") || q.contains("tanpa internet") {
            return .localSLM
        }

        // 2. Deteksi alur kerja otonom multi-langkah
        let autonomousKeywords = [
            "jadwalkan ", "alur kerja", "otomatiskan", "task otonom",
            "proyek otonom", "lakukan riset lalu", "selidiki dan buat",
            "analisis seluruh", "workflow", "buatkan playbook"
        ]
        if autonomousKeywords.contains(where: { q.contains($0) }) {
            return .autonomousWorkflow
        }

        // 3. Pola tugas cepat/rutin lokal
        let localActionKeywords = [
            "buka aplikasi", "tutup aplikasi", "open app", "close app",
            "rapikan folder", "cek kapasitas disk", "cek storage",
            "salin ke clipboard", "format tanggal", "hitung ",
            "pindahkan mouse", "klik tombol", "scroll ", "mute suara",
            "atur volume", "ambil screenshot", "capture screen"
        ]

        let isSimpleRoutine = localActionKeywords.contains { q.contains($0) }
        let isShortText = q.split(separator: " ").count <= 8

        if isSimpleRoutine && isShortText {
            return .localSLM
        }

        // 4. Tugas analitis, penulisan mendalam, atau riset web diarahkan ke Cloud LLM
        return .cloudLLM
    }

    /// Menentukan provider dan model terbaik berdasarkan query dan status provider yang terdaftar.
    func selectExecution(
        for query: String,
        activeProvider: any LLMProvider,
        activeModel: String
    ) -> (provider: any LLMProvider, model: String, tier: ExecutionTier, reason: String) {
        // Cek apakah smart routing diaktifkan pengguna (default true)
        let isSmartRoutingEnabled = UserDefaults.standard.object(forKey: "smartIntentRoutingEnabled") as? Bool ?? true
        guard isSmartRoutingEnabled else {
            return (activeProvider, activeModel, .cloudLLM, "Routing cerdas dinonaktifkan di pengaturan")
        }

        let tier = resolveTier(for: query)

        switch tier {
        case .localSLM:
            // Cek apakah provider Local MLX / Ollama terdaftar dan aktif
            if let local = ProviderRegistry.shared.provider(id: "local_mlx") {
                return (
                    provider: local,
                    model: local.defaultModel,
                    tier: .localSLM,
                    reason: "Tugas rutin dialihkan ke Edge SLM untuk privasi penuh & latensi cepat."
                )
            }
            // Jika local provider tidak ditemukan, fallback ke activeProvider
            return (
                provider: activeProvider,
                model: activeModel,
                tier: .cloudLLM,
                reason: "Edge SLM tidak terdaftar, dialihkan ke Cloud LLM."
            )

        case .autonomousWorkflow:
            return (
                provider: activeProvider,
                model: activeModel,
                tier: .autonomousWorkflow,
                reason: "Alur kerja otonom multi-langkah membutuhkan penalaran penuh via Cloud LLM."
            )

        case .cloudLLM:
            return (
                provider: activeProvider,
                model: activeModel,
                tier: .cloudLLM,
                reason: "Tugas membutuhkan kapabilitas penalaran canggih via Cloud LLM."
            )
        }
    }
}
