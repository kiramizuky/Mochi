import Foundation
import AppKit

// MARK: - Test Suite Paket 11: Proactive Sentry & Autonomous Health Watchers

@main
struct ProactiveSentryAndAutoHealerTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan ProactiveSentryAndAutoHealerTests (Paket 11)...")

        // MARK: - Test 1: Away Sentry Mode & Incident Logging
        log("T1: testAwaySentryModeAndIncidents")
        let sentry = ProactiveSentryService.shared

        // Test enable away mode
        let enableMsg = sentry.enableAwayMode()
        assert(sentry.isAwayModeActive == true, "Away mode harus aktif setelah enableAwayMode()")
        assert(enableMsg.contains("🛡️"), "Pesan aktivasi harus memuat ikon sentry")

        // Test incident recording
        let testIncident = SentryIncident(
            id: "test-incident-\(UUID().uuidString.prefix(6))",
            timestamp: Date(),
            type: .physicalIntruder,
            summary: "Uji coba deteksi penyusup",
            details: "Wajah asing terdeteksi di depan layar pada pengujian otomatis.",
            photoPath: "/tmp/mock_intruder.jpg",
            networkSSID: "Test-Coffee-Shop-WiFi"
        )
        sentry.addIncident(testIncident)

        let recent = sentry.recentIncidents
        assert(recent.contains(where: { $0.id == testIncident.id }), "Insiden baru harus tersimpan dalam recentIncidents")
        log("  Incident successfully logged: \(testIncident.id) (\(testIncident.type.rawValue))")

        // Test disable away mode
        let disableMsg = sentry.disableAwayMode()
        assert(sentry.isAwayModeActive == false, "Away mode harus nonaktif setelah disableAwayMode()")
        assert(disableMsg.contains("🛡️"), "Pesan nonaktif harus memuat ikon sentry")
        log("T1 OK ✅")

        // MARK: - Test 2: LAN New-Device Sentry & Trust Management
        log("T2: testWifiWatcherAndTrustManagement")
        let testMac = "00:1a:2b:3c:4d:5e"
        let testLabel = "MacBook Kantor Ali"

        // Trust device
        let trustMsg = sentry.trustDevice(mac: testMac, label: testLabel)
        assert(sentry.knownDevices[testMac] == testLabel, "Perangkat harus tersimpan di knownDevices")
        assert(trustMsg.contains("berhasil"), "Pesan trust device harus mengonfirmasi keberhasilan")
        log("  Trusted device added: \(testMac) -> \(testLabel)")

        // Untrust device
        let untrustMsg = sentry.untrustDevice(mac: testMac)
        assert(sentry.knownDevices[testMac] == nil, "Perangkat harus terhapus dari knownDevices")
        assert(untrustMsg.contains("dihapus"), "Pesan untrust harus mengonfirmasi penghapusan")
        log("  Untrusted device removed successfully")

        // Run Wi-Fi scan
        let wifiReport = await sentry.scanWifiForIntruders()
        assert(!wifiReport.summaryMarkdown.isEmpty, "Ringkasan markdown pemindaian Wi-Fi tidak boleh kosong")
        log("  Wi-Fi scan completed: \(wifiReport.totalDevicesScanned) total devices, \(wifiReport.newDevices.count) new devices detected")
        log("T2 OK ✅")

        // MARK: - Test 3: Container & Server Crash Auto-Healer
        log("T3: testContainerAndServerAutoHealer")
        sentry.isAutoHealEnabled = true
        sentry.autoHealRestartDocker = true

        let healReport = await sentry.runAutoHealAudit()
        assert(!healReport.summaryMarkdown.isEmpty, "Ringkasan auto-heal tidak boleh kosong")
        log("  Auto-heal audit completed: \(healReport.scannedContainersCount) containers, \(healReport.crashedContainersFound.count) crashes found, \(healReport.healedContainers.count) healed")
        log("T3 OK ✅")

        // MARK: - Test 4: Tool Registration and Aliases in ToolExecutor
        log("T4: testToolExecutorRegistrationAndAliases")
        let tools = ToolExecutor.allTools
        let toolNames = Set(tools.map { $0.name })

        let expectedTools = [
            "sentry_enable_away_mode",
            "sentry_check_status",
            "sentry_scan_wifi_intruders",
            "sentry_trust_device",
            "sentry_autoheal_check"
        ]

        for expected in expectedTools {
            assert(toolNames.contains(expected), "Tool '\(expected)' harus terdaftar di ToolExecutor")
        }
        log("  All 5 Sentry & Auto-Healer tools registered in ToolExecutor (Total tools: \(tools.count))")

        let expectedAliases: [String: String] = [
            "away_sentry": "sentry_enable_away_mode",
            "sentry_mode": "sentry_enable_away_mode",
            "sentry_status": "sentry_check_status",
            "check_sentry": "sentry_check_status",
            "wifi_sentry": "sentry_scan_wifi_intruders",
            "scan_wifi_intruders": "sentry_scan_wifi_intruders",
            "trust_device": "sentry_trust_device",
            "trust_mac": "sentry_trust_device",
            "auto_heal": "sentry_autoheal_check",
            "autoheal_check": "sentry_autoheal_check"
        ]

        for (alias, actual) in expectedAliases {
            let resolved = ToolExecutor.toolAliases[alias]
            assert(resolved == actual, "Alias '\(alias)' harus mengarah ke '\(actual)', didapat '\(resolved ?? "nil")'")
        }
        log("  All \(expectedAliases.count) Sentry aliases successfully verified")

        // Test tool execution via ToolExecutor
        let executor = ToolExecutor()
        let statusResult = await executor.execute(name: "sentry_check_status", input: .object([:]))
        assert(!statusResult.isError, "sentry_check_status tidak boleh menghasilkan error")
        assert(statusResult.output.contains("Proactive Sentry"), "Output harus memuat informasi status Sentry")
        log("  Executed sentry_check_status via ToolExecutor -> OK")
        log("T4 OK ✅")

        // MARK: - Test 5: Gemini OpenAPI Schema Safety
        log("T5: testSchemaSafetyForGemini")
        for tool in tools {
            let schemaDict = tool.inputSchema.anyValue
            verifyNoMissingArrayItems(schema: schemaDict, toolName: tool.name)

            let sanitized = GeminiProvider.sanitizeSchemaForGemini(schemaDict)
            verifyNoMissingArrayItems(schema: sanitized, toolName: tool.name)
        }
        log("  All \(tools.count) tools passed strict Gemini OpenAPI schema validation (zero missing items)")
        log("T5 OK ✅")

        log("🎉 SEMUA TEST PROACTIVE SENTRY & AUTO-HEALER (PAKET 11) BERHASIL (100% OK)!")
    }

    private static func verifyNoMissingArrayItems(schema: Any, toolName: String) {
        guard let dict = schema as? [String: Any] else { return }

        if let typeStr = dict["type"] as? String, typeStr.lowercased() == "array" {
            guard dict["items"] != nil else {
                fatalError("CRITICAL: Tool '\(toolName)' contains array schema without 'items' field!")
            }
        }

        if let props = dict["properties"] as? [String: Any] {
            for (_, propVal) in props {
                verifyNoMissingArrayItems(schema: propVal, toolName: toolName)
            }
        }
    }
}
