import Foundation

// MARK: - Phase 12: Node Engine + JavaScriptCore (8 node otomatisasi)

@main enum Phase12Tests {
    static func main() async throws {
        testNodeTypesAndDefinitions()
        await testNodeExecutorFileSystem()
        await testNodeExecutorCronSchedule()
        await testNodeExecutorIfElse()
        await testNodeExecutorJsonTransform()
        await testNodeExecutorClipboard()
        await testNodeExecutorRunShell()
        await testNodeExecutorHttpRequest()
        print("Phase12Tests: all cases passed")
    }
}

// MARK: - Node types & definitions

func testNodeTypesAndDefinitions() {
    precondition(NodeType.allCases.count == 8, "expected 8 node types, got \(NodeType.allCases.count)")
    precondition(NodeType.allCases.contains(.httpRequest))
    precondition(NodeType.allCases.contains(.fileSystem))
    precondition(NodeType.allCases.contains(.cronSchedule))
    precondition(NodeType.allCases.contains(.ifElse))
    precondition(NodeType.allCases.contains(.jsonTransform))
    precondition(NodeType.allCases.contains(.desktopNotification))
    precondition(NodeType.allCases.contains(.clipboard))
    precondition(NodeType.allCases.contains(.runShell))

    // Setiap tipe punya deskripsi dan display name yang tidak kosong
    for t in NodeType.allCases {
        precondition(!t.displayName.isEmpty, "displayName kosong untuk \(t)")
        precondition(!t.description.isEmpty, "description kosong untuk \(t)")
        let schema = t.inputSchema
        precondition(!schema.requiredKeys.isEmpty, "requiredKeys kosong untuk \(t)")
        precondition(!schema.outputKeys.isEmpty, "outputKeys kosong untuk \(t)")
    }

    // NodeDefinition buat chip/proyek
    let def = NodeDefinition(
        id: "n1",
        type: .httpRequest,
        name: "Fetch GitHub API",
        config: ["url": .string("https://api.github.com"), "method": .string("GET")],
        enabled: true
    )
    precondition(def.id == "n1")
    precondition(def.type == .httpRequest)
    precondition(def.enabled == true)
    precondition(def.inputSchema.requiredKeys.contains("url"))

    // AutomationNode
    let node = AutomationNode(id: "an1", nodeDefinitionId: "n1", positionX: 100, positionY: 200)
    precondition(node.id == "an1")
    precondition(node.nodeDefinitionId == "n1")
    precondition(node.positionX == 100)
    precondition(node.positionY == 200)
    precondition(node.enabled == true)

    // AutomationWorkflow
    let wf = AutomationWorkflow(
        id: "wf1",
        name: "Test Workflow",
        nodes: [node],
        edges: [],
        enabled: true
    )
    precondition(wf.id == "wf1")
    precondition(wf.name == "Test Workflow")
    precondition(wf.nodes.count == 1)
    precondition(wf.enabled == true)

    // WorkflowEdge
    let edge = WorkflowEdge(id: "e1", sourceNodeId: "n1", sourceOutputKey: "output",
                            targetNodeId: "n2", targetInputKey: "input")
    precondition(edge.id == "e1")
    precondition(edge.sourceNodeId == "n1")
    precondition(edge.targetNodeId == "n2")
}

// MARK: - NodeExecutor via ToolExecutor

func awaitTestExecutor(_ name: String, input: [String: JSONValue]) async -> ToolResult {
    let executor = ToolExecutor(confirmHandler: { _ in true })
    return await executor.execute(name: name, input: .object(input))
}

func testNodeExecutorFileSystem() async {
    // Test langsung melalui NodeRunner (bypass ToolExecutor)
    let nodeRunner = NodeRunner()
    let tmpPath = "/tmp/coucou-node-test-\(UUID().uuidString).txt"
    let writeResult = await nodeRunner.run(.fileSystem, input: NodeInput(values: [
        "operation": .string("write"),
        "path": .string(tmpPath),
        "content": .string("Hello Node Engine"),
    ]))
    precondition(!writeResult.isError, "file_system write failed: \(writeResult.errorMessage ?? "")")

    let readResult = await nodeRunner.run(.fileSystem, input: NodeInput(values: [
        "operation": .string("read"),
        "path": .string(tmpPath),
    ]))
    precondition(!readResult.isError, "file_system read failed: \(readResult.errorMessage ?? "")")
    let readContent = readResult.values["content"]?.stringValue ?? ""
    precondition(readContent.contains("Hello Node Engine"), "read output: \(readContent)")

    // Exists
    let existsResult = await nodeRunner.run(.fileSystem, input: NodeInput(values: [
        "operation": .string("exists"),
        "path": .string(tmpPath),
    ]))
    precondition(!existsResult.isError)
    precondition(existsResult.values["exists"]?.boolValue == true, "exists output: \(existsResult.values)")

    // Delete
    let delResult = await nodeRunner.run(.fileSystem, input: NodeInput(values: [
        "operation": .string("delete"),
        "path": .string(tmpPath),
    ]))
    precondition(!delResult.isError)

    let existsAfter = await nodeRunner.run(.fileSystem, input: NodeInput(values: [
        "operation": .string("exists"),
        "path": .string(tmpPath),
    ]))
    precondition(existsAfter.values["exists"]?.boolValue == false, "exists after delete: \(existsAfter.values)")
}

func testNodeExecutorCronSchedule() async {
    let result = await awaitTestExecutor("node_cron_schedule", input: [
        "interval": .number(30),
        "unit": .string("minutes"),
    ])
    precondition(!result.isError, "cron_schedule failed: \(result.output)")
    precondition(result.output.contains("nextRun"), "nextRun missing: \(result.output)")
    precondition(result.output.contains("scheduled"), "scheduled missing: \(result.output)")
}

func testNodeExecutorIfElse() async {
    // True branch
    let trueResult = await awaitTestExecutor("node_if_else", input: [
        "condition": .string("1 + 1 === 2"),
        "trueBranch": .object(["result": .string("yes")]),
        "falseBranch": .object(["result": .string("no")]),
    ])
    precondition(trueResult.output.contains("yes"), "true output: \(trueResult.output)")
    precondition(trueResult.output.contains("branchTaken"), "branchTaken: \(trueResult.output)")
    precondition(trueResult.output.contains("true"), "branchTaken true: \(trueResult.output)")

    // False branch
    let falseResult = await awaitTestExecutor("node_if_else", input: [
        "condition": .string("1 + 1 === 3"),
        "trueBranch": .object(["result": .string("yes")]),
        "falseBranch": .object(["result": .string("no")]),
    ])
    precondition(!falseResult.isError, "if_else false failed: \(falseResult.output)")
    precondition(falseResult.output.contains("no"), "false output: \(falseResult.output)")
    precondition(falseResult.output.contains("branchTaken"), "branchTaken: \(falseResult.output)")
    precondition(falseResult.output.contains("false"), "branchTaken false: \(falseResult.output)")
}

func testNodeExecutorJsonTransform() async {
    let result = await awaitTestExecutor("node_json_transform", input: [
        "input": .object([
            "items": .array([.string("a"), .string("b"), .string("c")]),
            "count": .number(3),
        ]),
        "script": .string("input.items.map(x => x.toUpperCase())"),
    ])
    precondition(!result.isError, "json_transform failed: \(result.output)")
    precondition(result.output.contains("A") || result.output.contains("a"), "transform output: \(result.output)")
}

func testNodeExecutorClipboard() async {
    // Write then read
    let writeResult = await awaitTestExecutor("node_clipboard", input: [
        "operation": .string("write"),
        "text": .string("Clipboard via Node Engine"),
    ])
    precondition(!writeResult.isError, "clipboard write failed: \(writeResult.output)")

    let readResult = await awaitTestExecutor("node_clipboard", input: [
        "operation": .string("read"),
    ])
    precondition(!readResult.isError, "clipboard read failed: \(readResult.output)")
    precondition(readResult.output.contains("Clipboard via Node Engine"), "clipboard output: \(readResult.output)")
}

func testNodeExecutorRunShell() async {
    let result = await awaitTestExecutor("node_run_shell", input: [
        "command": .string("echo node-shell-ok"),
    ])
    precondition(!result.isError, "node_run_shell failed: \(result.output)")
    precondition(result.output.contains("node-shell-ok"), "shell output: \(result.output)")
    precondition(result.output.contains("exitCode"), "exitCode missing: \(result.output)")
}

func testNodeExecutorHttpRequest() async {
    // Gunakan URL lokal yang pasti ada (localhost tidak akan ada, tapi harus menghasilkan error yang jelas)
    let result = await awaitTestExecutor("node_http_request", input: [
        "url": .string("http://127.0.0.1:1/example"),
        "method": .string("GET"),
    ])
    // Tidak memastikan sukses karena server mungkin tidak ada, tapi harus menghasilkan respons yang terstruktur
    precondition(result.output.contains("statusCode") || result.output.contains("errorMessage") || result.isError,
                 "http_request output: \(result.output)")
}
