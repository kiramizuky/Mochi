import Foundation

// MARK: - Generic Integration Poller
// Polls any REST API endpoint on a timer. Configured via IntegrationPollConfig.
// Each integration has its own poller instance tracked by integration ID.
// All AppState access is done on MainActor to avoid concurrency issues.
final class GenericIntegrationPoller: @unchecked Sendable {
    static let shared = GenericIntegrationPoller()
    private var timers: [String: DispatchSourceTimer] = [:]
    private var lastValues: [String: String] = [:] // integrationId -> last value

    private init() {}

    func start(for config: IntegrationPollConfig) {
        guard timers[config.id] == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 3, repeating: config.pollInterval)
        t.setEventHandler { [weak self] in
            self?.poll(config: config)
        }
        t.resume()
        timers[config.id] = t
    }

    func stop(for id: String) {
        timers[id]?.cancel()
        timers[id] = nil
        lastValues.removeValue(forKey: id)
    }

    func stopAll() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        lastValues.removeAll()
    }

    private func poll(config: IntegrationPollConfig) {
        guard let url = URL(string: config.endpoint) else {
            integrationLog(config.id, "Invalid URL: \(config.endpoint)")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if let apiKey = KeychainStore.shared.get(config.apiKeyName) {
            req.setValue(apiKey, forHTTPHeaderField: config.apiKeyHeader)
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data else {
                self.integrationLog(config.id, "HTTP \(code) \(error?.localizedDescription ?? "no data")")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.integrationLog(config.id, "Non-JSON response")
                return
            }
            let value = self.extractValue(from: json, config: config)
            guard let value, value != self.lastValues[config.id] else { return }
            self.lastValues[config.id] = value

            DispatchQueue.main.async {
                self.handleUpdate(config: config, value: value)
            }
        }.resume()
    }

    private func extractValue(from json: [String: Any], config: IntegrationPollConfig) -> String? {
        // Navigate JSON path (e.g. "data.0.text" or "message")
        let parts = config.valuePath.components(separatedBy: ".")
        var current: Any = json
        for part in parts {
            if let dict = current as? [String: Any] {
                current = dict[part]
            } else if let arr = current as? [Any], let idx = Int(part), idx < arr.count {
                current = arr[idx]
            } else {
                return nil
            }
        }
        if let s = current as? String { return s }
        if let n = current as? NSNumber { return n.stringValue }
        if let dict = current as? [String: Any] {
            return dict["text"] as? String ?? dict["message"] as? String ?? dict["content"] as? String
        }
        return nil
    }

    private func handleUpdate(config: IntegrationPollConfig, value: String) {
        // Must run on MainActor to access AppState
        DispatchQueue.main.async {
            let state = AppState.shared
            guard let idx = state.tasks.firstIndex(where: { $0.id == config.id }) else { return }
            state.tasks[idx].state = .finished
            state.tasks[idx].steps = [value]
            AppState.shared.tasks[idx].pillBadge = .finished
            SoundEngine.shared.play("finish")

            // Auto-clear after configured interval
            DispatchQueue.main.asyncAfter(deadline: .now() + max(5, config.pollInterval)) {
                guard let i = state.tasks.firstIndex(where: { $0.id == config.id }) else { return }
                state.tasks[i].state = .idle
                state.tasks[i].steps = []
                state.tasks[i].pillBadge = nil
            }
        }
    }

    private func integrationLog(_ id: String, _ message: String) {
        appendAppLog("integration_\(id).log", message)
    }

    // MARK: - Configuration

    struct IntegrationPollConfig: Sendable, Equatable {
        let id: String
        let endpoint: String
        let apiKeyName: String    // Keychain key name
        let apiKeyHeader: String  // HTTP header name (e.g. "Authorization", "X-N8N-API-KEY")
        let valuePath: String     // JSON path to extract value (e.g. "messages.0.text")
        let pollInterval: TimeInterval
    }
}
