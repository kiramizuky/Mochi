import Foundation

// MARK: - MCP server (generic JSON-RPC 2.0 over stdio)

/// Handler tipe untuk satu alat MCP. Menerima params (bisa nil), mengembalikan JSONValue.
typealias MCPServerHandler = ([String: JSONValue]?) async throws -> JSONValue

/// Server MCP generik Foundation-only: JSON-RPC 2.0 over stdio.
/// Cocok untuk diekspos kepada agen eksternal (Claude Code, Cursor, IDE) melalui stdio.
final class MCPServer: @unchecked Sendable {
    private let lockQueue = DispatchQueue(label: "mcp.server")
    private var handlers: [String: MCPServerHandler] = [:]
    private var serveTask: Task<Void, Never>?

    /// Daftarkan handler untuk satu metode (mis. "tools/list", "tool.run").
    func register(name: String, handler: @escaping MCPServerHandler) {
        lockQueue.sync {
            handlers[name] = handler
        }
    }

    /// Hapus handler.
    func unregister(name: String) {
        _ = lockQueue.sync {
            handlers.removeValue(forKey: name)
        }
    }

    /// Tangani satu permintaan JSON-RPC 2.0 (dipakai baik serveStdio maupun uji).
    func handle(method: String, params: [String: JSONValue]? = nil) async throws -> JSONValue {
        let handler: MCPServerHandler? = lockQueue.sync {
            handlers[method]
        }
        guard let handler else {
            throw MCPError.request("Method not found: \(method)")
        }
        return try await handler(params)
    }

    /// Jalankan server stdio: baca baris dari stdin, tulis respons JSON-RPC ke stdout.
    /// Berjalan sampai stdin ditutup atau Task dibatalkan.
    func serveStdio() async {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        var buffer = [UInt8]()
        do {
            for try await byte in stdin.bytes {
                buffer.append(byte)
                if byte == 0x0A {
                    let line = String(bytes: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    buffer.removeAll()
                    if line.isEmpty { continue }
                    let response = await handleLine(line: line)
                    if let data = try? JSONSerialization.data(withJSONObject: response) {
                        var out = data
                        out.append(0x0A)
                        try? stdout.write(contentsOf: out)
                    }
                }
            }
        } catch {
            // Stream berakhir — biarkan serveStdio selesai.
        }
    }

    // MARK: - Internal

    private func handleLine(line: String) async -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return errorResponse(id: nil, code: -32700, message: "Parse error")
        }
        let id = json["id"] as Any
        let method = (json["method"] as? String) ?? ""
        let rawParams = json["params"] as? [String: Any]
        let params: [String: JSONValue]? = rawParams?.mapValues(JSONValue.init(any:))

        do {
            let result = try await handle(method: method, params: params)
            return ["jsonrpc": "2.0", "id": id, "result": result.anyValue]
        } catch let error as MCPError {
            return errorResponse(id: id, code: -32603, message: error.description)
        } catch {
            return errorResponse(id: id, code: -32603, message: error.localizedDescription)
        }
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}
