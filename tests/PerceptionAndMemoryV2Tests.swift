import Foundation

// MARK: - PerceptionAndMemoryV2Tests (Semantic Vector RAG & File System Watcher)

@main enum PerceptionAndMemoryV2Tests {
    static func main() async throws {
        testVectorMemorySemanticRecall()
        testFileSystemWatcherClassification()
        testFileSystemWatcherFiltering()
        testFileSystemWatcherLifecycle()
        print("PerceptionAndMemoryV2Tests: all cases passed")
    }
}

// MARK: - Step 3: Semantic Vector Memory Tests

func testVectorMemorySemanticRecall() {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coucou_test_vec_\(UUID().uuidString)")
    let storeURL = tempDir.appendingPathComponent("vector_memory.json")
    let store = VectorMemoryStore(fileURL: storeURL)

    // Simpan beberapa memori dengan kategori berbeda
    store.savePreference(text: "Saya lebih menyukai kode ditulis dalam bahasa Swift dengan gaya fungsional dan tanpa force unwrapping.", category: "coding_preference")
    store.savePreference(text: "Semua pengeluaran dan invoice bulanan harus direkap ke folder Keuangan/2026.", category: "finance_rule")
    store.savePreference(text: "Kopi favorit saya adalah espresso tanpa gula di pagi hari.", category: "personal")

    // 1. Semantic search tentang kode -> harus memprioritaskan coding_preference
    let codeDigest = store.preferenceDigest(query: "bagaimana format dan gaya kode Swift saya?", maxItems: 2)
    precondition(codeDigest.contains("Swift"), "Digest harus menyertakan preferensi Swift: \(codeDigest)")
    precondition(!codeDigest.contains("espresso"), "Digest tidak boleh mengutamakan espresso untuk query kode")

    // 2. Semantic search tentang keuangan -> harus memprioritaskan finance_rule
    let financeDigest = store.preferenceDigest(query: "tagihan invoice pembayaran", maxItems: 2)
    precondition(financeDigest.contains("Keuangan"), "Digest harus memprioritaskan aturan keuangan: \(financeDigest)")

    // 3. Cleanup
    try? FileManager.default.removeItem(at: tempDir)
}

// MARK: - Step 4: File System Watcher Tests

func testFileSystemWatcherClassification() {
    let watcher = FileSystemWatcher.shared

    // Invoice
    let invoiceEvent = watcher.classifyFile(
        url: URL(fileURLWithPath: "/Users/test/Downloads/Invoice_Server_October.pdf"),
        filename: "Invoice_Server_October.pdf"
    )
    precondition(invoiceEvent.fileType == .invoice, "Harus diklasifikasikan sebagai invoice")
    precondition(invoiceEvent.suggestedActionText.contains("Faktur"), "Teks aksi harus menyebut faktur")

    // Data / Spreadsheet
    let dataEvent = watcher.classifyFile(
        url: URL(fileURLWithPath: "/Users/test/Downloads/sales_2026.xlsx"),
        filename: "sales_2026.xlsx"
    )
    precondition(dataEvent.fileType == .dataSpreadsheet, "Harus diklasifikasikan sebagai dataSpreadsheet")

    // Screenshot
    let ssEvent = watcher.classifyFile(
        url: URL(fileURLWithPath: "/Users/test/Desktop/Screen Shot 2026-10-26 at 05.00.00.png"),
        filename: "Screen Shot 2026-10-26 at 05.00.00.png"
    )
    precondition(ssEvent.fileType == .screenshot, "Harus diklasifikasikan sebagai screenshot")

    // Code
    let codeEvent = watcher.classifyFile(
        url: URL(fileURLWithPath: "/Users/test/Downloads/NeuralEngine.swift"),
        filename: "NeuralEngine.swift"
    )
    precondition(codeEvent.fileType == .code, "Harus diklasifikasikan sebagai code")

    // Archive
    let zipEvent = watcher.classifyFile(
        url: URL(fileURLWithPath: "/Users/test/Downloads/project_backup.zip"),
        filename: "project_backup.zip"
    )
    precondition(zipEvent.fileType == .archive, "Harus diklasifikasikan sebagai archive")
}

func testFileSystemWatcherFiltering() {
    let watcher = FileSystemWatcher.shared
    // Berkas sementara unduhan harus diklasifikasikan sebagai other atau diabaikan oleh scanner
    let tempCrEvent = watcher.classifyFile(
        url: URL(fileURLWithPath: "/Users/test/Downloads/big_movie.mp4.crdownload"),
        filename: "big_movie.mp4.crdownload"
    )
    precondition(tempCrEvent.fileType == .other, "File temporary harus masuk .other")
}

func testFileSystemWatcherLifecycle() {
    let watcher = FileSystemWatcher.shared
    let testTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("coucou_fswatch_test_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: testTempDir, withIntermediateDirectories: true)

    watcher.start(watchedDirectories: [testTempDir])
    watcher.stop()

    try? FileManager.default.removeItem(at: testTempDir)
}

