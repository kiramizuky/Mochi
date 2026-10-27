import Foundation
import AppKit

// MARK: - Proactive Sentry & Autonomous Health Watchers (Paket 11)

/// Tipe insiden keamanan atau crash layanan yang terdeteksi oleh sistem Sentry.
public struct SentryIncident: Codable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let type: IncidentType
    public let summary: String
    public let details: String
    public let photoPath: String?
    public let networkSSID: String?

    public enum IncidentType: String, Codable, Sendable {
        case physicalIntruder = "physical_intruder"
        case unauthorizedWifiDevice = "unauthorized_wifi_device"
        case containerCrash = "container_crash"
        case serverUnreachable = "server_unreachable"
    }
}

/// Laporan hasil audit pemulihan mandiri container dan server.
public struct AutoHealReport: Sendable {
    public let timestamp: Date
    public let scannedContainersCount: Int
    public let crashedContainersFound: [String]
    public let healedContainers: [String]
    public let unreachableServers: [String]
    public let summaryMarkdown: String
}

/// Laporan hasil pemindaian pengawas jaringan Wi-Fi lokal.
public struct WifiSentryReport: Sendable {
    public let timestamp: Date
    public let totalDevicesScanned: Int
    public let knownDevicesCount: Int
    public let newDevices: [DiscoveredNetworkDevice]
    public let summaryMarkdown: String
}

/// Layanan pengawas otonom (Sentry) yang bertindak sebagai penjaga fisik laptop,
/// pengawas jaringan Wi-Fi, dan pemulih otomatis crash container / server.
public final class ProactiveSentryService: @unchecked Sendable {
    public static let shared = ProactiveSentryService()

    private let lock = NSLock()
    private let defaults = UserDefaults.standard

    // Keys untuk persistensi pengaturan
    private let knownDevicesKey = "mochi_sentry_known_devices"
    private let awayModeKey = "mochi_sentry_away_mode"
    private let wifiWatcherKey = "mochi_sentry_wifi_watcher"
    private let autoHealKey = "mochi_sentry_autoheal_enabled"
    private let autoHealRestartDockerKey = "mochi_sentry_autoheal_restart_docker"
    private let incidentsKey = "mochi_sentry_incidents"

    // Background Daemon Task
    private var daemonTask: Task<Void, Never>?
    public private(set) var isDaemonRunning: Bool = false

    // State insiden in-memory
    private var _incidents: [SentryIncident] = []

    private init() {
        loadPersistedState()
        setupScreenNotifications()
    }

    // MARK: - Configuration Properties

    public var isAwayModeActive: Bool {
        get { defaults.bool(forKey: awayModeKey) }
        set {
            defaults.set(newValue, forKey: awayModeKey)
            if newValue {
                triggerProactiveChip(
                    id: "sentry_away_active",
                    text: "🛡️ Away Sentry Aktif",
                    fact: "Periksa status penjagaan fisik dan insiden keamanan laptop"
                )
            } else {
                removeProactiveChip(id: "sentry_away_active")
            }
        }
    }

    public var isWifiWatcherEnabled: Bool {
        get {
            if defaults.object(forKey: wifiWatcherKey) == nil { return true }
            return defaults.bool(forKey: wifiWatcherKey)
        }
        set { defaults.set(newValue, forKey: wifiWatcherKey) }
    }

    public var isAutoHealEnabled: Bool {
        get {
            if defaults.object(forKey: autoHealKey) == nil { return true }
            return defaults.bool(forKey: autoHealKey)
        }
        set { defaults.set(newValue, forKey: autoHealKey) }
    }

    public var autoHealRestartDocker: Bool {
        get {
            if defaults.object(forKey: autoHealRestartDockerKey) == nil { return true }
            return defaults.bool(forKey: autoHealRestartDockerKey)
        }
        set { defaults.set(newValue, forKey: autoHealRestartDockerKey) }
    }

    public var knownDevices: [String: String] {
        get { defaults.dictionary(forKey: knownDevicesKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: knownDevicesKey) }
    }

    public var recentIncidents: [SentryIncident] {
        lock.withLock { _incidents }
    }

    // MARK: - State Persistence

    private func loadPersistedState() {
        if let data = defaults.data(forKey: incidentsKey),
           let decoded = try? JSONDecoder().decode([SentryIncident].self, from: data) {
            _incidents = decoded
        }
    }

    private func saveIncidents() {
        lock.withLock {
            let top50 = Array(_incidents.prefix(50))
            if let data = try? JSONEncoder().encode(top50) {
                defaults.set(data, forKey: incidentsKey)
            }
        }
    }

    public func addIncident(_ incident: SentryIncident) {
        lock.withLock {
            _incidents.insert(incident, at: 0)
        }
        saveIncidents()
    }

    // MARK: - 1. Physical Intruder & Anti-Theft Guard (Away Sentry)

    public func enableAwayMode() -> String {
        isAwayModeActive = true
        startDaemonIfNeeded()
        return "🛡️ Mode Away Sentry diaktifkan. Laptop kini dalam pengawasan anti-maling & penyusup fisik. Jika ada orang asing menatap layar saat Anda pergi, asisten akan memotret senyap dan mengirimkan peringatan ke Telegram."
    }

    public func disableAwayMode() -> String {
        isAwayModeActive = false
        return "🛡️ Mode Away Sentry dinonaktifkan. Pengawasan fisik dihentikan."
    }

    /// Memeriksa apakah ada wajah orang asing di depan kamera saat away mode aktif.
    public func checkPhysicalIntruder() async -> (intruderDetected: Bool, incident: SentryIncident?, summary: String) {
        guard isAwayModeActive else {
            return (false, nil, "Away mode nonaktif.")
        }

        // Ambil SSID Wi-Fi aktif
        let wifiSSID = getActiveWifiSSID()

        do {
            // Ambil foto senyap via Webcam
            let photo = try await WebcamCaptureService.shared.capturePhoto()
            let verification = try await FaceRecognitionService.shared.verifyFace(in: photo.data)

            if verification.totalFacesDetected > 0 && !verification.isOwnerPresent {
                // INTRUDER DETECTED!
                let incidentId = UUID().uuidString
                let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
                let summary = "Terdeteksi orang asing (\(verification.totalFacesDetected) wajah) menatap layar pada \(timeStr)"
                let details = "Kamera mendeteksi \(verification.totalFacesDetected) wajah asing di depan laptop. Tidak cocok dengan profil pemilik terdaftar. Skor kecocokan: \(String(format: "%.0f%%", verification.confidenceScore * 100)). Wi-Fi: \(wifiSSID)."

                let incident = SentryIncident(
                    id: incidentId,
                    timestamp: Date(),
                    type: .physicalIntruder,
                    summary: summary,
                    details: details,
                    photoPath: photo.filePath,
                    networkSSID: wifiSSID
                )
                addIncident(incident)

                // 1. Tampilkan Proactive Chip di Notch Island
                triggerProactiveChip(
                    id: "sentry_intruder_\(incidentId.prefix(8))",
                    text: "🚨 Penyusup Terdeteksi: Wajah Asing!",
                    fact: "Periksa foto dan rincian penyusup keamanan laptop di Canvas"
                )

                // 2. Kirim Notifikasi Darurat ke Telegram Pemilik beserta Foto
                let tgCaption = """
                🚨 *PERINGATAN KEAMANAN LAPTOP (INTRUDER ALERT)!*
                Terdeteksi orang asing menatap layar MacBook Anda saat sedang ditinggalkan!

                • *Waktu:* `\(timeStr)`
                • *Total Wajah:* `\(verification.totalFacesDetected)`
                • *Wi-Fi Aktif:* `\(wifiSSID)`
                • *Catatan:* \(verification.message)
                """

                Task {
                    _ = await TelegramGatewayService.shared.sendPhoto(
                        imageData: photo.data,
                        caption: tgCaption,
                        filename: "intruder_\(incidentId.prefix(6)).jpg"
                    )
                }

                // 3. Tampilkan Laporan di Canvas Studio
                let canvasMarkdown = """
                # 🚨 Peringatan Keamanan Kritis: Penyusup Fisik Terdeteksi
                
                **Waktu Deteksi:** \(timeStr)  
                **Lokasi Jaringan (Wi-Fi):** `\(wifiSSID)`  
                **Jumlah Wajah Terdeteksi:** \(verification.totalFacesDetected)  
                **Status Pemilik:** ❌ Tidak Ditemukan / Tidak Cocok  
                
                ---
                
                ### Rincian Insiden:
                \(details)
                
                > [!CAUTION]
                > Foto penyusup telah berhasil disimpan secara aman di: `\(photo.filePath)` dan dikirimkan langsung ke Telegram terhubung.
                """

                await MainActor.run {
                    let artifact = CanvasArtifact(
                        id: "incident-\(incidentId)",
                        title: "🚨 Alert Penyusup: \(timeStr)",
                        type: .document,
                        content: canvasMarkdown
                    )
                    CanvasManager.shared.present(artifact: artifact)
                }

                return (true, incident, summary)
            } else if verification.isOwnerPresent {
                return (false, nil, "Wajah pemilik terverifikasi di depan layar. Tidak ada ancaman.")
            } else {
                return (false, nil, "Tidak ada wajah di depan kamera.")
            }
        } catch {
            return (false, nil, "Gagal menjalankan pengawasan kamera: \(error.localizedDescription)")
        }
    }

    // MARK: - 2. LAN New-Device Sentry (Wi-Fi Watcher)

    /// Memindai jaringan lokal dan mendeteksi perangkat asing baru yang belum dikenal.
    public func scanWifiForIntruders() async -> WifiSentryReport {
        let scanReport = await NetworkSecurityService.shared.scanLocalNetwork()
        var currentKnown = knownDevices
        var newDevices: [DiscoveredNetworkDevice] = []

        for device in scanReport.devices {
            // Abaikan router gateway
            if device.isGateway { continue }
            let normalizedMac = device.macAddress.lowercased()

            if currentKnown[normalizedMac] == nil {
                // Perangkat baru terdeteksi!
                newDevices.append(device)

                // Munculkan proactive chip di Notch
                let chipLabel = "⚠️ Perangkat baru: \(device.ipAddress)"
                let fact = "Periksa perangkat baru di Wi-Fi: IP \(device.ipAddress), MAC \(device.macAddress), Tipe \(device.deviceTypeGuess)"
                triggerProactiveChip(
                    id: "sentry_wifi_\(normalizedMac.replacingOccurrences(of: ":", with: "_"))",
                    text: chipLabel,
                    fact: fact
                )

                // Catat insiden
                let incident = SentryIncident(
                    id: UUID().uuidString,
                    timestamp: Date(),
                    type: .unauthorizedWifiDevice,
                    summary: "Perangkat baru terdeteksi di Wi-Fi: \(device.ipAddress) (\(device.deviceTypeGuess))",
                    details: "IP: \(device.ipAddress), MAC: \(device.macAddress), Tipe: \(device.deviceTypeGuess), Hostname: \(device.hostname)",
                    photoPath: nil,
                    networkSSID: getActiveWifiSSID()
                )
                addIncident(incident)
            }
        }

        var md = """
        # 📡 Laporan Sentry Jaringan Wi-Fi Lokal
        
        **Waktu Pemindaian:** \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))  
        **Total Perangkat di Jaringan:** \(scanReport.devices.count)  
        **Perangkat Tepercaya Terdaftar:** \(currentKnown.count)  
        **Perangkat Baru / Asing:** \(newDevices.count)  
        
        ---
        
        """

        if newDevices.isEmpty {
            md += "✅ **Semua perangkat di jaringan Wi-Fi lokal telah terverifikasi dan tepercaya.**\n"
        } else {
            md += "### ⚠️ Perangkat Asing Baru yang Terdeteksi:\n\n"
            md += "| IP Address | MAC Address | Perkiraan Perangkat | Hostname |\n"
            md += "| :--- | :--- | :--- | :--- |\n"
            for d in newDevices {
                md += "| `\(d.ipAddress)` | `\(d.macAddress)` | \(d.deviceTypeGuess) | \(d.hostname) |\n"
            }
            md += "\n> [!TIP]\n> Gunakan perintah *\"Percayai perangkat IP/MAC ini\"* untuk mendaftarkannya ke daftar perangkat aman.\n"
        }

        // Tampilkan ke Canvas jika ada perangkat baru
        if !newDevices.isEmpty {
            let finalMarkdown = md
            let count = newDevices.count
            await MainActor.run {
                let artifact = CanvasArtifact(
                    id: "wifi-sentry-\(UUID().uuidString.prefix(6))",
                    title: "⚠️ Perangkat Asing di Wi-Fi (\(count))",
                    type: .table,
                    content: finalMarkdown
                )
                CanvasManager.shared.present(artifact: artifact)
            }
        }

        return WifiSentryReport(
            timestamp: Date(),
            totalDevicesScanned: scanReport.devices.count,
            knownDevicesCount: currentKnown.count,
            newDevices: newDevices,
            summaryMarkdown: md
        )
    }

    /// Menambahkan MAC address ke daftar perangkat yang dipercaya.
    public func trustDevice(mac: String, label: String = "Trusted Device") -> String {
        let normMac = mac.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normMac.isEmpty else { return "MAC Address tidak valid." }

        var current = knownDevices
        current[normMac] = label
        knownDevices = current

        // Hapus proactive chip yang bersangkutan
        removeProactiveChip(id: "sentry_wifi_\(normMac.replacingOccurrences(of: ":", with: "_"))")

        return "✅ Perangkat `\(normMac)` (\(label)) berhasil didaftarkan sebagai perangkat terpercaya."
    }

    /// Menghapus perangkat dari daftar terpercaya.
    public func untrustDevice(mac: String) -> String {
        let normMac = mac.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var current = knownDevices
        current.removeValue(forKey: normMac)
        knownDevices = current
        return "🗑️ Perangkat `\(normMac)` telah dihapus dari daftar terpercaya."
    }

    // MARK: - 3. Container & Server Crash Auto-Healer

    /// Memindai container Docker dan server SSH terdaftar, serta memulihkan container yang crash.
    public func runAutoHealAudit() async -> AutoHealReport {
        var scannedCount = 0
        var crashedContainers: [String] = []
        var healedContainers: [String] = []
        var unreachableServers: [String] = []

        // 1. Audit Docker Containers
        let dockerAvailable = await DockerIntegrationService.shared.isDockerAvailable()
        if dockerAvailable {
            let (containers, _) = await DockerIntegrationService.shared.listContainers(all: true)
            scannedCount = containers.count

            for c in containers {
                let statusLower = c.status.lowercased()
                // Deteksi crash / abnormal exit
                let isCrashed = statusLower.contains("exited") && (!statusLower.contains("(0)") && !statusLower.contains("exit 0"))

                if isCrashed {
                    crashedContainers.append("\(c.name) (\(c.status))")

                    if autoHealRestartDocker {
                        // Jalankan auto-heal restart
                        let (success, _) = await DockerIntegrationService.shared.restartContainer(container: c.id)
                        if success {
                            healedContainers.append(c.name)
                            triggerProactiveChip(
                                id: "sentry_healed_\(c.id)",
                                text: "🔄 Container \(c.name) pulih otomatis",
                                fact: "Periksa log container \(c.name) yang baru saja di-restart otomatis oleh Auto-Healer"
                            )

                            // Kirim notifikasi Telegram
                            Task {
                                await TelegramGatewayService.shared.sendNotification(
                                    text: "🔄 *Container Auto-Healed:*\nContainer `\(c.name)` mengalami crash (\(c.status)) dan telah di-restart otomatis oleh Mochi."
                                )
                            }
                        }
                    } else {
                        // Tampilkan chip opsi restart manual
                        triggerProactiveChip(
                            id: "sentry_crashed_\(c.id)",
                            text: "🛑 Container \(c.name) crash",
                            fact: "Restart container \(c.name) sekarang"
                        )
                    }

                    // Catat insiden
                    let incident = SentryIncident(
                        id: UUID().uuidString,
                        timestamp: Date(),
                        type: .containerCrash,
                        summary: "Container \(c.name) mengalami crash (\(c.status))",
                        details: "Image: \(c.image), Status: \(c.status), Container ID: \(c.id). Healed: \(healedContainers.contains(c.name))",
                        photoPath: nil,
                        networkSSID: nil
                    )
                    addIncident(incident)
                }
            }
        }

        // 2. Audit SSH Remote Servers
        let servers = SSHServerGatewayService.shared.listServers()
        for server in servers {
            let (report, _) = await SSHServerGatewayService.shared.checkServerHealth(identifier: server.id)
            if report == nil {
                unreachableServers.append("\(server.name) (\(server.host))")
                triggerProactiveChip(
                    id: "sentry_server_\(server.id)",
                    text: "⚠️ Server \(server.name) tidak merespons",
                    fact: "Periksa koneksi SSH dan status server \(server.name) (\(server.host))"
                )

                let incident = SentryIncident(
                    id: UUID().uuidString,
                    timestamp: Date(),
                    type: .serverUnreachable,
                    summary: "Server SSH \(server.name) tidak merespons",
                    details: "Host: \(server.host):\(server.port), User: \(server.username)",
                    photoPath: nil,
                    networkSSID: getActiveWifiSSID()
                )
                addIncident(incident)
            }
        }

        // Susun ringkasan Markdown
        var md = """
        # 🩺 Laporan Pemantauan Mandiri & Auto-Healer
        
        **Waktu Audit:** \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))  
        **Docker Daemon:** \(dockerAvailable ? "Online" : "Offline / Tidak Terpasang")  
        **Container Diperiksa:** \(scannedCount)  
        **Server SSH Diperiksa:** \(servers.count)  
        
        ---
        
        """

        if crashedContainers.isEmpty && unreachableServers.isEmpty {
            md += "✅ **Semua container Docker dan remote server berada dalam kondisi sehat (Optimal).**\n"
        } else {
            if !crashedContainers.isEmpty {
                md += "### 🛑 Container Crash yang Ditemukan:\n"
                for c in crashedContainers {
                    md += "- `\(c)`\n"
                }
                if !healedContainers.isEmpty {
                    md += "\n### 🔄 Container yang Berhasil Dipulihkan (Auto-Restart):\n"
                    for h in healedContainers {
                        md += "- ✅ `\(h)` (Berhasil di-restart otomatis)\n"
                    }
                }
            }
            if !unreachableServers.isEmpty {
                md += "\n### ⚠️ Remote Server Tidak Merespons:\n"
                for s in unreachableServers {
                    md += "- ❌ `\(s)` (Koneksi timeout)\n"
                }
            }
        }

        return AutoHealReport(
            timestamp: Date(),
            scannedContainersCount: scannedCount,
            crashedContainersFound: crashedContainers,
            healedContainers: healedContainers,
            unreachableServers: unreachableServers,
            summaryMarkdown: md
        )
    }

    // MARK: - 4. Background Sentry Daemon Loop

    public func startDaemon(intervalSeconds: TimeInterval = 300) {
        lock.withLock {
            guard daemonTask == nil else { return }
            isDaemonRunning = true

            daemonTask = Task { [weak self] in
                while !Task.isCancelled {
                    // 1. Jika away mode aktif, cek intruder
                    if let self = self, self.isAwayModeActive {
                        _ = await self.checkPhysicalIntruder()
                    }

                    // 2. Jika wifi watcher aktif, scan LAN
                    if let self = self, self.isWifiWatcherEnabled {
                        _ = await self.scanWifiForIntruders()
                    }

                    // 3. Jika auto-heal aktif, periksa container & server
                    if let self = self, self.isAutoHealEnabled {
                        _ = await self.runAutoHealAudit()
                    }

                    try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                }
            }
        }
    }

    public func stopDaemon() {
        lock.withLock {
            daemonTask?.cancel()
            daemonTask = nil
            isDaemonRunning = false
        }
    }

    private func startDaemonIfNeeded() {
        if !isDaemonRunning {
            startDaemon()
        }
    }

    // MARK: - Proactive Chip UI Helpers

    private func triggerProactiveChip(id: String, text: String, fact: String) {
        Task { @MainActor in
            var chips = AppState.shared.proactiveChips
            // Hapus jika sudah ada chip serupa
            chips.removeAll { $0.id == id }
            chips.insert(ProactiveChip(id: id, text: text, fact: fact), at: 0)
            AppState.shared.proactiveChips = chips
        }
    }

    private func removeProactiveChip(id: String) {
        Task { @MainActor in
            AppState.shared.proactiveChips.removeAll { $0.id == id }
        }
    }

    // MARK: - macOS Screen Lock & Sleep Listeners

    private func setupScreenNotifications() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.isAwayModeActive {
                // Laptop dikunci saat away mode aktif: picu pengawasan kamera
                Task {
                    _ = await self.checkPhysicalIntruder()
                }
            }
        }

        dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.isAwayModeActive {
                // Seseorang membuka kunci layar saat away mode aktif!
                Task {
                    _ = await self.checkPhysicalIntruder()
                }
            }
        }
    }

    // MARK: - Helper SSID

    private func getActiveWifiSSID() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getairportnetwork", "en0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let out = String(data: data, encoding: .utf8), out.contains("Current Wi-Fi Network:") {
            return out.replacingOccurrences(of: "Current Wi-Fi Network:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Local Network / Wi-Fi"
    }
}
