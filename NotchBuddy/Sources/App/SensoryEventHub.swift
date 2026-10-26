import Foundation
import AppKit

// MARK: - Sensory Event Hub (Unified Sensory Coordination & Priority Dispatcher)
// Menyatukan persepsi pasif (Clipboard, File System, Ambient App Context, Memori)
// dan mengelola prioritas Proactive Chips di Notch secara elegan tanpa tumpang-tindih.

public enum SensoryPriority: Int, Sendable, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    case critical = 4

    public static func < (lhs: SensoryPriority, rhs: SensoryPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SensoryTrigger: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let goal: String
    public let priority: SensoryPriority
    public let timestamp: Date
    public let ttlSeconds: TimeInterval

    public var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > ttlSeconds
    }
}

public final class SensoryEventHub: @unchecked Sendable {
    public static let shared = SensoryEventHub()

    private let lock = NSLock()
    private var activeTriggers: [SensoryTrigger] = []
    private var isRunning = false
    private let maxVisibleChips = 5

    private init() {}

    // MARK: - Watcher Toggles

    public var isClipboardWatcherEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "clipboardWatcherEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "clipboardWatcherEnabled")
            if newValue {
                ClipboardWatcher.shared.start()
            } else {
                ClipboardWatcher.shared.stop()
            }
        }
    }

    public var isFileSystemWatcherEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "fileSystemWatcherEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "fileSystemWatcherEnabled")
            if newValue {
                FileSystemWatcher.shared.start()
            } else {
                FileSystemWatcher.shared.stop()
            }
        }
    }

    /// Memulai Sensory Event Hub dan subsistem pemantau pasif.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        isRunning = true
        if isClipboardWatcherEnabled {
            ClipboardWatcher.shared.start()
        }
        if isFileSystemWatcherEnabled {
            FileSystemWatcher.shared.start()
        }
    }

    /// Menghentikan Sensory Event Hub.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        ClipboardWatcher.shared.stop()
        FileSystemWatcher.shared.stop()
        activeTriggers.removeAll()
        isRunning = false
    }

    // MARK: - Trigger Registration & Priority Merging

    public func registerProactiveTrigger(
        id: String,
        title: String,
        goal: String,
        priority: SensoryPriority = .medium,
        ttlSeconds: TimeInterval = 600.0
    ) {
        lock.lock()
        // 1. Bersihkan trigger kedaluwarsa
        activeTriggers.removeAll { $0.isExpired }

        // 2. Cegah duplikasi judul yang sama persis (update ke posisi teratas jika ada)
        activeTriggers.removeAll { $0.title == title }

        let newTrigger = SensoryTrigger(
            id: id,
            title: title,
            goal: goal,
            priority: priority,
            timestamp: Date(),
            ttlSeconds: ttlSeconds
        )

        activeTriggers.append(newTrigger)

        // 3. Urutkan berdasarkan prioritas tertinggi, kemudian timestamp terbaru
        activeTriggers.sort {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.timestamp > $1.timestamp
        }

        let snapshot = Array(activeTriggers.prefix(maxVisibleChips))
        lock.unlock()

        // 4. Sinkronkan ke AppState dan tampilkan respon Mochi di Notch
        Task { @MainActor in
            self.publishToNotch(triggers: snapshot, latestPriority: priority)
        }
    }

    public func removeTrigger(id: String) {
        lock.lock()
        activeTriggers.removeAll { $0.id == id }
        let snapshot = Array(activeTriggers.prefix(maxVisibleChips))
        lock.unlock()

        Task { @MainActor in
            self.publishToNotch(triggers: snapshot, latestPriority: .low)
        }
    }

    public func allActiveTriggers() -> [SensoryTrigger] {
        lock.lock()
        defer { lock.unlock() }
        return activeTriggers.filter { !$0.isExpired }
    }

    // MARK: - Notch UI Synchronization

    @MainActor
    private func publishToNotch(triggers: [SensoryTrigger], latestPriority: SensoryPriority) {
        let proactiveChips = triggers.map { t in
            ProactiveChip(id: t.id, text: t.title, fact: t.goal)
        }

        AppState.shared.proactiveChips = proactiveChips

        // Respon visual Mochi di notch tergantung tingkat prioritas
        switch latestPriority {
        case .critical, .high:
            // Error atau darurat: Mochi menunjukkan perhatian serius
            AppState.shared.stateOverride = .thinking
            SoundEngine.shared.play("think")
            if latestPriority == .critical, let topTrigger = triggers.first {
                Task {
                    await TelegramGatewayService.shared.sendNotification(text: "⚠️ \(topTrigger.title)\n\(topTrigger.goal)")
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if AppState.shared.stateOverride == .thinking {
                    AppState.shared.stateOverride = nil
                }
            }
        case .medium:
            // Berkas baru atau tautan baru: Mochi tersenyum ramah
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            SoundEngine.shared.play("blip")
        case .low:
            break
        }
    }
}

