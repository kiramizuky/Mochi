import Foundation
import AppKit

// MARK: - Test Suite Lengkap: Dynamic Island Media Studio, Canvas 2.0 & LLM Tools (Paket 14 Tahap A, B, C, D)

@main
struct MediaStudioFullTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan MediaStudioFullTests (Paket 14 - Tahap A, B, C, D)...")

        // MARK: - Test 1: Canvas Artifacts (.media & .gallery)
        log("T1: testCanvasArtifactsTypes")
        assert(ArtifactType.allCases.contains(.media), "ArtifactType harus menyertakan .media")
        assert(ArtifactType.allCases.contains(.gallery), "ArtifactType harus menyertakan .gallery")
        assert(ArtifactType.media.iconName == "play.rectangle.fill", "Icon .media harus 'play.rectangle.fill'")
        assert(ArtifactType.gallery.iconName == "photo.on.rectangle.angled", "Icon .gallery harus 'photo.on.rectangle.angled'")
        assert(ArtifactType.media.displayName == "Media Studio", "DisplayName .media harus 'Media Studio'")
        assert(ArtifactType.gallery.displayName == "Galeri Media", "DisplayName .gallery harus 'Galeri Media'")

        let sampleArtifact = CanvasArtifact(
            title: "Galeri Foto Uji",
            type: .gallery,
            content: "[{\"filePath\":\"/tmp/test.png\",\"title\":\"test.png\"}]"
        )
        assert(sampleArtifact.type == .gallery, "Tipe artefak harus .gallery")
        log("  Canvas artifacts .media & .gallery verified.")
        log("T1 OK ✅")

        // MARK: - Test 2: MediaManagerService Canvas & Inspection Integration
        log("T2: testMediaManagerServiceInspectionAndGallery")
        let manager = MediaManagerService.shared

        await MainActor.run {
            // Buat file dummy gambar sementara
            let tempDir = NSTemporaryDirectory()
            let testImgPath = (tempDir as NSString).appendingPathComponent("test_screenshot_2026.png")
            let dummyData = "dummy image data".data(using: .utf8)!
            FileManager.default.createFile(atPath: testImgPath, contents: dummyData)

            // Test inspect & present
            let res = manager.inspectAndPresentMedia(path: testImgPath, presentInNotch: true, presentInCanvas: true)
            assert(res.success == true, "Inspect gambar yang ada harus sukses")
            assert(res.item?.mediaType == .image, "Media type harus .image")
            assert(res.item?.source == .localImage, "Media source harus .localImage")
            assert(CanvasManager.shared.currentArtifact?.type == .gallery, "Canvas artifact harus .gallery")

            // Test present gallery
            let galRes = manager.presentGalleryInCanvas(paths: [testImgPath], title: "Galeri Test")
            assert(galRes.success == true, "Present gallery harus sukses")
            assert(galRes.count == 1, "Jumlah item galeri harus 1")

            // Test list recent media
            let recent = manager.listRecentMedia(category: "all", limit: 5)
            log("  Recent media scanned: \(recent.count) items")

            // Cleanup
            try? FileManager.default.removeItem(atPath: testImgPath)
        }
        log("  MediaManagerService inspection and Canvas integration verified.")
        log("T2 OK ✅")

        // MARK: - Test 3: LLM Tools Registration & Gemini OpenAPI Schema Validation
        log("T3: testLLMToolsRegistrationAndSchema")
        let allTools = ToolExecutor.tools
        let toolNames = allTools.map { $0.name }

        assert(toolNames.contains("media_player_control"), "media_player_control harus terdaftar")
        assert(toolNames.contains("media_inspect_file"), "media_inspect_file harus terdaftar")
        assert(toolNames.contains("media_present_gallery"), "media_present_gallery harus terdaftar")
        assert(toolNames.contains("media_list_recent"), "media_list_recent harus terdaftar")

        // Verifikasi skema Gemini OpenAPI (Zero Missing Array Items Guardrail)
        func validateSchema(_ val: JSONValue, path: String) {
            if case .object(let dict) = val {
                if let typeVal = dict["type"]?.stringValue, typeVal == "array" {
                    assert(dict["items"] != nil, "Array schema pada '\(path)' wajib memiliki field 'items'!")
                }
                for (k, v) in dict {
                    validateSchema(v, path: "\(path).\(k)")
                }
            }
        }

        for tool in allTools {
            validateSchema(tool.inputSchema, path: tool.name)
        }
        log("  Total tools registered: \(allTools.count). All schemas comply with Gemini OpenAPI rules.")
        log("T3 OK ✅")

        // MARK: - Test 4: Tool Aliases & Routing
        log("T4: testToolAliases")
        let aliases = ToolExecutor.toolAliases
        assert(aliases["player_control"] == "media_player_control", "player_control -> media_player_control")
        assert(aliases["play_music"] == "media_player_control", "play_music -> media_player_control")
        assert(aliases["pause_music"] == "media_player_control", "pause_music -> media_player_control")
        assert(aliases["inspect_image"] == "media_inspect_file", "inspect_image -> media_inspect_file")
        assert(aliases["open_gallery"] == "media_present_gallery", "open_gallery -> media_present_gallery")
        assert(aliases["recent_screenshots"] == "media_list_recent", "recent_screenshots -> media_list_recent")
        log("  Tool aliases correctly mapped to media tools.")
        log("T4 OK ✅")

        // MARK: - Test 5: Apple Shortcuts URL Scheme (coucou://media)
        log("T5: testShortcutsURLScheme")
        await MainActor.run {
            let shortcuts = AppleShortcutsService.shared

            let urlToggle = URL(string: "coucou://media?action=toggle")!
            let resToggle = shortcuts.handleIncomingURL(urlToggle)
            assert(resToggle.contains("toggle"), "URL scheme toggle harus mengembalikan konfirmasi")

            let urlPlay = URL(string: "coucou://player?action=play")!
            let resPlay = shortcuts.handleIncomingURL(urlPlay)
            assert(resPlay.contains("play"), "URL scheme play harus mengembalikan konfirmasi")
        }
        log("  Apple Shortcuts URL scheme for media verified.")
        log("T5 OK ✅")

        log("🎉 SEMUA TEST PAKET 14 (TAHAP A, B, C, D) LULUS 100%!")
    }
}

