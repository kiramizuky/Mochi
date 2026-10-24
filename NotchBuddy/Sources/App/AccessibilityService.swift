import AppKit
import Foundation

// MARK: - Accessibility: read and act on the UI of the frontmost app

/// One element of an accessibility snapshot.
struct AXElementInfo: Sendable, Equatable {
    var role: String
    var title: String?
    var value: String?
    var description: String?
    var actions: [String]

    /// `Role "title/value"` — used in summaries and the focused line.
    var label: String {
        var text = title ?? ""
        if let value, !value.isEmpty {
            text = text.isEmpty ? value : text + "/" + value
        }
        guard !text.isEmpty else { return role }
        return "\(role) \"\(String(text.prefix(60)))\""
    }

    /// Whether the element carries any text worth reading.
    var hasText: Bool {
        title?.isEmpty == false || value?.isEmpty == false || description?.isEmpty == false
    }
}

/// Result of reading the UI structure of the frontmost application.
/// `elements` are indexed: a `press` action addresses the same order
/// (both come from one deterministic walk).
struct AXSnapshot: Sendable, Equatable {
    var appName: String
    var focused: String?
    var elements: [AXElementInfo]

    func summary(maxElements: Int = 40) -> String {
        var lines: [String] = ["App: \(appName)"]
        if let focused {
            lines.append("Focused: \(focused)")
        }
        lines.append("Elements (\(elements.count)):")
        for (index, element) in elements.prefix(maxElements).enumerated() {
            lines.append("[\(index)] \(element.label)")
        }
        return lines.joined(separator: "\n")
    }
}

/// A single UI action. Validated when the tool input is parsed, so a bad
/// argument fails before any policy or audit work happens.
enum AXAction: Sendable, Equatable {
    case press(index: Int)
    case typeText(String)
    case key(String)

    /// Virtual key codes (macOS hardware layout) accepted by the `key` action.
    static let keyCodes: [String: Int] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    init(input: JSONValue) throws {
        guard let name = input["action"]?.stringValue else {
            throw AccessibilityError.invalidAction("missing \"action\" (press, type or key)")
        }
        switch name {
        case "press":
            guard let raw = input["index"] else {
                throw AccessibilityError.invalidAction("press needs \"index\"")
            }
            guard case .number(let n) = raw, n >= 0, n < 1_000_000, n == n.rounded() else {
                throw AccessibilityError.invalidAction("\"index\" must be a non-negative integer")
            }
            self = .press(index: Int(n))
        case "type":
            guard let text = input["text"]?.stringValue, !text.isEmpty else {
                throw AccessibilityError.invalidAction("type needs a non-empty \"text\"")
            }
            self = .typeText(text)
        case "key":
            guard let key = input["key"]?.stringValue, Self.keyCodes[key] != nil else {
                let allowed = Self.keyCodes.keys.sorted().joined(separator: ", ")
                throw AccessibilityError.invalidAction("key must be one of: \(allowed)")
            }
            self = .key(key)
        default:
            throw AccessibilityError.invalidAction("unknown action \"\(name)\" (press, type or key)")
        }
    }

    /// Short, human-readable target for UI events and audit records.
    var target: String {
        switch self {
        case .press(let index):  return "press [\(index)]"
        case .typeText(let text): return "type \(String(text.prefix(80)))"
        case .key(let key):      return "key \(key)"
        }
    }
}

enum AccessibilityError: LocalizedError, Equatable {
    case permissionDenied
    case noFrontmostApp
    case invalidAction(String)
    case elementNotFound(Int)
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Accessibility permission not granted (System Settings → Privacy & Security → Accessibility)."
        case .noFrontmostApp:
            return "No frontmost application."
        case .invalidAction(let detail):
            return "Invalid action: \(detail)"
        case .elementNotFound(let index):
            return "No element at index \(index) — call ax_read again first."
        case .actionFailed(let detail):
            return "Action failed: \(detail)"
        }
    }
}

// MARK: - Client

protocol AXClientProtocol: Sendable {
    /// Read the UI structure of the frontmost app (throws without permission).
    func snapshot() throws -> AXSnapshot
    /// Perform one validated action on the frontmost app.
    func perform(_ action: AXAction) throws -> String
}

/// Real implementation on top of the Accessibility (AX) API and CGEvent.
/// SystemAXClient keeps no state, so a fresh value is fine everywhere.
struct SystemAXClient: AXClientProtocol {
    private static let visitBudget = 60
    private static let collectLimit = 40

    func snapshot() throws -> AXSnapshot {
        guard AXIsProcessTrusted() else { throw AccessibilityError.permissionDenied }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AccessibilityError.noFrontmostApp
        }
        let pairs = Self.collect(processIdentifier: app.processIdentifier)
        return AXSnapshot(
            appName: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            focused: Self.focusedDescription(processIdentifier: app.processIdentifier),
            elements: pairs.map { $0.info }
        )
    }

    func perform(_ action: AXAction) throws -> String {
        guard AXIsProcessTrusted() else { throw AccessibilityError.permissionDenied }
        switch action {
        case .press(let index):
            guard let app = NSWorkspace.shared.frontmostApplication else {
                throw AccessibilityError.noFrontmostApp
            }
            let pairs = Self.collect(processIdentifier: app.processIdentifier)
            guard index >= 0, index < pairs.count else {
                throw AccessibilityError.elementNotFound(index)
            }
            let element = pairs[index].element
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return "Pressed element [\(index)]."
            }
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, element)
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return "Pressed element [\(index)]."
            }
            throw AccessibilityError.actionFailed("press [\(index)]")

        case .typeText(let text):
            try Self.postUnicode(text)
            return "Typed \(text.count) characters."

        case .key(let key):
            guard let code = AXAction.keyCodes[key] else {
                throw AccessibilityError.invalidAction("key \"\(key)\"")
            }
            try Self.postKey(CGKeyCode(code))
            return "Pressed key \(key)."
        }
    }

    // MARK: Walk

    /// One deterministic preorder walk. `snapshot` and `press` both go through
    /// it, so an index from `ax_read` addresses the same element in `ax_act`
    /// while the UI is unchanged.
    private static func collect(processIdentifier pid: pid_t)
        -> [(element: AXUIElement, info: AXElementInfo)] {
        var stack: [AXUIElement] = [AXUIElementCreateApplication(pid)]
        var actionable: [(AXUIElement, AXElementInfo)] = []
        var textual: [(AXUIElement, AXElementInfo)] = []
        var visits = 0

        while visits < visitBudget, let element = stack.popLast() {
            visits += 1
            let info = elementInfo(element)
            if !info.actions.isEmpty {
                if actionable.count < collectLimit { actionable.append((element, info)) }
            } else if info.hasText, textual.count < collectLimit {
                textual.append((element, info))
            }
            stack.append(contentsOf: children(of: element).reversed())
        }
        let ordered = actionable + textual
        return ordered.prefix(collectLimit).map { (element: $0.0, info: $0.1) }
    }

    private static func elementInfo(_ element: AXUIElement) -> AXElementInfo {
        var actionNames: CFArray?
        var actions: [String] = []
        if AXUIElementCopyActionNames(element, &actionNames) == .success,
           let names = actionNames as? [String] {
            actions = names.sorted()
        }
        return AXElementInfo(
            role: stringAttribute(element, kAXRoleAttribute) ?? "Unknown",
            title: stringAttribute(element, kAXTitleAttribute),
            value: stringAttribute(element, kAXValueAttribute),
            description: stringAttribute(element, kAXDescriptionAttribute),
            actions: actions
        )
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == CFArrayGetTypeID() else {
            return []
        }
        let array = unsafeBitCast(raw, to: CFArray.self)
        let count = CFArrayGetCount(array)
        var result: [AXUIElement] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
            let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { continue }
            result.append(unsafeBitCast(object, to: AXUIElement.self))
        }
        return result
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw else { return nil }
        if let string = raw as? String { return string.isEmpty ? nil : string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func focusedDescription(processIdentifier pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        let info = elementInfo(unsafeBitCast(raw, to: AXUIElement.self))
        guard info.hasText || !info.actions.isEmpty else { return info.role }
        return info.label
    }

    // MARK: Keyboard events

    private static func postUnicode(_ text: String) throws {
        let units = Array(text.utf16)
        guard !units.isEmpty else { throw AccessibilityError.invalidAction("empty text") }
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                throw AccessibilityError.actionFailed("type")
            }
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count,
                                               unicodeString: buffer.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private static func postKey(_ code: CGKeyCode) throws {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: keyDown) else {
                throw AccessibilityError.actionFailed("key")
            }
            event.post(tap: .cghidEventTap)
        }
    }
}
