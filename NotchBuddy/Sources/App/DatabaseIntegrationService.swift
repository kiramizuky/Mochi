import Foundation

// MARK: - Database Safe Explorer & Query Engine (Integrasi Database & DevOps)

public enum DatabaseEngine: String, Codable, Sendable, CaseIterable {
    case sqlite = "SQLite"
    case postgres = "PostgreSQL"
    case mysql = "MySQL"
    case redis = "Redis"

    public var cliBinaryName: String {
        switch self {
        case .sqlite:   return "sqlite3"
        case .postgres: return "psql"
        case .mysql:    return "mysql"
        case .redis:    return "redis-cli"
        }
    }
}

public struct DatabaseConnectionConfig: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var engine: DatabaseEngine
    public var host: String
    public var port: Int
    public var user: String
    public var database: String
    public var filePath: String? // Khusus SQLite

    public init(
        id: String = UUID().uuidString,
        name: String,
        engine: DatabaseEngine,
        host: String = "localhost",
        port: Int = 5432,
        user: String = "postgres",
        database: String = "",
        filePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.filePath = filePath
    }
}

public final class DatabaseIntegrationService: @unchecked Sendable {
    public static let shared = DatabaseIntegrationService()

    private let storageKey = "mochi_saved_database_connections"

    private init() {}

    // MARK: - Connection Registry

    public func listConnections() -> [DatabaseConnectionConfig] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([DatabaseConnectionConfig].self, from: data) else {
            return []
        }
        return list
    }

    public func saveConnection(_ config: DatabaseConnectionConfig) {
        var current = listConnections()
        if let idx = current.firstIndex(where: { $0.id == config.id || $0.name.lowercased() == config.name.lowercased() }) {
            current[idx] = config
        } else {
            current.append(config)
        }
        if let encoded = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    public func removeConnection(id: String) {
        var current = listConnections()
        current.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    public func findConnection(identifier: String) -> DatabaseConnectionConfig? {
        let q = identifier.lowercased().trimmingCharacters(in: .whitespaces)
        return listConnections().first { $0.id.lowercased() == q || $0.name.lowercased() == q || $0.database.lowercased() == q }
    }

    // MARK: - Binary Resolver

    public func findClientBinary(for engine: DatabaseEngine) -> String? {
        let name = engine.cliBinaryName
        let candidates = [
            "/opt/homebrew/bin/" + name,
            "/usr/local/bin/" + name,
            "/usr/bin/" + name,
            NSHomeDirectory() + "/bin/" + name
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    public func isClientAvailable(engine: DatabaseEngine) -> Bool {
        return findClientBinary(for: engine) != nil
    }

    // MARK: - Safety Guardrail (Read-Only Enforcement)

    /// Memeriksa apakah query SQL aman untuk dieksekusi secara otonom (Read-Only).
    /// Mencegah DROP, DELETE, UPDATE, INSERT, ALTER, TRUNCATE, dll.
    public static func isSafeReadOnlyQuery(_ query: String) -> (isSafe: Bool, reason: String?) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            return (false, "Query tidak boleh kosong.")
        }

        // Tokenize query words
        let tokens = clean.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.uppercased() }
            .filter { !$0.isEmpty }

        let dangerousKeywords: Set<String> = [
            "DROP", "DELETE", "UPDATE", "INSERT", "ALTER", "TRUNCATE",
            "CREATE", "REPLACE", "GRANT", "REVOKE", "EXEC", "EXECUTE",
            "SHUTDOWN", "FLUSHDB", "FLUSHALL", "CONFIG", "RESTORE"
        ]

        for token in tokens {
            if dangerousKeywords.contains(token) {
                return (false, "Query ditolak oleh PolicyEngine: Terdeteksi perintah manipulasi/destruktif ('\(token)'). Hanya query SELECT atau inspeksi skema yang diizinkan dalam Safe Explorer.")
            }
        }

        // Pastikan kata awal adalah SELECT, EXPLAIN, WITH, PRAGMA, SHOW, DESC, DESCRIBE, atau KEYS/SCAN
        let allowedStartKeywords: Set<String> = [
            "SELECT", "EXPLAIN", "WITH", "PRAGMA", "SHOW", "DESC", "DESCRIBE", "KEYS", "SCAN", "INFO", "HGETALL", "GET", "LRANGE", "SMEMBERS"
        ]

        if let firstToken = tokens.first, !allowedStartKeywords.contains(firstToken) {
            return (false, "Query ditolak: Query harus diawali dengan perintah baca data (misal: SELECT, SHOW, DESCRIBE, PRAGMA, atau WITH).")
        }

        return (true, nil)
    }

    // MARK: - Process Execution Helper

    private func runProcess(binaryPath: String, arguments: [String]) async -> (output: String, exitCode: Int32) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (out, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("Gagal menjalankan klien DB: \(error.localizedDescription)", -1))
                }
            }
        }
    }

    // MARK: - Schema Inspection

    public func inspectSchema(engine: DatabaseEngine, target: String) async -> (tables: [String], summaryMarkdown: String) {
        guard let bin = findClientBinary(for: engine) else {
            let msg = "Klien DB '\(engine.cliBinaryName)' tidak terpasang di sistem. Pasang via Homebrew (misal: 'brew install libpq' atau 'brew install mysql-client')."
            return ([], msg)
        }

        var tables: [String] = []
        var detailsMarkdown = ""

        switch engine {
        case .sqlite:
            let path = (target as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                return ([], "Berkas database SQLite tidak ditemukan pada jalur: \(target)")
            }

            let (tableOut, _) = await runProcess(binaryPath: bin, arguments: [path, ".tables"])
            tables = tableOut.split(whereSeparator: { $0.isWhitespace }).map(String.init)

            let (schemaOut, _) = await runProcess(binaryPath: bin, arguments: [path, ".schema"])

            detailsMarkdown = "# Skema Database SQLite\n" +
                              "**File Path:** `\(path)` | **Jumlah Tabel:** \(tables.count)\n\n" +
                              "### Daftar Tabel:\n" +
                              tables.map { "- `\($0)`" }.joined(separator: "\n") +
                              "\n\n### Rincian DDL Skema:\n```sql\n\(schemaOut)\n```"

        case .postgres:
            let (out, code) = await runProcess(binaryPath: bin, arguments: ["-d", target, "-c", "\\dt"])
            detailsMarkdown = "# Skema Database PostgreSQL (\(target))\n\n"
            if code == 0 {
                detailsMarkdown += "```text\n\(out)\n```"
                let lines = out.components(separatedBy: .newlines)
                for line in lines where line.contains("|") && !line.contains("List of relations") {
                    let cols = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if cols.count >= 2 { tables.append(cols[1]) }
                }
            } else {
                detailsMarkdown += "⚠️ Gagal mengambil relasi:\n```\n\(out)\n```"
            }

        case .mysql:
            let (out, code) = await runProcess(binaryPath: bin, arguments: ["-e", "SHOW TABLES;", target])
            detailsMarkdown = "# Skema Database MySQL (\(target))\n\n"
            if code == 0 {
                detailsMarkdown += "```text\n\(out)\n```"
                let lines = out.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                tables = Array(lines.dropFirst())
            } else {
                detailsMarkdown += "⚠️ Gagal membaca tabel MySQL:\n```\n\(out)\n```"
            }

        case .redis:
            let (out, _) = await runProcess(binaryPath: bin, arguments: ["INFO", "keyspace"])
            detailsMarkdown = "# Status Keyspace Redis\n\n```text\n\(out)\n```"
        }

        // Auto-save to Canvas
        let artifact = CanvasArtifact(
            title: "Skema DB: \(target)",
            type: .table,
            content: detailsMarkdown
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        return (tables, detailsMarkdown)
    }

    // MARK: - Safe Query Execution

    public func executeSafeQuery(engine: DatabaseEngine, target: String, query: String) async -> (isError: Bool, output: String) {
        // 1. Guardrail validation
        let (isSafe, reason) = Self.isSafeReadOnlyQuery(query)
        guard isSafe else {
            return (true, reason ?? "Query ditolak oleh kebijakan keamanan.")
        }

        guard let bin = findClientBinary(for: engine) else {
            return (true, "Klien CLI '\(engine.cliBinaryName)' tidak ditemukan di sistem.")
        }

        var processArgs: [String] = []

        switch engine {
        case .sqlite:
            let path = (target as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                return (true, "Berkas SQLite tidak ditemukan: \(target)")
            }
            processArgs = ["-header", "-column", path, query]

        case .postgres:
            processArgs = ["-d", target, "-c", query]

        case .mysql:
            processArgs = ["-t", "-e", query, target]

        case .redis:
            let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            processArgs = words
        }

        let (out, code) = await runProcess(binaryPath: bin, arguments: processArgs)
        if code != 0 {
            return (true, "Eksekusi query gagal (exit code \(code)):\n```text\n\(out)\n```")
        }

        let tableContent = "# Hasil Query Database (\(engine.rawValue))\n" +
                           "**Target:** `\(target)`\n\n" +
                           "**Query:**\n```sql\n\(query)\n```\n\n" +
                           "### Data Output:\n```text\n\(out)\n```"

        let artifact = CanvasArtifact(
            title: "Query: \(target)",
            type: .table,
            content: tableContent
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        return (false, "Query berhasil dieksekusi. Hasil data telah ditampilkan di Canvas:\n\n```text\n\(out.prefix(1500))\n```")
    }
}

