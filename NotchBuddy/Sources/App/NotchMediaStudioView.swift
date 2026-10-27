import SwiftUI
import AppKit
import AVKit

// MARK: - Notch Media Studio View (Expanded Island Media Card)

struct NotchMediaStudioView: View {
    @ObservedObject var state: AppState
    @ObservedObject var mediaManager = MediaManagerService.shared
    @ObservedObject var waveform = AudioWaveformEngine.shared

    @State private var selectedTab: MediaStudioTab = .music
    @State private var seekPosition: Double = 0.0
    @State private var isDraggingScrubber: Bool = false
    @State private var copiedToast: Bool = false

    enum MediaStudioTab: String, CaseIterable {
        case music = "Musik"
        case video = "Video"
        case image = "Gambar"
    }

    init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Header Bar & Tab Switcher
            headerBar
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Divider().opacity(0.3)

            // Content Area berdasarkan Tab Terpilih
            Group {
                switch selectedTab {
                case .music:
                    musicPlayerCard
                case .video:
                    videoPlayerCard
                case .image:
                    imageViewerCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.75))
        .onAppear {
            if let item = mediaManager.currentItem {
                switch item.mediaType {
                case .music: selectedTab = .music
                case .video: selectedTab = .video
                case .image: selectedTab = .image
                }
                seekPosition = item.position
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Ikon & Judul
            HStack(spacing: 5) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 13, weight: .bold))
                Text("Media Studio")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }

            Spacer()

            // Tab Picker Segmented
            Picker("", selection: $selectedTab) {
                ForEach(MediaStudioTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)

            Spacer()

            // Tombol Tutup / Kembali ke Overview
            Button {
                withAnimation {
                    state.view = .overview
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 1. Music Player Card

    private var musicPlayerCard: some View {
        let item = mediaManager.currentItem ?? MediaItem(
            title: "Tidak Ada Lagu Aktif",
            artist: "Buka Spotify / Apple Music",
            album: "Mochi Media Hub",
            duration: 180,
            position: 0,
            source: .spotify
        )

        return HStack(spacing: 16) {
            // Album Art dengan Glow Ambient
            ZStack {
                // Ambient Glow
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: 80, height: 80)
                    .blur(radius: 12)

                // Album Art Box
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 74, height: 74)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: item.source.iconName)
                                .font(.system(size: 24))
                                .foregroundColor(.accentColor)
                            Text(item.source.displayName)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                    )
            }

            // Info Lagu, Scrubber, & Kontrol
            VStack(alignment: .leading, spacing: 6) {
                // Info Judul & Artis
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("\(item.artist) • \(item.album)")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // Interactive Scrubber Bar
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { isDraggingScrubber ? seekPosition : item.position },
                            set: { seekPosition = $0 }
                        ),
                        in: 0...max(1.0, item.duration),
                        onEditingChanged: { editing in
                            isDraggingScrubber = editing
                            if !editing {
                                Task {
                                    _ = await mediaManager.executeAction("seek")
                                }
                            }
                        }
                    )
                    .accentColor(.accentColor)
                    .controlSize(.mini)

                    HStack {
                        Text(formatTime(isDraggingScrubber ? seekPosition : item.position))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTime(item.duration))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                // Playback Controls & 16-Bar Frequency Spectrum
                HStack(spacing: 14) {
                    // Previous Track
                    Button {
                        Task { _ = await mediaManager.executeAction("previous") }
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    // Play / Pause Toggle
                    Button {
                        Task { _ = await mediaManager.executeAction("toggle") }
                    } label: {
                        Image(systemName: mediaManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)

                    // Next Track
                    Button {
                        Task { _ = await mediaManager.executeAction("next") }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Live 16-Bar Waveform Spectrum
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<min(12, waveform.expandedWaveHeights.count), id: \.self) { idx in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(LinearGradient(
                                    colors: [.accentColor, .cyan],
                                    startPoint: .bottom,
                                    endPoint: .top
                                ))
                                .frame(width: 2.5, height: waveform.expandedWaveHeights[idx])
                        }
                    }
                    .frame(height: 24, alignment: .bottom)
                }
            }
        }
    }

    // MARK: - 2. Video Player Card

    private var videoPlayerCard: some View {
        HStack(spacing: 14) {
            // Mini Video Frame Placeholder / Preview
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 130, height: 80)

                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(mediaManager.currentItem?.title ?? "Klip Rekaman Layar / CCTV")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("Pemutar klip video native macOS. Mendukung MP4, MOV, rekaman layar, dan rekaman kamera CCTV.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Button {
                        // Play / Pause klip
                        Task { _ = await mediaManager.executeAction("toggle") }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Putar Klip")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        // Buka video di QuickTime Player
                        if let url = mediaManager.currentItem?.fileURL {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Buka di QuickTime")
                        }
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - 3. Image Viewer & Screenshot Inspector Card

    private var imageViewerCard: some View {
        let screenshots = mediaManager.recentScreenshots
        let selected = mediaManager.currentItem ?? screenshots.first

        return HStack(spacing: 14) {
            // Preview Image Box
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 110, height: 80)

                if let url = selected?.fileURL, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 110, height: 80)
                        .cornerRadius(10)
                } else {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(selected?.title ?? "Tangkapan Layar Terbaru")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(selected?.fileSizeFormatted ?? "1.2 MB")
                        .font(.system(size: 9.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(4)

                    Text("PNG Image")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                }

                // Tombol Aksi Cepat
                HStack(spacing: 6) {
                    Button {
                        if let url = selected?.fileURL, let img = NSImage(contentsOf: url) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([img])
                            withAnimation { copiedToast = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { copiedToast = false }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copiedToast ? "checkmark" : "doc.on.doc")
                            Text(copiedToast ? "Tersalin" : "Salin")
                        }
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let url = selected?.fileURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                            Text("Finder")
                        }
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }

                // Mini Carousel Thumbnails
                if !screenshots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(screenshots) { sc in
                                Button {
                                    mediaManager.currentItem = sc
                                } label: {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(sc.id == selected?.id ? Color.accentColor : Color.white.opacity(0.15))
                                        .frame(width: 20, height: 14)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    // MARK: - Helper

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

