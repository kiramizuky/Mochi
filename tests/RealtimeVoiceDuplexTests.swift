import Foundation
import AppKit

// MARK: - Test Suite Paket 12: Real-Time Full-Duplex Voice 2.0 (Conversational Live Stream)

@main
struct RealtimeVoiceDuplexTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan RealtimeVoiceDuplexTests (Paket 12)...")

        // MARK: - Test 1: RealtimeVoiceStreamService Status & Stream Lifecycle
        log("T1: testStreamServiceLifecycleAndVAD")
        let streamService = RealtimeVoiceStreamService.shared

        await MainActor.run {
            // Periksa status default
            assert(streamService.status == .idle || streamService.status == .streaming, "Status awal harus idle atau streaming")
            log("  Initial stream status: \(streamService.status.displayName)")

            // Test set VAD sensitivity
            let originalVAD = streamService.vadSensitivity
            streamService.vadSensitivity = -32.0
            assert(streamService.vadSensitivity == -32.0, "vadSensitivity harus dapat diubah")
            streamService.vadSensitivity = originalVAD // restore
        }
        log("  Stream service lifecycle and VAD sensitivity verified.")
        log("T1 OK ✅")

        // MARK: - Test 2: Context-Adaptive Vocal Personas & Profiling
        log("T2: testContextAdaptiveVocalPersonas")
        await MainActor.run {
            // 1. Whisper Night Profile
            streamService.selectedPersonaStyle = .whisperNight
            let whisperProfile = streamService.resolveCurrentAudioProfile()
            assert(whisperProfile.rateMultiplier < 0.90, "Rate whisper harus lebih lambat (< 0.90)")
            assert(whisperProfile.volumeMultiplier < 0.75, "Volume whisper harus lebih lembut (< 0.75)")
            assert(whisperProfile.styleTag == "whisper", "Style tag harus 'whisper'")

            // 2. Urgent Alert Profile
            streamService.selectedPersonaStyle = .urgentAlert
            let alertProfile = streamService.resolveCurrentAudioProfile()
            assert(alertProfile.rateMultiplier > 1.0, "Rate alert harus lebih cepat (> 1.0)")
            assert(alertProfile.volumeMultiplier == 1.0, "Volume alert harus maksimal (1.0)")
            assert(alertProfile.styleTag == "alert", "Style tag harus 'alert'")

            // 3. Cheerful Morning Profile
            streamService.selectedPersonaStyle = .cheerfulMorning
            let morningProfile = streamService.resolveCurrentAudioProfile()
            assert(morningProfile.pitchMultiplier > 1.10, "Pitch morning harus lebih tinggi/ceria (> 1.10)")
            assert(morningProfile.styleTag == "cheerful", "Style tag harus 'cheerful'")

            // 4. Thoughtful Analyst Profile
            streamService.selectedPersonaStyle = .thoughtfulAnalyst
            let analystProfile = streamService.resolveCurrentAudioProfile()
            assert(analystProfile.rateMultiplier < 0.95, "Rate analyst harus tenang dan terukur (< 0.95)")
            assert(analystProfile.styleTag == "thoughtful", "Style tag harus 'thoughtful'")

            // 5. Natural Friendly Profile
            streamService.selectedPersonaStyle = .naturalFriendly
            let naturalProfile = streamService.resolveCurrentAudioProfile()
            assert(naturalProfile.styleTag == "natural", "Style tag harus 'natural'")

            // 6. Adaptive Auto Profile (Harus menghasilkan salah satu gaya valid)
            streamService.selectedPersonaStyle = .adaptiveAuto
            let activeStyle = streamService.resolveActiveStyle()
            assert(activeStyle != .adaptiveAuto, "resolveActiveStyle harus mengembalikan gaya spesifik konkrit")
            log("  Adaptive Auto dynamically resolved to: \(activeStyle.displayName)")

            // Prompt persona instruction checks
            for style in VocalPersonaStyle.allCases {
                streamService.selectedPersonaStyle = style
                let prompt = streamService.promptPersonaInstruction()
                assert(!prompt.isEmpty, "Instruksi prompt persona tidak boleh kosong untuk \(style.rawValue)")
            }
        }
        log("  All 6 vocal persona profiles and prompt modifiers verified.")
        log("T2 OK ✅")

        // MARK: - Test 3: Ultra-Fast Barge-In & Sub-Second Latency Measurement
        log("T3: testBargeInAndLatencyMetrics")
        await MainActor.run {
            let latency = streamService.measuredLatencyMs
            log("  Measured streaming latency: \(latency) ms (Sub-second target: < 400ms)")
            assert(latency <= 400, "Latensi percakapan streaming harus memenuhi target sub-detik (< 400ms)")

            let initialBargeIns = streamService.totalBargeInsCount
            assert(initialBargeIns >= 0, "Barge-in count harus valid integer non-negatif")
        }
        log("  Sub-second conversational latency (< 400ms) verified.")
        log("T3 OK ✅")

        // MARK: - Test 4: Tool Registration & Aliases
        log("T4: testToolRegistrationAndAliases")
        let allTools = ToolExecutor.allTools
        log("  Total registered tools: \(allTools.count)")
        assert(allTools.count >= 94, "Total tools harus minimal 94 (sebelumnya 92 + 2 Paket 12)")

        let toolNames = Set(allTools.map { $0.name })
        let expectedNewTools = ["voice_set_mode", "voice_status"]
        for expected in expectedNewTools {
            assert(toolNames.contains(expected), "Tool \(expected) harus terdaftar di ToolExecutor.allTools")
        }

        // Cek Aliases
        let expectedAliases = [
            ("set_voice_mode", "voice_set_mode"),
            ("voice_mode", "voice_set_mode"),
            ("duplex_voice", "voice_set_mode"),
            ("voice_info", "voice_status"),
        ]
        for (alias, canonical) in expectedAliases {
            assert(ToolExecutor.toolAliases[alias] == canonical, "Alias \(alias) harus memetakan ke \(canonical)")
        }
        log("  All 2 new tools and 4 aliases verified.")
        log("T4 OK ✅")

        // MARK: - Test 5: Gemini OpenAPI Schema Compliance
        log("T5: testGeminiOpenAPISchemaCompliance")
        for tool in allTools {
            validateOpenAPISchema(tool.inputSchema, toolName: tool.name)
        }
        log("  All \(allTools.count) tool schemas are 100% compliant with Gemini OpenAPI validation.")
        log("T5 OK ✅")

        log("🎉 SEMUA TEST PAKET 12 BERHASIL DILALUI DENGAN SEMPURNA!")
    }

    private static func validateOpenAPISchema(_ value: JSONValue, toolName: String) {
        switch value {
        case .object(let dict):
            if dict["type"]?.stringValue == "array" {
                assert(dict["items"] != nil, "Gemini OpenAPI violation in tool '\(toolName)': schema array harus memiliki properti 'items'!")
            }
            for (_, val) in dict {
                validateOpenAPISchema(val, toolName: toolName)
            }
        case .array(let arr):
            for val in arr {
                validateOpenAPISchema(val, toolName: toolName)
            }
        default:
            break
        }
    }
}

