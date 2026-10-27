import Foundation

// MARK: - Kubernetes Cluster Sentinel (DevOps & Cloud Command Center)

public struct K8sPodInfo: Codable, Sendable, Identifiable {
    public var id: String { "\(namespace)/\(name)" }
    public var namespace: String
    public var name: String
    public var ready: String
    public var status: String
    public var restarts: Int
    public var age: String
    public var isHealthy: Bool {
        status.lowercased() == "running" || status.lowercased() == "completed"
    }
}

public final class KubernetesIntegrationService: @unchecked Sendable {
    public static let shared = KubernetesIntegrationService()

    private init() {}

    // MARK: - Binary Resolver

    public func findKubectlBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/kubectl",
            "/usr/local/bin/kubectl",
            "/usr/bin/kubectl",
            NSHomeDirectory() + "/.krew/bin/kubectl",
            NSHomeDirectory() + "/bin/kubectl"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    public func isKubectlAvailable() async -> Bool {
        guard findKubectlBinary() != nil else { return false }
        let (out, code) = await runKubectlCommand(arguments: ["version", "--client"])
        return code == 0 && !out.isEmpty
    }

    // MARK: - Process Runner Helper

    public func runKubectlCommand(arguments: [String]) async -> (output: String, exitCode: Int32) {
        guard let bin = findKubectlBinary() else {
            return ("Kubectl CLI tidak ditemukan di sistem. Pastikan kubectl terpasang melalui Homebrew ('brew install kubectl') atau tersedia di PATH.", 1)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: bin)
                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                if let kubeconfig = env["KUBECONFIG"], !kubeconfig.isEmpty {
                    env["KUBECONFIG"] = kubeconfig
                }
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
                    continuation.resume(returning: ("Gagal mengeksekusi kubectl: \(error.localizedDescription)", -1))
                }
            }
        }
    }

    // MARK: - Cluster Context

    public func getCurrentContext() async -> String {
        let (out, code) = await runKubectlCommand(arguments: ["config", "current-context"])
        if code == 0 && !out.isEmpty {
            return out
        }
        return "Unknown / Not Connected"
    }

    // MARK: - Pods Inspection

    public func getPods(namespace: String? = nil) async -> (pods: [K8sPodInfo], summaryMarkdown: String) {
        var args = ["get", "pods"]
        if let ns = namespace, !ns.isEmpty, ns.lowercased() != "all" {
            args.append(contentsOf: ["-n", ns])
        } else {
            args.append("-A")
        }

        let context = await getCurrentContext()
        let (out, code) = await runKubectlCommand(arguments: args)

        guard code == 0 else {
            let errText = "⚠️ Gagal mengambil daftar pod dari cluster (\(context)):\n```\n\(out)\n```"
            return ([], errText)
        }

        var pods: [K8sPodInfo] = []
        let lines = out.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard lines.count > 1 else {
            let emptyMsg = "Cluster aktif (\(context)), tetapi tidak ada pod yang ditemukan pada namespace yang diminta."
            return ([], emptyMsg)
        }

        let isAllNamespace = (namespace == nil || namespace?.lowercased() == "all")

        // Parse line by line
        for line in lines.dropFirst() {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if isAllNamespace && parts.count >= 6 {
                let ns = parts[0]
                let name = parts[1]
                let ready = parts[2]
                let status = parts[3]
                let restarts = Int(parts[4]) ?? 0
                let age = parts[5]
                pods.append(K8sPodInfo(namespace: ns, name: name, ready: ready, status: status, restarts: restarts, age: age))
            } else if !isAllNamespace && parts.count >= 5 {
                let ns = namespace ?? "default"
                let name = parts[0]
                let ready = parts[1]
                let status = parts[2]
                let restarts = Int(parts[3]) ?? 0
                let age = parts[4]
                pods.append(K8sPodInfo(namespace: ns, name: name, ready: ready, status: status, restarts: restarts, age: age))
            }
        }

        // Format Markdown Table
        var md = "# Status Pod Kubernetes\n"
        md += "**Cluster Context:** `\(context)` | **Total Pods:** \(pods.count)\n\n"
        md += "| Namespace | Pod Name | Ready | Status | Restarts | Age |\n"
        md += "| :--- | :--- | :---: | :---: | :---: | :--- |\n"

        for pod in pods {
            let statusIcon = pod.isHealthy ? "🟢" : "🔴"
            md += "| `\(pod.namespace)` | `\(pod.name)` | \(pod.ready) | \(statusIcon) \(pod.status) | \(pod.restarts) | \(pod.age) |\n"
        }

        // Auto-save to Canvas
        let artifact = CanvasArtifact(
            title: "Kubernetes: \(context)",
            type: .table,
            content: md
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        return (pods, md)
    }

    // MARK: - Pod Diagnostics (Describe)

    public func describePod(name: String, namespace: String? = nil) async -> (details: String, summary: String) {
        var args = ["describe", "pod", name]
        if let ns = namespace, !ns.isEmpty {
            args.append(contentsOf: ["-n", ns])
        }

        let (out, code) = await runKubectlCommand(arguments: args)
        guard code == 0 else {
            return (out, "Gagal mendeskripsikan pod '\(name)': \(out)")
        }

        // Extract Events section from describe output
        var eventsSection = ""
        if let range = out.range(of: "Events:") {
            eventsSection = String(out[range.lowerBound...])
        } else {
            eventsSection = String(out.suffix(1500))
        }

        let md = "# Kubernetes Pod: \(name)\n\n" +
                 (namespace != nil ? "**Namespace:** `\(namespace!)`\n\n" : "") +
                 "### Rangkuman Event & Status Terakhir:\n```text\n" +
                 eventsSection +
                 "\n```\n\n### Log Lengkap Describe:\n<details><summary>Klik untuk melihat detail lengkap</summary>\n\n```text\n" +
                 out +
                 "\n```\n</details>"

        let artifact = CanvasArtifact(
            title: "Pod: \(name)",
            type: .document,
            content: md
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        let summary = "Berhasil mendeskripsikan pod '\(name)'. Detail event dan status telah disimpan di Canvas."
        return (md, summary)
    }

    // MARK: - Pod Logs

    public func getPodLogs(name: String, namespace: String? = nil, tail: Int = 100) async -> String {
        var args = ["logs", name, "--tail=\(tail)"]
        if let ns = namespace, !ns.isEmpty {
            args.append(contentsOf: ["-n", ns])
        }

        let (out, code) = await runKubectlCommand(arguments: args)
        guard code == 0 else {
            return "Gagal mengambil log dari pod '\(name)': \(out)"
        }

        if out.isEmpty {
            return "Log pod '\(name)' kosong (tidak ada output dalam \(tail) baris terakhir)."
        }

        return "Log Pod '\(name)' (\(tail) baris terakhir):\n\n```text\n\(out)\n```"
    }
}

