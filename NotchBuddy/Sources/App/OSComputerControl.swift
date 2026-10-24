import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

// MARK: - OS-Level Direct Computer Control (CUA)
// Mengendalikan mouse, keyboard, dan interaksi GUI tingkat OS via CoreGraphics.

public final class OSComputerControl: @unchecked Sendable {
    public static let shared = OSComputerControl()

    private let lock = NSLock()
    private var isPanicAborted: Bool = false
    private var lastUserMousePosition: CGPoint = .zero
    private var globalMouseMonitor: Any?

    private init() {
        setupSafetyMonitor()
    }

    deinit {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Safety Panic Guardrail

    private func setupSafetyMonitor() {
        // Monitor pergerakan mouse fisik oleh pengguna saat bot sedang berjalan
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self else { return }
            let currentPos = NSEvent.mouseLocation
            // Konversi koordinat Cocoa ke CoreGraphics jika diperlukan
            if self.isControlling && self.distance(currentPos, self.lastUserMousePosition) > 40.0 {
                // Pengguna menggerakkan mouse secara fisik! Picu panic interrupt!
                self.triggerPanicAbort(reason: "Pengguna mengambil alih kontrol mouse fisik.")
            }
            self.lastUserMousePosition = currentPos
        }
    }

    private var isControlling: Bool = false

    public func triggerPanicAbort(reason: String) {
        lock.withLock {
            isPanicAborted = true
            isControlling = false
        }

        Task { @MainActor in
            SoundEngine.shared.play("error")
            AppState.shared.activePlaybookProgress = "⚠️ Kontrol Dibatalkan: \(reason)"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            AppState.shared.activePlaybookProgress = nil
        }
    }

    public func resetPanic() {
        lock.withLock {
            isPanicAborted = false
        }
    }

    public func checkAborted() throws {
        let aborted = lock.withLock { isPanicAborted }
        if aborted {
            throw OSComputerControlError.aborted("Operasi GUI dihentikan karena panic guardrail aktif.")
        }
    }

    // MARK: - Mouse Operations

    /// Menggerakkan mouse ke koordinat layar (koordinat piksel absolut).
    public func move(to point: CGPoint) throws {
        try checkAborted()
        setControlling(true)
        defer { setControlling(false) }

        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw OSComputerControlError.failed("Gagal membuat event mouse move.")
        }
        moveEvent.post(tap: .cghidEventTap)
        usleep(25_000) // 25ms delay agar OS mendaftarkan kursor
    }

    /// Klik kiri, klik kanan, atau double click pada koordinat tertentu.
    public func click(at point: CGPoint, button: CGMouseButton = .left, clickCount: Int = 1) throws {
        try checkAborted()
        setControlling(true)
        defer { setControlling(false) }

        // Pindahkan mouse ke titik sasaran
        try move(to: point)

        let downType: CGEventType
        let upType: CGEventType

        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
        default:
            downType = .otherMouseDown
            upType = .otherMouseUp
        }

        for i in 1...clickCount {
            try checkAborted()

            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                throw OSComputerControlError.failed("Gagal membuat event klik.")
            }

            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))

            down.post(tap: .cghidEventTap)
            usleep(35_000) // Tahan tombol mouse 35ms
            up.post(tap: .cghidEventTap)
            usleep(35_000)
        }
    }

    /// Drag and drop dari satu titik ke titik lain.
    public func drag(from: CGPoint, to: CGPoint) throws {
        try checkAborted()
        setControlling(true)
        defer { setControlling(false) }

        try move(to: from)

        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left) else {
            throw OSComputerControlError.failed("Gagal memulai drag.")
        }
        down.post(tap: .cghidEventTap)
        usleep(50_000)

        // Langkah interpolasi agar drag terdaftar mulus oleh aplikasi
        let steps = 15
        for i in 1...steps {
            try checkAborted()
            let t = Double(i) / Double(steps)
            let currX = from.x + CGFloat(t) * (to.x - from.x)
            let currY = from.y + CGFloat(t) * (to.y - from.y)
            let current = CGPoint(x: currX, y: currY)

            guard let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: current, mouseButton: .left) else { continue }
            dragEvent.post(tap: .cghidEventTap)
            usleep(15_000)
        }

        guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) else {
            throw OSComputerControlError.failed("Gagal menyelesaikan drag.")
        }
        up.post(tap: .cghidEventTap)
        usleep(50_000)
    }

    /// Scroll vertikal atau horizontal.
    public func scroll(deltaY: Int32, deltaX: Int32 = 0) throws {
        try checkAborted()
        setControlling(true)
        defer { setControlling(false) }

        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else {
            throw OSComputerControlError.failed("Gagal membuat event scroll.")
        }
        scrollEvent.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    // MARK: - Keyboard Operations

    /// Mengetikkan teks secara langsung ke aplikasi aktif.
    public func typeText(_ text: String) throws {
        try checkAborted()
        setControlling(true)
        defer { setControlling(false) }

        for char in text {
            try checkAborted()
            let utf16Chars = Array(String(char).utf16)

            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                continue
            }

            down.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            up.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)

            down.post(tap: .cghidEventTap)
            usleep(12_000) // Delay natural antar karakter
            up.post(tap: .cghidEventTap)
            usleep(12_000)
        }
    }

    /// Menekan tombol pintasan khusus (misal: "return", "tab", "escape", "space", "command+s", dll).
    public func pressKey(named: String) throws {
        try checkAborted()
        setControlling(true)
        defer { setControlling(false) }

        let lower = named.lowercased()
        var flags: CGEventFlags = []
        if lower.contains("cmd") || lower.contains("command") { flags.insert(.maskCommand) }
        if lower.contains("shift") { flags.insert(.maskShift) }
        if lower.contains("ctrl") || lower.contains("control") { flags.insert(.maskControl) }
        if lower.contains("alt") || lower.contains("option") { flags.insert(.maskAlternate) }

        let keyCode: CGKeyCode
        if lower.contains("return") || lower.contains("enter") { keyCode = 36 }
        else if lower.contains("tab") { keyCode = 48 }
        else if lower.contains("space") { keyCode = 49 }
        else if lower.contains("escape") || lower.contains("esc") { keyCode = 53 }
        else if lower.contains("backspace") || lower.contains("delete") { keyCode = 51 }
        else if lower.contains("up") { keyCode = 126 }
        else if lower.contains("down") { keyCode = 125 }
        else if lower.contains("left") { keyCode = 123 }
        else if lower.contains("right") { keyCode = 124 }
        else { keyCode = 36 } // default return

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw OSComputerControlError.failed("Gagal membuat event tombol.")
        }

        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }

        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    // MARK: - Helpers

    private func setControlling(_ val: Bool) {
        lock.withLock {
            isControlling = val
            if val {
                lastUserMousePosition = NSEvent.mouseLocation
            }
        }
    }

    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = p1.x - p2.x
        let dy = p1.y - p2.y
        return sqrt(dx * dx + dy * dy)
    }
}

public enum OSComputerControlError: Error, LocalizedError, CustomStringConvertible {
    case failed(String)
    case aborted(String)

    public var description: String {
        switch self {
        case .failed(let msg): return "OS Computer Control Error: \(msg)"
        case .aborted(let msg): return "OS Computer Control Aborted: \(msg)"
        }
    }

    public var errorDescription: String? { description }
}
