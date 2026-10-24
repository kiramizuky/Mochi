import Foundation
import AppKit
import SwiftUI

// MARK: - Canvas Window Controller
// Floating companion window tepat di bawah notch untuk menampilkan Artifacts Studio.

@MainActor
public final class CanvasWindowController: NSObject, NSWindowDelegate {
    public static let shared = CanvasWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    public func show(artifact: CanvasArtifact) {
        if let win = window {
            placeBelowIsland(win)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        win.title = "Artifacts Studio — \(artifact.title)"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true

        let host = NSHostingView(rootView: CanvasView())
        host.sizingOptions = [.minSize]
        win.contentView = host
        win.contentMinSize = NSSize(width: 540, height: 400)
        win.isReleasedWhenClosed = false
        win.delegate = self

        placeBelowIsland(win)
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.orderOut(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        CanvasManager.shared.isPresented = false
    }

    private func placeBelowIsland(_ win: NSWindow) {
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main ?? win.screen
        guard let screen else { win.center(); return }
        let visible = screen.visibleFrame
        let islandBottom = screen.frame.maxY - 320 - 12
        let top = min(visible.maxY, islandBottom)
        var frame = win.frame
        frame.size.height = min(frame.height, max(top - visible.minY - 12, win.minSize.height))
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = max(visible.minY + 12, top - frame.height)
        win.setFrame(frame, display: true)
    }
}
