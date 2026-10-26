import Foundation

// MARK: - Dynamic Tool Synthesizer (Pilar C: Metacognitive Tool Maker)

/// Manajer penciptaan, penyimpanan, dan penyediaan alat dinamis berbasis JIT.
public final class DynamicToolSynthesizer: @unchecked Sendable {
    public static let shared = DynamicToolSynthesizer()

    private let lock = NSLock()
    private var tools: [String: DynamicTool] = [:]

    private func normalizeId(_ id: String) -> String {
        id.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
    }

    private var storageDir: URL {
        if let custom = ProcessInfo.processInfo.environment["COUCOU_DYNAMIC_TOOLS_DIR"] {
            return URL(fileURLWithPath: custom)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let base = appSupport.appendingPathComponent("NotchBuddy/dynamic_tools", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            } catch {
                return FileManager.default.temporaryDirectory.appendingPathComponent("coucou_dynamic_tools", isDirectory: true)
            }
        }
        return base
    }

    private init() {
        loadStoredTools()
    }

    // MARK: - Storage Management

    private func loadStoredTools() {
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
                let files = try FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil)
                for file in files where file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file),
                          let tool = try? JSONDecoder().decode(DynamicTool.self, from: data) else {
                        continue
                    }
                    tools[tool.id] = tool
                }
            } catch {
                // Folder belum ada atau kosong — inisialisasi normal
            }
        }
    }

    private func saveToolToDisk(_ tool: DynamicTool) {
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            let file = storageDir.appendingPathComponent("\(tool.id).json")
            let data = try JSONEncoder().encode(tool)
            try data.write(to: file, options: .atomic)
        } catch {
            print("⚠️ Gagal menyimpan dynamic tool \(tool.id): \(error.localizedDescription)")
        }
    }

    // MARK: - Synthesis & Execution

    /// Daftarkan atau buat alat baru on-the-fly.
    public func registerTool(
        id: String,
        name: String,
        description: String,
        language: DynamicToolLanguage,
        scriptSource: String,
        parameterNames: [String] = []
    ) -> Result<DynamicTool, DynamicToolError> {
        let cleanId = id.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        guard !cleanId.isEmpty else {
            return .failure(.invalidDefinition("ID alat tidak boleh kosong."))
        }

        // Validasi keamanan via sandbox guardrail
        let safety = DynamicSkillSandbox.shared.validateSafety(scriptSource: scriptSource, language: language)
        if case .failure(let err) = safety {
            return .failure(err)
        }

        let newTool = DynamicTool(
            id: cleanId,
            name: name,
            description: description,
            language: language,
            scriptSource: scriptSource,
            parameterNames: parameterNames,
            isVerified: true,
            executionCount: 0,
            createdAt: Date()
        )

        lock.withLock {
            tools[cleanId] = newTool
        }
        saveToolToDisk(newTool)

        return .success(newTool)
    }

    /// Eksekusi alat dinamis berdasarkan ID.
    func executeTool(id: String, arguments: [String: String]) async -> ToolResult {
        let cleanId = normalizeId(id)
        guard let tool = getTool(id: cleanId) else {
            return ToolResult(output: "Dynamic tool '\(id)' tidak ditemukan.", isError: true, exitCode: 1)
        }

        let result = await DynamicSkillSandbox.shared.execute(tool: tool, arguments: arguments)

        if !result.isError {
            lock.withLock {
                var updated = tool
                updated.executionCount += 1
                tools[cleanId] = updated
                saveToolToDisk(updated)
            }
        }

        return result
    }

    /// Mengambil tool berdasarkan ID.
    public func getTool(id: String) -> DynamicTool? {
        let cleanId = normalizeId(id)
        return lock.withLock { tools[cleanId] }
    }

    /// Mengembalikan semua dynamic tools yang terdaftar.
    public var allTools: [DynamicTool] {
        lock.withLock { Array(tools.values.sorted { $0.createdAt > $1.createdAt }) }
    }

    /// Mengembalikan LLMToolDef untuk semua dynamic tools agar bisa langsung dipanggil oleh LLM.
    var llmToolDefs: [LLMToolDef] {
        allTools.map { $0.toLLMToolDef() }
    }

    /// Hapus dynamic tool.
    public func removeTool(id: String) -> Bool {
        let cleanId = normalizeId(id)
        return lock.withLock {
            guard tools.removeValue(forKey: cleanId) != nil else { return false }
            let file = storageDir.appendingPathComponent("\(cleanId).json")
            try? FileManager.default.removeItem(at: file)
            return true
        }
    }
}

