import Foundation

// MARK: - Remote Server SSH Health Sentinel & Gateway (Integrasi Server & DevOps)

public struct RemoteServerConfig: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var keyPath: String?

    public init(id: String = UUID().uuidString,
                name: String,
                host: String,
                port: Int = 22,
                username: String = "root",
                keyPath: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.keyPath = keyPath
    }
}

public struct ServerHealthReport: Codable, Sendable {
    public let timestamp: Date
    public let serverName: String
    public let host: String
    public let isReachable: Bool
    public let uptimeString: String
    public let loadAverage: String
    public let memoryUsage: String
    public let diskUsage: String
    public let activeServicesSnippet: String
    public let summaryMarkdown: String
}

public final class SSHServerGatewayService: @unchecked Sendable {
    public static let shared = SSHServerGatewayService()

    private let defaults = UserDefaults.standard
    private let storageKey = "mochi_configured_remote_servers"
    private let lock = NSLock()

    private init() {}

    // MARK: - Server Registry Management

    public func listServers() -> [RemoteServerConfig] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([RemoteServerConfig].self, from: data) else {
            return []
        }
        return list
    }

    public func addOrUpdateServer(_ config: RemoteServerConfig) {
        lock.lock()
        defer { lock.unlock() }

        var list: [RemoteServerConfig] = []
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([RemoteServerConfig].self, from: data) {
            list = saved
        }

        if let idx = list.firstIndex(where: { $0.id == config.id || $0.name.lowercased() == config.name.lowercased() }) {
            list[idx] = config
        } else {
            list.append(config)
        }

        if let encoded = try? JSONEncoder().encode(list) {
            defaults.set(encoded, forKey: storageKey)
        }
    }

    public func removeServer(id: String) {
        lock.lock()
        defer { lock.unlock() }

        var list: [RemoteServerConfig] = []
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([RemoteServerConfig].self, from: data) {
            list = saved.filter { $0.id != id && $0.name.lowercased() != id.lowercased() }
            if let encoded = try? JSONEncoder().encode(list) {
                defaults.set(encoded, forKey: storageKey)
            }
        }
    }

    public func findServer(identifier: String) -> RemoteServerConfig? {
        let all = listServers()
        let q = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == q || $0.name.lowercased() == q || $0.host.lowercased() == q }
    }

    // MARK: - SSH Execution Helper

    private func runSSHCommand(server: RemoteServerConfig, remoteScript: String, timeout: TimeInterval = 10) async -> (output: String, exitCode: Int32) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

                var args = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-p", "\(server.port)"
                ]

                if let key = server.keyPath, !key.isEmpty {
                    let expandedKey = key.replacingOccurrences(of: "~", with: NSHomeDirectory())
                    if FileManager.default.fileExists(atPath: expandedKey) {
                        args.append(contentsOf: ["-i", expandedKey])
                    }
                }

                args.append("\(server.username)@\(server.host)")
                args.append(remoteScript)

                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()

                    // Watchdog timeout
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning {
                            process.terminate()
                        }
                    }

                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("Gagal mengeksekusi koneksi SSH: \(error.localizedDescription)", -1))
                }
            }
        }
    }

    // MARK: - Server Health Audit

    public func checkServerHealth(identifier: String) async -> (report: ServerHealthReport?, summaryMarkdown: String) {
        guard let server = findServer(identifier: identifier) else {
            return (nil, "Server dengan ID/Nama '\(identifier)' tidak ditemukan di konfigurasi Mochi.")
        }

        let auditScript = """
        echo '===UPTIME==='; uptime;
        echo '===MEM==='; free -m 2>/dev/null || vmstat -s 2>/dev/null | head -n 5 || echo 'Mem info not available';
        echo '===DISK==='; df -h / 2>/dev/null | tail -n 1;
        echo '===SERVICES==='; systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | head -n 6 || ps aux | head -n 6;
        """

        let (output, code) = await runSSHCommand(server: server, remoteScript: auditScript)

        guard code == 0 else {
            let msg = "Gagal terhubung ke server '\(server.name)' (\(server.host)): \(output)\nPastikan SSH key terdaftar dan port \(server.port) terbuka."
            return (nil, msg)
        }

        var uptime = "Unknown"
        var load = "Unknown"
        var mem = "Unknown"
        var disk = "Unknown"
        var services = ""

        if output.contains("===UPTIME===") {
            let parts = output.components(separatedBy: "===UPTIME===")
            if parts.count >= 2 {
                let upChunk = parts[1].components(separatedBy: "===MEM===")[0].trimmingCharacters(in: .whitespacesAndNewlines)
                uptime = upChunk
                if let loadIdx = upChunk.range(of: "load average:") {
                    load = String(upChunk[loadIdx.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        if output.contains("===MEM===") {
            let parts = output.components(separatedBy: "===MEM===")
            if parts.count >= 2 {
                mem = parts[1].components(separatedBy: "===DISK===")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if output.contains("===DISK===") {
            let parts = output.components(separatedBy: "===DISK===")
            if parts.count >= 2 {
                disk = parts[1].components(separatedBy: "===SERVICES===")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if output.contains("===SERVICES===") {
            let parts = output.components(separatedBy: "===SERVICES===")
            if parts.count >= 2 {
                services = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let md = """
        # Laporan Kesehatan Server: \(server.name)
        - **Host / IP**: `\(server.host):\(server.port)`
        - **Pengguna**: `\(server.username)`
        - **Status Koneksi**: 🟢 Online & Responding
        - **Waktu Audit**: \(Date().formatted())

        ### ⏱️ Uptime & Load
        - **Uptime**: \(uptime)
        - **Load Average**: `\(load)`

        ### 💾 Pemakaian Disk (Root /)
        ```text
        \(disk)
        ```

        ### 🧠 Memori (RAM)
        ```text
        \(mem)
        ```

        ### ⚙️ Layanan Aktif (Sample)
        ```text
        \(services)
        ```
        """

        let report = ServerHealthReport(
            timestamp: Date(),
            serverName: server.name,
            host: server.host,
            isReachable: true,
            uptimeString: uptime,
            loadAverage: load,
            memoryUsage: mem,
            diskUsage: disk,
            activeServicesSnippet: services,
            summaryMarkdown: md
        )

        // Simpan ke Canvas Artifact
        let artifact = CanvasArtifact(
            id: "server_health_\(server.id)_\(Int(Date().timeIntervalSince1970))",
            title: "Server Health: \(server.name)",
            type: .document,
            content: md
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        let summary = """
        Server '\(server.name)' (\(server.host)) beroperasi normal:
        • Load Average: \(load)
        • Disk Root: \(disk)
        • Laporan diagnostik lengkap telah dimuat ke jendela Canvas Mochi.
        """

        return (report, summary)
    }

    // MARK: - Execute Safe Remote Command

    public func runRemoteCommand(identifier: String, command: String) async -> (output: String, isError: Bool) {
        guard let server = findServer(identifier: identifier) else {
            return ("Server '\(identifier)' tidak ditemukan.", true)
        }

        let (output, code) = await runSSHCommand(server: server, remoteScript: command)
        return (output, code != 0)
    }

    // MARK: - Tail Remote Log

    public func tailLog(identifier: String, logPathOrService: String, lines: Int = 50) async -> String {
        guard let server = findServer(identifier: identifier) else {
            return "Server '\(identifier)' tidak ditemukan."
        }

        let cmd: String
        if logPathOrService.hasPrefix("/") {
            cmd = "tail -n \(lines) \(logPathOrService)"
        } else {
            cmd = "journalctl -u \(logPathOrService) -n \(lines) --no-pager 2>/dev/null || tail -n \(lines) /var/log/\(logPathOrService).log"
        }

        let (output, code) = await runSSHCommand(server: server, remoteScript: cmd)
        if code != 0 {
            return "Gagal membaca log '\(logPathOrService)' pada server \(server.name): \(output)"
        }
        return "Log terakhir (\(lines) baris) dari '\(logPathOrService)' di server \(server.name):\n\n```log\n\(output)\n```"
    }
}

