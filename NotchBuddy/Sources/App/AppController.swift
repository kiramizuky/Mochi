import AppKit
import Foundation
import MediaPlayer
import ScreenCaptureKit

struct RunningAppInfo: Sendable, Equatable {
    let name: String
    let bundleID: String
    let pid: Int32
    let isActive: Bool
}

enum AppError: LocalizedError {
    case noMatch(String)
    case notRunning(String)
    case noVisibleWindow(String)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMatch(let value): return "No running app matches \"\(value)\"."
        case .notRunning(let value): return "\"\(value)\" is not running."
        case .noVisibleWindow(let value): return "No visible window for \"\(value)\"."
        case .captureFailed(let value): return value
        }
    }
}

protocol WorkspaceControlling: Sendable {
    func listRunningApplications() -> [RunningAppInfo]
    func terminate(pid: Int32) -> Bool
}

struct SystemWorkspace: WorkspaceControlling {
    func listRunningApplications() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map {
                RunningAppInfo(
                    name: $0.localizedName ?? $0.bundleIdentifier ?? "Unknown",
                    bundleID: $0.bundleIdentifier ?? "",
                    pid: $0.processIdentifier,
                    isActive: $0.isActive)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func terminate(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.terminate()
    }
}

/// A captured window: the file it was written to and the raw PNG bytes
/// (the agent embeds the bytes as an image block when they are small enough).
struct ScreenshotCapture: Sendable, Equatable {
    var path: String
    var data: Data
}

struct AppController: Sendable {
    var workspace: any WorkspaceControlling = SystemWorkspace()

    func list(filter: String?) -> String {
        var apps = workspace.listRunningApplications()
        if let filter, !filter.isEmpty {
            let needle = filter.lowercased()
            apps = apps.filter {
                $0.name.lowercased().contains(needle)
                    || $0.bundleID.lowercased().contains(needle)
            }
        }
        return Self.formatList(apps)
    }

    func close(_ name: String) throws -> String {
        guard let app = Self.match(query: name, in: workspace.listRunningApplications()) else {
            throw AppError.noMatch(name)
        }
        guard workspace.terminate(pid: app.pid) else {
            throw AppError.notRunning(app.name)
        }
        return "Quit requested for \(app.name)."
    }

    func screenshot(_ name: String) async throws -> String {
        let capture = try await capture(name)
        return "Screenshot saved to \(capture.path)"
    }

    func capture(_ name: String) async throws -> ScreenshotCapture {
        guard let app = Self.match(query: name, in: workspace.listRunningApplications()) else {
            throw AppError.noMatch(name)
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw AppError.captureFailed(
                "Grant Screen Recording in System Settings › Privacy & Security.")
        }
        guard let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == app.bundleID
        }) else {
            throw AppError.noVisibleWindow(app.name)
        }

        let image: CGImage
        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            throw AppError.captureFailed("Screen capture failed: \(error.localizedDescription)")
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.captureFailed("Could not encode screenshot.")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchBuddy/Screenshots",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safeBundle = app.bundleID.replacingOccurrences(of: ".", with: "-")
        let file = dir.appendingPathComponent("\(safeBundle)-\(stamp).png")
        try png.write(to: file)
        return ScreenshotCapture(path: file.path, data: png)
    }

    static func match(query: String, in apps: [RunningAppInfo]) -> RunningAppInfo? {
        var needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if needle.hasSuffix(".app") {
            needle = String(needle.dropLast(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !needle.isEmpty else { return nil }

        if let exact = apps.first(where: { $0.bundleID.lowercased() == needle }) { return exact }
        if let exact = apps.first(where: { $0.name.lowercased() == needle }) { return exact }

        let prefixes = apps.filter { $0.name.lowercased().hasPrefix(needle) }
        if let active = prefixes.first(where: { $0.isActive }) { return active }
        if let first = prefixes.first { return first }

        let contains = apps.filter { $0.name.lowercased().contains(needle) }
        if let active = contains.first(where: { $0.isActive }) { return active }
        return contains.first
    }

    static func formatList(_ apps: [RunningAppInfo], limit: Int = 30) -> String {
        guard !apps.isEmpty else { return "No regular applications are running." }
        var lines = "Running applications (\(apps.count)):"
        for app in apps.prefix(limit) {
            lines += "\n- \(app.name)"
            if app.isActive { lines += " (frontmost)" }
            if !app.bundleID.isEmpty { lines += " — \(app.bundleID)" }
        }
        if apps.count > limit {
            lines += "\nand \(apps.count - limit) more"
        }
        return lines
    }

    // MARK: - Media control (play/pause/next/prev via Now Playing Center)

    /// Kontrol pemutaran media aplikasi yang aktif di Now Playing Center
    /// (mis. Music, Spotify, Podcasts). `action` satu dari: play, pause,
    /// next, previous.
    func mediaControl(_ action: String) -> String {
        let center = MPRemoteCommandCenter.shared()
        switch action.lowercased() {
        case "play":
            return center.playCommand.isEnabled ? "Play." : "Play tidak tersedia."
        case "pause":
            return center.pauseCommand.isEnabled ? "Pause." : "Pause tidak tersedia."
        case "next":
            return center.nextTrackCommand.isEnabled ? "Next track." : "Next tidak tersedia."
        case "previous":
            return center.previousTrackCommand.isEnabled ? "Previous track." : "Previous tidak tersedia."
        default:
            return "Aksi media tidak dikenal: \(action) (play/pause/next/previous)."
        }
    }
}
