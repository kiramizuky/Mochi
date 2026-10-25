import Foundation
import AVFoundation

// MARK: - TTS Engine Type
enum TTSEngineType: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case openAI = "openai"
    case elevenLabs = "elevenlabs"
    case groq = "groq"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "Apple System (Offline)"
        case .openAI: return "OpenAI TTS (Human Mode)"
        case .elevenLabs: return "ElevenLabs (Ultra-Realistic)"
        case .groq: return "Groq Orpheus TTS (Ultra-Fast)"
        }
    }
}

// MARK: - HumanVoiceEngine (Generative Natural Speech)
@MainActor
final class HumanVoiceEngine: NSObject, AVAudioPlayerDelegate {
    static let shared = HumanVoiceEngine()

    private var activePlayer: AVAudioPlayer?
    private var tempAudioFileURL: URL?
    private(set) var isPlaying: Bool = false

    var onPlaybackFinished: (() -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - Speak with Generative TTS

    func speak(
        text: String,
        engine: TTSEngineType,
        openAIVoice: String = "nova",
        elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM",
        groqVoice: String = "autumn",
        groqModel: String = "canopylabs/orpheus-v1-english",
        fallback: @escaping () -> Void
    ) {
        stop()

        guard !text.isEmpty else { return }

        Task {
            do {
                let audioData: Data
                let format: String
                switch engine {
                case .openAI:
                    audioData = try await fetchOpenAIAudio(text: text, voice: openAIVoice)
                    format = "mp3"
                case .elevenLabs:
                    audioData = try await fetchElevenLabsAudio(text: text, voiceId: elevenLabsVoiceId)
                    format = "mp3"
                case .groq:
                    audioData = try await fetchGroqAudio(text: text, voice: groqVoice, model: groqModel)
                    format = "wav"
                case .system:
                    fallback()
                    return
                }

                try playAudioData(audioData, format: format)
            } catch {
                print("⚠️ [HumanVoiceEngine] Generative TTS failed, falling back to system TTS: \(error.localizedDescription)")
                fallback()
            }
        }
    }

    func stop() {
        if let player = activePlayer, player.isPlaying {
            player.stop()
        }
        activePlayer = nil
        isPlaying = false
        if let url = tempAudioFileURL {
            try? FileManager.default.removeItem(at: url)
            tempAudioFileURL = nil
        }
    }

    // MARK: - Audio Playback

    private func playAudioData(_ data: Data, format: String = "wav") throws {
        if let old = tempAudioFileURL {
            try? FileManager.default.removeItem(at: old)
            tempAudioFileURL = nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mochi_speech_\(UUID().uuidString).\(format)")
        try data.write(to: tempURL)
        self.tempAudioFileURL = tempURL

        let player = try AVAudioPlayer(contentsOf: tempURL)
        player.delegate = self
        player.volume = 0.95
        player.prepareToPlay()
        player.play()
        self.activePlayer = player
        self.isPlaying = true
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.activePlayer = nil
            if let url = self.tempAudioFileURL {
                try? FileManager.default.removeItem(at: url)
                self.tempAudioFileURL = nil
            }
            self.onPlaybackFinished?()
        }
    }

    // MARK: - OpenAI TTS API

    private func fetchOpenAIAudio(text: String, voice: String) async throws -> Data {
        let key = ProviderRegistry.shared.key(for: "openai")
            ?? KeychainStore.shared.get("openai-api-key")
            ?? ""
        guard !key.isEmpty else {
            throw NSError(domain: "HumanVoiceEngine", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenAI API key missing"])
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": voice.lowercased(),
            "response_format": "mp3",
            "speed": 1.02
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw NSError(domain: "HumanVoiceEngine", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        return data
    }

    // MARK: - ElevenLabs TTS API

    private func fetchElevenLabsAudio(text: String, voiceId: String) async throws -> Data {
        let key = KeychainStore.shared.get("elevenlabs-api-key") ?? ""
        guard !key.isEmpty else {
            throw NSError(domain: "HumanVoiceEngine", code: 401, userInfo: [NSLocalizedDescriptionKey: "ElevenLabs API key missing"])
        }

        let cleanVoiceId = voiceId.isEmpty ? "21m00Tcm4TlvDq8ikWAM" : voiceId
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(cleanVoiceId)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 18)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "use_speaker_boost": true
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw NSError(domain: "HumanVoiceEngine", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        return data
    }

    // MARK: - Groq TTS API (Canopy Labs Orpheus with Multi-Key Rotation)

    private func fetchGroqAudio(text: String, voice: String = "autumn", model: String = "canopylabs/orpheus-v1-english") async throws -> Data {
        let maxRetries = 3
        var lastError: Error?

        for _ in 1...maxRetries {
            let key = ProviderRegistry.shared.key(for: "groq")
                ?? KeychainStore.shared.get("groq-api-key")
                ?? ""

            guard !key.isEmpty else {
                throw NSError(domain: "HumanVoiceEngine", code: 401, userInfo: [NSLocalizedDescriptionKey: "Groq API key missing. Tambahkan di Settings > AI Provider > Groq."])
            }

            guard let url = URL(string: "https://api.groq.com/openai/v1/audio/speech") else {
                throw URLError(.badURL)
            }

            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("MochiAssistant/1.0", forHTTPHeaderField: "User-Agent")

            let allowedVoices = ["autumn", "diana", "hannah", "austin", "daniel", "troy"]
            let inputVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let cleanVoice = allowedVoices.contains(inputVoice) ? inputVoice : "autumn"
            let cleanModel = model.isEmpty ? "canopylabs/orpheus-v1-english" : model

            // Pastikan tidak melebihi 650 karakter agar aman dari batas 1200 TPM Free Tier Groq Orpheus
            let safeText = text.count > 650 ? VoiceText.spokenResponse(from: text, maxLength: 650) : text

            let payload: [String: Any] = [
                "model": cleanModel,
                "input": safeText,
                "voice": cleanVoice,
                "response_format": "wav"
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                if statusCode == 200 {
                    ProviderRegistry.shared.reportSuccess(providerId: "groq", keySecret: key)
                    return data
                } else if statusCode == 429 || statusCode == 413 {
                    // Rate limit atau TPM token limit: rotasi key otomatis
                    ProviderRegistry.shared.reportFailure(providerId: "groq", keySecret: key, isRateLimit: true)
                    continue
                } else {
                    ProviderRegistry.shared.reportFailure(providerId: "groq", keySecret: key, isRateLimit: false)
                    let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
                    throw NSError(domain: "HumanVoiceEngine", code: statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NSError(domain: "HumanVoiceEngine", code: 429, userInfo: [NSLocalizedDescriptionKey: "Groq TTS rate limit reached across available keys."])
    }
}
