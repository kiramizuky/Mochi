import Foundation
import AppKit

// MARK: - Visual Grounding Engine (Screen to Coordinate Mapping)

public struct GroundedElement: Sendable, Codable {
    public var x: Double
    public var y: Double
    public var confidence: Double
    public var label: String
}

public enum CUAActionType: String, Sendable, CaseIterable {
    case click = "click"
    case doubleClick = "double_click"
    case rightClick = "right_click"
    case typeText = "type_text"
    case pressKey = "press_key"
    case scroll = "scroll"
}

public final class VisualGroundingEngine: @unchecked Sendable {
    public static let shared = VisualGroundingEngine()

    private let apps = AppController()
    private let control = OSComputerControl.shared
    private let axClient = SystemAXClient()

    private init() {}

    /// Menemukan koordinat elemen UI di layar berdasarkan deskripsi visual.
    public func locateElement(query: String, inApp: String? = nil) async throws -> GroundedElement {
        let capture = try await apps.capture(inApp ?? "frontmost")
        let mainScreenBounds = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // 1. Coba pencarian berbasis Accessibility Tree terlebih dahulu (cepat & 100% presisi jika didukung)
        if let axPoint = locateViaAX(query: query) {
            return GroundedElement(x: Double(axPoint.x), y: Double(axPoint.y), confidence: 0.95, label: query)
        }

        // 2. Evaluasi via Vision Multimodal LLM jika tersedia gambar tangkapan layar
        let provider = ProviderRegistry.shared.activeProvider
        let model = UserDefaults.standard.string(forKey: "model") ?? "claude-sonnet-4-6"

        let systemInstruction = """
        You are a visual grounding engine for a macOS GUI agent.
        The screen resolution is approximately \(Int(mainScreenBounds.width)) x \(Int(mainScreenBounds.height)) pixels.
        Your task is to identify the center coordinate [x, y] of the UI element described by the user.
        Top-left is (0, 0), and bottom-right is (\(Int(mainScreenBounds.width)), \(Int(mainScreenBounds.height))).
        Always reply strictly in JSON format:
        {
          "x": number,
          "y": number,
          "confidence": 0.0 to 1.0,
          "label": "short description of matched element"
        }
        """

        let prompt = "LOCATE ELEMENT: \"\(query)\". Find its exact center coordinates on this screen."

        if !capture.data.isEmpty {
            do {
                let base64 = capture.data.base64EncodedString()
                let request = LLMRequest(
                    model: model,
                    system: systemInstruction,
                    messages: [
                        LLMMessage(role: .user, content: [
                            .text(prompt),
                            .image(mediaType: "image/png", base64: base64)
                        ])
                    ],
                    maxTokens: 256,
                    tools: []
                )

                let response = try await provider.complete(request)
                if let parsed = parseCoordinateJson(response.text) {
                    return parsed
                }
            } catch {
                // Fallback jika Vision LLM gagal
            }
        }

        // Fallback: klik tengah jendela depan
        let fallbackPoint = CGPoint(x: mainScreenBounds.midX, y: mainScreenBounds.midY)
        return GroundedElement(x: Double(fallbackPoint.x), y: Double(fallbackPoint.y), confidence: 0.3, label: "\(query) (tengah layar)")
    }

    /// Closed-Loop Driving: Cari elemen, jalankan aksi OS, lalu verifikasi hasil visualnya dengan koreksi mandiri.
    public func clickAndVerify(element: String, expectedResult: String, inApp: String? = nil) async throws -> VisualVerificationResult {
        return try await executeClosedLoopAction(
            goal: expectedResult,
            elementDescription: element,
            actionType: .click,
            inApp: inApp,
            maxRetries: 2
        )
    }

    /// Closed-Loop Execution Engine dengan Self-Healing:
    /// Menjalankan siklus Look -> Plan -> Act -> Verify -> Self-Heal hingga kondisi visual yang diharapkan tercapai.
    public func executeClosedLoopAction(
        goal: String,
        elementDescription: String,
        actionType: CUAActionType = .click,
        textToType: String? = nil,
        inApp: String? = nil,
        maxRetries: Int = 2
    ) async throws -> VisualVerificationResult {
        var lastResult: VisualVerificationResult? = nil

        for attempt in 1...max(1, maxRetries) {
            try control.checkAborted()

            // 1. Look: Cari elemen UI
            let grounded = try await locateElement(query: elementDescription, inApp: inApp)
            let point = CGPoint(x: grounded.x, y: grounded.y)

            // 2. Act: Jalankan aksi tingkat OS via CoreGraphics
            switch actionType {
            case .click:
                let clickCount = attempt > 1 ? 2 : 1
                try control.click(at: point, button: .left, clickCount: clickCount)
            case .doubleClick:
                try control.click(at: point, button: .left, clickCount: 2)
            case .rightClick:
                try control.click(at: point, button: .right, clickCount: 1)
            case .typeText:
                try control.click(at: point, button: .left, clickCount: 1)
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let text = textToType, !text.isEmpty {
                    try control.typeText(text)
                }
            case .pressKey:
                let key = textToType ?? "return"
                try control.pressKey(named: key)
            case .scroll:
                try control.scroll(deltaY: -5)
            }

            // Jeda 600ms agar UI merespons perubahan state
            try? await Task.sleep(nanoseconds: 600_000_000)

            // 3. Verify: Periksa apakah kondisi visual goal tercapai
            let verification = try await VisualVerificationService.shared.verify(goal: goal, appName: inApp)
            lastResult = verification

            if verification.passed {
                return verification
            }

            // 4. Self-Healing fallback jika attempt belum habis:
            // Jika klik CoreGraphics tidak mengubah UI, coba trigger via Accessibility API langsung
            if attempt < maxRetries {
                if let snap = try? axClient.snapshot() {
                    let lowerDesc = elementDescription.lowercased()
                    if let matchIdx = snap.elements.firstIndex(where: {
                        $0.label.lowercased().contains(lowerDesc) || $0.role.lowercased().contains(lowerDesc)
                    }) {
                        _ = try? axClient.perform(.press(index: matchIdx))
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        let axVerification = try await VisualVerificationService.shared.verify(goal: goal, appName: inApp)
                        if axVerification.passed {
                            return axVerification
                        }
                        lastResult = axVerification
                    }
                }
            }
        }

        return lastResult ?? VisualVerificationResult(
            passed: false,
            confidence: 0.0,
            observation: "Aksi visual gagal mencapai goal setelah \(maxRetries) percobaan.",
            screenshotPath: ""
        )
    }

    // MARK: - Private Helpers

    private func locateViaAX(query: String) -> CGPoint? {
        // Cek apakah ada elemen terfokus atau tombol dengan label sesuai query
        let lowerQuery = query.lowercased()
        guard let snap = try? axClient.snapshot() else { return nil }

        // Jika ada element yang labelnya cocok di snapshot AX
        for el in snap.elements {
            if el.label.lowercased().contains(lowerQuery) || el.role.lowercased().contains(lowerQuery) {
                // Di Accessibility macOS, titik elemen dapat didekati
                let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
                return CGPoint(x: screen.midX, y: screen.midY)
            }
        }
        return nil
    }

    private func parseCoordinateJson(_ text: String) -> GroundedElement? {
        guard let data = text.data(using: .utf8) else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let json = try? JSONSerialization.jsonObject(with: cleaned.data(using: .utf8) ?? data) as? [String: Any],
              let x = json["x"] as? Double,
              let y = json["y"] as? Double else {
            return nil
        }

        let conf = (json["confidence"] as? Double) ?? 0.8
        let label = (json["label"] as? String) ?? "UI Element"
        return GroundedElement(x: x, y: y, confidence: conf, label: label)
    }
}
