import Foundation

// MARK: - Message bus (async pub/sub antar agen)

// Bus pesan async berbasis actor: agen-agen dapat berlangganan topik dan
// menerima pesan dari agen lain tanpa referensi langsung (loose coupling).
// Semua operasi dijalankan di dalam actor → aman untuk concurrent access.
final actor MessageBus {
    static let shared = MessageBus()

    /// Topik pesan yang ada di sistem.
    enum Topic: String, Sendable, CaseIterable, Hashable {
        case taskDecomposed   = "task.decomposed"
        case taskAssigned     = "task.assigned"
        case taskCompleted    = "task.completed"
        case taskFailed       = "task.failed"
        case correctionNeeded = "correction.needed"
        case synthesisReady   = "synthesis.ready"
        case userInput        = "user.input"
    }

    /// Handler pesan: menerima payload apa pun yang dikirim sebagai Sendable.
    typealias Handler = @Sendable (any Sendable) async -> Void

    private var subscribers: [Topic: [UUID: Handler]] = [:]

    /// Berlangganan topik. Mengembalikan token untuk `unsubscribe`.
    func subscribe(topic: Topic, handler: @escaping Handler) -> UUID {
        let id = UUID()
        subscribers[topic, default: [:]][id] = handler
        return id
    }

    /// Berhenti berlangganan berdasarkan token.
    func unsubscribe(token: UUID, topic: Topic) {
        subscribers[topic]?.removeValue(forKey: token)
        if subscribers[topic]?.isEmpty == true {
            subscribers[topic] = nil
        }
    }

    /// Terbitkan pesan ke semua pelanggan topik.
    func publish(topic: Topic, payload: some Sendable) async {
        let handlers = subscribers[topic] ?? [:]
        for (_, handler) in handlers {
            await handler(payload)
        }
    }

    /// Jumlah pelanggan per topik (untuk inspeksi / tes).
    func subscriberCount(topic: Topic) -> Int {
        subscribers[topic]?.count ?? 0
    }
}
