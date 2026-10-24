import Foundation

// MARK: - MCP bridge — mengekspos alat Councou sebagai server MCP

/// Jembatan antara klien MCP eksternal (Claude Code, Cursor, IDE) dan eksekusi Coucou.
/// Setiap panggilan alat melewati ToolExecutor → PolicyEngine → AuditLog, jadi hard floor
/// dan konsent tetap berlaku untuk permintaan yang datang melalui MCP.
///
/// Handler yang bergantung pada AppState (notch.*, chat.*) didaftarkan di AppDelegate,
/// bukan di sini, agar MCPBridge tetap dapat diuji secara terisolasi tanpa seluruh graf App.
final class MCPBridge: @unchecked Sendable {
    private let mcpServer = MCPServer()
    private let executor: ToolExecutor
    private let health: HealthService
    private let memory: MemoryService
    private var serverTask: Task<Void, Never>?

    init(executor: ToolExecutor = ToolExecutor(),
         health: HealthService = .shared,
         memory: MemoryService = .shared) {
        self.executor = executor
        self.health = health
        self.memory = memory
        registerHandlers()
    }

    /// Server MCP yang dielola — dipakai AppDelegate untuk mendaftarkan handler tambahan
    /// (notch.*, chat.*) yang membutuhkan AppState.
    var server: MCPServer { mcpServer }

    // MARK: - Publish

    /// Mulai mendengarkan stdio (untuk dijalankan sebagai proses MCP server).
    func startStdio() async {
        serverTask = Task { await mcpServer.serveStdio() }
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
    }

    /// Dispatch satu metode — dipakai oleh uji.
    func dispatch(method: String, params: [String: JSONValue]? = nil) async throws -> JSONValue {
        try await mcpServer.handle(method: method, params: params)
    }

    // MARK: - Handler registration

    private func registerHandlers() {
        // --- tool.run: jalankan salah satu alat Coucou via ToolExecutor (policy + audit) ---
        mcpServer.register(name: "tool.run") { [weak self] params in
            guard let self,
                  let params,
                  case .string(let name) = params["name"] ?? .null else {
                throw MCPError.request("missing tool name")
            }
            let input = params["input"] ?? .object([:])
            let result = await self.executor.execute(name: name, input: input)
            return JSONValue.object([
                "output": .string(result.output),
                "isError": .bool(result.isError),
                "exitCode": result.exitCode.map { .number(Double($0)) } ?? .null,
            ])
        }

        // --- memory.save ---
        mcpServer.register(name: "memory.save") { [weak self] params in
            guard let self,
                  let params,
                  case .string(let text) = params["text"] ?? .null,
                  !text.isEmpty else {
                throw MCPError.request("missing text")
            }
            let isNew = try self.memory.remember(text)
            return .string(isNew ? "Remembered." : "Already remembered — refreshed.")
        }

        // --- memory.all ---
        mcpServer.register(name: "memory.all") { [weak self] _ in
            guard let self else { throw MCPError.request("bridge deallocated") }
            let entries = self.memory.all()
            return .array(entries.map { e in
                .object([
                    "id": .string(e.id),
                    "text": .string(e.text),
                    "updatedAt": .string(e.updatedAt.timeIntervalSince1970.description),
                ])
            })
        }

        // --- memory.forget ---
        mcpServer.register(name: "memory.forget") { [weak self] params in
            guard let self,
                  let params,
                  case .string(let id) = params["id"] ?? .null else {
                throw MCPError.request("missing id")
            }
            try self.memory.forget(id)
            return .string("forgotten")
        }

        // --- system.health ---
        mcpServer.register(name: "system.health") { [weak self] _ in
            guard let self else { throw MCPError.request("bridge deallocated") }
            let statuses = self.health.check()
            return .array(statuses.map { s in
                .object([
                    "id": .string(s.id),
                    "label": .string(s.label),
                    "ok": .bool(s.ok),
                    "detail": .string(s.detail),
                ])
            })
        }
    }
}
