import Foundation
import AVFoundation

// MARK: - Local Audio Playback Service

@MainActor
public final class AudioPlaybackService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    public static let shared = AudioPlaybackService()

    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentPosition: Double = 0.0
    @Published public private(set) var currentDuration: Double = 0.0
    @Published public private(set) var currentLocalItem: MediaItem?

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    private override init() {
        super.init()
    }

    public func play(url: URL) {
        stop()

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            self.player = p
            self.isPlaying = true
            self.currentDuration = p.duration
            self.currentPosition = 0.0

            let item = MediaItem(
                id: url.path,
                title: url.deletingPathExtension().lastPathComponent,
                artist: "Audio Lokal",
                album: "File Mac",
                duration: p.duration,
                position: 0.0,
                source: .localAudio,
                mediaType: .music,
                fileURL: url
            )
            self.currentLocalItem = item

            startProgressTimer()
        } catch {
            print("⚠️ [AudioPlaybackService] Gagal memutar audio: \(error.localizedDescription)")
            self.isPlaying = false
        }
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    public func resume() {
        guard let p = player else { return }
        p.play()
        isPlaying = true
        startProgressTimer()
    }

    public func stop() {
        stopProgressTimer()
        player?.stop()
        player = nil
        isPlaying = false
        currentPosition = 0.0
        currentDuration = 0.0
        currentLocalItem = nil
    }

    public func seek(to seconds: Double) {
        guard let p = player else { return }
        let clamped = max(0.0, min(seconds, p.duration))
        p.currentTime = clamped
        currentPosition = clamped
    }

    public func setVolume(_ vol: Float) {
        player?.volume = max(0.0, min(1.0, vol))
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let p = self.player else { return }
                self.currentPosition = p.currentTime
                if var item = self.currentLocalItem {
                    item.position = p.currentTime
                    self.currentLocalItem = item
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    // MARK: - AVAudioPlayerDelegate
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
        }
    }
}

