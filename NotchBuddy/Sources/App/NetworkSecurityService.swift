import Foundation
import SystemConfiguration

// MARK: - Network & Laptop Security Sentinel (Paket 5)

public struct SecurityCheckItem: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let title: String
    public let isPassed: Bool
    public let statusText: String
    public let details: String
    public let recommendation: String
}

public struct LaptopSecurityReport: Codable, Sendable {
    public let timestamp: Date
    public let healthScore: Int
    public let checks: [SecurityCheckItem]
    public let openPortsCount: Int
    public let summaryMarkdown: String
}

public struct DiscoveredNetworkDevice: Codable, Sendable, Identifiable {
    public var id: String { ipAddress }
    public let ipAddress: String
    public let macAddress: String
    public let hostname: String
    public let isGateway: Bool
    public let deviceTypeGuess: String
}

public struct NetworkScanReport: Codable, Sendable {
    public let timestamp: Date
    public let activeInterface: String
    public let localIP: String
    public let gatewayIP: String
    public let devices: [DiscoveredNetworkDevice]
    public let summaryText: String
}

public struct NetworkDiagnosticsReport: Codable, Sendable {
    public let timestamp: Date
    public let targetHost: String
    public let isConnected: Bool
    public let latencyMs: Double
    public let dnsResolutionMs: Double
    public let publicIP: String?
    public let summaryText: String
}

public final class NetworkSecurityService: @unchecked Sendable {
    public static let shared = NetworkSecurityService()

    private init() {}

    // MARK: - Process Execution Helper

    private func runProcess(executable: String, arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: - 1. Laptop Security Audit

    public func auditLaptopSecurity() async -> LaptopSecurityReport {
        var checks: [SecurityCheckItem] = []
        var score = 100

        // 1. Firewall Status
        let fwOut = await runProcess(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getglobalstate"]
        )
        let fwEnabled = fwOut.lowercased().contains("enabled")
        if !fwEnabled { score -= 20 }
        checks.append(SecurityCheckItem(
            name: "firewall",
            title: "macOS Application Firewall",
            isPassed: fwEnabled,
            statusText: fwEnabled ? "Aktif (Protected)" : "Nonaktif (Vulnerable)",
            details: fwOut.isEmpty ? "Tidak dapat membaca status firewall." : fwOut,
            recommendation: fwEnabled ? "Firewall sudah aktif melindungi koneksi masuk." : "Aktifkan Firewall di System Settings → Network → Firewall."
        ))

        // 2. FileVault Disk Encryption
        let fvOut = await runProcess(executable: "/usr/bin/fdesetup", arguments: ["status"])
        let fvEnabled = fvOut.lowercased().contains("is on") || fvOut.lowercased().contains("enabled")
        if !fvEnabled { score -= 25 }
        checks.append(SecurityCheckItem(
            name: "filevault",
            title: "FileVault (Enkripsi Disk XTS-AES 128)",
            isPassed: fvEnabled,
            statusText: fvEnabled ? "Aktif (Terenkripsi)" : "Nonaktif (Risiko Pencurian Data)",
            details: fvOut.isEmpty ? "Status FileVault tidak terdeteksi." : fvOut,
            recommendation: fvEnabled ? "Semua data disk diamankan enkripsi hardware." : "Nyalakan FileVault di System Settings → Privacy & Security → FileVault."
        ))

        // 3. SIP (System Integrity Protection)
        let sipOut = await runProcess(executable: "/usr/bin/csrutil", arguments: ["status"])
        let sipEnabled = sipOut.lowercased().contains("enabled")
        if !sipEnabled { score -= 25 }
        checks.append(SecurityCheckItem(
            name: "sip",
            title: "System Integrity Protection (SIP)",
            isPassed: sipEnabled,
            statusText: sipEnabled ? "Aktif (Kernel Aman)" : "Nonaktif (Rootless Disabled)",
            details: sipOut.isEmpty ? "Status SIP tidak terdeteksi." : sipOut,
            recommendation: sipEnabled ? "Integritas berkas sistem dan kernel macOS terlindungi." : "Nyalakan kembali SIP via Recovery Mode (`csrutil enable`)."
        ))

        // 4. Gatekeeper Status
        let gkOut = await runProcess(executable: "/usr/sbin/spctl", arguments: ["--status"])
        let gkEnabled = gkOut.lowercased().contains("assessments enabled")
        if !gkEnabled { score -= 15 }
        checks.append(SecurityCheckItem(
            name: "gatekeeper",
            title: "Gatekeeper & App Verification",
            isPassed: gkEnabled,
            statusText: gkEnabled ? "Aktif (Notarisasi Terverifikasi)" : "Nonaktif (Aplikasi Tidak Dibatasi)",
            details: gkOut.isEmpty ? "Assessments enabled" : gkOut,
            recommendation: gkEnabled ? "Aplikasi luar harus ternotarisasi Apple sebelum berjalan." : "Aktifkan Gatekeeper (`sudo spctl --master-enable`)."
        ))

        // 5. Open Listening Ports
        let lsofOut = await runProcess(executable: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN"])
        let lines = lsofOut.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let listeningCount = max(0, lines.count - 1)
        if listeningCount > 8 { score -= 15 }

        var portSummary: [String] = []
        for line in lines.dropFirst().prefix(10) {
            let parts = line.split(separator: " ").map { String($0) }
            if parts.count >= 9 {
                let processName = parts[0]
                let address = parts[8]
                portSummary.append("• `\(processName)` mendengarkan di `\(address)`")
            }
        }

        checks.append(SecurityCheckItem(
            name: "listening_ports",
            title: "Listening Ports (Port Terbuka Jaringan)",
            isPassed: listeningCount <= 8,
            statusText: "\(listeningCount) port listening terdeteksi",
            details: portSummary.isEmpty ? "Tidak ada port publik mencurigakan yang terbuka." : portSummary.joined(separator: "\n"),
            recommendation: listeningCount <= 8 ? "Jumlah port terbuka normal untuk penggunaan workstation." : "Tutup service yang tidak digunakan untuk memperkecil bidang serangan."
        ))

        let finalScore = max(10, min(100, score))

        // Generate Markdown Summary
        var md = "# Laporan Audit Keamanan Laptop macOS\n\n"
        md += "**Skor Keamanan:** `\(finalScore)/100` " + (finalScore >= 80 ? "🛡️ (Sangat Baik)" : (finalScore >= 60 ? "⚠️ (Perlu Perhatian)" : "🚨 (Berisiko Tinggi)")) + "\n"
        md += "*Waktu Audit:* \(Date().formatted(date: .abbreviated, time: .shortened))\n\n"
        md += "### Ringkasan Status Proteksi:\n"

        for item in checks {
            md += "- **\(item.title):** \(item.isPassed ? "✅" : "❌") \(item.statusText)\n"
            if !item.isPassed {
                md += "  - *Saran:* \(item.recommendation)\n"
            }
        }

        if !portSummary.isEmpty {
            md += "\n### Port Terbuka Aktif (Top 10):\n"
            md += portSummary.joined(separator: "\n") + "\n"
        }

        let report = LaptopSecurityReport(
            timestamp: Date(),
            healthScore: finalScore,
            checks: checks,
            openPortsCount: listeningCount,
            summaryMarkdown: md
        )

        // Simpan ke Canvas Artifact agar dapat langsung ditampilkan di jendela Canvas jika pengguna minta
        let auditArtifact = CanvasArtifact(
            id: "security_audit_\(Int(Date().timeIntervalSince1970))",
            title: "Audit Keamanan Laptop (Skor \(finalScore)/100)",
            type: .document,
            content: md
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = auditArtifact
        }

        return report
    }

    // MARK: - 2. Local Network Scan (LAN / Wi-Fi)

    public func scanLocalNetwork() async -> NetworkScanReport {
        // Ambil IP lokal dan interface default
        let routeOut = await runProcess(executable: "/sbin/route", arguments: ["-n", "get", "default"])
        var gateway = "192.168.1.1"
        var interface = "en0"

        for line in routeOut.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("interface:") {
                interface = trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }

        let ifconfigOut = await runProcess(executable: "/sbin/ifconfig", arguments: [interface])
        var localIP = "127.0.0.1"
        for line in ifconfigOut.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("inet ") {
                let parts = t.split(separator: " ")
                if parts.count >= 2 {
                    localIP = String(parts[1])
                    break
                }
            }
        }

        // Pindai ARP Table
        let arpOut = await runProcess(executable: "/usr/sbin/arp", arguments: ["-a", "-n"])
        var devices: [DiscoveredNetworkDevice] = []

        for line in arpOut.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Contoh format: ? (192.168.1.1) at 0:11:22:33:44:55 on en0 ifscope [ethernet]
            let parts = trimmed.split(separator: " ").map { String($0) }
            guard parts.count >= 4 else { continue }

            var ip = parts[1].replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            if !ip.contains(".") && parts.count >= 2 { ip = parts[0] }
            let mac = parts[3].lowercased()

            guard mac != "(incomplete)" && !mac.contains("incomplete") && mac.contains(":") else { continue }

            let isGw = (ip == gateway)
            let hostname = isGw ? "Router / Gateway" : (ip == localIP ? "Laptop Ini (MacBook)" : "Device (\(ip))")

            // Guess device type
            var guess = "Perangkat Jaringan"
            if isGw { guess = "Wi-Fi Router / Gateway" }
            else if ip == localIP { guess = "MacBook / Komputer Utama" }
            else if mac.hasPrefix("dc:a6:32") || mac.hasPrefix("b8:27:eb") { guess = "Raspberry Pi / Server IoT" }
            else if mac.hasPrefix("ac:bc:32") || mac.hasPrefix("f0:18:98") || mac.hasPrefix("3c:06:30") { guess = "Apple Device (iPhone/iPad/Mac)" }
            else { guess = "Smartphone / Smart Home / CCTV" }

            devices.append(DiscoveredNetworkDevice(
                ipAddress: ip,
                macAddress: mac,
                hostname: hostname,
                isGateway: isGw,
                deviceTypeGuess: guess
            ))
        }

        // Urutkan perangkat berdasarkan IP
        devices.sort { d1, d2 in
            let p1 = d1.ipAddress.split(separator: ".").compactMap { Int($0) }
            let p2 = d2.ipAddress.split(separator: ".").compactMap { Int($0) }
            if p1.count == 4 && p2.count == 4 {
                for i in 0..<4 {
                    if p1[i] != p2[i] { return p1[i] < p2[i] }
                }
            }
            return d1.ipAddress < d2.ipAddress
        }

        var summary = "Ditemukan \(devices.count) perangkat aktif pada jaringan Wi-Fi/LAN (\(interface), IP Lokal: \(localIP), Gateway: \(gateway)):\n"
        for d in devices {
            summary += "- `\(d.ipAddress)` [\(d.macAddress)] - \(d.hostname) (\(d.deviceTypeGuess))\n"
        }

        // Simpan ke Canvas Artifact tabel jika banyak perangkat
        var tableMd = "# Hasil Pemindaian Jaringan Lokal (LAN / Wi-Fi)\n\n"
        tableMd += "**Interface:** `\(interface)` | **IP Lokal:** `\(localIP)` | **Gateway:** `\(gateway)`\n\n"
        tableMd += "| Alamat IP | MAC Address | Perangkat | Estimasi Tipe |\n"
        tableMd += "| :--- | :--- | :--- | :--- |\n"
        for d in devices {
            tableMd += "| `\(d.ipAddress)` | `\(d.macAddress)` | \(d.hostname) | \(d.deviceTypeGuess) |\n"
        }
        let scanArtifact = CanvasArtifact(
            id: "network_scan_\(Int(Date().timeIntervalSince1970))",
            title: "Pemindaian LAN (\(devices.count) Perangkat)",
            type: .table,
            content: tableMd
        )
        Task { @MainActor in
            CanvasManager.shared.currentArtifact = scanArtifact
        }

        return NetworkScanReport(
            timestamp: Date(),
            activeInterface: interface,
            localIP: localIP,
            gatewayIP: gateway,
            devices: devices,
            summaryText: summary
        )
    }

    // MARK: - 3. Network Diagnostics (Latency, Ping, DNS, Public IP)

    public func runDiagnostics(targetHost: String? = nil) async -> NetworkDiagnosticsReport {
        let host = targetHost ?? "1.1.1.1"

        // 1. Ping Latency
        let startPing = Date()
        let pingOut = await runProcess(executable: "/sbin/ping", arguments: ["-c", "2", "-t", "3", host])
        let pingElapsed = Date().timeIntervalSince(startPing) * 1000.0

        let isConnected = pingOut.contains("bytes from") || pingOut.contains("round-trip")
        var avgLatency = pingElapsed / 2.0

        // Parse avg latency from ping output: round-trip min/avg/max/stddev = 12.345/14.567/...
        if let rtLine = pingOut.components(separatedBy: "\n").first(where: { $0.contains("round-trip") || $0.contains("avg") }) {
            let comps = rtLine.components(separatedBy: "=")
            if comps.count >= 2 {
                let stats = comps[1].trimmingCharacters(in: .whitespaces).split(separator: "/")
                if stats.count >= 2, let parsed = Double(stats[1]) {
                    avgLatency = parsed
                }
            }
        }

        // 2. DNS Resolution Speed
        let startDns = Date()
        _ = await runProcess(executable: "/usr/bin/host", arguments: ["-W", "2", "google.com"])
        let dnsMs = Date().timeIntervalSince(startDns) * 1000.0

        // 3. Public IP lookup (via lightweight fast API)
        var publicIP: String? = nil
        if let url = URL(string: "https://api.ipify.org") {
            var req = URLRequest(url: url, timeoutInterval: 3.0)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                publicIP = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let summary = """
        Diagnostik Jaringan ke \(host):
        • Status Koneksi: \(isConnected ? "Online (Terhubung) ✓" : "Offline (Gagal Terhubung) ❌")
        • Latensi Ping Rata-rata: \(String(format: "%.1f", avgLatency)) ms
        • Kecepatan Resolusi DNS: \(String(format: "%.1f", dnsMs)) ms
        • Public IP Publik: \(publicIP ?? "Tidak terdeteksi / Offline")
        """

        return NetworkDiagnosticsReport(
            timestamp: Date(),
            targetHost: host,
            isConnected: isConnected,
            latencyMs: avgLatency,
            dnsResolutionMs: dnsMs,
            publicIP: publicIP,
            summaryText: summary
        )
    }
}
