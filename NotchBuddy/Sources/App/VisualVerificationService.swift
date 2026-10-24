import Foundation
import AppKit

// MARK: - Visual Fallback & Goal Verification

public struct VisualVerificationResult: Sendable, Codable {
    public var passed: Bool
    public var confidence: Double
    public var observation: String
    public var screenshotPath: String

    public init(passed: Bool, confidence: Double, observation: String, screenshotPath: String) {
        self.passed = passed
        self.confidence = confidence
        self.observation = observation
        self.screenshotPath = screenshotPath
    }
}

public final class VisualVerificationService: @unchecked Sendable {
    public static let shared = VisualVerificationService()
    private let apps = AppController()
    private let axClient = SystemAXClient()

    private init() {}

    /// Mengambil screenshot jendela atau layar dan memverifikasi apakah goal visual tercapai.
    public func verify(goal: String, appName: String? = nil) async throws -> VisualVerificationResult {
        // 1. Ambil capture visual
        let targetApp = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let capture = try await apps.capture(targetApp.isEmpty ? "frontmost" : targetApp)
        
        let filePath = capture.path
        let imageData = capture.data

        // 2. Evaluasi via Vision Multimodal LLM jika tersedia
        let provider = ProviderRegistry.shared.activeProvider
        let model = UserDefaults.standard.string(forKey: "model") ?? "claude-sonnet-4-6"

        let prompt = """
        You are Coucou's Visual Verification Engine. You inspect screenshots taken from the user's macOS computer.
        Your task is to determine whether the requested GOAL has been achieved on screen.
        
        GOAL TO VERIFY: "\(goal)"
        
        Always reply strictly in valid JSON format:
        {
          "passed": true or false,
          "confidence": 0.0 to 1.0,
          "observation": "concise description of what is visible on the screen and why the goal passed or failed"
        }
        """

        if !imageData.isEmpty {
            do {
                let base64 = imageData.base64EncodedString()
                let systemInstruction = """
                You are Coucou's Visual Verification Engine. You inspect screenshots taken from the user's macOS computer.
                Your task is to determine whether the requested GOAL has been achieved on screen.
                Always reply strictly in valid JSON format:
                {
                  "passed": true or false,
                  "confidence": 0.0 to 1.0,
                  "observation": "concise description of what is visible on the screen and why the goal passed or failed"
                }
                """

                let request = LLMRequest(
                    model: model,
                    system: systemInstruction,
                    messages: [
                        LLMMessage(role: .user, content: [
                            .text(prompt),
                            .image(mediaType: "image/png", base64: base64)
                        ])
                    ],
                    maxTokens: 512,
                    tools: []
                )

                let response = try await provider.complete(request)
                let textResponse = response.text

                if let parsed = parseJsonResult(textResponse) {
                    return VisualVerificationResult(
                        passed: parsed.passed,
                        confidence: parsed.confidence,
                        observation: parsed.observation,
                        screenshotPath: filePath
                    )
                }
            } catch {
                // Fallback to accessibility and window inspection
            }
        }

        // 3. Fallback Heuristik Lokal jika model vision tidak merespons
        let axDump: String
        do {
            let snap = try axClient.snapshot()
            axDump = snap.summary()
        } catch {
            axDump = ""
        }

        let axLower = axDump.lowercased()
        let goalKeywords = goal.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 }
        
        var matches = 0
        for kw in goalKeywords {
            if axLower.contains(kw) {
                matches += 1
            }
        }

        let ratio = goalKeywords.isEmpty ? 0.5 : Double(matches) / Double(goalKeywords.count)
        let passed = ratio >= 0.35
        let obs = passed
            ? "Tangkapan visual (\(filePath)) berhasil diambil. Elemen UI sesuai kata kunci goal (\(matches)/\(goalKeywords.count))."
            : "Tangkapan visual (\(filePath)) berhasil diambil, namun kondisi goal belum sepenuhnya terverifikasi secara visual pada jendela aktif."

        return VisualVerificationResult(
            passed: passed,
            confidence: ratio,
            observation: obs,
            screenshotPath: filePath
        )
    }

    private func parseJsonResult(_ text: String) -> (passed: Bool, confidence: Double, observation: String)? {
        guard let data = text.data(using: .utf8) else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonObject = try? JSONSerialization.jsonObject(with: cleaned.data(using: .utf8) ?? data) as? [String: Any] else {
            return nil
        }

        let passed = (jsonObject["passed"] as? Bool) ?? false
        let conf = (jsonObject["confidence"] as? Double) ?? 0.8
        let obs = (jsonObject["observation"] as? String) ?? "Visual goal verified."

        return (passed, conf, obs)
    }
}
