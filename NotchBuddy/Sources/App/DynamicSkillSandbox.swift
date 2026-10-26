import Foundation

// MARK: - Dynamic Skill Sandbox (Pilar C: Metacognitive Tool Maker)

/// Lingkungan eksekusi terisolasi untuk mengompilasi dan menjalankan alat dinamis secara aman.
public final class DynamicSkillSandbox: @unchecked Sendable {
    public static let shared = DynamicSkillSandbox()
    private init() {}

    /// Validasi keamanan script terhadap hard safety floor PolicyEngine.
    public func validateSafety(scriptSource: String, language: DynamicToolLanguage) -> Result<Void, DynamicToolError> {
        let lower = scriptSource.lowercased()

        // Daftar pola destruktif yang dilarang keras
        let dangerousPatterns = [
            "sudo ", "rm -rf /", "rm -rf ~", "rm -rf *",
            "diskutil erase", "dd if=", "mkfs", "> /dev/sda",
            ":(){ :|:& };:", "chmod -r 777 /", "nvram -c"
        ]

        for pattern in dangerousPatterns {
            if lower.contains(pattern) {
                return .failure(.securityViolation("Pelanggaran Keamanan: Kode terdeteksi memuat perintah berbahaya '\(pattern)' yang dilarang oleh PolicyEngine."))
            }
        }

        return .success(())
    }

    /// Eksekusi DynamicTool dalam sandbox direktori temporer dengan batasan waktu.
    func execute(
        tool: DynamicTool,
        arguments: [String: String] = [:],
        timeoutSeconds: TimeInterval = 20.0
    ) async -> ToolResult {
        // 1. Validasi keamanan kode
        let safetyCheck = validateSafety(scriptSource: tool.scriptSource, language: tool.language)
        if case .failure(let error) = safetyCheck {
            return ToolResult(output: error.localizedDescription, isError: true, exitCode: 1)
        }

        // 2. Siapkan direktori sandbox terisolasi
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-sandbox-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return ToolResult(output: "Gagal membuat lingkungan sandbox: \(error.localizedDescription)", isError: true, exitCode: 1)
        }

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // 3. Tulis script source ke dalam sandbox
        let scriptFile = tempDir.appendingPathComponent("main.\(tool.language.fileExtension)")
        do {
            try tool.scriptSource.write(to: scriptFile, atomically: true, encoding: .utf8)
        } catch {
            return ToolResult(output: "Gagal menulis script ke sandbox: \(error.localizedDescription)", isError: true, exitCode: 1)
        }

        // 4. Siapkan argument input sebagai JSON file dan environment variables
        let argsJsonFile = tempDir.appendingPathComponent("input_args.json")
        if let argsData = try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted]) {
            try? argsData.write(to: argsJsonFile)
        }

        // 5. Jalankan sesuai bahasa
        switch tool.language {
        case .bash:
            return await runProcess(
                executable: "/bin/bash",
                arguments: [scriptFile.path],
                currentDirectory: tempDir,
                environment: arguments,
                timeout: timeoutSeconds
            )

        case .python:
            let pythonBin = findPythonExecutable()
            return await runProcess(
                executable: pythonBin,
                arguments: [scriptFile.path],
                currentDirectory: tempDir,
                environment: arguments,
                timeout: timeoutSeconds
            )

        case .swift:
            // JIT Compilation: compile Swift source into executable binary
            let mcDir = tempDir.appendingPathComponent("mc")
            try? FileManager.default.createDirectory(at: mcDir, withIntermediateDirectories: true)
            let binaryFile = tempDir.appendingPathComponent("tool_bin")

            let compileResult = await runProcess(
                executable: "/usr/bin/swiftc",
                arguments: [
                    "-module-cache-path", mcDir.path,
                    scriptFile.path,
                    "-o", binaryFile.path
                ],
                currentDirectory: tempDir,
                environment: [:],
                timeout: 30.0
            )

            if compileResult.isError {
                return ToolResult(
                    output: "Kompilasi JIT Swift Gagal:\n\(compileResult.output)",
                    isError: true,
                    exitCode: compileResult.exitCode
                )
            }

            // Jalankan binary hasil kompilasi
            return await runProcess(
                executable: binaryFile.path,
                arguments: [],
                currentDirectory: tempDir,
                environment: arguments,
                timeout: timeoutSeconds
            )

        case .javascript:
            // Gunakan node jika tersedia, fallback ke osascript -l JavaScript
            let nodeBin = findNodeExecutable()
            if let nodeBin {
                return await runProcess(
                    executable: nodeBin,
                    arguments: [scriptFile.path],
                    currentDirectory: tempDir,
                    environment: arguments,
                    timeout: timeoutSeconds
                )
            } else {
                return await runProcess(
                    executable: "/usr/bin/osascript",
                    arguments: ["-l", "JavaScript", scriptFile.path],
                    currentDirectory: tempDir,
                    environment: arguments,
                    timeout: timeoutSeconds
                )
            }
        }
    }

    // MARK: - Process Execution Helper

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> ToolResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory

                var env = ProcessInfo.processInfo.environment
                for (k, v) in environment {
                    env["ARG_\(k.uppercased())"] = v
                    env[k] = v
                }
                env["COUCOU_SANDBOX"] = "1"
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ToolResult(output: "Eksekusi proses gagal: \(error.localizedDescription)", isError: true, exitCode: 1))
                    return
                }

                // Watchdog timeout timer
                let deadline = DispatchTime.now() + timeout
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                timer.schedule(deadline: deadline)
                timer.setEventHandler {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                timer.resume()

                process.waitUntilExit()
                timer.cancel()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                let combined = (outStr + (errStr.isEmpty ? "" : "\n" + errStr)).trimmingCharacters(in: .whitespacesAndNewlines)
                let isErr = process.terminationStatus != 0
                continuation.resume(returning: ToolResult(
                    output: combined.isEmpty ? (isErr ? "Proses gagal tanpa output" : "Selesai tanpa output") : combined,
                    isError: isErr,
                    exitCode: Int(process.terminationStatus)
                ))
            }
        }
    }

    private func findPythonExecutable() -> String {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return "/usr/bin/python3"
    }

    private func findNodeExecutable() -> String? {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }
}

