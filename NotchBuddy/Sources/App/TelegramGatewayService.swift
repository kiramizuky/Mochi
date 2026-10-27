import Foundation
import AppKit

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
        appendAppLog("nb.log", "TelegramGateway: Pairing direset oleh pengguna.")
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
                AppState.shared.activePlaybookProgress = "✅ Telegram HP Terhubung (\(senderName))"
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
                SoundEngine.shared.play("finish")
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
            AppState.shared.activePlaybookProgress = "🔑 Telegram PIN: \(pin)"
            AppState.shared.stateOverride = .question
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
            SoundEngine.shared.play("think")
        }

        appendAppLog("nb.log", "TelegramGateway: Pairing request dari chat ID \(chatId), PIN ditampilkan di Notch")

        let prompt = "🔒 *Otentikasi Diperlukan*\n\nMacBook Anda menampilkan kode pairing 6-digit di Notch.\nSilakan masukkan kode tersebut di chat ini untuk menghubungkan ponsel Anda."
        await sendMessage(chatId: chatId, text: prompt, token: token)
    }

    // MARK: - Remote Commands Execution

    private func handleVerifiedCommand(chatId: String, text: String, token: String) async {
        guard !text.isEmpty else { return }

        if text == "/start" || text == "/help" {
            let help = """
            🤖 *Coucou Mac Remote Assistant*

            Perintah yang tersedia:
            • `/status` - Cek status baterai, memori & Mochi di Mac
            • `/screenshot` - Tangkap layar Mac dan kirim foto
            • `/canvas` - Lihat teks artefak Canvas Studio yang aktif
            • `/cancel` - Batalkan tugas otonom yang sedang berjalan
            • Atau *kirim instruksi langsung* untuk dieksekusi oleh Mac!
            """
            await sendMessage(chatId: chatId, text: help, token: token)
            return
        }

        if text == "/status" {
            let status = await collectMacStatus()
            await sendMessage(chatId: chatId, text: status, token: token)
            return
        }

        if text == "/screenshot" {
            await sendMessage(chatId: chatId, text: "📸 Mengambil tangkapan layar Mac...", token: token)
            await captureAndSendScreenshot(chatId: chatId, token: token)
            return
        }

        if text == "/canvas" {
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

        if text == "/cancel" {
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

        let taskResult = await MainActor.run { () -> String in
            if let t = AppState.shared.autonomousTasks.first(where: { $0.id == taskId }) {
                let note = t.note ?? (t.status == .completed ? "Selesai tanpa catatan." : "Gagal.")
                return (t.status == .completed ? "✅ *Tugas Selesai:*\n" : "⚠️ *Tugas Selesai Sebagian:*\n") + note
            }
            return "✅ Tugas telah diproses oleh Mac."
        }

        await sendMessage(chatId: chatId, text: taskResult, token: token)
    }

    // MARK: - Mac System Diagnostics

    private func collectMacStatus() async -> String {
        return await MainActor.run {
            let mode = AppState.shared.mode.rawValue
            let runningTask = AppState.shared.autonomousTasks.first(where: { $0.status == .running })?.goal ?? "Tidak ada (Idle)"
            let battery = getBatteryPercentage()
            let dateStr = ISO8601DateFormatter().string(from: Date())

            return """
            💻 *Status MacBook Coucou*
            • Waktu: `\(dateStr)`
            • Island Mode: `\(mode)`
            • Daya/Baterai: `\(battery)`
            • Tugas Otonom: `\(runningTask)`
            • Mode Otonom Aktif: `\(AppState.shared.autonomousEnabled ? "Ya" : "Tidak")`
            """
        }
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
                return parts[1].components(separatedBy: ";")[0]
            }
        }
        return "Tersambung Listrik / Mac Desktop"
    }

    // MARK: - Screenshot Capture & Dispatch

    private func captureAndSendScreenshot(chatId: String, token: String) async {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-tg-ss.png")
        try? FileManager.default.removeItem(at: tempFile)

        let captured = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-t", "png", tempFile.path]
                do {
                    try p.run()
                    p.waitUntilExit()
                    continuation.resume(returning: p.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }

        guard captured, let imageData = try? Data(contentsOf: tempFile) else {
            await sendMessage(chatId: chatId, text: "⚠️ Gagal mengambil tangkapan layar (Izin Screen Recording mungkin diperlukan).", token: token)
            return
        }

        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Kirim via multipart form-data ke sendPhoto
        let boundary = "Boundary-\(UUID().uuidString)"
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendPhoto") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("🖥️ Tangkapan layar Mac saat ini\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"screenshot.png\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Outbound Message Helper

    public func sendMessage(chatId: String, text: String, token: String? = nil) async {
        guard let activeToken = token ?? botToken else { return }
        guard let url = URL(string: "https://api.telegram.org/bot\(activeToken)/sendMessage") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "parse_mode": "Markdown"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        _ = try? await URLSession.shared.data(for: request)
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

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
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

