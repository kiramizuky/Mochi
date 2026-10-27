import Foundation
import AppKit
import Darwin

// MARK: - Telegram Encrypted Gateway (Pilar D: Mobile On-The-Go)

/// Gateway komunikasi terenkripsi yang memungkinkan kontrol otonom macOS dari smartphone via Telegram Bot API.
public final class TelegramGatewayService: @unchecked Sendable {
    public static let shared = TelegramGatewayService()

    private let lock = NSLock()
    private var pollingTask: Task<Void, Never>?
    private var lastUpdateId: Int = 0

    // State Pairing Handshake
    private var pendingPairingPin: String? = nil
    private var pendingPairingExpiration: Date? = nil

    private init() {}

    // MARK: - Configuration Properties

    public var botToken: String? {
        if let token = KeychainStore.shared.get("telegram-bot-token"), !token.isEmpty {
            return token
        }
        return UserDefaults.standard.string(forKey: "telegramBotToken")
    }

    public var allowedChatId: String? {
        get { UserDefaults.standard.string(forKey: "telegram-allowed-chat-id") }
        set { UserDefaults.standard.set(newValue, forKey: "telegram-allowed-chat-id") }
    }

    public var isRunning: Bool {
        lock.withLock { pollingTask != nil }
    }

    public func setBotToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.shared.remove("telegram-bot-token")
            UserDefaults.standard.removeObject(forKey: "telegramBotToken")
            stop()
        } else {
            KeychainStore.shared.set("telegram-bot-token", value: trimmed)
            UserDefaults.standard.set(trimmed, forKey: "telegramBotToken")
            if isRunning {
                stop()
                start()
            }
        }
    }

    public func unlinkPairing() {
        allowedChatId = nil
        cancelPendingPairing()
        appendAppLog("nb.log", "TelegramGateway: Pairing direset oleh pengguna.")
    }

    /// Membatalkan proses pairing yang sedang berlangsung dan menutup kartu di Notch
    public func cancelPendingPairing() {
        lock.withLock {
            pendingPairingPin = nil
            pendingPairingExpiration = nil
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                AppState.shared.telegramPairingPIN = nil
                AppState.shared.telegramPairingChatName = nil
                AppState.shared.telegramPairingExpiration = nil
                AppState.shared.stateOverride = nil
                if AppState.shared.view == .telegramPairing {
                    AppState.shared.view = .overview
                    AppState.shared.mode = .compact
                }
            }
        } else {
            Task { @MainActor in
                AppState.shared.telegramPairingPIN = nil
                AppState.shared.telegramPairingChatName = nil
                AppState.shared.telegramPairingExpiration = nil
                AppState.shared.stateOverride = nil
                if AppState.shared.view == .telegramPairing {
                    AppState.shared.view = .overview
                    AppState.shared.mode = .compact
                }
            }
        }
    }

    // MARK: - Lifecycle Management

    public func start() {
        lock.withLock {
            guard pollingTask == nil else { return }
            guard let token = botToken, !token.isEmpty else {
                appendAppLog("nb.log", "TelegramGateway: Bot token belum dikonfigurasi.")
                return
            }

            appendAppLog("nb.log", "TelegramGateway: Memulai long polling gateway...")
            pollingTask = Task { [weak self] in
                await self?.runPollingLoop(token: token)
            }
        }
    }

    public func stop() {
        lock.withLock {
            pollingTask?.cancel()
            pollingTask = nil
            appendAppLog("nb.log", "TelegramGateway: Dihentikan.")
        }
    }

    public func restart() {
        stop()
        start()
    }

    // MARK: - Long Polling Engine

    private func runPollingLoop(token: String) async {
        while !Task.isCancelled {
            do {
                let urlString = "https://api.telegram.org/bot\(token)/getUpdates?offset=\(lastUpdateId + 1)&timeout=20"
                guard let url = URL(string: urlString) else { break }

                var request = URLRequest(url: url)
                request.timeoutInterval = 30.0

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ok = json["ok"] as? Bool, ok,
                      let updates = json["result"] as? [[String: Any]] else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                for update in updates {
                    if let updateId = update["update_id"] as? Int {
                        self.lastUpdateId = max(self.lastUpdateId, updateId)
                    }
                    if let message = update["message"] as? [String: Any] {
                        await processIncomingMessage(message, token: token)
                    }
                }
            } catch {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: - Incoming Message Handler & Security Verification

    private func processIncomingMessage(_ message: [String: Any], token: String) async {
        guard let chat = message["chat"] as? [String: Any],
              let chatId = chat["id"] else { return }

        let chatIdStr = String(describing: chatId)
        let text = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let senderName = (message["from"] as? [String: Any])?["first_name"] as? String ?? "User"

        // 1. Verifikasi Pairing Keamanan
        let currentAllowed = self.allowedChatId
        if currentAllowed == nil || currentAllowed != chatIdStr {
            await handleUnpairedSender(chatId: chatIdStr, text: text, senderName: senderName, token: token)
            return
        }

        // 2. Sender telah terverifikasi — proses perintah remote
        await handleVerifiedCommand(chatId: chatIdStr, text: text, token: token)
    }

    // MARK: - Pairing Handshake Protocol

    private func handleUnpairedSender(chatId: String, text: String, senderName: String, token: String) async {
        // Periksa apakah pesan adalah PIN pairing
        let isMatchingPin = lock.withLock { () -> Bool in
            guard let activePin = pendingPairingPin,
                  let exp = pendingPairingExpiration,
                  Date() < exp else { return false }
            return text == activePin
        }

        if isMatchingPin {
            // Pairing Sukses!
            self.allowedChatId = chatId
            lock.withLock {
                pendingPairingPin = nil
                pendingPairingExpiration = nil
            }

            await MainActor.run {
                AppState.shared.telegramPairingPIN = nil
                AppState.shared.telegramPairingChatName = nil
                AppState.shared.telegramPairingExpiration = nil
                AppState.shared.activePlaybookProgress = "✅ Telegram HP Terhubung (\(senderName))"
                AppState.shared.stateOverride = nil
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
                SoundEngine.shared.play("finish")

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if AppState.shared.view == .telegramPairing {
                        AppState.shared.view = .overview
                        AppState.shared.mode = .compact
                    }
                }
            }

            appendAppLog("nb.log", "TelegramGateway: Pairing handshake berhasil untuk chat ID \(chatId)")

            await sendMessage(
                chatId: chatId,
                text: "🎉 *Pairing Berhasil!*\nSmartphone Anda kini resmi terhubung ke MacBook ini.\n\nKetik */help* untuk melihat daftar perintah remote.",
                token: token
            )
            return
        }

        // Generate PIN 6-digit baru jika belum ada
        let pin = lock.withLock { () -> String in
            if let activePin = pendingPairingPin,
               let exp = pendingPairingExpiration,
               Date() < exp {
                return activePin
            }
            let newPin = String(format: "%06d", Int.random(in: 100_000...999_999))
            pendingPairingPin = newPin
            pendingPairingExpiration = Date().addingTimeInterval(300) // Berlaku 5 menit
            return newPin
        }

        // Tampilkan PIN di Notch MacBook pengguna secara visual
        await MainActor.run {
            AppState.shared.telegramPairingPIN = pin
            AppState.shared.telegramPairingChatName = senderName
            AppState.shared.telegramPairingExpiration = Date().addingTimeInterval(300)
            AppState.shared.activePlaybookProgress = "🔑 Telegram PIN: \(pin)"
            AppState.shared.stateOverride = .question

            // Buka Notch Island secara visual ke kartu Telegram Pairing
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.telegramPairing)
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
            SoundEngine.shared.play("think")
        }

        appendAppLog("nb.log", "TelegramGateway: Pairing request dari chat ID \(chatId), PIN ditampilkan di Notch")

        let prompt = "🔒 *Otentikasi Diperlukan*\n\nMacBook Anda menampilkan kode pairing 6-digit di Notch.\nSilakan masukkan kode tersebut di chat ini untuk menghubungkan ponsel Anda."
        await sendMessage(chatId: chatId, text: prompt, token: token)
    }

    // MARK: - Remote Commands Execution

    private func handleVerifiedCommand(chatId: String, text: String, token: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()

        if lower == "/start" || lower == "/help" {
            let help = """
            🤖 *Coucou Mac Remote Assistant*

            Perintah yang tersedia:
            • `/status` - Cek status baterai, memori & Mochi di Mac
            • `/screenshot` (atau `/screenshoot`, `/ss`) - Tangkap layar Mac dan kirim foto
            • `/camera` (atau `/photo`, `/webcam`) - Tangkap foto webcam FaceTime MacBook
            • `/canvas` - Lihat teks artefak Canvas Studio yang aktif
            • `/cancel` - Batalkan tugas otonom yang sedang berjalan
            • Atau *kirim instruksi langsung* untuk dieksekusi oleh Mac!
            """
            await sendMessage(chatId: chatId, text: help, token: token)
            return
        }

        if lower == "/status" {
            let status = await collectMacStatus()
            await sendMessage(chatId: chatId, text: status, token: token)
            return
        }

        if lower == "/screenshot" || lower == "/screenshoot" || lower == "/ss" || lower == "/capture" || lower == "/screen" {
            await sendMessage(chatId: chatId, text: "📸 Mengambil tangkapan layar Mac...", token: token)
            await captureAndSendScreenshot(chatId: chatId, token: token)
            return
        }

        if lower == "/camera" || lower == "/photo" || lower == "/foto" || lower == "/webcam" {
            await sendMessage(chatId: chatId, text: "📷 Mengambil foto dari kamera webcam MacBook...", token: token)
            await captureAndSendWebcamPhoto(chatId: chatId, token: token)
            return
        }

        if lower == "/canvas" {
            let artifactInfo = await MainActor.run { () -> String in
                guard let art = CanvasManager.shared.currentArtifact else {
                    return "Tidak ada artefak aktif di Canvas Studio saat ini."
                }
                let preview = art.content.count > 1000 ? String(art.content.prefix(1000)) + "\n… (terpotong)" : art.content
                return "📄 *Canvas Studio: \(art.title)* (\(art.type.displayName))\n\n\(preview)"
            }
            await sendMessage(chatId: chatId, text: artifactInfo, token: token)
            return
        }

        if lower == "/cancel" {
            AutonomousAgent.shared.cancel()
            await MainActor.run {
                AppState.shared.activePlaybookProgress = nil
            }
            await sendMessage(chatId: chatId, text: "⏹️ Tugas otonom di Mac telah dibatalkan.", token: token)
            return
        }

        // Teks umum dianggap sebagai instruksi otonom ke MacBook
        let goal = text.hasPrefix("/run ") ? String(text.dropFirst(5)) : text
        await sendMessage(chatId: chatId, text: "⏳ *Menjalankan di Mac:* \"\(goal)\"...", token: token)

        await MainActor.run {
            AppState.shared.activePlaybookProgress = "📱 Telegram: \(goal.prefix(25))..."
        }

        let taskId = await AutonomousAgent.shared.submit(goal: goal, source: "telegram")
        if taskId.isEmpty {
            await sendMessage(chatId: chatId, text: "⚠️ Mac sedang sibuk menjalankan tugas lain atau mode otonom nonaktif.", token: token)
            return
        }

        // Tunggu hingga tugas selesai dan kirim hasilnya kembali ke Telegram
        var waited = 0
        while AutonomousAgent.shared.isRunning && waited < 60 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }

        let rawTask = await MainActor.run { () -> (goal: String, isSuccess: Bool, note: String) in
            if let t = AppState.shared.autonomousTasks.first(where: { $0.id == taskId }) {
                let note = t.note ?? (t.status == .completed ? "Selesai tanpa catatan." : "Gagal.")
                return (t.goal, t.status == .completed, note)
            }
            return (goal, true, "Tugas telah diproses oleh Mac.")
        }

        let formattedResult = TelegramFormatter.formatTaskSummary(
            goal: rawTask.goal,
            isSuccess: rawTask.isSuccess,
            rawOutput: rawTask.note
        )

        await sendMessage(chatId: chatId, text: formattedResult, token: token, asMarkdownV2: false)
    }

    // MARK: - Mac System Diagnostics (Telegram Styled & Compact)

    private func collectMacStatus() async -> String {
        let ram = SystemMetrics.getRAM()
        let cpu = SystemMetrics.getCPU()
        let disk = SystemMetrics.getDisk()
        let battery = getBatteryPercentage()
        let isAutoEnabled = UserDefaults.standard.object(forKey: "autonomousEnabled") as? Bool ?? true

        let (mode, taskName) = await MainActor.run {
            let m = AppState.shared.mode.rawValue
            let running = AppState.shared.autonomousTasks.first(where: { $0.status == .running })?.goal
            return (m, running)
        }

        let taskInfo = taskName != nil ? "`\(taskName!)`" : "Idle"

        let text = """
        💻 *Mochi MacBook Status*

        🧠 *RAM:* `\(String(format: "%.1f", ram.usedGB)) / \(String(format: "%.1f", ram.totalGB)) GB` [\(SystemMetrics.makeBar(percent: ram.percent))] \(String(format: "%.0f", ram.percent))%
        ⚡ *CPU:* `\(String(format: "%.0f", cpu))%` [\(SystemMetrics.makeBar(percent: cpu))]
        💾 *Disk:* `\(String(format: "%.1f", disk.freeGB)) GB Bebas` (\(String(format: "%.0f", disk.percentUsed))% terpakai)
        🔋 *Baterai:* `\(battery)`

        🏝️ *Notch:* `\(mode)` • *Tugas:* \(taskInfo)
        🤖 *Mode Otonom:* `\(isAutoEnabled ? "Aktif ✓" : "Nonaktif")`
        """

        return text
    }

    private func getBatteryPercentage() -> String {
        // Baca status baterai via pmset
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8), output.contains("%") {
            let parts = output.components(separatedBy: "\t")
            if parts.count > 1 {
                return parts[1].components(separatedBy: ";")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "Tersambung Listrik / Mac Desktop"
    }

    // MARK: - Screenshot & Webcam Capture & Dispatch

    private func captureAndSendScreenshot(chatId: String, token: String) async {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-tg-ss-\(Int(Date().timeIntervalSince1970)).png")
        try? FileManager.default.removeItem(at: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let captured = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-t", "png", tempFile.path]
                do {
                    try p.run()
                    p.waitUntilExit()
                    let exists = FileManager.default.fileExists(atPath: tempFile.path)
                    continuation.resume(returning: p.terminationStatus == 0 && exists)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }

        guard captured, let imageData = try? Data(contentsOf: tempFile), !imageData.isEmpty else {
            await sendMessage(chatId: chatId, text: "⚠️ Gagal mengambil tangkapan layar (Izin Screen Recording mungkin diperlukan di Pengaturan Sistem > Privasi & Keamanan > Perekaman Layar).", token: token)
            return
        }

        let sent = await sendPhoto(imageData: imageData, caption: "🖥️ Tangkapan layar Mac saat ini", chatId: chatId, filename: "screenshot.png")
        if !sent {
            await sendMessage(chatId: chatId, text: "⚠️ Gagal mengunggah foto tangkapan layar ke Telegram.", token: token)
        }
    }

    private func captureAndSendWebcamPhoto(chatId: String, token: String) async {
        do {
            let res = try await WebcamCaptureService.shared.capturePhoto()
            let facesInfo = res.detectedFacesCount > 0 ? ", \(res.detectedFacesCount) wajah terdeteksi" : ""
            let caption = "📷 Foto Kamera Webcam (\(res.width)x\(res.height) px\(facesInfo))"
            let sent = await sendPhoto(imageData: res.data, caption: caption, chatId: chatId, filename: "webcam.jpg")
            if !sent {
                await sendMessage(chatId: chatId, text: "⚠️ Gagal mengirim foto webcam ke Telegram.", token: token)
            }
        } catch {
            await sendMessage(chatId: chatId, text: "⚠️ Gagal mengambil foto webcam: \(error.localizedDescription)", token: token)
        }
    }

    // MARK: - Outbound Message Helper

    public func sendMessage(chatId: String, text: String, token: String? = nil, asMarkdownV2: Bool = true) async {
        guard let activeToken = token ?? botToken else { return }
        guard let url = URL(string: "https://api.telegram.org/bot\(activeToken)/sendMessage") else { return }

        // Jika asMarkdownV2 aktif, konversi teks ke format MarkdownV2 yang aman
        let formattedText = asMarkdownV2 ? TelegramFormatter.toMarkdownV2(text) : text

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": formattedText,
            "parse_mode": "MarkdownV2"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return
            }
        } catch {}

        // Fallback otomatis: jika MarkdownV2 ditolak, kirim sebagai teks murni tanpa parse_mode
        var fallbackRequest = URLRequest(url: url)
        fallbackRequest.httpMethod = "POST"
        fallbackRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let fallbackPayload: [String: Any] = [
            "chat_id": chatId,
            "text": text
        ]
        fallbackRequest.httpBody = try? JSONSerialization.data(withJSONObject: fallbackPayload)
        _ = try? await URLSession.shared.data(for: fallbackRequest)
    }

    /// Mengirim notifikasi proaktif ke smartphone terdaftar jika ada event kritis/penting.
    public func sendNotification(text: String) async {
        guard let chatId = allowedChatId, let token = botToken else { return }
        await sendMessage(chatId: chatId, text: "🔔 *Notifikasi Mac:*\n\(text)", token: token)
    }

    /// Mengirim foto (misal tangkapan penyusup webcam) ke Telegram terdaftar.
    @discardableResult
    public func sendPhoto(imageData: Data, caption: String, chatId: String? = nil, filename: String = "sentry.jpg") async -> Bool {
        guard let token = botToken, let targetChatId = chatId ?? allowedChatId else { return false }
        let boundary = "Boundary-\(UUID().uuidString)"
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendPhoto") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(targetChatId)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)

        let mimeType = filename.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
        } catch {
            return false
        }
        return false
    }
}

// MARK: - Telegram MarkdownV2 Formatter & System Metrics

public enum TelegramFormatter {
    /// Mengonversi teks umum / markdown ke format MarkdownV2 Telegram yang valid dan ter-escape aman.
    public static func toMarkdownV2(_ text: String) -> String {
        var result = ""
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCodeBlock.toggle()
                result += "```\n"
                continue
            }

            if inCodeBlock {
                let escaped = line
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                result += escaped + "\n"
            } else {
                var processedLine = line

                // Ubah header Markdown (# Judul) menjadi *Judul*
                if processedLine.hasPrefix("#") {
                    let clean = processedLine.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                    processedLine = "*\(clean)*"
                }

                // Ubah unordered list markdown "- " / "* " menjadi bullet "• "
                if processedLine.hasPrefix("- ") || processedLine.hasPrefix("* ") {
                    processedLine = "• " + processedLine.dropFirst(2)
                }

                result += escapeMarkdownV2Line(processedLine) + "\n"
            }
        }

        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedResult.count > 3900 {
            let cut = String(trimmedResult.prefix(3850))
            return cut + "\n\n_\\.\\.\\. \\(teks diringkas sesuai batas Telegram\\)_"
        }
        return trimmedResult
    }

    private static func escapeMarkdownV2Line(_ line: String) -> String {
        var escaped = ""
        var inInlineCode = false

        var i = line.startIndex
        while i < line.endIndex {
            let char = line[i]

            if char == "`" {
                inInlineCode.toggle()
                escaped.append(char)
                i = line.index(after: i)
                continue
            }

            if inInlineCode {
                if char == "\\" {
                    escaped.append("\\\\")
                } else {
                    escaped.append(char)
                }
                i = line.index(after: i)
                continue
            }

            if char == "*" {
                escaped.append(char)
                i = line.index(after: i)
                continue
            }

            // Karakter khusus yang wajib di-escape di Telegram MarkdownV2 di luar kode
            let specialChars: Set<Character> = ["_", "[", "]", "(", ")", "~", ">", "#", "+", "-", "=", "|", "{", "}", ".", "!"]
            if specialChars.contains(char) {
                escaped.append("\\")
                escaped.append(char)
            } else {
                escaped.append(char)
            }

            i = line.index(after: i)
        }

        return escaped
    }

    /// Memformat hasil tugas otonom agar singkat, berestetika, dan bergaya Telegram
    public static func formatTaskSummary(goal: String, isSuccess: Bool, rawOutput: String) -> String {
        let statusEmoji = isSuccess ? "✅" : "⚠️"
        let statusTitle = isSuccess ? "Tugas Selesai" : "Tugas Selesai Sebagian"

        var cleanNote = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanNote.isEmpty {
            cleanNote = isSuccess ? "Instruksi berhasil dijalankan di Mac." : "Gagal menyelesaikan instruksi."
        }

        // Jika output berisi dump log panjang, ambil ringkasannya
        let lines = cleanNote.components(separatedBy: "\n")
        let formattedBody: String
        if lines.count > 12 {
            let topLines = lines.prefix(8).joined(separator: "\n")
            let bottomLines = lines.suffix(3).joined(separator: "\n")
            formattedBody = "\(topLines)\n…\n\(bottomLines)"
        } else {
            formattedBody = cleanNote
        }

        let summary = """
        \(statusEmoji) *\(statusTitle)*
        🎯 *Target:* `\(goal)`

        \(formattedBody)
        """
        return toMarkdownV2(summary)
    }
}

// MARK: - Internal System Metrics (RAM, CPU, Disk)

private enum SystemMetrics {
    static func getRAM() -> (usedGB: Double, totalGB: Double, percent: Double) {
        var totalMemory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalMemory, &size, nil, 0)
        let totalGB = Double(totalMemory) / (1024 * 1024 * 1024)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()

        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }

        if result == KERN_SUCCESS {
            let pageSize = UInt64(getpagesize())
            let active = UInt64(vmStats.active_count) * pageSize
            let wired = UInt64(vmStats.wire_count) * pageSize
            let compressed = UInt64(vmStats.compressor_page_count) * pageSize
            let usedBytes = active + wired + compressed
            let usedGB = Double(usedBytes) / (1024 * 1024 * 1024)
            let percent = totalMemory > 0 ? (Double(usedBytes) / Double(totalMemory)) * 100.0 : 0.0
            return (usedGB, totalGB, percent)
        }
        return (0, totalGB, 0)
    }

    static func getCPU() -> Double {
        var cpuLoad = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()

        let cpuResult = withUnsafeMutablePointer(to: &cpuLoad) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { intPtr in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, intPtr, &cpuCount)
            }
        }

        if cpuResult == KERN_SUCCESS {
            let user = Double(cpuLoad.cpu_ticks.0)
            let sys = Double(cpuLoad.cpu_ticks.1)
            let idle = Double(cpuLoad.cpu_ticks.2)
            let nice = Double(cpuLoad.cpu_ticks.3)
            let totalTicks = user + sys + idle + nice
            return totalTicks > 0 ? ((user + sys + nice) / totalTicks) * 100.0 : 0.0
        }
        return 0.0
    }

    static func getDisk() -> (freeGB: Double, totalGB: Double, percentUsed: Double) {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let totalSpace = attrs[.systemSize] as? Int64,
           let freeSpace = attrs[.systemFreeSize] as? Int64 {
            let freeGB = Double(freeSpace) / (1024 * 1024 * 1024)
            let totalGB = Double(totalSpace) / (1024 * 1024 * 1024)
            let percentUsed = totalSpace > 0 ? ((Double(totalSpace - freeSpace)) / Double(totalSpace)) * 100.0 : 0.0
            return (freeGB, totalGB, percentUsed)
        }
        return (0, 0, 0)
    }

    static func makeBar(percent: Double, length: Int = 8) -> String {
        let filled = max(0, min(length, Int((percent / 100.0) * Double(length))))
        let empty = length - filled
        return String(repeating: "■", count: filled) + String(repeating: "□", count: empty)
    }
}

