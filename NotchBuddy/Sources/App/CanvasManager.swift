import Foundation
import AppKit
import Combine

// MARK: - Canvas Manager
// Mengelola siklus hidup, penayangan, dan ekspor Canvas Artifacts Studio.

public enum CanvasDockCorner: String, CaseIterable, Identifiable, Sendable {
    case belowNotch   = "Bawah Notch"
    case topRight     = "Kanan Atas"
    case bottomRight  = "Kanan Bawah"
    case center       = "Tengah Layar"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .belowNotch:  return "rectangle.topthird.inset.filled"
        case .topRight:    return "rectangle.inset.topright.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .center:      return "rectangle.center.inset.filled"
        }
    }
}

@MainActor
public final class CanvasManager: ObservableObject {
    public static let shared = CanvasManager()

    @Published public var currentArtifact: CanvasArtifact? = nil
    @Published public var isPresented: Bool = false
    @Published public var history: [CanvasArtifact] = []

    // MARK: - Canvas 2.0: Floating HUD & Pinning
    @Published public var isPinned: Bool = false
    @Published public var hudOpacity: Double = 1.0
    @Published public var currentCorner: CanvasDockCorner = .belowNotch

    private init() {}

    /// Menampilkan artifact di Canvas Studio.
    public func present(artifact: CanvasArtifact) {
        self.currentArtifact = artifact
        self.isPresented = true

        // Simpan ke riwayat (maksimal 20)
        if !history.contains(where: { $0.id == artifact.id }) {
            history.insert(artifact, at: 0)
            if history.count > 20 { history.removeLast() }
        }

        // Buka floating companion window
        CanvasWindowController.shared.show(artifact: artifact)
        SoundEngine.shared.play("tick")

        // Perbarui AppState agar Notch menampilkan tombol Canvas
        AppState.shared.activePlaybookProgress = "Canvas: \(artifact.title)"
    }

    /// Menutup Canvas Studio.
    public func dismiss() {
        self.isPresented = false
        CanvasWindowController.shared.close()
    }

    /// Toggle pin to desktop (Floating HUD always on top).
    public func togglePin() {
        isPinned.toggle()
        CanvasWindowController.shared.applyPinState(isPinned: isPinned, opacity: isPinned ? hudOpacity : 1.0)
        SoundEngine.shared.play("tick")
    }

    /// Mengatur transparansi Canvas saat dalam mode HUD.
    public func setOpacity(_ opacity: Double) {
        hudOpacity = max(0.5, min(1.0, opacity))
        if isPinned {
            CanvasWindowController.shared.applyPinState(isPinned: true, opacity: hudOpacity)
        }
    }

    /// Memindahkan posisi Canvas ke sudut monitor yang dipilih.
    public func setDockCorner(_ corner: CanvasDockCorner) {
        currentCorner = corner
        CanvasWindowController.shared.dockTo(corner: corner)
        SoundEngine.shared.play("tick")
    }

    /// Menyalin isi konten artifact ke clipboard macOS.
    public func copyToClipboard() {
        guard let content = currentArtifact?.content else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        SoundEngine.shared.play("tick")
    }

    /// Mengekspor artifact langsung ke Microsoft Word.
    public func exportToWord() {
        guard let artifact = currentArtifact else { return }
        Task {
            do {
                _ = try AppAutomation.writeOfficeText(text: artifact.content, app: "Microsoft Word", mode: "append")
                SoundEngine.shared.play("finish")
            } catch {
                // Fallback ke TextEdit jika Word tidak ada
                _ = try? AppAutomation.writeOfficeText(text: artifact.content, app: "TextEdit", mode: "append")
            }
        }
    }

    /// Mengekspor artifact data tabel langsung ke Microsoft Excel.
    public func exportToExcel() {
        guard let artifact = currentArtifact else { return }
        Task {
            do {
                _ = try AppAutomation.writeOfficeText(text: artifact.content, app: "Microsoft Excel", mode: "insert")
                SoundEngine.shared.play("finish")
            } catch {
                // Clipboard fallback
                copyToClipboard()
            }
        }
    }
}
