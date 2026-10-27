import Foundation
import AVFoundation

// MARK: - Realtime Voice Duplex & Conversational Interruption Engine

@MainActor
public final class VoiceDuplexEngine: ObservableObject {
    public static let shared = VoiceDuplexEngine()

    @Published public var isDuplexActive: Bool = false
    @Published public var isInterrupted: Bool = false
    @Published public var emotionalTone: EmotionalTone = .attentive

    public enum EmotionalTone: String, CaseIterable, Sendable {
        case attentive = "attentive" // Siap mendengar, ramah & responsif
        case focused   = "focused"   // Sedang memproses tugas terstruktur
        case caution   = "caution"   // Menunggu persetujuan manusia
    }

    private var audioEngine: AVAudioEngine?
    private var isTapInstalled: Bool = false
    private var lastBargeInTime: Date = .distantPast

    private init() {}

    /// Mengaktifkan mode Voice Duplex (Interupsi Alami Real-time).
    public func startDuplex() {
        guard !isDuplexActive else { return }

        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                await MainActor.run {
                    self.isDuplexActive = false
                }
                return
            }

            await MainActor.run {
                self.setupAndStartEngine()
                RealtimeVoiceStreamService.shared.startLiveStream()
            }
        }
    }

    private func setupAndStartEngine() {
        stopDuplex()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let bus = 0
        let format = inputNode.outputFormat(forBus: bus)

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            isDuplexActive = false
            return
        }

        Self.installVADTap(on: inputNode, bus: bus, format: format)
        isTapInstalled = true

        do {
            engine.prepare()
            try engine.start()
            self.audioEngine = engine
            self.isDuplexActive = true
        } catch {
            self.isDuplexActive = false
            self.audioEngine = nil
            self.isTapInstalled = false
        }
    }

    /// Menonaktifkan mode Voice Duplex.
    public func stopDuplex() {
        if let engine = audioEngine {
            if isTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                isTapInstalled = false
            }
            engine.stop()
        }
        audioEngine = nil
        isDuplexActive = false
        RealtimeVoiceStreamService.shared.stopLiveStream()
    }

    /// Callback audio nonisolated agar tidak memeriksa MainActor di thread CoreAudio.
    nonisolated private static func installVADTap(
        on inputNode: AVAudioInputNode,
        bus: Int,
        format: AVAudioFormat
    ) {
        inputNode.installTap(onBus: bus, bufferSize: 1024, format: format) { buffer, _ in
            analyzeBufferNonisolated(buffer)
        }
    }

    /// Analisis VAD di thread audio tanpa memblokir MainActor
    nonisolated private static func analyzeBufferNonisolated(_ buffer: AVAudioPCMBuffer) {
        // Cegah echo speaker memotong suara asisten sendiri saat asisten sedang berbicara
        guard !VoiceManager.isMutedForOutput else { return }

        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = buffer.frameLength
        guard frames > 0 else { return }

        var sumSquares: Float = 0.0
        for i in 0..<Int(frames) {
            let sample = channelData[i]
            sumSquares += sample * sample
        }

        let rms = sqrt(sumSquares / Float(frames))
        let db = 20 * log10(max(rms, 0.00001))

        // Ambang batas desibel vokal bicara manusia (~ -28 dB)
        if db > -28.0 {
            Task { @MainActor in
                VoiceDuplexEngine.shared.triggerBargeInIfSpeaking()
            }
        }
    }

    /// Dieksekusi di MainActor untuk menghentikan TTS dan memulai mendengarkan pengguna
    public func triggerBargeInIfSpeaking() {
        guard !VoiceManager.isMutedForOutput else { return }
        let now = Date()
        guard now.timeIntervalSince(lastBargeInTime) > 1.2 else { return }
        guard VoiceManager.shared.isSpeaking else { return }
        lastBargeInTime = now

        // Pengguna menyela pembicaraan asisten!
        VoiceManager.shared.stopSpeaking()
        isInterrupted = true
        SoundEngine.shared.play("tick")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)

        // Mulai transkripsi suara pengguna
        VoiceManager.shared.startPTT()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.isInterrupted = false
        }
    }

    /// Menyesuaikan nada emosional asisten berdasarkan jenis pekerjaan.
    public func setTone(_ tone: EmotionalTone) {
        self.emotionalTone = tone
        switch tone {
        case .attentive:
            AppState.shared.stateOverride = nil
        case .focused:
            AppState.shared.stateOverride = .thinking
        case .caution:
            AppState.shared.stateOverride = .approval
        }
    }
}
