import Foundation
import CoreGraphics

// MARK: - Idle Detection Engine
// Mendeteksi apakah sistem macOS sedang idle (tidak ada input mouse/keyboard pengguna).

public final class IdleDetectionEngine: @unchecked Sendable {
    public static let shared = IdleDetectionEngine()

    private var timer: Timer?
    private let lock = NSLock()
    private var isRunning = false
    public var onIdleThresholdReached: (@Sendable (TimeInterval) -> Void)?

    public var idleThresholdSeconds: TimeInterval = 900 // 15 menit default

    private init() {}

    /// Mengambil durasi (dalam detik) sejak event input pengguna terakhir.
    public var currentIdleSeconds: TimeInterval {
        // CGEventSource.secondsSinceLastEventType memeriksa gabungan mouse + keyboard di level kernel
        let anyInputEventType = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
    }

    /// Memulai monitoring idle secara berkala di latar belakang.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        isRunning = true

        DispatchQueue.main.async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                let idle = self.currentIdleSeconds
                if idle >= self.idleThresholdSeconds {
                    self.onIdleThresholdReached?(idle)
                }
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.invalidate()
        timer = nil
        isRunning = false
    }
}
