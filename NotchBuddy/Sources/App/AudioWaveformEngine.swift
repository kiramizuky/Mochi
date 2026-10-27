import Foundation
import SwiftUI

// MARK: - Audio Waveform Engine (Equalizer Wavebars Visualizer)

@MainActor
public final class AudioWaveformEngine: ObservableObject {
    public static let shared = AudioWaveformEngine()

    /// 4 batang wavebars vertikal untuk Notch Resting Pill (lebar 2.5px, variasi 3px - 14px)
    @Published public private(set) var compactWaveHeights: [CGFloat] = [4, 8, 12, 6]

    /// 16 batang frekuensi untuk Expanded Media Card
    @Published public private(set) var expandedWaveHeights: [CGFloat] = Array(repeating: 6.0, count: 16)

    @Published public var isAnimating: Bool = false

    private var animationTimer: Timer?
    private var phase: Double = 0.0

    private init() {
        start()
    }

    public func start() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    public func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        compactWaveHeights = [3, 3, 3, 3]
        expandedWaveHeights = Array(repeating: 3.0, count: 16)
    }

    private func tick() {
        let isPlaying = MediaManagerService.shared.isPlaying || AudioPlaybackService.shared.isPlaying
        self.isAnimating = isPlaying

        guard isPlaying else {
            // Animasi istirahat (rendah/tenang)
            self.compactWaveHeights = [3, 4, 3, 3]
            self.expandedWaveHeights = Array(repeating: 3.0, count: 16)
            return
        }

        phase += 0.35

        // 1. Update 4-Bar Compact Notch Wavebars
        var newCompact: [CGFloat] = []
        for i in 0..<4 {
            let offset = Double(i) * 0.9
            let s = sin(phase + offset)
            // Normalisasi tinggi antara 3px s.d. 14px
            let h = 3.0 + CGFloat((s + 1.0) / 2.0) * 11.0
            newCompact.append(max(3.0, h))
        }
        self.compactWaveHeights = newCompact

        // 2. Update 16-Bar Expanded Frequency Spectrum
        var newExpanded: [CGFloat] = []
        for i in 0..<16 {
            let offset = Double(i) * 0.45
            let s1 = sin(phase * 1.2 + offset)
            let s2 = cos(phase * 0.8 - offset * 0.5)
            let combined = (s1 + s2 + 2.0) / 4.0
            let h = 4.0 + CGFloat(combined) * 22.0
            newExpanded.append(max(4.0, h))
        }
        self.expandedWaveHeights = newExpanded
    }
}

