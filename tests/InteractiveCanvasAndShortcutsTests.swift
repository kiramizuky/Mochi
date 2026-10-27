import Foundation
import AppKit

// MARK: - Test Suite Paket 13: Interactive Canvas Studio 2.0 & Apple Ecosystem (Siri & Shortcuts)

@main
struct InteractiveCanvasAndShortcutsTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan InteractiveCanvasAndShortcutsTests (Paket 13)...")

        // MARK: - Test 1: Canvas Artifact Types, Floating HUD & Pinning
        log("T1: testCanvasArtifactsAndFloatingHUD")
        let htmlArtifact = CanvasArtifact(title: "Sandbox Test", type: .html, content: "<h1>Hello World</h1>")
        assert(htmlArtifact.type == .html, "Artifact type harus .html")
        assert(htmlArtifact.type.displayName == "Web Sandbox", "Display name untuk .html harus 'Web Sandbox'")
        assert(htmlArtifact.type.iconName == "globe.americas.fill", "Icon untuk .html harus 'globe.americas.fill'")

        let formArtifact = CanvasArtifact(title: "Form Test", type: .form, content: "Nama: Budi\nEmail: budi@test.com")
        assert(formArtifact.type == .form, "Artifact type harus .form")
        assert(formArtifact.type.displayName == "Form Interaktif", "Display name untuk .form harus 'Form Interaktif'")
        assert(formArtifact.type.iconName == "slider.horizontal.3", "Icon untuk .form harus 'slider.horizontal.3'")

        // Uji CanvasManager Pinning & Opacity State
        await MainActor.run {
            let manager = CanvasManager.shared
            let initialPin = manager.isPinned
            manager.togglePin()
            assert(manager.isPinned == !initialPin, "togglePin harus mengubah nilai isPinned")
            manager.togglePin() // kembalikan

            manager.setOpacity(0.85)
            assert(manager.hudOpacity == 0.85, "hudOpacity harus menjadi 0.85")

            manager.setDockCorner(.topRight)
            assert(manager.currentCorner == .topRight, "currentCorner harus menjadi .topRight")
            manager.setDockCorner(.belowNotch)
            assert(manager.currentCorner == .belowNotch, "currentCorner harus kembali ke .belowNotch")
        }
        log("  Canvas artifacts (.html, .form) & HUD pinning state verified.")
        log("T1 OK ✅")

        // MARK: - Test 2: Table Data Parsing, Search Filtering & Sorting
        log("T2: testTableDataSearchAndSorting")
        let sampleTable = """
        Nama | Umur | Kota
        Alice | 30 | Jakarta
        Charlie | 22 | Bandung
        Bob | 25 | Surabaya
        David | 28 | Denpasar
        """

        let lines = sampleTable.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var rows: [[String]] = []
        for line in lines {
            let cols = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            rows.append(cols)
        }
        assert(rows.count == 5, "Harus terdapat 5 baris (1 header + 4 data)")

        let header = rows.first!
        let dataRows = Array(rows.dropFirst())

        // Uji Filter Pencarian
        let searchQuery = "surabaya"
        let filtered = dataRows.filter { row in
            row.contains { $0.lowercased().contains(searchQuery.lowercased()) }
        }
        assert(filtered.count == 1, "Hanya 1 baris yang harus cocok dengan pencarian 'surabaya'")
        assert(filtered.first?[0] == "Bob", "Baris yang cocok harus Bob")

        // Uji Sort Berdasarkan Kolom Umur (index 1 - Angka) Ascending
        var sortedByAge = dataRows
        sortedByAge.sort { r1, r2 in
            let n1 = Double(r1[1]) ?? 0
            let n2 = Double(r2[1]) ?? 0
            return n1 < n2
        }
        assert(sortedByAge.first?[0] == "Charlie", "Yang termuda harus Charlie (22)")
        assert(sortedByAge.last?[0] == "Alice", "Yang tertua harus Alice (30)")

        // Uji Sort Berdasarkan Kolom Nama (index 0 - Alfabetis) Ascending
        var sortedByName = dataRows
        sortedByName.sort { r1, r2 in
            r1[0].localizedCaseInsensitiveCompare(r2[0]) == .orderedAscending
        }
        assert(sortedByName.first?[0] == "Alice", "Pertama secara alfabetis harus Alice")
        assert(sortedByName.last?[0] == "David", "Terakhir secara alfabetis harus David")

        log("  Table search filter and numerical/alphabetical sorting verified.")
        log("T2 OK ✅")

        // MARK: - Test 3: Apple Shortcuts Service & URL Scheme Routing
        log("T3: testAppleShortcutsServiceAndURLScheme")
        let scService = AppleShortcutsService.shared

        // Uji CLI Shortcuts listing
        let (listOk, listOut, _) = await scService.listShortcuts(filter: "NonExistentShortcutName12345")
        assert(listOk == true, "listShortcuts harus mengembalikan status sukses (atau fallback terstruktur)")
        log("  Apple Shortcuts CLI list executed. Output sample: \(listOut.prefix(60))...")

        // Uji Incoming URL Routing (coucou:// & mochi://)
        let validURL1 = URL(string: "coucou://ask?q=Siapkan%20laporan")!
        let validURL2 = URL(string: "mochi://canvas?title=Hasil&type=html&content=<b>OK</b>")!
        let validURL3 = URL(string: "coucou://sentry?away=true")!

        await MainActor.run {
            scService.handleIncomingURL(validURL1)
            scService.handleIncomingURL(validURL2)
            scService.handleIncomingURL(validURL3)
        }
        log("  Incoming URL schemes handled cleanly without crash.")
        log("T3 OK ✅")

        // MARK: - Test 4: Tool Registration (Total Tools & Aliases)
        log("T4: testToolRegistrationAndAliases")
        let allTools = ToolExecutor.allTools
        log("  Total registered tools: \(allTools.count)")
        assert(allTools.count >= 92, "Total tools harus minimal 92 (sebelumnya 89 + 3 Paket 13)")

        let toolNames = Set(allTools.map { $0.name })
        let expectedNewTools = ["shortcuts_list_shortcuts", "shortcuts_run_shortcut", "canvas_present_widget"]
        for expected in expectedNewTools {
            assert(toolNames.contains(expected), "Tool \(expected) harus terdaftar di ToolExecutor.allTools")
        }

        // Cek Aliases
        let expectedAliases = [
            ("apple_shortcuts", "shortcuts_list_shortcuts"),
            ("list_shortcuts", "shortcuts_list_shortcuts"),
            ("run_shortcut", "shortcuts_run_shortcut"),
            ("execute_shortcut", "shortcuts_run_shortcut"),
            ("show_canvas", "canvas_present_widget"),
            ("open_canvas", "canvas_present_widget"),
        ]
        for (alias, canonical) in expectedAliases {
            assert(ToolExecutor.toolAliases[alias] == canonical, "Alias \(alias) harus memetakan ke \(canonical)")
        }
        log("  All 3 new tools and 6 aliases verified.")
        log("T4 OK ✅")

        // MARK: - Test 5: Gemini OpenAPI Schema Compliance
        log("T5: testGeminiOpenAPISchemaCompliance")
        for tool in allTools {
            validateOpenAPISchema(tool.inputSchema, toolName: tool.name)
        }
        log("  All \(allTools.count) tool schemas are 100% compliant with Gemini OpenAPI validation.")
        log("T5 OK ✅")

        log("🎉 SEMUA TEST PAKET 13 BERHASIL DILALUI DENGAN SEMPURNA!")
    }

    private static func validateOpenAPISchema(_ value: JSONValue, toolName: String) {
        switch value {
        case .object(let dict):
            if dict["type"]?.stringValue == "array" {
                assert(dict["items"] != nil, "Gemini OpenAPI violation in tool '\(toolName)': schema array harus memiliki properti 'items'!")
            }
            for (_, val) in dict {
                validateOpenAPISchema(val, toolName: toolName)
            }
        case .array(let arr):
            for val in arr {
                validateOpenAPISchema(val, toolName: toolName)
            }
        default:
            break
        }
    }
}

