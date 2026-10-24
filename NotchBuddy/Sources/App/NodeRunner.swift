import Foundation
import JavaScriptCore
import AppKit
import UserNotifications

// MARK: - Node runner (eksekusi setiap tipe node melalui ToolExecutor)

/// Eksekusi satu node dan kembalikan hasil. Semua I/O (file, jaringan, clipboard,
/// notifikasi, shell) dijalankan lewat Swift — JavaScript hanya untuk logika
/// kondisi/transformasi, tidak punya akses langsung ke sistem.
final class NodeRunner: @unchecked Sendable {
    private let engine = NodeEngine()

    /// Jalankan satu node. Setiap tipe node memvalidasi input sebelum dieksekusi.
    func run(_ type: NodeType, input: NodeInput) async -> NodeOutput {
        switch type {
        case .httpRequest:   return await runHttpRequest(input)
        case .fileSystem:    return runFileSystem(input)
        case .cronSchedule:  return runCronSchedule(input)
        case .ifElse:        return runIfElse(input)
        case .jsonTransform: return runJsonTransform(input)
        case .desktopNotification: return runDesktopNotification(input)
        case .clipboard:     return runClipboard(input)
        case .runShell:      return await runShell(input)
        case .slack, .discord, .telegram, .trello, .linear, .airtable, .supabase, .firebase,
             .shopify, .wordpress, .dropbox, .googledrive, .gmail, .outlook, .zoom,
             .asana, .jira, .monday, .clickup, .hubspot, .salesforce, .zendesk, .intercom,
             .whatsapp, .pipedrive, .mailchimp, .convertkit, .patreon, .gumroad,
             .lemonsqueezy, .quickbooks, .xero, .paypal, .square, .typeform, .jotform,
             .mailerlite, .activecampaign, .zoho, .freshdesk:
            return await runIntegrationApiNode(input)
        }
    }

    // MARK: - HTTP Request

    private func runHttpRequest(_ input: NodeInput) async -> NodeOutput {
        guard let urlString = input.values["url"]?.stringValue, !urlString.isEmpty,
              let url = URL(string: urlString) else {
            return NodeOutput(values: [:], isError: true, errorMessage: "URL diperlukan untuk http_request")
        }

        let method = input.values["method"]?.stringValue ?? "GET"
        let bodyString = input.values["body"]?.stringValue ?? ""
        let headersInput = input.values["headers"]?.objectValue ?? [:]

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyString.isEmpty ? nil : Data(bodyString.utf8)
        for (key, value) in headersInput {
            if let v = value.stringValue { request.setValue(v, forHTTPHeaderField: key) }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            var output: [String: JSONValue] = [
                "statusCode": .number(Double(httpResponse?.statusCode ?? 0)),
                "body": .string(String(data: data, encoding: .utf8) ?? ""),
            ]
            if let allHeaders = httpResponse?.allHeaderFields as? [String: String] {
                output["headers"] = .object(allHeaders.mapValues { .string($0) })
            }
            return NodeOutput(values: output, isError: false, errorMessage: nil)
        } catch {
            return NodeOutput(values: [:], isError: true, errorMessage: "HTTP request gagal: \(error.localizedDescription)")
        }
    }

    // MARK: - File System

    private func runFileSystem(_ input: NodeInput) -> NodeOutput {
        guard let operation = input.values["operation"]?.stringValue,
              let pathString = input.values["path"]?.stringValue,
              !pathString.isEmpty else {
            return NodeOutput(values: [:], isError: true, errorMessage: "operation dan path diperlukan untuk file_system")
        }

        let path = (pathString as NSString).expandingTildeInPath
        let fm = FileManager.default

        switch operation.lowercased() {
        case "read":
            guard fm.fileExists(atPath: path) else {
                return NodeOutput(values: [:], isError: true, errorMessage: "File tidak ditemukan: \(path)")
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let content = String(data: data, encoding: .utf8) else {
                return NodeOutput(values: [:], isError: true, errorMessage: "Tidak dapat membaca file: \(path)")
            }
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = attrs?[.size] as? Double ?? 0
            return NodeOutput(
                values: [
                    "content": .string(content),
                    "exists": .bool(true),
                    "size": .number(size),
                ],
                isError: false, errorMessage: nil
            )

        case "write":
            let content = input.values["content"]?.stringValue ?? ""
            let url = URL(fileURLWithPath: path)
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return NodeOutput(
                    values: ["content": .string(content), "exists": .bool(true), "size": .number(Double(content.utf8.count))],
                    isError: false, errorMessage: nil
                )
            } catch {
                return NodeOutput(values: [:], isError: true, errorMessage: "Gagal menulis file: \(error.localizedDescription)")
            }

        case "exists":
            return NodeOutput(
                values: ["exists": .bool(fm.fileExists(atPath: path))],
                isError: false, errorMessage: nil
            )

        case "delete":
            do {
                try fm.removeItem(atPath: path)
                return NodeOutput(values: ["exists": .bool(false)], isError: false, errorMessage: nil)
            } catch {
                return NodeOutput(values: [:], isError: true, errorMessage: "Gagal menghapus file: \(error.localizedDescription)")
            }

        default:
            return NodeOutput(values: [:], isError: true, errorMessage: "Operasi file_system tidak dikenal: \(operation)")
        }
    }

    // MARK: - Cron Schedule

    private func runCronSchedule(_ input: NodeInput) -> NodeOutput {
        guard let intervalInput = input.values["interval"],
              let interval = intervalInput.numberValue ?? Double(intervalInput.stringValue ?? ""),
              let unit = input.values["unit"]?.stringValue else {
            return NodeOutput(values: [:], isError: true, errorMessage: "interval dan unit diperlukan untuk cron_schedule")
        }

        let seconds: TimeInterval
        switch unit.lowercased() {
        case "seconds", "second", "s": seconds = interval
        case "minutes", "minute", "m": seconds = interval * 60
        case "hours", "hour", "h": seconds = interval * 3600
        case "days", "day", "d": seconds = interval * 86400
        default:
            return NodeOutput(values: [:], isError: true, errorMessage: "Unit tidak dikenal: \(unit)")
        }

        let nextRun = Date().addingTimeInterval(seconds)
        return NodeOutput(
            values: [
                "nextRun": .number(nextRun.timeIntervalSince1970),
                "interval": .number(seconds),
                "unit": .string(unit),
                "scheduled": .bool(true),
            ],
            isError: false, errorMessage: nil
        )
    }

    // MARK: - If / Else

    private func runIfElse(_ input: NodeInput) -> NodeOutput {
        guard let condition = input.values["condition"]?.stringValue, !condition.isEmpty else {
            return NodeOutput(values: [:], isError: true, errorMessage: "condition diperlukan untuk if_else")
        }

        let trueBranch = input.values["trueBranch"]?.objectValue ?? [:]
        let falseBranch = input.values["falseBranch"]?.objectValue ?? [:]

        // Evaluasi kondisi menggunakan JavaScript
        let jsResult = engine.evaluate(condition, variables: input.values.mapValues { $0.anyValue })
        guard let jsResult else {
            return NodeOutput(values: [:], isError: true,
                errorMessage: "Gagal mengevaluasi kondisi: \(engine.lastJSException ?? "kesalahan JavaScript tidak diketahui")")
        }
        let isTrue = jsResult.toBool()

        let branch = isTrue ? trueBranch : falseBranch
        return NodeOutput(
            values: [
                "result": .object(branch.mapValues { $0 }),
                "branchTaken": .string(isTrue ? "true" : "false"),
            ],
            isError: false, errorMessage: nil
        )
    }

    // MARK: - JSON Transform

    private func runJsonTransform(_ input: NodeInput) -> NodeOutput {
        guard let inputObj = input.values["input"]?.objectValue,
              let script = input.values["script"]?.stringValue, !script.isEmpty else {
            return NodeOutput(values: [:], isError: true, errorMessage: "input dan script diperlukan untuk json_transform")
        }

        // Sediakan input sebagai variabel JS bernama 'input'
        let jsResult = engine.evaluate(script, variables: ["input": inputObj.mapValues { $0.anyValue }])
        guard let jsResult else {
            return NodeOutput(values: [:], isError: true,
                errorMessage: "Gagal mengevaluasi transformasi: \(engine.lastJSException ?? "kesalahan JavaScript tidak diketahui")")
        }
        let output = engine.toJSONValue(jsResult)

        return NodeOutput(
            values: ["output": output],
            isError: false, errorMessage: nil
        )
    }

    // MARK: - Desktop Notification

    private func runDesktopNotification(_ input: NodeInput) -> NodeOutput {
        guard let title = input.values["title"]?.stringValue, !title.isEmpty else {
            return NodeOutput(values: [:], isError: true, errorMessage: "title diperlukan untuk desktop_notification")
        }

        let body = input.values["body"]?.stringValue ?? ""

        let center = UNUserNotificationCenter.current()
        var delivered = false

        let semaphore = DispatchSemaphore(value: 0)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = UNNotificationSound.default

                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                center.add(request) { error in
                    delivered = error == nil
                    semaphore.signal()
                }
            } else {
                semaphore.signal()
            }
        }
        semaphore.wait()

        return NodeOutput(
            values: ["delivered": .bool(delivered)],
            isError: !delivered,
            errorMessage: delivered ? nil : "Notifikasi tidak dapat dikirim (izin ditolak)"
        )
    }

    // MARK: - Clipboard

    private func runClipboard(_ input: NodeInput) -> NodeOutput {
        guard let operation = input.values["operation"]?.stringValue else {
            return NodeOutput(values: [:], isError: true, errorMessage: "operation diperlukan untuk clipboard")
        }

        let pasteboard = NSPasteboard.general

        switch operation.lowercased() {
        case "read":
            let content = pasteboard.string(forType: .string) ?? ""
            return NodeOutput(
                values: ["content": .string(content), "success": .bool(true)],
                isError: false, errorMessage: nil
            )

        case "write":
            guard let text = input.values["text"]?.stringValue else {
                return NodeOutput(values: [:], isError: true, errorMessage: "text diperlukan untuk clipboard write")
            }
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(text, forType: .string)
            return NodeOutput(
                values: ["content": .string(text), "success": .bool(true)],
                isError: false, errorMessage: nil
            )

        case "clear":
            pasteboard.clearContents()
            return NodeOutput(
                values: ["content": .string(""), "success": .bool(true)],
                isError: false, errorMessage: nil
            )

        default:
            return NodeOutput(values: [:], isError: true, errorMessage: "Operasi clipboard tidak dikenal: \(operation)")
        }
    }

    // MARK: - Run Shell

    private func runShell(_ input: NodeInput) async -> NodeOutput {
        guard let command = input.values["command"]?.stringValue, !command.isEmpty else {
            return NodeOutput(values: [:], isError: true, errorMessage: "command diperlukan untuk run_shell")
        }

        let cwd = input.values["cwd"]?.stringValue
        var resolvedCwd: String? = nil
        if let cwd, !cwd.isEmpty {
            let expanded = (cwd as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                resolvedCwd = expanded
            }
        }

        let r = await runProcess("/bin/zsh", ["-lc", command], cwd: resolvedCwd, timeout: 30)
        var output = r.output
        if output.isEmpty { output = r.exitCode == 0 ? "(no output)" : "(no output, exit \(r.exitCode))" }

        return NodeOutput(
            values: [
                "output": .string(output),
                "exitCode": .number(Double(r.exitCode)),
            ],
                isError: r.exitCode != 0,
            errorMessage: r.exitCode != 0 ? "Shell exit code \(r.exitCode)" : nil
        )
    }

    // MARK: - Integration API node
    // Panggil API eksternal untuk integrasi (Slack, n8n, Stripe, dll.)
    private func runIntegrationApiNode(_ input: NodeInput) async -> NodeOutput {
        guard let integrationId = input.values["integration_id"]?.stringValue,
              let endpoint = input.values["endpoint"]?.stringValue,
              !integrationId.isEmpty, !endpoint.isEmpty else {
            return NodeOutput(values: [:], isError: true, errorMessage: "integration_id dan endpoint diperlukan untuk node integrasi")
        }

        // Cari konfigurasi integrasi
        guard let config = AgentTask.integrationPollConfigs.first(where: { $0.id == integrationId }) else {
            return NodeOutput(values: [:], isError: true, errorMessage: "Integrasi tidak dikonfigurasi: \(integrationId)")
        }

        // Bangun URL lengkap
        let baseUrl = config.endpoint.hasPrefix("http") ? config.endpoint : "https://api.\(integrationId.replacingOccurrences(of: "integration_", with: "")).com"
        let fullUrl = endpoint.hasPrefix("http") ? endpoint : baseUrl + endpoint

        guard let url = URL(string: fullUrl) else {
            return NodeOutput(values: [:], isError: true, errorMessage: "URL tidak valid: \(fullUrl)")
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        let method = input.values["method"]?.stringValue ?? "GET"
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Tambah header auth
        if let apiKey = KeychainStore.shared.get(config.apiKeyName), !apiKey.isEmpty {
            if config.apiKeyHeader.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(apiKey, forHTTPHeaderField: config.apiKeyHeader)
            }
        }

        // Tambah body untuk POST/PUT
        if method.uppercased() == "POST" || method.uppercased() == "PUT" {
            if let bodyStr = input.values["body"]?.stringValue, !bodyStr.isEmpty {
                request.httpBody = bodyStr.data(using: .utf8)
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            guard code == 200 else {
                return NodeOutput(values: [:], isError: true, errorMessage: "API error \(code): \(String(data: data, encoding: .utf8) ?? "")")
            }
            let resultStr = String(data: data, encoding: .utf8) ?? "(no output)"
            return NodeOutput(values: ["output": .string(resultStr)], isError: false, errorMessage: nil)
        } catch {
            return NodeOutput(values: [:], isError: true, errorMessage: "Request gagal: \(error.localizedDescription)")
        }
    }

    // MARK: - Process runner

    private func runProcess(_ executable: String, _ arguments: [String],
                            cwd: String?, timeout: TimeInterval) async -> (output: String, exitCode: Int32) {
        let fm = FileManager.default
        let logURL = fm.temporaryDirectory.appendingPathComponent("jarvis-node-\(UUID().uuidString).log")
        fm.createFile(atPath: logURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: logURL.path) else {
            return ("Internal error: cannot capture output.", -1)
        }
        defer {
            try? handle.close()
            try? fm.removeItem(at: logURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        do { try process.run() } catch {
            return ("Failed to start \(executable): \(error.localizedDescription)", -1)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }

        let data = (try? Data(contentsOf: logURL)) ?? Data()
        var output = String(decoding: data, as: UTF8.self)
        if output.count > 8_000 {
            output = String(output.prefix(8_000)) + "\n… (truncated)"
        }
        return (output, exitCode)
    }
}
