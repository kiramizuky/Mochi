import Foundation
import NaturalLanguage

// MARK: - Local Vector Database for User Preferences & Long-term Semantic Recall

public struct VectorMemoryItem: Codable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var category: String  // e.g. "preference", "rule", "project", "style", "personal"
    public var vector: [Double]
    public var metadata: [String: String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                text: String,
                category: String = "preference",
                vector: [Double] = [],
                metadata: [String: String] = [:],
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.category = category
        self.vector = vector
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct VectorSearchResult: Sendable {
    public var item: VectorMemoryItem
    public var score: Double
}

public final class VectorMemoryStore: @unchecked Sendable {
    public static let shared = VectorMemoryStore()

    private let fileURL: URL
    private let lock = NSLock()
    private var items: [VectorMemoryItem] = []
    private let sentenceEmbedding: NLEmbedding?

    public init(fileURL: URL? = nil) {
        if let custom = fileURL {
            self.fileURL = custom
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("NotchBuddy", isDirectory: true)
                .appendingPathComponent("vector_memory.json")
        }

        // Siapkan on-device embedding jika tersedia di macOS
        self.sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)

        load()
    }

    // MARK: - Embedding Generation (Hybrid NLEmbedding + Character/Word Token Vector)

    /// Menghasilkan representasi vektor densitas tinggi untuk teks (hybrid).
    public func embed(_ text: String) -> [Double] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return [] }

        // Jika NLEmbedding menghasilkan vektor, gunakan vektor Apple
        if let nl = sentenceEmbedding, let vec = nl.vector(for: cleaned) {
            return vec
        }

        // Fallback: Token-based deterministic vector (128 dimensi) untuk multi-bahasa (ID/EN)
        return generateSparseHashVector(cleaned, dimensions: 128)
    }

    private func generateSparseHashVector(_ text: String, dimensions: Int) -> [Double] {
        var vector = Array(repeating: 0.0, count: dimensions)
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }

        for (idx, token) in tokens.enumerated() {
            var hash = 5381
            for byte in token.utf8 {
                hash = ((hash << 5) &+ hash) &+ Int(byte)
            }
            let bucket = abs(hash) % dimensions
            let weight = 1.0 + (1.0 / Double(idx + 1))
            vector[bucket] += weight
        }

        // Normalisasi L2 norm
        let norm = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        if norm > 0.00001 {
            return vector.map { $0 / norm }
        }
        return vector
    }

    // MARK: - Operations

    /// Simpan atau perbarui preferensi personal pengguna.
    @discardableResult
    public func savePreference(text: String, category: String = "preference", metadata: [String: String] = [:]) -> VectorMemoryItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let vector = embed(trimmed)

        lock.lock()
        defer { lock.unlock() }

        // Jika teks sudah ada (case-insensitive), update
        if let index = items.firstIndex(where: { $0.text.lowercased() == trimmed.lowercased() }) {
            var existing = items[index]
            existing.category = category
            existing.vector = vector
            existing.metadata = metadata
            existing.updatedAt = Date()
            items[index] = existing
            persistLocked()
            return existing
        }

        let item = VectorMemoryItem(
            text: trimmed,
            category: category,
            vector: vector,
            metadata: metadata
        )
        items.insert(item, at: 0)
        persistLocked()
        return item
    }

    /// Cari memori dan preferensi personal yang paling relevan dengan query semantik.
    public func search(query: String, topK: Int = 5, minScore: Double = 0.15) -> [VectorSearchResult] {
        let queryVector = embed(query)
        let qTokens = Set(query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })

        lock.lock()
        let snapshot = items
        lock.unlock()

        var results: [VectorSearchResult] = []

        for item in snapshot {
            var score = 0.0

            // 1. Cosine similarity
            if !queryVector.isEmpty && !item.vector.isEmpty && queryVector.count == item.vector.count {
                var dot = 0.0
                for i in 0..<queryVector.count {
                    dot += queryVector[i] * item.vector[i]
                }
                score = dot
            }

            // 2. Token overlap boost untuk kecocokan kata persis
            let itemTokens = Set(item.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
            let overlap = qTokens.intersection(itemTokens).count
            if !qTokens.isEmpty {
                let tokenRatio = Double(overlap) / Double(qTokens.count)
                score = max(score, score * 0.5 + tokenRatio * 0.5)
                if overlap > 0 {
                    score += 0.2
                }
            }

            if score >= minScore {
                results.append(VectorSearchResult(item: item, score: score))
            }
        }

        results.sort { $0.score > $1.score }
        return Array(results.prefix(topK))
    }

    /// Menghasilkan ringkasan preferensi personal terformat untuk disuntikkan ke prompt asisten.
    public func preferenceDigest(query: String? = nil, maxItems: Int = 10) -> String {
        let matchedItems: [VectorMemoryItem]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            matchedItems = search(query: query, topK: maxItems).map(\.item)
        } else {
            lock.lock()
            matchedItems = Array(items.prefix(maxItems))
            lock.unlock()
        }

        guard !matchedItems.isEmpty else { return "" }

        var lines = ["User Personal Preferences & Long-term Memory:"]
        for m in matchedItems {
            lines.append("- [\(m.category)] \(m.text)")
        }
        return lines.joined(separator: "\n")
    }

    public func all() -> [VectorMemoryItem] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    public func delete(id: String) {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll { $0.id == id }
        persistLocked()
    }

    // MARK: - Persistence

    private func persistLocked() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Silently fail persistence in sandboxed/test env
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([VectorMemoryItem].self, from: data) else {
            return
        }
        self.items = decoded
    }
}
