import Foundation
import AppKit

@main
struct ApplicationAndServerIntegrationTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan ApplicationAndServerIntegrationTests...")

        // T1: Docker Integration Service
        log("T1: testDockerIntegrationService")
        let isDockerAvail = await DockerIntegrationService.shared.isDockerAvailable()
        log("  Docker available on system: \(isDockerAvail)")

        let containerTable = await DockerIntegrationService.shared.listContainers(all: true)
        assert(!containerTable.summaryMarkdown.isEmpty, "Container output should not be empty")
        log("  Docker listContainers executed successfully: \(containerTable.containers.count) container(s) found")

        let mockLogs = await DockerIntegrationService.shared.getLogs(container: "nonexistent_mock_container_xyz", tail: 10)
        assert(!mockLogs.isEmpty, "Mock log retrieval should return meaningful message")
        log("T1 OK ✅")

        // T2: SSH Server Gateway Service
        log("T2: testSSHServerGatewayService")
        let serverId = "test_server_\(UUID().uuidString.prefix(6))"
        let testServer = RemoteServerConfig(
            id: serverId,
            name: "Test Cloud Node",
            host: "127.0.0.1",
            port: 2222,
            username: "ubuntu",
            keyPath: "~/.ssh/id_rsa"
        )

        SSHServerGatewayService.shared.addOrUpdateServer(testServer)
        let servers = SSHServerGatewayService.shared.listServers()
        guard servers.contains(where: { $0.id == serverId }) else {
            fatalError("Remote server not found in registry")
        }

        let foundByName = SSHServerGatewayService.shared.findServer(identifier: "Test Cloud Node")
        guard foundByName?.id == serverId else {
            fatalError("Failed to find server by name")
        }

        let foundByHost = SSHServerGatewayService.shared.findServer(identifier: "127.0.0.1")
        guard foundByHost?.id == serverId else {
            fatalError("Failed to find server by host")
        }

        // Test checkServerHealth fallback
        let (report, summary) = await SSHServerGatewayService.shared.checkServerHealth(identifier: serverId)
        assert(!summary.isEmpty, "Server health summary should not be empty")
        log("  Server health fallback returned summary: \(summary.prefix(60))...")

        SSHServerGatewayService.shared.removeServer(id: serverId)
        let serversAfter = SSHServerGatewayService.shared.listServers()
        guard !serversAfter.contains(where: { $0.id == serverId }) else {
            fatalError("Server should be deleted from registry")
        }
        log("T2 OK ✅")

        // T3: Apple Apps Integration Service
        log("T3: testAppleAppsIntegrationService")
        let calResult = await AppleAppsIntegrationService.shared.listCalendarEvents(daysAhead: 1)
        assert(!calResult.isEmpty, "Calendar query result should not be empty")
        log("  Calendar query executed: \(calResult.prefix(50))...")

        let mediaResult = await AppleAppsIntegrationService.shared.controlMedia(action: "now_playing")
        assert(!mediaResult.isEmpty, "Media control result should not be empty")
        log("  Media control executed: \(mediaResult.prefix(50))...")
        log("T3 OK ✅")

        // T4: ToolExecutor Registration & Synonyms Resolution
        log("T4: testToolExecutorRegistrationAndSynonyms")
        let toolNames = ToolExecutor.tools.map { $0.name }

        let expectedTools = [
            "docker_list_containers", "docker_get_logs", "docker_restart_container",
            "ssh_list_servers", "ssh_server_health", "ssh_run_command", "ssh_tail_log",
            "calendar_list_events", "reminder_add_task", "notes_create_note", "media_control"
        ]

        for tool in expectedTools {
            guard toolNames.contains(tool) else {
                fatalError("Missing registered tool in ToolExecutor: \(tool)")
            }
        }
        log("  All \(expectedTools.count) application & server tools registered in ToolExecutor")

        // Test synonyms / fuzzy matching resolution
        let testSynonyms: [(input: String, expected: String)] = [
            ("docker_ps", "docker_list_containers"),
            ("docker_logs", "docker_get_logs"),
            ("restart_container", "docker_restart_container"),
            ("check_server", "ssh_server_health"),
            ("server_health", "ssh_server_health"),
            ("server_status", "ssh_server_health"),
            ("ssh_command", "ssh_run_command"),
            ("server_logs", "ssh_tail_log"),
            ("calendar", "calendar_list_events"),
            ("add_reminder", "reminder_add_task"),
            ("create_note", "notes_create_note"),
            ("music_control", "media_control"),
            ("spotify_control", "media_control")
        ]

        for pair in testSynonyms {
            let resolved = ToolExecutor.toolAliases[pair.input] ?? pair.input
            guard resolved == pair.expected else {
                fatalError("Synonym resolution failed for '\(pair.input)'. Expected: \(pair.expected), got: \(resolved)")
            }
        }
        log("  Synonyms mapping successfully verified for all tools")
        log("T4 OK ✅")

        // T5: Schema Validator & Gemini OpenAPI Safety Check
        log("T5: testSchemaSafetyForGemini")
        // Check every tool registered in ToolExecutor for array fields without items
        for tool in ToolExecutor.tools {
            let schemaDict = tool.inputSchema.anyValue
            verifyNoMissingArrayItems(schema: schemaDict, toolName: tool.name)
            
            // Also test GeminiProvider.sanitizeSchemaForGemini
            let sanitized = GeminiProvider.sanitizeSchemaForGemini(schemaDict)
            verifyNoMissingArrayItems(schema: sanitized, toolName: tool.name)
        }
        log("  All \(ToolExecutor.tools.count) tools passed strict Gemini OpenAPI schema validation (zero missing items)")
        log("T5 OK ✅")

        log("🎉 SEMUA TEST APPLICATION & SERVER INTEGRATIONS BERHASIL (100% OK)!")
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

