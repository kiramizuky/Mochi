import Foundation

// MARK: - Long-term memory (short facts, JSON on disk, prompt injection)

/// One remembered fact about the user or their project. Secrets never go
/// here — they stay in the Keychain.
struct MemoryEntry: Codable, Sendable, Equatable {
    var id: String
    var text: String
    var updatedAt: Date
}

/// Remembers short facts across sessions (`<Application Support>/NotchBuddy/memory.json`)
/// and injects a compact digest into the system prompt. Thread-safe; tests
/// inject their own file URL.
final class MemoryService: @unchecked Sendable {
    static let shared = MemoryService()

    static let maxEntries = 200

    private let url: URL
    private let lock = NSLock()
    private var entries: [MemoryEntry]

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        let dir = self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.entries = Self.load(from: self.url)
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("NotchBuddy", isDirectory: true)
            .appendingPathComponent("memory.json")
    }

    /// Saves a fact. Text already present (case-insensitive) bumps the entry
    /// instead of growing the list. Returns `true` when the entry is new.
    @discardableResult
    func remember(_ text: String) throws -> Bool {
        let cleaned = Self.sanitize(text)
        guard !cleaned.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }

        let lowered = cleaned.lowercased()
        if let existing = entries.firstIndex(where: { $0.text.lowercased() == lowered }) {
            var entry = entries.remove(at: existing)
            entry.updatedAt = Date()
            entries.insert(entry, at: 0)
            try persistLocked()
            return false
        }

        entries.insert(MemoryEntry(id: UUID().uuidString, text: cleaned, updatedAt: Date()), at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        try persistLocked()
        return true
    }

    func forget(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.id == id }
        try persistLocked()
    }

    /// All entries, newest first.
    func all() -> [MemoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Compact digest appended to the system prompt; `""` when empty.
    func formatForSystemPrompt(maxChars: Int = 1200, limit: Int = 20) -> String {
        let snapshot = all()
        guard !snapshot.isEmpty else { return "" }

        var lines = ["Facts you remember about the user:"]
        var used = 0
        var seen = Set<String>()
        for entry in snapshot {
            guard seen.insert(entry.text.lowercased()).inserted else { continue }
            let line = "- \(entry.text)"
            if used + line.count + 1 > maxChars { break }
            lines.append(line)
            used += line.count + 1
            if lines.count - 1 >= limit { break }
        }
        guard lines.count > 1 else { return "" }
        return lines.joined(separator: "\n")
    }

    /// Newlines and repeated whitespace collapse to single spaces.
    static func sanitize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: Persistence

    private func persistLocked() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    private static func load(from url: URL) -> [MemoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MemoryEntry].self, from: data)) ?? []
    }
}
