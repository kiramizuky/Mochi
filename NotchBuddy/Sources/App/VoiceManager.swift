import Foundation
import AppKit
import AVFoundation
import Speech
import NaturalLanguage

// MARK: - Voice layer for Mochi: speaks assistant answers, push-to-talk dictation,
// and an optional wake word ("Mochi", default OFF so the mic stays fully
// silent — 0 % CPU — until the user opts in).
@MainActor
final class VoiceManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceManager()

    // MARK: Settings (persisted)

    @Published var soundEnabled: Bool = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakAnswers, forKey: "soundEnabled") }
    }
    @Published var speakAnswers: Bool = UserDefaults.standard.object(forKey: "speakAnswers") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakAnswers, forKey: "speakAnswers") }
    }
    @Published var wakeWordEnabled: Bool = UserDefaults.standard.object(forKey: "wakeWordEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(wakeWordEnabled, forKey: "wakeWordEnabled") }
    }
    @Published var ttsEngine: TTSEngineType = TTSEngineType(rawValue: UserDefaults.standard.string(forKey: "ttsEngine") ?? "system") ?? .system {
        didSet { UserDefaults.standard.set(ttsEngine.rawValue, forKey: "ttsEngine") }
    }
    @Published var openAIVoice: String = UserDefaults.standard.string(forKey: "openAIVoice") ?? "nova" {
        didSet { UserDefaults.standard.set(openAIVoice, forKey: "openAIVoice") }
    }
    @Published var elevenLabsVoiceId: String = UserDefaults.standard.string(forKey: "elevenLabsVoiceId") ?? "21m00Tcm4TlvDq8ikWAM" {
        didSet { UserDefaults.standard.set(elevenLabsVoiceId, forKey: "elevenLabsVoiceId") }
    }

    // MARK: PTT & Hands-Free state

    @Published private(set) var pttStatus: PTTStatus = .idle
    @Published private(set) var wakeListening = false
    @Published var isAttentiveSession: Bool = false
    @Published var attentiveSecondsRemaining: Int = 0

    // Set by the prompt view while it is on screen.
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// Default: reveals the island on the prompt view.
    var onWakeWord: (() -> Void)?

    // MARK: Private

    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    /// Flag thread-safe untuk mematikan input mikrofon secara instan saat asisten berbicara
    nonisolated(unsafe) static var isMutedForOutput: Bool = false

    private var isWakeSession = false
    private var isHandsFreeActive = false
    private var lastPartial = ""
    private var finalDelivered = false
    private var wakeCooldownUntil = Date.distantPast
    private var pttTimeout: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var wakeRestart: Task<Void, Never>?
    private var attentiveSessionTimer: Task<Void, Never>?
    private var attentiveSessionDeadline: Date = .distantPast
    private var attentiveCommitTask: Task<Void, Never>?
    private var handsFreeCommitTask: Task<Void, Never>?

    private let maxPTTSeconds: UInt64 = 30

    private override init() {
        super.init()
        synthesizer.delegate = self
        onWakeWord = {
            NotificationCenter.default.post(name: .voiceWake, object: nil)
        }
        HumanVoiceEngine.shared.onPlaybackFinished = { [weak self] in
            self?.handleResponseSpeechFinished()
        }
        // Re-arm an already-earned opt-in on next launch (permission prompt
        // only appears here if it was never granted).
        if wakeWordEnabled {
            Task { [weak self] in
                await self?.setWakeWordAsync(enabled: true)
            }
        }
    }

    // MARK: - TTS (speak answers)

    func speak(_ markdown: String) {
        guard speakAnswers else { return }
        let text = VoiceText.spokenResponse(from: markdown)
        guard !text.isEmpty else { return }

        // 1. Matikan input mic dan batalkan proses commit agar suara AI tidak dijawab sendiri
        Self.isMutedForOutput = true
        attentiveCommitTask?.cancel()
        attentiveCommitTask = nil
        handsFreeCommitTask?.cancel()
        handsFreeCommitTask = nil
        lastPartial = ""

        endAudioOnly()
        wakeListening = false

        stopSpeaking()

        if ttsEngine != .system {
            HumanVoiceEngine.shared.speak(
                text: text,
                engine: ttsEngine,
                openAIVoice: openAIVoice,
                elevenLabsVoiceId: elevenLabsVoiceId
            ) { [weak self] in
                self?.speakSystem(text)
            }
        } else {
            speakSystem(text)
        }
    }

    private func speakSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.08 // Mochi: slightly warm/young
        if let language = Self.voiceLanguage(for: text) {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        synthesizer.speak(utterance)
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || HumanVoiceEngine.shared.isPlaying
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        HumanVoiceEngine.shared.stop()
        Self.isMutedForOutput = false
    }

    /// Match the reply's language (EN/FR/…) to an installed TTS voice.
    private static func voiceLanguage(for text: String) -> String? {
        guard let dominant = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        let code = dominant.rawValue
        if AVSpeechSynthesisVoice(language: code) != nil { return code }
        let base = String(code.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .first { $0.language.hasPrefix(base) }?.language
    }

    // MARK: - Push-to-talk

    func startPTT() {
        Task { @MainActor [weak self] in
            await self?.startPTTAsync()
        }
    }

    func stopPTT() {
        Task { @MainActor [weak self] in
            await self?.stopPTTAsync()
        }
    }

    private func startPTTAsync() async {
        let next = PTTReducer.reduce(pttStatus, .press)
        guard next != pttStatus else { return } // already requesting/listening
        pttStatus = next
        guard next == .requesting else { return }
        stopSpeaking()
        await requestPermissionsAndListen()
    }

    private func stopPTTAsync() async {
        guard pttStatus == .listening || pttStatus == .requesting else { return }
        pttStatus = PTTReducer.reduce(pttStatus, .release) // → .idle
        // Let the recognizer finalize with the audio it already has.
        teardownAudio(cancelTask: false)
        scheduleFinalFallback()
        if wakeWordEnabled { scheduleWakeRestart(after: 1.6) }
    }

    private func requestPermissionsAndListen() async {
        do {
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            let speechStatus = await Self.requestSpeechAuthorization()
            guard micOK, speechStatus == .authorized else {
                pttStatus = PTTReducer.reduce(pttStatus, .permissionsDenied)
                SoundEngine.shared.play("error")
                onError?("Microphone or Speech access denied — enable Coucou in System Settings → Privacy & Security.")
                return
            }
            beginListening(wake: false) // applies .permissionsGranted → .listening
        } catch {
            failListening(wake: false, message: "Microphone or Speech access denied — enable Coucou in System Settings → Privacy & Security.")
        }
    }

    private func beginListening(wake: Bool) {
        teardownAudio(cancelTask: true)
        lastPartial = ""
        finalDelivered = false
        isWakeSession = wake

        if wake {
            guard wakeWordEnabled else { return }
            wakeListening = true
        } else {
            pttStatus = PTTReducer.reduce(pttStatus, .permissionsGranted)
            guard pttStatus == .listening else {
                return // user released while the permission dialog was up
            }
            SoundEngine.shared.play("blip")
        }

        // Create speech recognizer with current locale
        let locale = Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            failListening(wake: wake, message: "Speech recognition not available for current locale.")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            failListening(wake: wake, message: "Format audio mikrofon tidak valid.")
            return
        }

        Self.installAudioTap(on: input, format: format, request: req)
        tapInstalled = true

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            failListening(wake: wake, message: "Microphone unavailable: \(error.localizedDescription)")
            return
        }

        task = Self.startRecognitionTask(recognizer: recognizer, request: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text {
                    if self.isWakeSession {
                        self.handleWake(text: text, isFinal: isFinal)
                    } else {
                        self.handlePTT(text: text, isFinal: isFinal)
                    }
                }
                if let error {
                    self.handleRecognitionEnd(error: error)
                }
            }
        }

        if wake {
            wakeRestart?.cancel()
            wakeRestart = nil
        } else {
            let timeout = UInt64(maxPTTSeconds) * 1_000_000_000
            pttTimeout?.cancel()
            pttTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
                guard !Task.isCancelled, let self, self.pttStatus == .listening else { return }
                self.stopPTT()
            }
        }
    }

    // MARK: - Push-to-talk results

    private func handlePTT(text: String, isFinal: Bool) {
        guard !isWakeSession else { return }
        // Cegah perekaman jika output suara AI sedang aktif (anti audio-loop)
        guard !Self.isMutedForOutput && !isSpeaking else { return }
        lastPartial = text
        onPartial?(text)

        if isHandsFreeActive {
            // Mode hands-free: gunakan timer hening 2.5 detik agar tidak memotong user yang sedang bicara
            scheduleHandsFreePTTCommit()
        } else if isFinal {
            deliverFinal(text)
        }
    }

    private func scheduleHandsFreePTTCommit() {
        handsFreeCommitTask?.cancel()
        handsFreeCommitTask = Task { [weak self] in
            // Beri jeda hening 2.5 detik sebelum menganggap user selesai berbicara
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.isHandsFreeActive else { return }
            guard !Self.isMutedForOutput && !self.isSpeaking else { return }

            let candidate = self.lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return }

            // Jika ucapan tampak belum selesai (berakhir kata hubung/preposisi), beri waktu tambahan 2.0 detik
            if VoiceText.isSentenceIncomplete(candidate) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.isHandsFreeActive else { return }
                guard !Self.isMutedForOutput && !self.isSpeaking else { return }
            }

            let finalCandidate = self.lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard finalCandidate.count >= 3 else { return }
            self.deliverFinal(finalCandidate)
        }
    }

    private func deliverFinal(_ raw: String) {
        guard !finalDelivered else { return }
        finalDelivered = true
        handsFreeCommitTask?.cancel()
        handsFreeCommitTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        if let final = VoiceText.finalizeTranscript(raw) {
            SoundEngine.shared.play("tick")
            onFinal?(final)
            if isHandsFreeActive {
                isHandsFreeActive = false
                startOrResetAttentiveSession(duration: 60)
                AppState.shared.executeCommand(final)
            }
        }
        pttStatus = PTTReducer.reduce(pttStatus, .transcriptFinal(raw))
        teardownAudio(cancelTask: true)
        if wakeWordEnabled { scheduleWakeRestart(after: 0.4) }
    }

    private func scheduleFinalFallback() {
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self, !self.finalDelivered else { return }
            guard !Self.isMutedForOutput && !self.isSpeaking else { return }
            if let fallback = VoiceText.finalizeTranscript(self.lastPartial) {
                if VoiceText.isSentenceIncomplete(fallback) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled, !self.finalDelivered else { return }
                }
                self.deliverFinal(self.lastPartial)
            }
        }
    }

    private func handleRecognitionEnd(error: Error) {
        if wakeListening {
            // Apple ends wake sessions on long silence — just re-arm.
            endAudioOnly()
            scheduleWakeRestart(after: 0.6)
            return
        }
        guard pttStatus == .listening, !finalDelivered else { return }
        if let fallback = VoiceText.finalizeTranscript(lastPartial) {
            deliverFinal(fallback)
        } else {
            failListening(wake: false, message: error.localizedDescription)
        }
    }

    private func failListening(wake: Bool, message: String) {
        teardownAudio(cancelTask: true)
        if wake {
            scheduleWakeRestart(after: 1.5)
        } else {
            pttStatus = PTTReducer.reduce(pttStatus, .audioError(message))
            SoundEngine.shared.play("error")
            onError?(message)
        }
    }

    // MARK: - Hands-Free & 1-Minute Attentive Session

    /// Memulai atau memperbarui timer sesi attentive 1 menit (60 detik).
    /// Selama jendela ini, pengguna dapat berbicara langsung tanpa perlu mengulang wake word.
    /// Jika 60 detik berlalu tanpa aktivitas suara/perintah baru, Notch kembali ke mode idle.
    func startOrResetAttentiveSession(duration: TimeInterval = 60) {
        attentiveSessionTimer?.cancel()
        isAttentiveSession = true
        attentiveSessionDeadline = Date().addingTimeInterval(duration)
        attentiveSecondsRemaining = Int(duration)

        attentiveSessionTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { break }
                let remaining = Int(self.attentiveSessionDeadline.timeIntervalSinceNow)
                if remaining <= 0 {
                    self.endAttentiveSession()
                    break
                }
                self.attentiveSecondsRemaining = remaining
            }
        }
    }

    /// Mengakhiri sesi attentive dan mengembalikan Notch ke mode idle
    func endAttentiveSession() {
        attentiveSessionTimer?.cancel()
        attentiveSessionTimer = nil
        attentiveCommitTask?.cancel()
        attentiveCommitTask = nil
        handsFreeCommitTask?.cancel()
        handsFreeCommitTask = nil
        isAttentiveSession = false
        isHandsFreeActive = false
        attentiveSecondsRemaining = 0
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
        if wakeWordEnabled && pttStatus == .idle {
            scheduleWakeRestart(after: 0.4)
        }
    }

    /// Dipanggil saat TTS (audio respons) selesai membaca seluruh teks jawaban
    func handleResponseSpeechFinished() {
        // Beri jeda 600ms agar reverb/gema ruangan speaker benar-benar habis sebelum mic dibuka kembali
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            Self.isMutedForOutput = false

            // Reset/mulai timer 1 menit (60 detik) setelah asisten selesai berbicara
            self.startOrResetAttentiveSession(duration: 60)
            if self.wakeWordEnabled && self.pttStatus == .idle {
                self.scheduleWakeRestart(after: 0.1)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.handleResponseSpeechFinished()
        }
    }

    private func scheduleAttentiveCommandCommit() {
        attentiveCommitTask?.cancel()
        attentiveCommitTask = Task { [weak self] in
            // Beri jeda hening 2.5 detik agar user tidak terpotong saat berpikir
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.isAttentiveSession else { return }
            guard !Self.isMutedForOutput && !self.isSpeaking else { return }

            let candidate = self.lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return }

            // Jika ucapan tampak belum selesai (berakhir kata hubung/preposisi), beri waktu tambahan 2.0 detik
            if VoiceText.isSentenceIncomplete(candidate) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.isAttentiveSession else { return }
                guard !Self.isMutedForOutput && !self.isSpeaking else { return }
            }

            let finalCandidate = self.lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            guard finalCandidate.count >= 3 else { return }
            self.commitAttentiveCommand(finalCandidate)
        }
    }

    private func commitAttentiveCommand(_ raw: String) {
        attentiveCommitTask?.cancel()
        attentiveCommitTask = nil
        let command: String
        if let extracted = VoiceText.extractCommand(from: raw) {
            command = extracted
        } else {
            command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard command.count >= 2 else { return }
        lastPartial = ""
        SoundEngine.shared.play("tick")
        startOrResetAttentiveSession(duration: 60)
        endAudioOnly()
        AppState.shared.executeCommand(command)
        scheduleWakeRestart(after: 0.8)
    }

    // MARK: - Wake word (default OFF)

    /// Called from Settings when the toggle flips.
    func setWakeWord(enabled: Bool) {
        Task { [weak self] in
            await self?.setWakeWordAsync(enabled: enabled)
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    nonisolated private static func installAudioTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Abaikan input mikrofon saat asisten sedang bersuara agar tidak mendengarkan suara sendiri
            guard !VoiceManager.isMutedForOutput else { return }
            request.append(buffer)
        }
    }

    nonisolated private static func startRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request, resultHandler: handler)
    }

    private func setWakeWordAsync(enabled: Bool) async {
        if enabled {
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            let speechStatus = await Self.requestSpeechAuthorization()
            guard micOK, speechStatus == .authorized else {
                wakeWordEnabled = false // revert the toggle
                onError?("Microphone or Speech access denied — wake word disabled.")
                return
            }
            guard wakeWordEnabled, pttStatus == .idle else { return }
            SoundEngine.shared.play("blip")
            beginListening(wake: true)
        } else {
            stopWakeWord()
        }
    }

    private func stopWakeWord() {
        attentiveSessionTimer?.cancel()
        attentiveSessionTimer = nil
        attentiveCommitTask?.cancel()
        attentiveCommitTask = nil
        handsFreeCommitTask?.cancel()
        handsFreeCommitTask = nil
        isAttentiveSession = false
        isHandsFreeActive = false
        attentiveSecondsRemaining = 0
        wakeRestart?.cancel()
        wakeRestart = nil
        wakeListening = false
        isWakeSession = false
        teardownAudio(cancelTask: true)
    }

    private func handleWake(text: String, isFinal: Bool) {
        guard wakeListening else { return }
        // Jangan proses audio jika suara AI sedang aktif
        guard !Self.isMutedForOutput && !isSpeaking else { return }

        // 1. Jika dalam sesi attentive (jendela 60s aktif), tangkap ucapan sebagai perintah lanjutan
        if isAttentiveSession {
            lastPartial = text
            onPartial?(text)
            scheduleAttentiveCommandCommit()
            return
        }

        // 2. Deteksi Wake Word ("Mochi" atau "Jarvis")
        let hasWake = VoiceText.containsWakeWord(text, word: "mochi") || VoiceText.containsWakeWord(text, word: "jarvis")

        guard hasWake, Date() >= wakeCooldownUntil else {
            if isFinal {
                endAudioOnly()
                scheduleWakeRestart(after: 0.4)
            }
            return
        }

        wakeCooldownUntil = Date().addingTimeInterval(3)

        // 3. Cek apakah perintah diucapkan bersamaan dengan wake word:
        // contoh: "Mochi, tolong buka Safari"
        if let directCommand = VoiceText.extractCommand(from: text), directCommand.count >= 2 {
            SoundEngine.shared.play("blip")
            startOrResetAttentiveSession(duration: 60)
            endAudioOnly()
            AppState.shared.executeCommand(directCommand)
            scheduleWakeRestart(after: 0.8)
            return
        }

        // 4. Jika hanya memanggil wake word (contoh: "Mochi" atau "Jarvis"):
        SoundEngine.shared.play("blip")
        onWakeWord?()
        startOrResetAttentiveSession(duration: 60)

        // Mulai mendengarkan kalimat perintah berikutnya secara aktif
        isHandsFreeActive = true
        endAudioOnly()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, !Task.isCancelled else { return }
            self.startPTT()
        }
    }

    private func scheduleWakeRestart(after seconds: Double) {
        guard wakeWordEnabled else { return }
        wakeRestart?.cancel()
        wakeRestart = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.wakeWordEnabled, self.pttStatus == .idle else { return }
            self.wakeListening = true
            self.beginListening(wake: true)
        }
    }

    // MARK: - Teardown

    private func endAudioOnly() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        pttTimeout?.cancel()
        pttTimeout = nil
    }

    private func teardownAudio(cancelTask: Bool) {
        endAudioOnly()
        if cancelTask {
            task?.cancel()
            task = nil
            request = nil
        }
    }
}
