import Foundation
import AppKit
import Combine

// MARK: - Canvas Manager
// Mengelola siklus hidup, penayangan, dan ekspor Canvas Artifacts Studio.

@MainActor
public final class CanvasManager: ObservableObject {
    public static let shared = CanvasManager()

    @Published public var currentArtifact: CanvasArtifact? = nil
    @Published public var isPresented: Bool = false
    @Published public var history: [CanvasArtifact] = []

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
