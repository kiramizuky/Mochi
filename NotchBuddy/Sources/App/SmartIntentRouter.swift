import Foundation

// MARK: - Smart Intent Router (Edge vs Cloud Hybrid Orchestration)

public enum ExecutionTier: String, Sendable {
    case localSLM = "local_edge"    // On-device MLX/Local: <50ms, gratis, privasi penuh
    case cloudLLM = "cloud_advanced" // Claude Sonnet / GPT-4o: multi-step complex reasoning
}

public final class SmartIntentRouter: @unchecked Sendable {
    public static let shared = SmartIntentRouter()
    private init() {}

    /// Menentukan tier eksekusi terbaik berdasarkan sifat perintah dan ketersediaan koneksi.
    public func resolveTier(for query: String) -> ExecutionTier {
        let q = query.lowercased()

        // 1. Jika pengguna secara eksplisit meminta local atau offline
        if q.contains("offline") || q.contains("secara lokal") || q.contains("on-device") {
            return .localSLM
        }

        // 2. Pola tugas cepat/rutin lokal
        let localActionKeywords = [
            "buka aplikasi", "tutup aplikasi", "open app", "close app",
            "rapikan folder", "cek kapasitas disk", "cek storage",
            "salin ke clipboard", "format tanggal", "hitung ",
            "pindahkan mouse", "klik tombol", "scroll "
        ]

        let isSimpleRoutine = localActionKeywords.contains { q.contains($0) }
        let isShortText = q.split(separator: " ").count <= 8

        if isSimpleRoutine && isShortText {
            return .localSLM
        }

        // 3. Tugas analitis, penulisan mendalam, atau riset web diarahkan ke Cloud LLM
        return .cloudLLM
    }
}
