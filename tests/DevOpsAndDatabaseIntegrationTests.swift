import Foundation
import AppKit

@main
struct DevOpsAndDatabaseIntegrationTests {
    static func main() async throws {
        let err = FileHandle.standardError
        func log(_ s: String) { err.write((s + "\n").data(using: .utf8)!) }

        log("🚀 Menjalankan DevOpsAndDatabaseIntegrationTests (Paket 10)...")

        // MARK: - T1: Kubernetes Integration Service
        log("T1: testKubernetesIntegrationService")
        let isK8sAvail = await KubernetesIntegrationService.shared.isKubectlAvailable()
        log("  Kubectl available on system: \(isK8sAvail)")

        let currentCtx = await KubernetesIntegrationService.shared.getCurrentContext()
        assert(!currentCtx.isEmpty, "Cluster context should not be empty")
        log("  Current context: \(currentCtx)")

        let podResult = await KubernetesIntegrationService.shared.getPods(namespace: "default")
        assert(!podResult.summaryMarkdown.isEmpty, "Pod summary markdown should not be empty")
        log("  Pod query executed successfully")

        let descResult = await KubernetesIntegrationService.shared.describePod(name: "mock-pod-sample-xyz")
        assert(!descResult.summary.isEmpty, "Describe summary should not be empty")
        log("T1 OK ✅")

        // MARK: - T2: Database Safe Explorer & Guardrail
        log("T2: testDatabaseSafeExplorerAndGuardrail")
        // 1. Setup temporary SQLite database
        let tmpDir = FileManager.default.temporaryDirectory
        let dbFile = tmpDir.appendingPathComponent("test_mochi_\(UUID().uuidString.prefix(6)).db")
        let dbPath = dbFile.path

        // Buat tabel sample via sqlite3 process
        let createProcess = Process()
        createProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        createProcess.arguments = [
            dbPath,
            "CREATE TABLE employees (id INTEGER PRIMARY KEY, name TEXT, department TEXT, salary REAL);" +
            "INSERT INTO employees VALUES (1, 'Alice', 'Engineering', 95000);" +
            "INSERT INTO employees VALUES (2, 'Bob', 'Security', 88000);" +
            "INSERT INTO employees VALUES (3, 'Charlie', 'Product', 92000);"
        ]
        try createProcess.run()
        createProcess.waitUntilExit()

        defer {
            try? FileManager.default.removeItem(at: dbFile)
        }

        // Test inspectSchema
        let schemaResult = await DatabaseIntegrationService.shared.inspectSchema(engine: .sqlite, target: dbPath)
        assert(schemaResult.tables.contains("employees"), "Schema inspector must find 'employees' table")
        assert(schemaResult.summaryMarkdown.contains("employees"), "Schema markdown must mention 'employees'")
        log("  SQLite schema inspection verified: found tables: \(schemaResult.tables)")

        // Test safe query execution (SELECT)
        let queryResult = await DatabaseIntegrationService.shared.executeSafeQuery(
            engine: .sqlite,
            target: dbPath,
            query: "SELECT name, department, salary FROM employees WHERE salary > 90000;"
        )
        assert(!queryResult.isError, "Safe SELECT query must succeed")
        assert(queryResult.output.contains("Alice") && queryResult.output.contains("Charlie"), "Result must contain Alice and Charlie")
        log("  Safe query execution verified successfully")

        // Test Guardrail blocking dangerous commands
        let dangerousQueries = [
            "DROP TABLE employees;",
            "DELETE FROM employees WHERE id = 1;",
            "UPDATE employees SET salary = 999999;",
            "INSERT INTO employees VALUES (4, 'Eve', 'Hacker', 0);",
            "TRUNCATE TABLE employees;",
            "ALTER TABLE employees ADD COLUMN hacked TEXT;",
            "FLUSHALL;"
        ]

        for q in dangerousQueries {
            let (isSafe, reason) = DatabaseIntegrationService.isSafeReadOnlyQuery(q)
            guard !isSafe else {
                fatalError("CRITICAL: Dangerous query was NOT blocked: '\(q)'")
            }
            log("  Blocked dangerous query correctly: '\(q.prefix(25))...' -> Reason: \(reason?.prefix(40) ?? "")")
        }

        // Test Guardrail allowing safe queries
        let safeQueries = [
            "SELECT * FROM employees;",
            "SELECT count(*) FROM employees WHERE department = 'Engineering';",
            "EXPLAIN QUERY PLAN SELECT * FROM employees;",
            "PRAGMA table_info(employees);",
            "WITH high_earners AS (SELECT * FROM employees WHERE salary > 90000) SELECT name FROM high_earners;"
        ]

        for q in safeQueries {
            let (isSafe, _) = DatabaseIntegrationService.isSafeReadOnlyQuery(q)
            guard isSafe else {
                fatalError("CRITICAL: Safe query was falsely blocked: '\(q)'")
            }
        }
        log("  All safe queries correctly permitted")
        log("T2 OK ✅")

        // MARK: - T3: Developer Environment Service
        log("T3: testDeveloperEnvironmentService")
        // Test smart commit generator
        let commitResult = await DeveloperEnvironmentService.shared.smartCommit(directory: nil, prefix: nil)
        assert(!commitResult.message.isEmpty, "Smart commit message must not be empty")
        log("  Smart commit generated message: '\(commitResult.suggestedCommit)'")

        // Test PR review fallback
        let prResult = await DeveloperEnvironmentService.shared.reviewPullRequest(prNumberOrBranch: nil, repoPath: nil)
        assert(!prResult.summary.isEmpty, "PR review summary must not be empty")
        assert(!prResult.outputMarkdown.isEmpty, "PR review markdown must not be empty")
        log("  PR review / git log fallback executed: \(prResult.summary)")
        log("T3 OK ✅")

        // MARK: - T4: ToolExecutor Registration & Aliases
        log("T4: testToolExecutorRegistrationAndAliases")
        let toolNames = ToolExecutor.tools.map { $0.name }

        let expectedTools = [
            "k8s_get_pods", "k8s_describe_pod", "k8s_pod_logs",
            "db_inspect_schema", "db_execute_safe_query",
            "editor_goto_file_line", "git_smart_commit", "gh_pr_review_summary"
        ]

        for t in expectedTools {
            guard toolNames.contains(t) else {
                fatalError("Missing registered tool in ToolExecutor: \(t)")
            }
        }
        log("  All \(expectedTools.count) DevOps & Database tools registered in ToolExecutor (Total tools: \(toolNames.count))")

        // Test alias mappings
        let testAliases: [(input: String, expected: String)] = [
            ("kubectl_pods", "k8s_get_pods"),
            ("k8s_pods", "k8s_get_pods"),
            ("kubectl_describe", "k8s_describe_pod"),
            ("describe_pod", "k8s_describe_pod"),
            ("kubectl_logs", "k8s_pod_logs"),
            ("pod_logs", "k8s_pod_logs"),
            ("inspect_db", "db_inspect_schema"),
            ("db_schema", "db_inspect_schema"),
            ("query_db", "db_execute_safe_query"),
            ("sql_query", "db_execute_safe_query"),
            ("db_query", "db_execute_safe_query"),
            ("open_editor", "editor_goto_file_line"),
            ("goto_line", "editor_goto_file_line"),
            ("open_line", "editor_goto_file_line"),
            ("smart_commit", "git_smart_commit"),
            ("git_commit", "git_smart_commit"),
            ("review_pr", "gh_pr_review_summary"),
            ("pr_review", "gh_pr_review_summary")
        ]

        for pair in testAliases {
            let resolved = ToolExecutor.toolAliases[pair.input] ?? pair.input
            guard resolved == pair.expected else {
                fatalError("Alias resolution failed for '\(pair.input)'. Expected: \(pair.expected), got: \(resolved)")
            }
        }
        log("  All \(testAliases.count) aliases successfully verified")
        log("T4 OK ✅")

        // MARK: - T5: Gemini OpenAPI Schema Validation
        log("T5: testSchemaSafetyForGemini")
        for tool in ToolExecutor.tools {
            let schemaDict = tool.inputSchema.anyValue
            verifyNoMissingArrayItems(schema: schemaDict, toolName: tool.name)

            let sanitized = GeminiProvider.sanitizeSchemaForGemini(schemaDict)
            verifyNoMissingArrayItems(schema: sanitized, toolName: tool.name)
        }
        log("  All \(ToolExecutor.tools.count) tools passed strict Gemini OpenAPI schema validation (zero missing items)")
        log("T5 OK ✅")

        log("🎉 SEMUA TEST DEVOPS & DATABASE COMMAND CENTER (PAKET 10) BERHASIL (100% OK)!")
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

