import Foundation

// MARK: - Multi-Key item

/// Satu entri API Key dalam pool multi-key.
struct AIKeyItem: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var providerId: String // "anthropic", "openai", "gemini", dll
    var label: String
    var isEnabled: Bool
    var failureCount: Int
    var lastUsed: Date?
    var cooldownUntil: Date?

    var isAvailable: Bool {
        guard isEnabled else { return false }
        if let cooldownUntil {
            return Date() >= cooldownUntil
        }
        return true
    }
}

extension Notification.Name {
    static let aiKeysChanged = Notification.Name("aiKeysChanged")
}

// MARK: - Provider registry with Multi-Key Pool

/// Registry of LLM providers + persisted active provider + Multi-Key Pool manager.
/// Thread-safe; supports auto-switching, parallel round-robin, and rate-limit cooldown.
final class ProviderRegistry: @unchecked Sendable {
    static let shared = ProviderRegistry()

    static let defaultProviderId = "anthropic"
    private static let providerDefaultsKey = "activeProviderId"
    private static let keyPoolDefaultsKey = "aiKeyPoolItems"

    private let lock = NSLock()
    private var providers: [any LLMProvider] = []
    private var keyPool: [AIKeyItem] = []
    private var roundRobinIndex: [String: Int] = [:]

    private init() {
        self.keyPool = Self.loadKeyPool()

        register(AnthropicProvider(keyProvider: { [weak self] in
            self?.key(for: "anthropic")
        }))
        register(OpenAIProvider(keyProvider: { [weak self] in
            self?.key(for: "openai")
        }))
        register(GeminiProvider(keyProvider: { [weak self] in
            self?.key(for: "gemini")
        }))
        register(GroqProvider(keyProvider: { [weak self] in
            self?.key(for: "groq")
        }))
        register(LocalSLMProvider())

        migrateLegacyKeysIfNeeded()
    }

    // MARK: - Provider registration

    func register(_ provider: any LLMProvider) {
        lock.withLock {
            providers.removeAll { $0.id == provider.id }
            providers.append(provider)
        }
    }

    var available: [any LLMProvider] { lock.withLock { providers } }

    var activeProviderId: String {
        lock.withLock {
            let stored = UserDefaults.standard.string(forKey: Self.providerDefaultsKey) ?? Self.defaultProviderId
            return providers.contains { $0.id == stored } ? stored : Self.defaultProviderId
        }
    }

    var activeProvider: any LLMProvider {
        let id = activeProviderId
        if let match = lock.withLock({ providers.first { $0.id == id } }) { return match }
        return lock.withLock { providers.first } ?? AnthropicProvider(keyProvider: { nil })
    }

    func provider(id: String) -> (any LLMProvider)? {
        lock.withLock { providers.first { $0.id == id } }
    }

    func setActiveProvider(id: String) {
        lock.withLock {
            guard providers.contains(where: { $0.id == id }) else { return }
            UserDefaults.standard.set(id, forKey: Self.providerDefaultsKey)
        }
    }

    // MARK: - Multi-Key Pool Management

    /// Mengambil semua key untuk provider tertentu.
    func keys(for providerId: String) -> [AIKeyItem] {
        lock.withLock {
            keyPool.filter { $0.providerId == providerId }
        }
    }

    /// Menambahkan key baru ke dalam pool.
    @discardableResult
    func addKey(providerId: String, label: String, secret: String) -> AIKeyItem {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = trimmedLabel.isEmpty ? "Key \(keys(for: providerId).count + 1)" : trimmedLabel

        let item = AIKeyItem(
            id: UUID().uuidString,
            providerId: providerId,
            label: cleanLabel,
            isEnabled: true,
            failureCount: 0,
            lastUsed: nil,
            cooldownUntil: nil
        )

        // Simpan rahasia di Keychain
        KeychainStore.shared.set("ai-key-\(item.id)", value: trimmedSecret)
        // Simpan juga sebagai legacy key jika ini key pertama
        if KeychainStore.shared.get("\(providerId)-api-key") == nil {
            KeychainStore.shared.set("\(providerId)-api-key", value: trimmedSecret)
        }

        lock.withLock {
            keyPool.append(item)
            Self.saveKeyPool(keyPool)
        }

        NotificationCenter.default.post(name: .aiKeysChanged, object: nil)
        return item
    }

    /// Menghapus key dari pool dan Keychain.
    func removeKey(id: String) {
        lock.withLock {
            keyPool.removeAll { $0.id == id }
            Self.saveKeyPool(keyPool)
        }
        KeychainStore.shared.remove("ai-key-\(id)")
        NotificationCenter.default.post(name: .aiKeysChanged, object: nil)
    }

    /// Mengaktifkan atau menonaktifkan key tertentu.
    func setKeyEnabled(id: String, enabled: Bool) {
        lock.withLock {
            guard let idx = keyPool.firstIndex(where: { $0.id == id }) else { return }
            keyPool[idx].isEnabled = enabled
            Self.saveKeyPool(keyPool)
        }
        NotificationCenter.default.post(name: .aiKeysChanged, object: nil)
    }

    /// Mendapatkan key aktif untuk provider dengan rotasi cerdas (auto-switch & round-robin).
    func key(for providerId: String) -> String? {
        lock.withLock {
            let matching = keyPool.filter { $0.providerId == providerId }

            // 1. Coba ambil dari pool yang aktif dan tidak dalam masa cooldown
            let available = matching.filter { $0.isAvailable }
            if !available.isEmpty {
                let idx = roundRobinIndex[providerId, default: 0] % available.count
                roundRobinIndex[providerId] = idx + 1
                var selected = available[idx]
                selected.lastUsed = Date()
                if let mainIdx = keyPool.firstIndex(where: { $0.id == selected.id }) {
                    keyPool[mainIdx] = selected
                    Self.saveKeyPool(keyPool)
                }
                if let secret = KeychainStore.shared.get("ai-key-\(selected.id)"), !secret.isEmpty {
                    return secret
                }
            }

            // 2. Jika semua dalam masa cooldown, gunakan key yang diaktifkan sebagai upaya terakhir
            let anyEnabled = matching.filter { $0.isEnabled }
            if let fallback = anyEnabled.first,
               let secret = KeychainStore.shared.get("ai-key-\(fallback.id)"), !secret.isEmpty {
                return secret
            }

            // 3. Fallback ke legacy key jika pool kosong
            return KeychainStore.shared.get("\(providerId)-api-key")
        }
    }

    /// Laporkan kegagalan key (misal 429 Rate Limit) untuk auto-switch ke key berikutnya.
    func reportFailure(providerId: String, keySecret: String? = nil, isRateLimit: Bool = true) {
        lock.withLock {
            let now = Date()
            let cooldownSeconds: TimeInterval = isRateLimit ? 60 : 15

            // Cari key yang cocok atau key yang paling baru digunakan
            let matchingIndices = keyPool.indices.filter { keyPool[$0].providerId == providerId && keyPool[$0].isEnabled }
            if let targetIdx = matchingIndices.first(where: { idx in
                if let keySecret, let sec = KeychainStore.shared.get("ai-key-\(keyPool[idx].id)"), sec == keySecret {
                    return true
                }
                return false
            }) ?? matchingIndices.sorted(by: { (keyPool[$0].lastUsed ?? .distantPast) > (keyPool[$1].lastUsed ?? .distantPast) }).first {
                keyPool[targetIdx].failureCount += 1
                keyPool[targetIdx].cooldownUntil = now.addingTimeInterval(cooldownSeconds)
                Self.saveKeyPool(keyPool)
            }
        }
        NotificationCenter.default.post(name: .aiKeysChanged, object: nil)
    }

    /// Laporkan kesuksesan penggunaan key.
    func reportSuccess(providerId: String, keySecret: String? = nil) {
        lock.withLock {
            let matchingIndices = keyPool.indices.filter { keyPool[$0].providerId == providerId }
            if let targetIdx = matchingIndices.first(where: { idx in
                if let keySecret, let sec = KeychainStore.shared.get("ai-key-\(keyPool[idx].id)"), sec == keySecret {
                    return true
                }
                return false
            }) {
                keyPool[targetIdx].failureCount = 0
                keyPool[targetIdx].cooldownUntil = nil
                Self.saveKeyPool(keyPool)
            }
        }
    }

    // MARK: - Internal Storage & Migration

    private static func loadKeyPool() -> [AIKeyItem] {
        guard let data = UserDefaults.standard.data(forKey: keyPoolDefaultsKey),
              let items = try? JSONDecoder().decode([AIKeyItem].self, from: data) else {
            return []
        }
        return items
    }

    private static func saveKeyPool(_ items: [AIKeyItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: keyPoolDefaultsKey)
        }
    }

    private func migrateLegacyKeysIfNeeded() {
        for providerId in ["anthropic", "openai", "gemini", "groq"] {
            let existing = keys(for: providerId)
            if existing.isEmpty,
               let legacyKey = KeychainStore.shared.get("\(providerId)-api-key"),
               !legacyKey.isEmpty {
                addKey(providerId: providerId, label: "Primary Key", secret: legacyKey)
            }
        }
    }
}
