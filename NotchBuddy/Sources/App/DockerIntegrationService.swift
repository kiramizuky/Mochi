import Foundation

// MARK: - Docker Desktop & Container Management (Integrasi Server & DevOps)

public struct DockerContainerInfo: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var status: String
    public var ports: String
    public var isRunning: Bool
}

public final class DockerIntegrationService: @unchecked Sendable {
    public static let shared = DockerIntegrationService()

    private init() {}

    // MARK: - Binary Resolver

    private func findDockerBinary() -> String? {
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/usr/bin/docker",
            NSHomeDirectory() + "/.docker/bin/docker"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Process Runner Helper

    private func runDockerCommand(arguments: [String]) async -> (output: String, exitCode: Int32) {
        guard let bin = findDockerBinary() else {
            return ("Docker CLI tidak ditemukan di sistem. Pastikan Docker Desktop terpasang di /Applications/Docker.app atau /opt/homebrew/bin/docker.", 1)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: bin)
                process.arguments = arguments
                
                // Set common environment for Docker CLI on macOS
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("Gagal mengeksekusi Docker: \(error.localizedDescription)", -1))
                }
            }
        }
    }

    // MARK: - Check Availability

    public func isDockerAvailable() async -> Bool {
        let (output, code) = await runDockerCommand(arguments: ["version", "--format", "{{.Server.Version}}"])
        return code == 0 && !output.isEmpty
    }

    // MARK: - List Containers

    public func listContainers(all: Bool = true) async -> (containers: [DockerContainerInfo], summaryMarkdown: String) {
        var args = ["ps", "--format", "{{.ID}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}"]
        if all { args.append("-a") }

        let (output, code) = await runDockerCommand(arguments: args)
        guard code == 0 else {
            let msg = "Gagal membaca container Docker: \(output)"
            return ([], msg)
        }

        var containers: [DockerContainerInfo] = []
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 4 else { continue }
            let id = parts[0]
            let name = parts[1]
            let image = parts[2]
            let status = parts[3]
            let ports = parts.count >= 5 ? parts[4] : ""
            let isRunning = status.lowercased().hasPrefix("up")

            containers.append(DockerContainerInfo(
                id: id,
                name: name,
                image: image,
                status: status,
                ports: ports,
                isRunning: isRunning
            ))
        }

        if containers.isEmpty {
            return ([], "Tidak ada container Docker yang ditemukan.")
        }

        var tableMd = "# Daftar Container Docker (\(containers.count) Container)\n\n"
        tableMd += "| Status | Nama Container | Image | Port | Container ID |\n"
        tableMd += "| :---: | :--- | :--- | :--- | :--- |\n"
        for c in containers {
            let icon = c.isRunning ? "🟢 Up" : "🔴 Stopped"
            tableMd += "| \(icon) | `\(c.name)` | `\(c.image)` | \(c.ports.isEmpty ? "-" : "`\(c.ports)`") | `\(c.id)` |\n"
        }

        // Simpan ke Canvas Artifact
        let artifact = CanvasArtifact(
            id: "docker_ps_\(Int(Date().timeIntervalSince1970))",
            title: "Docker Containers (\(containers.count) Total)",
            type: .table,
            content: tableMd
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        let summary = "Ditemukan \(containers.count) container Docker:\n" +
            containers.map { "• \($0.isRunning ? "🟢" : "🔴") \($0.name) (\($0.image)) - \($0.status)" }.joined(separator: "\n") +
            "\n\nRingkasan lengkap telah dimuat ke jendela Canvas Mochi."

        return (containers, summary)
    }

    // MARK: - Get Container Logs

    public func getLogs(container: String, tail: Int = 100) async -> String {
        let (output, code) = await runDockerCommand(arguments: ["logs", "--tail", "\(tail)", container])
        if code != 0 {
            return "Gagal mengambil log container '\(container)': \(output)"
        }
        let lines = output.isEmpty ? "(Log kosong)" : output
        return "Log terakhir (\(tail) baris) dari container '\(container)':\n\n```log\n\(lines)\n```"
    }

    // MARK: - Restart Container

    public func restartContainer(container: String) async -> (success: Bool, message: String) {
        let (output, code) = await runDockerCommand(arguments: ["restart", container])
        if code == 0 {
            return (true, "Container '\(container)' berhasil di-restart ✓")
        } else {
            return (false, "Gagal me-restart container '\(container)': \(output)")
        }
    }
}

