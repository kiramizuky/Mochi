import Foundation

// MARK- Self-correction (analisis gagal → perbaiki input → coba ulang sekali)

// Self-correction: saat pemanggilan alat gagal, susun prompt perbaikan ke LLM
// yang menulis ulang input alat, lalu coba eksekusi sekali lagi. Digunakan oleh
// WorkflowEngine / AutonomousAgent untuk mengurangi gagal satu kali karena
// argumen salah atau path tidak lengkap.
final class SelfCorrection: @unchecked Sendable {
    static let shared = SelfCorrection()
    private init() {}

    /// Perbaiki dan coba ulang satu langkah yang gagal.
    /// - Returns: hasil eksekusi setelah perbaikan, atau hasil asli jika
    ///   perbaikan tidak berhasil / LLM tidak mengembalikan input yang valid.
    func correct(
        step: AutonomousStep,
        error: String,
        provider: any LLMProvider,
        model: String,
        executor: ToolExecutor
    ) async -> ToolResult {
        let prompt = """
        Panggilan alat gagal.

        Alat: \(step.tool)
        Input asli: \(jsonString(step.input))
        Pesan error: \(error)

        Tulis ulang input sebagai objek JSON yang benar agar alat bisa dijalankan.
        Kembalikan HANYA objek JSON, tanpa penjelasan lain. Jika tidak ada yang
        bisa diperbaiki, kembalikan objek kosong {}.
        """

        do {
            let response = try await provider.complete(
                LLMRequest(
                    model: model,
                    system: "Anda membantu memperbaiki input alat yang gagal. Kembalikan hanya JSON.",
                    messages: [LLMMessage(role: .user, content: [.text(prompt)])],
                    maxTokens: 1024
                )
            )
            let corrected = parseCorrectedInput(from: response.text)
            guard let corrected, !corrected.isEmpty else {
                return ToolResult(output: error, isError: true, exitCode: nil)
            }
            // Coba ulang sekali dengan input yang diperbaiki.
            let retry = await executor.execute(name: step.tool, input: .object(corrected))
            return retry
        } catch {
            return ToolResult(output: "Gagal memperbaiki: \(error.localizedDescription). Asli: \(error)", isError: true, exitCode: nil)
        }
    }

    // MARK: - Parsing

    private func parseCorrectedInput(from text: String) -> [String: JSONValue]? {
        // Coba temukan objek JSON pertama dalam teks (lempar pembungkus markdown jika ada).
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json.mapValues(JSONValue.init(any:))
    }

    private func jsonString(_ input: [String: JSONValue]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: input.mapValues { $0.anyValue }),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}