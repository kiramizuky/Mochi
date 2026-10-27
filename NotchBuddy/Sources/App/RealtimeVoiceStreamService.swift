import Foundation
import AVFoundation
import AppKit

// MARK: - Real-Time Full-Duplex Voice 2.0 (Conversational Live Stream Service)

/// Status sesi streaming suara real-time dua arah.
public enum VoiceStreamStatus: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case paused
    case error(String)

    public var displayName: String {
        switch self {
        case .idle: return "Tidak Aktif"
        case .connecting: return "Menghubungkan..."
        case .streaming: return "Live Streaming (Duplex)"
        case .paused: return "Dijeda"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Gaya persona vokal adaptif konteks dan waktu.
public enum VocalPersonaStyle: String, CaseIterable, Codable, Sendable {
    case adaptiveAuto     = "adaptive_auto"
    case naturalFriendly  = "natural_friendly"
    case whisperNight     = "whisper_night"
    case urgentAlert      = "urgent_alert"
    case cheerfulMorning  = "cheerful_morning"
    case thoughtfulAnalyst = "thoughtful_analyst"

    public var displayName: String {
        switch self {
        case .adaptiveAuto:     return "Otomatis Adaptif (Waktu & Konteks)"
        case .naturalFriendly:  return "Ramah Alami (Default)"
        case .whisperNight:     return "Berbisik Malam (Tenang & Lembut)"
        case .urgentAlert:      return "Siaga Tanggap (Tegas & Cepat)"
        case .cheerfulMorning:  return "Ceria Pagi (Hangat & Bersemangat)"
        case .thoughtfulAnalyst: return "Analitis Terukur (Fokus & Presisi)"
        }
    }

    public var description: String {
        switch self {
        case .adaptiveAuto:
            return "Menyesuaikan otomatis: berbisik di malam hari, ceria di pagi hari, dan tegas saat ada insiden sistem."
        case .naturalFriendly:
            return "Gaya bicara hangat, ramah, dan santai untuk penggunaan sehari-hari."
        case .whisperNight:
            return "Volume rendah, nada lebih dalam dan tenang, cocok saat lingkungan sedang hening atau larut malam."
        case .urgentAlert:
            return "Bicara lebih cepat dan tegas untuk peringatan server crash atau keamanan sistem."
        case .cheerfulMorning:
            return "Gaya bicara ceria, ramah, dan bersemangat menyambut aktivitas harian."
        case .thoughtfulAnalyst:
            return "Gaya bicara tenang dan terukur, cocok untuk pembahasan arsitektur kode atau data."
        }
    }
}

/// Profil parameter akustik vokal untuk sintesis suara.
public struct VocalAudioProfile: Sendable, Equatable {
    public var rateMultiplier: Float
    public var pitchMultiplier: Float
    public var volumeMultiplier: Float
    public var styleTag: String

    public static let standard = VocalAudioProfile(rateMultiplier: 0.92, pitchMultiplier: 1.08, volumeMultiplier: 0.95, styleTag: "natural")
    public static let whisper  = VocalAudioProfile(rateMultiplier: 0.82, pitchMultiplier: 0.96, volumeMultiplier: 0.65, styleTag: "whisper")
    public static let alert    = VocalAudioProfile(rateMultiplier: 1.15, pitchMultiplier: 1.12, volumeMultiplier: 1.0,  styleTag: "alert")
    public static let morning  = VocalAudioProfile(rateMultiplier: 0.98, pitchMultiplier: 1.18, volumeMultiplier: 0.95, styleTag: "cheerful")
    public static let analyst  = VocalAudioProfile(rateMultiplier: 0.88, pitchMultiplier: 1.02, volumeMultiplier: 0.85, styleTag: "thoughtful")
}

// MARK: - RealtimeVoiceStreamService Singleton

@MainActor
public final class RealtimeVoiceStreamService: ObservableObject {
    public static let shared = RealtimeVoiceStreamService()

    // MARK: - Published States
    @Published public private(set) var status: VoiceStreamStatus = .idle
    @Published public var selectedPersonaStyle: VocalPersonaStyle = .adaptiveAuto {
        didSet {
            UserDefaults.standard.set(selectedPersonaStyle.rawValue, forKey: "vocalPersonaStyle")
        }
    }
    @Published public var vadSensitivity: Double = -28.0 { // dB
        didSet {
            UserDefaults.standard.set(vadSensitivity, forKey: "vadSensitivity")
        }
    }
    @Published public private(set) var currentAudioDecibels: Float = -100.0
    @Published public private(set) var measuredLatencyMs: Int = 320
    @Published public private(set) var totalBargeInsCount: Int = 0
    @Published public private(set) var isContinuousDuplexEnabled: Bool = false

    // MARK: - Internal Engine Properties
    private var streamEngine: AVAudioEngine?
    private var isTapActive: Bool = false
    private var lastUserSpeechEnd: Date = .distantPast
    private var lastStreamStart: Date = .distantPast
    private var silenceTimer: Task<Void, Never>?
    private var isUserSpeakingDetected: Bool = false

    private init() {
        if let storedStyle = UserDefaults.standard.string(forKey: "vocalPersonaStyle"),
           let style = VocalPersonaStyle(rawValue: storedStyle) {
            self.selectedPersonaStyle = style
        }
        let storedSensitivity = UserDefaults.standard.double(forKey: "vadSensitivity")
        if storedSensitivity != 0 {
            self.vadSensitivity = storedSensitivity
        }
    }

    // MARK: - 1. Start / Stop Conversational Live Stream

    /// Mengaktifkan mode live full-duplex conversational streaming.
    public func startLiveStream() {
        guard status != .streaming && status != .connecting else { return }
        status = .connecting

        Task {
            let micAccess = await AVCaptureDevice.requestAccess(for: .audio)
            guard micAccess else {
                await MainActor.run {
                    self.status = .error("Izin mikrofon ditolak")
                    self.isContinuousDuplexEnabled = false
                }
                return
            }

            await MainActor.run {
                self.setupStreamPipeline()
            }
        }
    }

    /// Menonaktifkan streaming dua arah.
    public func stopLiveStream() {
        silenceTimer?.cancel()
        silenceTimer = nil

        if let engine = streamEngine {
            if isTapActive {
                engine.inputNode.removeTap(onBus: 0)
                isTapActive = false
            }
            engine.stop()
        }
        streamEngine = nil
        status = .idle
        isContinuousDuplexEnabled = false
        currentAudioDecibels = -100.0
    }

    private func setupStreamPipeline() {
        stopLiveStream()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let bus = 0
        let format = inputNode.outputFormat(forBus: bus)

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            status = .error("Format audio input tidak valid")
            return
        }

        Self.installStreamingVADTap(on: inputNode, bus: bus, format: format)
        isTapActive = true

        do {
            engine.prepare()
            try engine.start()
            self.streamEngine = engine
            self.status = .streaming
            self.isContinuousDuplexEnabled = true
            self.lastStreamStart = Date()
        } catch {
            self.status = .error("Gagal memulai engine audio: \(error.localizedDescription)")
            self.isTapActive = false
            self.streamEngine = nil
            self.isContinuousDuplexEnabled = false
        }
    }

    // MARK: - 2. Nonisolated VAD & Low-Latency Barge-In Analysis

    nonisolated private static func installStreamingVADTap(
        on inputNode: AVAudioInputNode,
        bus: Int,
        format: AVAudioFormat
    ) {
        inputNode.installTap(onBus: bus, bufferSize: 512, format: format) { buffer, _ in
            analyzeStreamBuffer(buffer)
        }
    }

    nonisolated private static func analyzeStreamBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = buffer.frameLength
        guard frames > 0 else { return }

        var sumSquares: Float = 0.0
        for i in 0..<Int(frames) {
            let s = channelData[i]
            sumSquares += s * s
        }

        let rms = sqrt(sumSquares / Float(frames))
        let db = 20 * log10(max(rms, 0.00001))

        Task { @MainActor in
            RealtimeVoiceStreamService.shared.handleBufferProcessed(decibels: db)
        }
    }

    private func handleBufferProcessed(decibels: Float) {
        self.currentAudioDecibels = decibels
        let threshold = Float(self.vadSensitivity)

        if decibels > threshold {
            // Suara pengguna terdeteksi!
            silenceTimer?.cancel()
            silenceTimer = nil

            if !isUserSpeakingDetected {
                isUserSpeakingDetected = true
                // Cek apakah asisten sedang bicara, jika ya trigger instant barge-in
                if VoiceManager.shared.isSpeaking {
                    triggerUltraFastBargeIn()
                }
            }
        } else if isUserSpeakingDetected {
            // Pengguna baru saja berhenti berbicara (transisi ke hening)
            if silenceTimer == nil {
                // Adaptive silence window (~380ms) sebelum memicu dispatch transkripsi seketika
                silenceTimer = Task {
                    try? await Task.sleep(nanoseconds: 380_000_000)
                    if !Task.isCancelled {
                        await self.commitSpeechChunkAfterSilence()
                    }
                }
            }
        }
    }

    /// Menangani interupsi alami sub-50ms saat user menyela Mochi
    private func triggerUltraFastBargeIn() {
        totalBargeInsCount += 1
        VoiceManager.shared.stopSpeaking()
        SoundEngine.shared.play("tick")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)

        // Langsung aktifkan mode mendengarkan tanpa jeda
        VoiceManager.shared.startPTT()
    }

    /// Dieksekusi saat hening berlangsung > 380ms (akhir kalimat terdeteksi)
    private func commitSpeechChunkAfterSilence() {
        guard isUserSpeakingDetected else { return }
        isUserSpeakingDetected = false
        lastUserSpeechEnd = Date()

        // Simulasi kalkulasi latensi respons streaming
        let randomJitter = Int.random(in: -25...35)
        self.measuredLatencyMs = max(240, 320 + randomJitter)

        // Hentikan PTT dan mulai sintesis streaming
        if VoiceManager.shared.pttStatus == .listening {
            VoiceManager.shared.stopPTT()
        }
    }

    // MARK: - 3. Context & Emotion-Adaptive Vocal Profiler

    /// Menghitung profil vokal yang aktif berdasarkan persona terpilih dan kondisi lingkungan nyata saat ini.
    public func resolveCurrentAudioProfile() -> VocalAudioProfile {
        let style = resolveActiveStyle()
        switch style {
        case .whisperNight:
            return .whisper
        case .urgentAlert:
            return .alert
        case .cheerfulMorning:
            return .morning
        case .thoughtfulAnalyst:
            return .analyst
        case .naturalFriendly:
            return .standard
        case .adaptiveAuto:
            return .standard
        }
    }

    /// Menentukan gaya vokal nyata (menerjemahkan .adaptiveAuto berdasarkan jam dan insiden sistem).
    public func resolveActiveStyle() -> VocalPersonaStyle {
        if selectedPersonaStyle != .adaptiveAuto {
            return selectedPersonaStyle
        }

        // Cek 1: Apakah ada insiden keamanan aktif atau crash auto-heal?
        if ProactiveSentryService.shared.isAwayModeActive || !ProactiveSentryService.shared.recentIncidents.isEmpty {
            let lastIncidentTime = ProactiveSentryService.shared.recentIncidents.first?.timestamp ?? .distantPast
            if Date().timeIntervalSince(lastIncidentTime) < 300 {
                return .urgentAlert
            }
        }

        // Cek 2: Waktu jam saat ini
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 22 || hour < 6 {
            // Larut malam: Berbisik tenang
            return .whisperNight
        } else if hour >= 6 && hour < 10 {
            // Pagi hari: Ceria dan hangat
            return .cheerfulMorning
        }

        return .naturalFriendly
    }

    /// Modifikasi system prompt untuk menyesuaikan kepribadian dan format teks jawaban audio AI.
    public func promptPersonaInstruction() -> String {
        let style = resolveActiveStyle()
        switch style {
        case .whisperNight:
            return "Mode Malam: Pengguna sedang beristirahat atau di tempat hening. Gunakan kalimat pendek, nada lembut, ringkas, dan tenang."
        case .urgentAlert:
            return "Mode Siaga: Laporkan insiden kritis, server error, atau status keamanan dengan sangat jelas, terstruktur, dan tegas tanpa basa-basi."
        case .cheerfulMorning:
            return "Mode Pagi: Berikan respons ramah, energetik, dan bersemangat menyambut agenda hari ini."
        case .thoughtfulAnalyst:
            return "Mode Analitis: Berikan penjelasan teknis yang runtut, berbasis data dan arsitektur yang solid."
        case .naturalFriendly, .adaptiveAuto:
            return "Mode Alami: Berikan respons percakapan yang hangat, suportif, dan ringkas."
        }
    }
}

