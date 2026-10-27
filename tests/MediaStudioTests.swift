import Foundation
import AppKit

// MARK: - Test Suite Tahap A & B: Dynamic Island Media Studio & Multi-Format Player

@main
struct MediaStudioTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan MediaStudioTests (Tahap A & B)...")

        // MARK: - Test 1: Media Item Models & Formats
        log("T1: testMediaItemModelsAndSources")
        let musicItem = MediaItem(
            title: "Midnight City",
            artist: "M83",
            album: "Hurry Up, We're Dreaming",
            duration: 243.0,
            position: 45.0,
            source: .spotify,
            mediaType: .music
        )
        assert(musicItem.mediaType == .music, "MediaType harus .music")
        assert(musicItem.source == .spotify, "MediaSource harus .spotify")
        assert(musicItem.source.displayName == "Spotify", "DisplayName harus 'Spotify'")
        assert(musicItem.source.iconName == "music.note", "IconName harus 'music.note'")

        let videoItem = MediaItem(
            title: "Screen Recording 2026.mov",
            duration: 60.0,
            source: .localVideo,
            mediaType: .video
        )
        assert(videoItem.mediaType == .video, "MediaType harus .video")
        assert(videoItem.source.displayName == "Video Lokal", "DisplayName harus 'Video Lokal'")

        let imageItem = MediaItem(
            title: "CCTV_Snapshot.png",
            source: .localImage,
            mediaType: .image,
            fileSizeFormatted: "1.4 MB"
        )
        assert(imageItem.mediaType == .image, "MediaType harus .image")
        assert(imageItem.fileSizeFormatted == "1.4 MB", "FileSize harus '1.4 MB'")
        log("  Media item models and types verified.")
        log("T1 OK ✅")

        // MARK: - Test 2: MediaManagerService State & Presentation
        log("T2: testMediaManagerServiceState")
        let manager = MediaManagerService.shared

        await MainActor.run {
            // Test scan recent media
            manager.scanRecentMediaFiles()
            log("  Recent media scanned: \(manager.recentScreenshots.count) screenshots indexed")

            // Test present in notch
            manager.presentMediaInNotch(musicItem)
            assert(AppState.shared.activeMediaItem?.title == "Midnight City", "ActiveMediaItem harus terupdate")
            assert(AppState.shared.view == .media, "IslandView harus berpindah ke .media")
            assert(AppState.shared.mode == .expanded, "IslandMode harus berpindah ke .expanded")

            // Test set volume
            manager.setPlaybackVolume(0.75)
            assert(manager.volume == 0.75, "Volume harus terupdate menjadi 0.75")
        }
        log("  MediaManagerService presentation in Notch verified.")
        log("T2 OK ✅")

        // MARK: - Test 3: AudioWaveformEngine Live Equalizer Bars
        log("T3: testAudioWaveformEngine")
        let waveform = AudioWaveformEngine.shared

        await MainActor.run {
            // 4-Bar Compact
            let compactBars = waveform.compactWaveHeights
            assert(compactBars.count == 4, "Compact wavebars harus memiliki tepat 4 batang")
            for h in compactBars {
                assert(h >= 2.0 && h <= 20.0, "Tinggi batang compact harus berada dalam rentang normal (2-20)")
            }

            // 16-Bar Expanded
            let expandedBars = waveform.expandedWaveHeights
            assert(expandedBars.count == 16, "Expanded wavebars harus memiliki 16 batang frekuensi")
            for h in expandedBars {
                assert(h >= 2.0 && h <= 30.0, "Tinggi batang expanded harus berada dalam rentang normal (2-30)")
            }
        }
        log("  AudioWaveformEngine compact & expanded wavebars verified.")
        log("T3 OK ✅")

        // MARK: - Test 4: Island Layout & View Registration
        log("T4: testIslandViewRegistration")
        let allViews = IslandView.allCases
        assert(allViews.contains(.media), "IslandView harus menyertakan case .media")

        let mediaLayout = IslandConst.viewLayouts[.media]
        assert(mediaLayout != nil, "ViewLayout untuk .media harus terdaftar")
        assert(mediaLayout?.height == 195, "Tinggi layout .media harus 195px")

        let size = islandSize(mode: .expanded, view: .media)
        assert(size.1 == 195, "islandSize untuk .expanded .media harus mengembalikan tinggi 195px")
        log("  IslandView.media registration and dimensions verified.")
        log("T4 OK ✅")

        // MARK: - Test 5: AudioPlaybackService Local Playback State Machine
        log("T5: testAudioPlaybackService")
        let audioPlayer = AudioPlaybackService.shared

        await MainActor.run {
            assert(audioPlayer.isPlaying == false, "Default audio playback harus false")
            audioPlayer.setVolume(0.5)
            audioPlayer.seek(to: 10.0)
            audioPlayer.stop()
            assert(audioPlayer.currentPosition == 0.0, "Stop harus mereset posisi ke 0.0")
        }
        log("  AudioPlaybackService state machine verified.")
        log("T5 OK ✅")

        log("🎉 SEMUA TEST TAHAP A & B BERHASIL DILALUI DENGAN SEMPURNA!")
    }
}

