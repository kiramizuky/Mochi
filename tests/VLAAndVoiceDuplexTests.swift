import Foundation
import AppKit

// MARK: - VLAAndVoiceDuplexTests (Closed-Loop VLA CUA & Voice Duplex Persona)

@main enum VLAAndVoiceDuplexTests {
    static func main() async throws {
        testCUAActionTypes()
        testVisualVerificationResultEncoding()
        await testVoiceDuplexToneAndState()
        print("VLAAndVoiceDuplexTests: all cases passed")
    }
}

// MARK: - Step 5: Closed-Loop CUA Action Types

func testCUAActionTypes() {
    let allCases = CUAActionType.allCases
    precondition(allCases.contains(.click))
    precondition(allCases.contains(.doubleClick))
    precondition(allCases.contains(.rightClick))
    precondition(allCases.contains(.typeText))
    precondition(allCases.contains(.pressKey))
    precondition(allCases.contains(.scroll))

    precondition(CUAActionType(rawValue: "click") == .click)
    precondition(CUAActionType(rawValue: "double_click") == .doubleClick)
    precondition(CUAActionType(rawValue: "type_text") == .typeText)
}

func testVisualVerificationResultEncoding() {
    let result = VisualVerificationResult(
        passed: true,
        confidence: 0.95,
        observation: "Modal tertutup dan tombol terverifikasi.",
        screenshotPath: "/tmp/test.png"
    )
    precondition(result.passed == true)
    precondition(result.confidence > 0.9)
    precondition(result.screenshotPath == "/tmp/test.png")

    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(result),
          let decoded = try? JSONDecoder().decode(VisualVerificationResult.self, from: data) else {
        preconditionFailure("VisualVerificationResult harus bisa di-encode dan decode Codable")
    }
    precondition(decoded.passed == result.passed)
    precondition(decoded.observation == result.observation)
}

// MARK: - Step 6: Voice Duplex Persona & Emotional Tone

@MainActor
func testVoiceDuplexToneAndState() async {
    let duplex = VoiceDuplexEngine.shared
    let state = AppState.shared

    // 1. Uji setTone .focused -> stateOverride = .thinking
    duplex.setTone(.focused)
    precondition(state.effectiveState == .thinking, "Tone focused harus menghasilkan state thinking, got \(state.effectiveState)")

    // 2. Uji setTone .caution -> stateOverride = .approval
    duplex.setTone(.caution)
    precondition(state.effectiveState == .approval, "Tone caution harus menghasilkan state approval, got \(state.effectiveState)")

    // 3. Uji setTone .attentive -> stateOverride kembali ke nil
    duplex.setTone(.attentive)
    precondition(state.stateOverride == nil, "Tone attentive harus mereset stateOverride")

    // 4. Uji interupsi duplex
    duplex.isInterrupted = true
    precondition(state.effectiveState == .question, "Saat interrupted, effectiveState harus .question, got \(state.effectiveState)")
    duplex.isInterrupted = false
}

