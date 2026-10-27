import Foundation
import AppKit
import AVFoundation

// MARK: - Media Item Models

public enum MediaType: String, Codable, Sendable {
    case music
    case video
    case image
}

public enum MediaSource: String, Codable, Sendable {
    case spotify
    case appleMusic
    case localAudio
    case localVideo
    case localImage

    public var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .localAudio: return "Audio Lokal"
        case .localVideo: return "Video Lokal"
        case .localImage: return "Foto / Screenshot"
        }
    }

    public var iconName: String {
        switch self {
        case .spotify: return "music.note"
        case .appleMusic: return "applelogo"
        case .localAudio: return "waveform"
        case .localVideo: return "film"
        case .localImage: return "photo"
        }
    }
}

public struct MediaItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double // detik
    public var position: Double // detik
    public var artworkURL: String?
    public var source: MediaSource
    public var mediaType: MediaType
    public var fileURL: URL?
    public var fileSizeFormatted: String?
    public var dimensions: CGSize?

    public init(
        id: String = UUID().uuidString,
        title: String,
        artist: String = "",
        album: String = "",
        duration: Double = 0.0,
        position: Double = 0.0,
        artworkURL: String? = nil,
        source: MediaSource = .localAudio,
        mediaType: MediaType = .music,
        fileURL: URL? = nil,
        fileSizeFormatted: String? = nil,
        dimensions: CGSize? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.artworkURL = artworkURL
        self.source = source
        self.mediaType = mediaType
        self.fileURL = fileURL
        self.fileSizeFormatted = fileSizeFormatted
        self.dimensions = dimensions
    }
}

// MARK: - MediaManagerService

@MainActor
public final class MediaManagerService: ObservableObject {
    public static let shared = MediaManagerService()

    @Published public var currentItem: MediaItem?
    @Published public var isPlaying: Bool = false
    @Published public var volume: Double = 0.8
    @Published public var recentScreenshots: [MediaItem] = []
    @Published public var recentMediaFiles: [MediaItem] = []

    private var pollTimer: Timer?

    private init() {
        startPolling()
        scanRecentMediaFiles()
    }

    // MARK: - 1. Polling State Media macOS

    public func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNowPlaying()
            }
        }
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Memeriksa pemutar aktif (Spotify / Apple Music)
    public func refreshNowPlaying() {
        // Jika sedang memutar file lokal via AudioPlaybackService, sinkronkan dari sana
        if AudioPlaybackService.shared.isPlaying, let local = AudioPlaybackService.shared.currentLocalItem {
            self.currentItem = local
            self.isPlaying = true
            syncToAppState()
            return
        }

        // Query AppleScript non-blocking
        Task {
            let item = await queryExternalPlayers()
            await MainActor.run {
                if let item = item {
                    self.currentItem = item
                    self.isPlaying = (item.position > 0 && self.isPlaying) || self.checkIfPlayingApp()
                } else if AudioPlaybackService.shared.isPlaying {
                    self.currentItem = AudioPlaybackService.shared.currentLocalItem
                    self.isPlaying = true
                }
                self.syncToAppState()
            }
        }
    }

    private func syncToAppState() {
        AppState.shared.activeMediaItem = self.currentItem
        AppState.shared.isMediaPlaying = self.isPlaying
        if let item = self.currentItem {
            AppState.shared.mediaPlaybackPosition = item.position
            AppState.shared.mediaDuration = item.duration
        }
    }

    private func checkIfPlayingApp() -> Bool {
        // Cek sederhana via AppleScript status
        let script = """
        tell application "System Events"
            set sRunning to (name of processes) contains "Spotify"
            set mRunning to (name of processes) contains "Music"
        end tell
        if sRunning then
            tell application "Spotify" to return (player state is playing) as string
        else if mRunning then
            tell application "Music" to return (player state is playing) as string
        end if
        return "false"
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let output = appleScript.executeAndReturnError(&error).stringValue ?? "false"
            return output.lowercased() == "true"
        }
        return false
    }

    private func queryExternalPlayers() async -> MediaItem? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let script = """
                tell application "System Events"
                    set sRunning to (name of processes) contains "Spotify"
                    set mRunning to (name of processes) contains "Music"
                end tell
                if sRunning then
                    tell application "Spotify"
                        set tName to name of current track
                        set tArtist to artist of current track
                        set tAlbum to album of current track
                        set tDur to (duration of current track) / 1000.0
                        set tPos to player position
                        return tName & ":::" & tArtist & ":::" & tAlbum & ":::" & (tDur as string) & ":::" & (tPos as string) & ":::spotify"
                    end tell
                else if mRunning then
                    tell application "Music"
                        set tName to name of current track
                        set tArtist to artist of current track
                        set tAlbum to album of current track
                        set tDur to duration of current track
                        set tPos to player position
                        return tName & ":::" & tArtist & ":::" & tAlbum & ":::" & (tDur as string) & ":::" & (tPos as string) & ":::applemusic"
                    end tell
                end if
                return ""
                """
                var error: NSDictionary?
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(returning: nil)
                    return
                }
                let desc = appleScript.executeAndReturnError(&error)
                let text = desc.stringValue ?? ""
                guard !text.isEmpty && text.contains(":::") else {
                    continuation.resume(returning: nil)
                    return
                }

                let parts = text.components(separatedBy: ":::")
                guard parts.count >= 6 else {
                    continuation.resume(returning: nil)
                    return
                }

                let name = parts[0]
                let artist = parts[1]
                let album = parts[2]
                let duration = Double(parts[3]) ?? 180.0
                let pos = Double(parts[4]) ?? 0.0
                let srcTag = parts[5]

                let item = MediaItem(
                    id: "ext-\(name)-\(artist)",
                    title: name,
                    artist: artist,
                    album: album,
                    duration: duration,
                    position: pos,
                    source: srcTag == "spotify" ? .spotify : .appleMusic,
                    mediaType: .music
                )
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - 2. Kontrol Playback (Play, Pause, Next, Prev, Volume)

    public func executeAction(_ action: String) async -> (success: Bool, message: String) {
        let act = action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Jika memutar audio lokal
        if let current = currentItem, current.source == .localAudio {
            switch act {
            case "play", "resume":
                AudioPlaybackService.shared.resume()
                isPlaying = true
                syncToAppState()
                return (true, "Audio lokal dilanjutkan ▶️")
            case "pause":
                AudioPlaybackService.shared.pause()
                isPlaying = false
                syncToAppState()
                return (true, "Audio lokal dijeda ⏸️")
            case "toggle":
                if AudioPlaybackService.shared.isPlaying {
                    AudioPlaybackService.shared.pause()
                    isPlaying = false
                } else {
                    AudioPlaybackService.shared.resume()
                    isPlaying = true
                }
                syncToAppState()
                return (true, "Playback lokal di-toggle ⏯️")
            default:
                break
            }
        }

        // Delegasikan ke AppleScript untuk Spotify / Music
        let res = await AppleAppsIntegrationService.shared.controlMedia(action: act)
        if act == "play" || act == "resume" {
            self.isPlaying = true
        } else if act == "pause" || act == "stop" {
            self.isPlaying = false
        } else if act == "toggle" {
            self.isPlaying.toggle()
        }
        syncToAppState()
        return (true, res)
    }

    public func setPlaybackVolume(_ newVol: Double) {
        self.volume = max(0.0, min(1.0, newVol))
        AudioPlaybackService.shared.setVolume(Float(self.volume))
    }

    // MARK: - 3. Scan File Media Lokal (Screenshots & Clips)

    public func scanRecentMediaFiles() {
        let fm = FileManager.default
        var items: [MediaItem] = []

        // 1. Scan folder Screenshots / Desktop
        let home = fm.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop")
        let pictures = home.appendingPathComponent("Pictures")
        let screenshotsDir = pictures.appendingPathComponent("Screenshots")

        let scanDirs = [screenshotsDir, desktop]
        for dir in scanDirs {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles) else {
                continue
            }
            let imageFiles = contents.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["png", "jpg", "jpeg", "webp", "heic"].contains(ext)
            }

            for url in imageFiles.prefix(6) {
                let sizeStr = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { "\($0 / 1024) KB" } ?? "Unknown"
                let item = MediaItem(
                    id: url.path,
                    title: url.lastPathComponent,
                    artist: "Screenshot macOS",
                    album: "Desktop Capture",
                    source: .localImage,
                    mediaType: .image,
                    fileURL: url,
                    fileSizeFormatted: sizeStr
                )
                items.append(item)
            }
        }

        self.recentScreenshots = Array(items.prefix(8))
    }

    /// Menampilkan file media tertentu (foto/video/audio) ke Notch Island
    public func presentMediaInNotch(_ item: MediaItem) {
        self.currentItem = item
        if item.mediaType == .music && item.source == .localAudio, let url = item.fileURL {
            AudioPlaybackService.shared.play(url: url)
            self.isPlaying = true
        }
        syncToAppState()
        AppState.shared.view = .media
        AppState.shared.mode = .expanded
    }

    // MARK: - 4. Interaksi Cepat & Helper Pemutar

    public func controlPlayback(action: String) async -> (success: Bool, message: String) {
        await executeAction(action)
    }

    public func resumePlayback() {
        Task { _ = await controlPlayback(action: "play") }
    }

    public func pausePlayback() {
        Task { _ = await controlPlayback(action: "pause") }
    }

    public func togglePlayPause() {
        Task { _ = await controlPlayback(action: "toggle") }
    }

    public func nextTrack() {
        Task { _ = await controlPlayback(action: "next") }
    }

    public func previousTrack() {
        Task { _ = await controlPlayback(action: "previous") }
    }

    public func seek(to seconds: Double) {
        if currentItem?.source == .localAudio {
            AudioPlaybackService.shared.seek(to: seconds)
            self.currentItem?.position = seconds
            syncToAppState()
        }
    }

    // MARK: - 5. Inspeksi File Media & Tampilan ke Notch / Canvas

    /// Menganalisis berkas media lokal dan menampilkannya di Notch Island dan/atau Canvas Studio
    public func inspectAndPresentMedia(
        path: String,
        presentInNotch: Bool = true,
        presentInCanvas: Bool = false
    ) -> (success: Bool, item: MediaItem?, message: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return (false, nil, "Berkas tidak ditemukan pada lokasi: \(expandedPath)")
        }

        let ext = fileURL.pathExtension.lowercased()
        let audioExts = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg"]
        let videoExts = ["mp4", "mov", "m4v", "mkv", "webm", "avi"]
        let imageExts = ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"]

        let mediaType: MediaType
        let mediaSource: MediaSource

        if audioExts.contains(ext) {
            mediaType = .music
            mediaSource = .localAudio
        } else if videoExts.contains(ext) {
            mediaType = .video
            mediaSource = .localVideo
        } else if imageExts.contains(ext) {
            mediaType = .image
            mediaSource = .localImage
        } else {
            return (false, nil, "Format berkas .\(ext) tidak didukung sebagai media.")
        }

        // Hitung ukuran berkas
        let attr = (try? FileManager.default.attributesOfItem(atPath: expandedPath)) ?? [:]
        let fileSize = (attr[.size] as? NSNumber)?.int64Value ?? 0
        let formattedSize = fileSize > 1_048_576 ? String(format: "%.1f MB", Double(fileSize) / 1_048_576.0) : "\(fileSize / 1024) KB"

        var dimensions: CGSize? = nil
        var duration: Double = 0.0

        if mediaType == .image {
            if let img = NSImage(contentsOfFile: expandedPath) {
                dimensions = img.size
            }
        } else {
            let asset = AVURLAsset(url: fileURL)
            duration = CMTimeGetSeconds(asset.duration)
            if duration.isNaN { duration = 0.0 }
        }

        let item = MediaItem(
            id: expandedPath,
            title: fileURL.deletingPathExtension().lastPathComponent,
            artist: mediaSource.displayName,
            album: ext.uppercased(),
            duration: duration,
            position: 0.0,
            source: mediaSource,
            mediaType: mediaType,
            fileURL: fileURL,
            fileSizeFormatted: formattedSize,
            dimensions: dimensions
        )

        if presentInNotch {
            presentMediaInNotch(item)
        }

        if presentInCanvas {
            if mediaType == .image {
                _ = presentGalleryInCanvas(paths: [expandedPath], folderPath: nil, title: "Inspeksi Foto: \(item.title)")
            } else {
                presentMediaInCanvas(item)
            }
        }

        let dimMsg = dimensions.map { " (\(Int($0.width))×\(Int($0.height)) px)" } ?? ""
        let durMsg = duration > 0 ? " [\(Int(duration / 60)):\(String(format: "%02d", Int(duration.truncatingRemainder(dividingBy: 60))))]" : ""
        let msg = "Media '\(item.title).\(ext)' berhasil diinspeksi\(dimMsg)\(durMsg) - \(formattedSize)."
        return (true, item, msg)
    }

    /// Menampilkan pemutar audio/video layar lebar di Canvas Studio
    public func presentMediaInCanvas(_ item: MediaItem) {
        let title = "Media Studio: \(item.title)"
        var metadata: [String: String] = [
            "title": item.title,
            "artist": item.artist,
            "album": item.album,
            "source": item.source.rawValue,
            "mediaType": item.mediaType.rawValue,
            "duration": "\(Int(item.duration))",
            "fileSize": item.fileSizeFormatted ?? "Unknown"
        ]
        if let path = item.fileURL?.path {
            metadata["filePath"] = path
        }

        let content = """
        # \(item.title)
        **Artis**: \(item.artist.isEmpty ? "Artis Tidak Diketahui" : item.artist)
        **Album**: \(item.album)
        **Durasi**: \(Int(item.duration / 60)):\(String(format: "%02d", Int(item.duration.truncatingRemainder(dividingBy: 60))))
        **Ukuran**: \(item.fileSizeFormatted ?? "-")
        **Lokasi**: \(item.fileURL?.path ?? "Streaming / Remote")
        """

        let artifact = CanvasArtifact(
            id: "media-\(UUID().uuidString.prefix(6))",
            title: title,
            type: .media,
            content: content,
            metadata: metadata
        )
        CanvasManager.shared.present(artifact: artifact)
    }

    /// Menampilkan galeri foto/screenshot ke Canvas Studio
    public func presentGalleryInCanvas(
        paths: [String]? = nil,
        folderPath: String? = nil,
        title: String? = nil
    ) -> (success: Bool, count: Int, message: String) {
        var targets: [URL] = []
        let fm = FileManager.default
        let imageExts = ["png", "jpg", "jpeg", "webp", "heic", "gif"]

        if let explicit = paths, !explicit.isEmpty {
            targets = explicit.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        } else if let folder = folderPath, !folder.isEmpty {
            let expanded = (folder as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles) {
                targets = files.filter { imageExts.contains($0.pathExtension.lowercased()) }
            }
        } else {
            // Default: gabungkan recent screenshots dan Desktop images
            let home = fm.homeDirectoryForCurrentUser
            let desktop = home.appendingPathComponent("Desktop")
            let screenshotsDir = home.appendingPathComponent("Pictures/Screenshots")
            for dir in [screenshotsDir, desktop] {
                if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles) {
                    targets.append(contentsOf: files.filter { imageExts.contains($0.pathExtension.lowercased()) })
                }
            }
        }

        targets = targets.filter { fm.fileExists(atPath: $0.path) }
        guard !targets.isEmpty else {
            return (false, 0, "Tidak ada file gambar yang ditemukan untuk ditampilkan di galeri.")
        }

        // Buat representasi JSON untuk Canvas Gallery View
        var itemsData: [[String: String]] = []
        for url in targets.prefix(30) {
            let attr = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attr[.size] as? NSNumber)?.int64Value ?? 0
            let sizeStr = size > 1_048_576 ? String(format: "%.1f MB", Double(size) / 1_048_576.0) : "\(size / 1024) KB"
            let modDate = (attr[.modificationDate] as? Date).map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "-"

            itemsData.append([
                "filePath": url.path,
                "title": url.lastPathComponent,
                "size": sizeStr,
                "date": modDate,
                "format": url.pathExtension.uppercased()
            ])
        }

        let jsonString: String
        if let data = try? JSONSerialization.data(withJSONObject: itemsData, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            jsonString = str
        } else {
            jsonString = targets.map { $0.path }.joined(separator: "\n")
        }

        let galleryTitle = title ?? "Galeri Media (\(itemsData.count) Berkas)"
        let artifact = CanvasArtifact(
            id: "gallery-\(UUID().uuidString.prefix(6))",
            title: galleryTitle,
            type: .gallery,
            content: jsonString,
            metadata: ["itemCount": "\(itemsData.count)"]
        )
        CanvasManager.shared.present(artifact: artifact)
        return (true, itemsData.count, "Galeri media dengan \(itemsData.count) berkas berhasil ditampilkan di Canvas Studio.")
    }

    /// Menemukan rekaman layar, screenshot, atau lagu terbaru
    public func listRecentMedia(category: String = "all", limit: Int = 10) -> [MediaItem] {
        scanRecentMediaFiles()
        var results: [MediaItem] = []

        if category == "screenshots" || category == "all" {
            results.append(contentsOf: recentScreenshots)
        }

        if (category == "downloads" || category == "all") && results.count < limit {
            let fm = FileManager.default
            let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            if let files = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles) {
                let mediaExts = ["png", "jpg", "jpeg", "webp", "mp4", "mov", "mp3", "m4a", "wav"]
                let filtered = files.filter { mediaExts.contains($0.pathExtension.lowercased()) }
                for file in filtered.prefix(limit) {
                    let ext = file.pathExtension.lowercased()
                    let mType: MediaType = ["mp3", "m4a", "wav"].contains(ext) ? .music : (["mp4", "mov"].contains(ext) ? .video : .image)
                    let mSource: MediaSource = mType == .music ? .localAudio : (mType == .video ? .localVideo : .localImage)
                    results.append(MediaItem(
                        id: file.path,
                        title: file.lastPathComponent,
                        artist: "Downloads",
                        album: ext.uppercased(),
                        source: mSource,
                        mediaType: mType,
                        fileURL: file
                    ))
                }
            }
        }

        return Array(results.prefix(limit))
    }
}


