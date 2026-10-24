import Foundation

// MARK: - MCP (Model Context Protocol) types

/// Konfigurasi server MCP — disimpan di UserDefaults (bukan Keychain: tidak ada rahasia di sini).
struct MCPServerConfig: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var transport: MCPTransport
    var enabled: Bool
}

enum MCPTransport: Sendable, Equatable, Codable {
    case stdio(command: String, args: [String])
    case http(url: URL)

    var description: String {
        switch self {
        case .stdio(let command, _): return "stdio: \(command)"
        case .http(let url): return "http: \(url.absoluteString)"
        }
    }
}

enum MCPError: Error, Equatable, CustomStringConvertible {
    case parse(String)
    case request(String)
    case timeout
    case notInitialized
    case toolNotFound(String)
    case connection(String)

    var description: String {
        switch self {
        case .parse(let m): return "Parse error: \(m)"
        case .request(let m): return "Request error: \(m)"
        case .timeout: return "Request timed out"
        case .notInitialized: return "MCP server not initialized"
        case .toolNotFound(let n): return "Tool not found: \(n)"
        case .connection(let m): return "Connection error: \(m)"
        }
    }
}

struct MCPTool: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var description: String?
    var inputSchema: JSONValue?
}

enum MCPContent: Equatable {
    case text(String)
}

struct MCPCallToolResult: Equatable {
    var content: [MCPContent]
    var isError: Bool
}

// MARK: - JSON-RPC 2.0 klien untuk server MCP

/// Klien MCP Foundation-only: JSON-RPC 2.0 over stdio (server lokal) atau HTTP (server remote).
/// Setiap permintaan melewati timeout 30 s. Tidak ada dependensi pihak ketiga.
final class MCPClient: @unchecked Sendable {
    private let transport: MCPTransport

    // Stdio
    private var process: Process?
    private var stdin: FileHandle?
    private var stdioBuffer = Data()
    private var stdoutTask: Task<Void, Never>?

    // HTTP
    private var session: URLSession?

    // Request tracking (guardian oleh lockQueue agar aman di antar konteks async).
    private let lockQueue = DispatchQueue(label: "mcp.client")
    private var nextRequestId: Int = 1
    private var pending: [Int: UnsafeContinuation<JSONValue, Error>] = [:]

    private(set) var initialized = false

    init(transport: MCPTransport) {
        self.transport = transport
    }

    deinit { close() }

    // MARK: - Lifecycle

    /// Mulai koneksi dan jalankan `initialize`. Harus dipanggil sebelum listTools / callTool.
    func start() async throws {
        switch transport {
        case .stdio(let command, let args):
            try startStdio(command: command, args: args)
        case .http:
            session = URLSession(configuration: .default)
        }
        _ = try await initialize()
    }

    private func startStdio(command: String, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()

        self.process = process
        self.stdin = inputPipe.fileHandleForWriting

        let stream = AsyncStream<String> { [weak self] continuation in
            guard let self else { continuation.finish(); return }
            let handle = outputPipe.fileHandleForReading
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty {
                    h.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                self.stdioBuffer.append(data)
                while let nl = self.stdioBuffer.range(of: Data([0x0A])) {
                    let lineData = self.stdioBuffer.subdata(in: self.stdioBuffer.startIndex..<nl.lowerBound)
                    self.stdioBuffer.removeSubrange(self.stdioBuffer.startIndex..<nl.upperBound)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        continuation.yield(line)
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                handle.readabilityHandler = nil
            }
        }

        stdoutTask = Task {
            for await line in stream {
                handleIncoming(line: line)
            }
        }
    }

    private func closeStdio() {
        stdin?.closeFile()
        stdin = nil
        process?.terminate()
        process = nil
        stdoutTask?.cancel()
        stdoutTask = nil
    }

    // MARK: - Requests

    private func nextId() -> Int {
        lockQueue.sync {
            let id = nextRequestId
            nextRequestId += 1
            return id
        }
    }

    private func sendRaw(_ method: String, id: Int, params: [String: JSONValue]?) {
        var body: [String: JSONValue] = ["method": .string(method), "id": .number(Double(id))]
        if let params { body["params"] = .object(params) }
        var frame: [String: Any] = body.mapValues { $0.anyValue }
        frame["jsonrpc"] = "2.0"
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let handle = stdin else { return }
        var out = data
        out.append(0x0A)
        try? handle.write(contentsOf: out)
    }

    private func httpRequest(method: String, params: [String: JSONValue]? = nil) async throws -> JSONValue {
        guard let session,
              case .http(let url) = transport else {
            throw MCPError.connection("no HTTP session")
        }
        let id = nextId()
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let params { body["params"] = params.mapValues { $0.anyValue } }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPError.connection("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.parse("invalid HTTP response")
        }
        return try parseResponse(id: id, dict: json)
    }

    private func request(method: String, params: [String: JSONValue]? = nil) async throws -> JSONValue {
        switch transport {
        case .http:
            return try await httpRequest(method: method, params: params)
        case .stdio:
            return try await stdioRequest(method: method, params: params)
        }
    }

    private func stdioRequest(method: String, params: [String: JSONValue]? = nil) async throws -> JSONValue {
        guard stdin != nil else { throw MCPError.connection("stdio not open") }
        let id = nextId()
        return try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<JSONValue, Error>) in
            lockQueue.sync {
                pending[id] = continuation
            }

            sendRaw(method, id: id, params: params)

            // Timeout 30 s
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.lockQueue.sync {
                    if self?.pending.removeValue(forKey: id) != nil {
                        continuation.resume(throwing: MCPError.timeout)
                    }
                }
            }
        }
    }

    private func handleIncoming(line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else { return } // notifikasi diabaikan

        let cont: UnsafeContinuation<JSONValue, Error>? = lockQueue.sync {
            pending.removeValue(forKey: id)
        }
        guard let cont else { return }

        if let error = json["error"] as? [String: Any] {
            let msg = (error["message"] as? String) ?? "unknown"
            cont.resume(throwing: MCPError.request(msg))
        } else if let result = json["result"] {
            cont.resume(returning: JSONValue(any: result))
        } else {
            cont.resume(throwing: MCPError.parse("no result or error"))
        }
    }

    private func parseResponse(id: Int, dict: [String: Any]) throws -> JSONValue {
        if let error = dict["error"] as? [String: Any] {
            let msg = (error["message"] as? String) ?? "unknown"
            throw MCPError.request(msg)
        }
        guard let result = dict["result"] else {
            throw MCPError.parse("no result or error")
        }
        return JSONValue(any: result)
    }

    // MARK: - MCP protocol

    /// Handshake dengan server. Dipanggil otomatis oleh start().
    func initialize() async throws {
        let _ = try await request(method: "initialize", params: [
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("Coucou"),
                "version": .string("1.0.0"),
            ]),
        ])
        // Kirim notification `initialized` (tidak menunggu respons)
        let frame: [String: Any] = ["jsonrpc": "2.0", "method": "initialized", "params": [:]]
        if case .stdio = transport {
            guard let data = try? JSONSerialization.data(withJSONObject: frame),
                  let handle = stdin else { return }
            var out = data
            out.append(0x0A)
            try? handle.write(contentsOf: out)
        }
        initialized = true
    }

    /// Daftar alat yang disediakan server.
    func listTools() async throws -> [MCPTool] {
        guard initialized else { throw MCPError.notInitialized }
        let result = try await request(method: "tools/list")
        guard case .object(let dict) = result,
              case .array(let tools) = dict["tools"] ?? .null else { return [] }
        return tools.compactMap { v in
            guard case .object(let o) = v,
                  case .string(let name) = o["name"] ?? .null else { return nil }
            return MCPTool(
                name: name,
                description: o["description"]?.stringValue,
                inputSchema: o["inputSchema"]
            )
        }
    }

    /// Panggil alat pada server.
    func callTool(name: String, arguments: JSONValue? = nil) async throws -> MCPCallToolResult {
        guard initialized else { throw MCPError.notInitialized }
        var params: [String: JSONValue] = ["name": .string(name)]
        if let arguments { params["arguments"] = arguments }
        let result = try await request(method: "tools/call", params: params)
        return MCPCallToolResult(from: result)
    }

    func close() {
        closeStdio()
        session = nil
        let conts: [UnsafeContinuation<JSONValue, Error>] = lockQueue.sync {
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for cont in conts {
            cont.resume(throwing: MCPError.connection("client closed"))
        }
    }
}

// MARK: - Result parsing

extension MCPCallToolResult {
    init(from result: JSONValue) {
        var content: [MCPContent] = []
        var isError = false
        if case .object(let dict) = result {
            if case .bool(let e) = dict["isError"] ?? .null { isError = e }
            if case .array(let arr) = dict["content"] ?? .null {
                for item in arr {
                    if case .object(let o) = item,
                       case .string(let kind) = o["type"] ?? .null, kind == "text",
                       case .string(let text) = o["text"] ?? .null {
                        content.append(.text(text))
                    }
                }
            }
        }
        self.content = content
        self.isError = isError
    }
}
