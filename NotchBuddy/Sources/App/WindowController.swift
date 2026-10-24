import AppKit
import CoreGraphics
import Foundation

// MARK: - Window control (AppKit)

/// Informasi satu jendela yang terlihat.
struct WindowInfo: Identifiable, Equatable, Sendable {
    var id: Int { windowNumber }
    var windowNumber: Int
    var appName: String
    var bundleID: String?
    var title: String
    var bounds: CGRect
    var isMain: Bool
    var isMinimized: Bool
}

/// Kontrol jendela macOS (daftar, fokus, geser, ubah ukuran).
/// Operasi yang menyentuh AppKit (NSWindow/NSApplication) dijalankan melalui
/// `MainActor.assumeIsolated` agar dapat dipanggil dari konteks non-isolasi
/// (mis. ToolExecutor) tanpa `await` di setiap pemanggilan.
protocol WindowControlling {
    func listWindows() -> [WindowInfo]
    func focus(windowNumber: Int) -> Bool
    func move(windowNumber: Int, to point: CGPoint) -> Bool
    func resize(windowNumber: Int, size: CGSize) -> Bool
}

final class SystemWindowController: WindowControlling {
    func listWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: AnyObject]] else { return [] }

        return info.compactMap { dict in
            guard let number = dict[kCGWindowNumber as String] as? Int,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: AnyObject],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            let appName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
            let bundleID = dict["kCGWindowOwnerBundleID"] as? String
            let title = (dict[kCGWindowName as String] as? String) ?? ""
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            guard layer >= 0, layer < 200 else { return nil }
            let isMain = (dict["kCGWindowIsMain"] as? Bool) ?? false
            let isMinimized = (dict[kCGWindowMemoryUsage as String] != nil) && bounds.isEmpty
            return WindowInfo(windowNumber: number, appName: appName, bundleID: bundleID,
                              title: title, bounds: bounds, isMain: isMain, isMinimized: isMinimized)
        }.sorted { $0.appName < $1.appName }
    }

    func focus(windowNumber: Int) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: AnyObject]] else { return false }
        guard let entry = info.first(where: { $0[kCGWindowNumber as String] as? Int == windowNumber }),
              let pid = entry[kCGWindowOwnerPID as String] as? Int32 else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        guard app.activate(options: [.activateAllWindows]) else { return false }
        return true
    }

    func move(windowNumber: Int, to point: CGPoint) -> Bool {
        MainActor.assumeIsolated {
            guard let window = Self.window(for: windowNumber) else { return false }
            var frame = window.frame
            frame.origin = point
            window.setFrame(frame, display: true, animate: false)
            return true
        }
    }

    func resize(windowNumber: Int, size: CGSize) -> Bool {
        MainActor.assumeIsolated {
            guard let window = Self.window(for: windowNumber) else { return false }
            var frame = window.frame
            frame.size = size
            window.setFrame(frame, display: true, animate: false)
            return true
        }
    }

    private static func window(for number: Int) -> NSWindow? {
        MainActor.assumeIsolated {
            guard let windows = NSApplication.shared.value(forKey: "windows") as? [NSWindow] else {
                return nil
            }
            return windows.first { $0.windowNumber == number }
        }
    }
}

/// Wrapper: daftar jendela milik aplikasi tertentu (atau semua aplikasi).
func windows(ofApp bundleIDOrName: String? = nil) -> [WindowInfo] {
    let controller = SystemWindowController()
    let all = controller.listWindows()
    guard let filter = bundleIDOrName, !filter.isEmpty else { return all }
    let needle = filter.lowercased()
    return all.filter {
        $0.appName.lowercased().contains(needle)
            || $0.bundleID?.lowercased().contains(needle) == true
    }
}
