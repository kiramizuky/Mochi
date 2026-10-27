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

    /// Menerapkan status Pin-to-Desktop dan transparansi dinamis (Floating HUD mode).
    public func applyPinState(isPinned: Bool, opacity: Double = 0.90) {
        guard let win = window else { return }
        if isPinned {
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .stationary]
            win.alphaValue = CGFloat(opacity)
        } else {
            win.level = .normal
            win.collectionBehavior = []
            win.alphaValue = 1.0
        }
    }

    /// Memindahkan jendela Canvas secara animatif ke sudut layar monitor yang dipilih.
    public func dockTo(corner: CanvasDockCorner) {
        guard let win = window else { return }
        let screen = win.screen ?? IslandWindowController.notchScreen() ?? NSScreen.main
        guard let screen else { win.center(); return }
        let visible = screen.visibleFrame
        var frame = win.frame

        switch corner {
        case .belowNotch:
            let islandBottom = screen.frame.maxY - 320 - 12
            let top = min(visible.maxY, islandBottom)
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = max(visible.minY + 12, top - frame.height)
        case .topRight:
            frame.origin.x = visible.maxX - frame.width - 20
            frame.origin.y = visible.maxY - frame.height - 20
        case .bottomRight:
            frame.origin.x = visible.maxX - frame.width - 20
            frame.origin.y = visible.minY + 20
        case .center:
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
        }

        win.setFrame(frame, display: true, animate: true)
    }

    private func placeBelowIsland(_ win: NSWindow) {
        dockTo(corner: .belowNotch)
    }
}
