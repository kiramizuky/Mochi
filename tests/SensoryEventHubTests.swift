import Foundation
import AppKit

// MARK: - SensoryEventHubTests (Smart Clipboard Watcher & Sensory Event Hub)

@main enum SensoryEventHubTests {
    static func main() async throws {
        testClipboardClassificationError()
        testClipboardClassificationURLs()
        testClipboardClassificationJSON()
        testClipboardClassificationSQL()
        testClipboardClassificationCode()
        testClipboardClassificationPlainText()
        testSensoryEventHubPrioritiesAndDedup()
        print("SensoryEventHubTests: all cases passed")
    }
}

// MARK: - Clipboard Classification Tests

func testClipboardClassificationError() {
    let watcher = ClipboardWatcher.shared

    let errorText = """
    fatal error: Index out of range in ArraySlice.swift:42
    Current stack trace:
    0x0000000100001234
    """
    let event = watcher.classify(errorText)
    precondition(event.type == .errorTrace, "Harus diklasifikasikan sebagai errorTrace")
    precondition(event.suggestedChipTitle.contains("Error"), "Judul chip harus menyebutkan Error")
    precondition(event.suggestedActionGoal.contains("Analisis pesan error"), "Goal harus meminta analisis error")
}

func testClipboardClassificationURLs() {
    let watcher = ClipboardWatcher.shared

    // YouTube
    let ytEvent = watcher.classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    precondition(ytEvent.type == .url)
    precondition(ytEvent.suggestedChipTitle.contains("YouTube"))

    // GitHub
    let ghEvent = watcher.classify("https://github.com/Louis-CFM/coucou/pull/24")
    precondition(ghEvent.type == .url)
    precondition(ghEvent.suggestedChipTitle.contains("GitHub"))

    // Standard web
    let webEvent = watcher.classify("https://developer.apple.com/documentation/swift")
    precondition(webEvent.type == .url)
    precondition(webEvent.suggestedChipTitle.contains("Tautan Disalin"))
}

func testClipboardClassificationJSON() {
    let watcher = ClipboardWatcher.shared

    let validJson = """
    {"status": "success", "users": [{"id": 1, "name": "Mochi"}], "count": 1}
    """
    let event = watcher.classify(validJson)
    precondition(event.type == .rawJSON, "Harus diklasifikasikan sebagai rawJSON")
    precondition(event.suggestedChipTitle.contains("JSON"), "Judul chip harus menyebutkan JSON")
}

func testClipboardClassificationSQL() {
    let watcher = ClipboardWatcher.shared

    let sqlText = "SELECT id, username, email FROM auth_users WHERE active = true ORDER BY created_at DESC"
    let event = watcher.classify(sqlText)
    precondition(event.type == .sqlQuery, "Harus diklasifikasikan sebagai sqlQuery")
    precondition(event.suggestedChipTitle.contains("SQL"), "Judul chip harus menyebutkan SQL")
}

func testClipboardClassificationCode() {
    let watcher = ClipboardWatcher.shared

    let codeText = """
    public func fetchUserBalance(id: String) async throws -> Double {
        let account = try await db.find(id)
        return account.balance
    }
    """
    let event = watcher.classify(codeText)
    precondition(event.type == .codeSnippet, "Harus diklasifikasikan sebagai codeSnippet")
    precondition(event.suggestedChipTitle.contains("Kode"), "Judul chip harus menyebutkan Kode")
}

func testClipboardClassificationPlainText() {
    let watcher = ClipboardWatcher.shared

    let normalText = "Halo, selamat pagi apa kabar hari ini."
    let event = watcher.classify(normalText)
    precondition(event.type == .plainText, "Teks biasa harus diklasifikasikan sebagai plainText")
    precondition(event.suggestedChipTitle.isEmpty, "Teks biasa tidak boleh memunculkan chip")
}

// MARK: - Sensory Event Hub Tests

func testSensoryEventHubPrioritiesAndDedup() {
    let hub = SensoryEventHub.shared

    // Register trigger dengan prioritas berbeda
    hub.registerProactiveTrigger(
        id: "trig_low",
        title: "Ingatan Rutin",
        goal: "Goal rutin",
        priority: .low
    )

    hub.registerProactiveTrigger(
        id: "trig_high",
        title: "Error Compiler!",
        goal: "Perbaiki compiler",
        priority: .high
    )

    hub.registerProactiveTrigger(
        id: "trig_med",
        title: "Berkas Unduhan Baru",
        goal: "Buka berkas",
        priority: .medium
    )

    let all = hub.allActiveTriggers()
    precondition(!all.isEmpty, "Triggers tidak boleh kosong")
    precondition(all.first?.title == "Error Compiler!", "Trigger prioritas tertinggi (.high) harus berada di posisi terdepan, got \(all.first?.title ?? "")")

    // Uji deduplikasi judul yang sama
    hub.registerProactiveTrigger(
        id: "trig_high_v2",
        title: "Error Compiler!",
        goal: "Perbaiki compiler v2",
        priority: .critical
    )

    let updated = hub.allActiveTriggers()
    let errorTriggers = updated.filter { $0.title == "Error Compiler!" }
    precondition(errorTriggers.count == 1, "Judul yang sama harus dideduplikasi")
    precondition(errorTriggers.first?.priority == .critical, "Prioritas harus terupdate ke critical")

    // Cleanup
    hub.removeTrigger(id: "trig_low")
    hub.removeTrigger(id: "trig_med")
    hub.removeTrigger(id: "trig_high_v2")
}

