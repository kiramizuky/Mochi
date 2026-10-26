import Foundation

// MARK: - Dynamic Tool & Skill Models (Pilar C: Metacognitive Tool Maker)

/// Bahasa pemrograman yang didukung untuk sintesis alat baru on-the-fly.
public enum DynamicToolLanguage: String, Codable, Sendable, CaseIterable {
    case bash       = "bash"
    case python     = "python"
    case swift      = "swift"
    case javascript = "javascript"

    public var fileExtension: String {
        switch self {
        case .bash: return "sh"
        case .python: return "py"
        case .swift: return "swift"
        case .javascript: return "js"
        }
    }

    public var displayName: String {
        switch self {
        case .bash: return "Shell Script (Zsh/Bash)"
        case .python: return "Python 3"
        case .swift: return "Native Swift"
        case .javascript: return "JavaScript (Node/JSC)"
        }
    }
}

/// Definisi alat baru yang diciptakan dan dikompilasi sendiri oleh AI Assistant.
public enum DynamicToolError: LocalizedError, Sendable, Equatable {
    case securityViolation(String)
    case invalidDefinition(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .securityViolation(let msg): return msg
        case .invalidDefinition(let msg): return msg
        case .executionFailed(let msg): return msg
        }
    }
}

public struct DynamicTool: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var language: DynamicToolLanguage
    public var scriptSource: String
    public var parameterNames: [String]
    public var isVerified: Bool
    public var executionCount: Int
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        description: String,
        language: DynamicToolLanguage,
        scriptSource: String,
        parameterNames: [String] = [],
        isVerified: Bool = false,
        executionCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.language = language
        self.scriptSource = scriptSource
        self.parameterNames = parameterNames
        self.isVerified = isVerified
        self.executionCount = executionCount
        self.createdAt = createdAt
    }

    /// Konversi ke LLMToolDef agar dapat langsung dikenali dan dipanggil oleh LLM Provider.
    func toLLMToolDef() -> LLMToolDef {
        var properties: [String: JSONValue] = [:]
        for param in parameterNames {
            properties[param] = .object([
                "type": .string("string"),
                "description": .string("Parameter '\(param)' untuk alat \(name)")
            ])
        }

        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(parameterNames.map { .string($0) })
        ])

        return LLMToolDef(
            name: id,
            description: "[Dynamic Tool] \(description) (Dibuat otomatis oleh Coucou Synthesizer)",
            inputSchema: schema
        )
    }
}

