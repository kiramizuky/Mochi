import Foundation

// MARK: - Audit log (append-only JSONL, one line per tool attempt)

struct AuditEntry: Sendable, Equatable, Codable {
    var timestamp: String
    var category: String
    var action: String
    var target: String
    var decision: String
    var reason: String?
    var exitCode: Int?
}

final class AuditLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// New instance per call: `ISO8601DateFormatter` is not Sendable and may keep mutable state.
    private static var iso8601: ISO8601DateFormatter { ISO8601DateFormatter() }

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        let dir = self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("NotchBuddy", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
    }

    func record(category: ActionCategory, action: String, target: String,
                decision: PolicyDecision, reason: String? = nil, exitCode: Int? = nil) {
        let entry = AuditEntry(
            timestamp: Self.iso8601.string(from: Date()),
            category: category.rawValue,
            action: action,
            target: String(target.prefix(500)),
            decision: decision.rawValue,
            reason: reason,
            exitCode: exitCode
        )
        guard var line = try? encoder.encode(entry),
              line.count < 200_000 else { return }
        line.append(0x0A) // \n

        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// All valid entries, oldest first. Corrupt lines are skipped.
    func entries() -> [AuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AuditEntry.self, from: lineData)
        }
    }
}
