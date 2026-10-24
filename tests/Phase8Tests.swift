import Foundation

// MARK: - Phase 8: MCP (Model Context Protocol)

@main enum Phase8Tests {
    static func main() async throws {
        testMCPTransportDescription()
        try await testMCPServerUnknownMethod()
        try await testMCPServerToolsList()
        try await testMCPBridgeMemory()
        try await testMCPBridgeSystemHealth()
        try await testMCPBridgeUnknownMethod()
        try await testMCPBridgeToolRunShell()
        print("Phase8Tests: all cases passed")
    }
}

// MARK: - Transport

func testMCPTransportDescription() {
    let stdio = MCPTransport.stdio(command: "/usr/bin/claude", args: [])
    precondition(stdio.description == "stdio: /usr/bin/claude", "got: \(stdio.description)")
    let http = MCPTransport.http(url: URL(string: "http://localhost:18765/mcp")!)
    precondition(http.description.hasPrefix("http: "), "got: \(http.description)")
}

// MARK: - Server

func testMCPServerUnknownMethod() async throws {
    let server = MCPServer()
    do {
        _ = try await server.handle(method: "mcp/notfound")
        preconditionFailure("expected method-not-found error")
    } catch {
        guard let e = error as? MCPError else {
            preconditionFailure("wrong error type: \(error)")
        }
        precondition(e.description.contains("Method not found"), "got: \(e)")
    }
}

func testMCPServerToolsList() async throws {
    let server = MCPServer()
    server.register(name: "tools/list") { _ in
        .object([
            "tools": .array([
                .object([
                    "name": .string("echo"),
                    "description": .string("echo something"),
                    "inputSchema": .object(["type": .string("object")]),
                ]),
            ]),
        ])
    }
    let result = try await server.handle(method: "tools/list")
    guard case .object(let dict) = result,
          case .array(let tools) = dict["tools"] ?? .null else {
        preconditionFailure("bad tools/list result: \(result)")
    }
    precondition(tools.count == 1, "expected 1 tool, got \(tools.count)")
    guard case .object(let first) = tools.first,
          case .string(let name) = first["name"] ?? .null else {
        preconditionFailure("bad tool entry")
    }
    precondition(name == "echo")
}

// MARK: - Bridge

func testMCPBridgeMemory() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-mcp-\(UUID().uuidString)", isDirectory: true)
    let memory = MemoryService(url: tmp.appendingPathComponent("memory.json"))
    let bridge = MCPBridge(executor: ToolExecutor(), health: HealthService.shared, memory: memory)

    let params: [String: JSONValue] = ["text": .string("MCP test fact")]
    let r1 = try await bridge.dispatch(method: "memory.save", params: params)
    guard case .string(let s) = r1 else { preconditionFailure("expected string, got \(r1)") }
    precondition(s == "Remembered.", "got: \(s)")

    // Idempotent re-save refreshes instead of duplicating.
    let r2 = try await bridge.dispatch(method: "memory.save", params: params)
    guard case .string(let s2) = r2 else { preconditionFailure("expected string, got \(r2)") }
    precondition(s2 == "Already remembered — refreshed.", "got: \(s2)")

    let all = try await bridge.dispatch(method: "memory.all")
    guard case .array(let arr) = all else { preconditionFailure("expected array, got \(all)") }
    precondition(arr.count == 1, "expected 1 fact, got \(arr.count)")

    guard case .object(let first) = arr.first,
          case .string(let id) = first["id"] ?? .null else {
        preconditionFailure("no id in fact")
    }
    _ = try await bridge.dispatch(method: "memory.forget", params: ["id": .string(id)])

    let all2 = try await bridge.dispatch(method: "memory.all")
    guard case .array(let arr2) = all2 else { preconditionFailure("expected array, got \(all2)") }
    precondition(arr2.count == 0, "expected 0 facts after forget, got \(arr2.count)")
}

func testMCPBridgeSystemHealth() async throws {
    let bridge = MCPBridge()
    let result = try await bridge.dispatch(method: "system.health")
    guard case .array(let arr) = result else { preconditionFailure("expected array, got \(result)") }
    precondition(arr.count == 5, "expected 5 statuses, got \(arr.count)")
    let ids = arr.compactMap { $0["id"]?.stringValue }
    for expected in ["api_key", "microphone", "accessibility", "screen_capture", "disk_space"] {
        precondition(ids.contains(expected), "missing status id: \(expected)")
    }
}

func testMCPBridgeUnknownMethod() async throws {
    let bridge = MCPBridge()
    do {
        _ = try await bridge.dispatch(method: "mcp/notreal")
        preconditionFailure("expected method-not-found error")
    } catch {
        guard let e = error as? MCPError else {
            preconditionFailure("wrong error type: \(error)")
        }
        precondition(e.description.contains("Method not found"), "got: \(e)")
    }
}

func testMCPBridgeToolRunShell() async throws {
    let bridge = MCPBridge(executor: ToolExecutor(confirmHandler: { _ in true }))
    let result = try await bridge.dispatch(method: "tool.run", params: [
        "name": .string("shell_run"),
        "input": .object(["command": .string("echo mcp-ok")]),
    ])
    guard case .object(let dict) = result else { preconditionFailure("expected object, got \(result)") }
    guard case .string(let output) = dict["output"] ?? .null else {
        preconditionFailure("expected output string, got \(dict["output"] as Any)")
    }
    precondition(output.contains("mcp-ok"), "output did not contain mcp-ok: \(output)")
    guard case .number(let code) = dict["exitCode"] ?? .null else {
        preconditionFailure("expected exitCode number, got \(dict["exitCode"] as Any)")
    }
    precondition(Int(code) == 0, "expected exit code 0, got \(code)")
}
