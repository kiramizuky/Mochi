import Foundation
import AppKit

// MARK: - Developer Environment & Git Workflow Supercharger (Paket 10)

public final class DeveloperEnvironmentService: @unchecked Sendable {
    public static let shared = DeveloperEnvironmentService()

    private init() {}

    // MARK: - Helper Process Runner

    private func runCommand(binary: String, arguments: [String], currentDirectory: String? = nil) async -> (output: String, exitCode: Int32) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments
                if let dir = currentDirectory, FileManager.default.fileExists(atPath: dir) {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }

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
                    continuation.resume(returning: ("Gagal: \(error.localizedDescription)", -1))
                }
            }
        }
    }

    // MARK: - IDE Deep Link (Goto Line)

    public func gotoFileLine(
        editor: String? = nil,
        path: String,
        line: Int = 1,
        column: Int = 1
    ) async -> (success: Bool, message: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return (false, "Berkas tidak ditemukan: \(path)")
        }

        // Tentukan editor CLI
        let choice = (editor ?? "auto").lowercased()
        var cliName = "code"

        if choice.contains("cursor") {
            cliName = "cursor"
        } else if choice.contains("windsurf") {
            cliName = "windsurf"
        } else if choice.contains("xcode") {
            cliName = "xed"
        } else if choice.contains("vscode") || choice.contains("code") {
            cliName = "code"
        } else {
            // Auto detect: periksa cursor -> code -> windsurf -> xed
            if findBinary(name: "cursor") != nil {
                cliName = "cursor"
            } else if findBinary(name: "code") != nil {
                cliName = "code"
            } else if findBinary(name: "windsurf") != nil {
                cliName = "windsurf"
            } else if findBinary(name: "xed") != nil {
                cliName = "xed"
            }
        }

        if let bin = findBinary(name: cliName) {
            let targetArg = "\(expandedPath):\(line):\(column)"
            let args: [String]
            if cliName == "xed" {
                args = ["-line", "\(line)", expandedPath]
            } else {
                args = ["-g", targetArg]
            }

            let (out, code) = await runCommand(binary: bin, arguments: args)
            if code == 0 {
                return (true, "Berhasil membuka berkas '\(URL(fileURLWithPath: path).lastPathComponent)' pada baris \(line) di \(cliName.capitalized).")
            } else {
                return (false, "Gagal melompat ke baris: \(out)")
            }
        }

        // Fallback: buka secara native via NSWorkspace
        await MainActor.run {
            NSWorkspace.shared.open(URL(fileURLWithPath: expandedPath))
        }
        return (true, "Editor CLI '\(cliName)' tidak ditemukan, berkas dibuka dengan aplikasi default macOS.")
    }

    private func findBinary(name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/" + name,
            "/usr/local/bin/" + name,
            "/usr/bin/" + name,
            NSHomeDirectory() + "/bin/" + name,
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return nil
    }

    // MARK: - Smart Conventional Git Commit

    public func smartCommit(directory: String? = nil, prefix: String? = nil) async -> (success: Bool, message: String, suggestedCommit: String) {
        guard let gitBin = findBinary(name: "git") else {
            return (false, "Git CLI tidak ditemukan.", "")
        }

        let repoDir = directory ?? FileManager.default.currentDirectoryPath

        // 1. Cek status
        let (statusOut, statusCode) = await runCommand(binary: gitBin, arguments: ["status", "--porcelain"], currentDirectory: repoDir)
        guard statusCode == 0 else {
            return (false, "Direktori '\(repoDir)' bukan repositori git aktif: \(statusOut)", "")
        }

        let changes = statusOut.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !changes.isEmpty else {
            return (true, "Repositori bersih. Tidak ada berkas yang dimodifikasi untuk di-commit.", "")
        }

        // 2. Cek diff staged atau unstaged
        var (diffOut, _) = await runCommand(binary: gitBin, arguments: ["diff", "--cached", "--stat"], currentDirectory: repoDir)
        if diffOut.isEmpty {
            let (workingDiff, _) = await runCommand(binary: gitBin, arguments: ["diff", "--stat"], currentDirectory: repoDir)
            diffOut = workingDiff
        }

        // 3. Analisis inferensi tipe commit
        var commitType = prefix ?? "feat"
        let modifiedFiles = changes.map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }

        if prefix == nil {
            let lowerFiles = modifiedFiles.map { $0.lowercased() }
            if lowerFiles.allSatisfy({ $0.contains("doc") || $0.hasSuffix(".md") }) {
                commitType = "docs"
            } else if lowerFiles.allSatisfy({ $0.contains("test") }) {
                commitType = "test"
            } else if lowerFiles.contains(where: { $0.contains("fix") || $0.contains("bug") }) {
                commitType = "fix"
            } else if lowerFiles.contains(where: { $0.contains("plan") || $0.contains("roadmap") }) {
                commitType = "docs"
            } else {
                commitType = "feat"
            }
        }

        // Tentukan ringkasan cakupan (scope)
        var scope = "core"
        if let first = modifiedFiles.first {
            let parts = first.components(separatedBy: "/")
            if parts.count > 1 {
                scope = parts[parts.count - 2].lowercased()
            } else {
                scope = URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent.lowercased()
            }
        }

        let summaryDesc = "update \(modifiedFiles.count) file(s) across \(scope)"
        let suggestedMsg = "\(commitType)(\(scope)): \(summaryDesc)"

        let details = "# Usulan Smart Conventional Commit\n\n" +
                      "**Pesan Commit yang Disarankan:**\n" +
                      "```text\n\(suggestedMsg)\n```\n\n" +
                      "### Berkas yang Berubah (\(modifiedFiles.count)):\n" +
                      modifiedFiles.map { "- `\($0)`" }.joined(separator: "\n") +
                      "\n\n### Rangkuman Diff:\n```text\n\(diffOut)\n```"

        let artifact = CanvasArtifact(
            title: "Smart Commit: \(suggestedMsg)",
            type: .document,
            content: details
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        return (true, details, suggestedMsg)
    }

    // MARK: - Pull Request Review & Diff Summary

    public func reviewPullRequest(prNumberOrBranch: String? = nil, repoPath: String? = nil) async -> (success: Bool, outputMarkdown: String, summary: String) {
        let repo = repoPath ?? FileManager.default.currentDirectoryPath

        if let ghBin = findBinary(name: "gh") {
            var args = ["pr", "view"]
            if let pr = prNumberOrBranch, !pr.isEmpty {
                args.append(pr)
            }
            args.append(contentsOf: ["--comments"])

            let (out, code) = await runCommand(binary: ghBin, arguments: args, currentDirectory: repo)
            if code == 0 && !out.isEmpty {
                let md = "# GitHub Pull Request Review\n\n" +
                         "```text\n\(out)\n```"

                let artifact = CanvasArtifact(
                    title: "PR Review: \(prNumberOrBranch ?? "Active")",
                    type: .document,
                    content: md
                )
                Task { @MainActor in
                    CanvasManager.shared.currentArtifact = artifact
                }
                return (true, md, "Berhasil memuat rincian PR via GitHub CLI. Ditampilkan di Canvas.")
            }
        }

        // Fallback: gunakan git log lokal
        guard let gitBin = findBinary(name: "git") else {
            return (false, "Git atau GitHub CLI ('gh') tidak ditemukan.", "Gagal mereview PR.")
        }

        let (logOut, _) = await runCommand(binary: gitBin, arguments: ["log", "-n", "5", "--stat", "--oneline"], currentDirectory: repo)
        let md = "# Rangkuman Git Log Terakhir (Fallback PR Review)\n\n" +
                 "```text\n\(logOut)\n```"

        let artifact = CanvasArtifact(
            title: "Git Log Review",
            type: .document,
            content: md
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = artifact
        }

        return (true, md, "Rangkuman 5 commit terakhir berhasil dimuat ke Canvas.")
    }
}

