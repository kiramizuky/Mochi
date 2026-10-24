import Foundation

// MARK: - Policy engine (hard floor + per-category modes)

/// How aggressively tools are auto-approved.
enum PolicyMode: String, Sendable, CaseIterable {
    /// Every non-floor action runs without asking (JARVIS default for shell/email/network).
    case autopilot
    /// Ask once per category, then allow for the rest of the session.
    case askOnce = "ask_once"
    /// Ask on every action.
    case manual
}

/// What a tool call is trying to do, used to pick a mode.
enum ActionCategory: String, Sendable, CaseIterable {
    case shell
    case fileWrite = "file_write"
    case email
    case network
    case appControl = "app_control"
    case read
}

enum PolicyDecision: String, Sendable, Equatable {
    case allow
    case deny
    case confirm
}

/// One thing the agent wants to do. `command` is the shell command, file path,
/// URL or app name — whatever is meaningful for display and the hard floor.
struct PolicyAction: Sendable, Equatable {
    var category: ActionCategory
    var command: String
}

struct PolicyVerdict: Sendable, Equatable {
    var decision: PolicyDecision
    var reason: String?

    static func allow(_ reason: String? = nil) -> PolicyVerdict {
        PolicyVerdict(decision: .allow, reason: reason)
    }
    static func deny(_ reason: String) -> PolicyVerdict {
        PolicyVerdict(decision: .deny, reason: reason)
    }
    static let confirm = PolicyVerdict(decision: .confirm, reason: nil)
}

struct PolicyEngine: Sendable {
    /// Per-category mode. `read` bypasses modes entirely (always allowed).
    var modes: [ActionCategory: PolicyMode]
    /// Categories the user already approved this session (askOnce).
    private(set) var confirmed: Set<ActionCategory> = []

    init(modes: [ActionCategory: PolicyMode] = PolicyEngine.defaultModes) {
        self.modes = modes
    }

    /// Super Autopilot defaults: semua kategori berjalan bebas tanpa konfirmasi user.
    /// Hard floor tetap berlaku untuk aksi berbahaya (sudo, rm -rf, pipe-to-shell, etc).
    static nonisolated(unsafe) var defaultModes: [ActionCategory: PolicyMode] = [
        .shell: .autopilot,
        .email: .autopilot,
        .network: .autopilot,
        .fileWrite: .autopilot,
        .appControl: .autopilot,
        .read: .autopilot,
    ]

    /// Pure: never mutates. `confirm(_:)` is what flips askOnce to allow.
    func evaluate(_ action: PolicyAction) -> PolicyVerdict {
        // Reads are always fine — including .claude/settings.json (read is not write).
        if action.category == .read { return .allow() }

        if let reason = Self.floorReason(action) {
            return .deny(reason)
        }

        if confirmed.contains(action.category) { return .allow() }

        switch modes[action.category] ?? .manual {
        case .autopilot: return .allow()
        case .askOnce:   return .confirm
        case .manual:    return .confirm
        }
    }

    /// The user clicked "Allow" for this category (askOnce: stays allowed for the session).
    mutating func confirm(_ category: ActionCategory) {
        confirmed.insert(category)
    }

    // MARK: - Hard floor (absolute deny, above every mode)

    /// Reasons that must never be executed regardless of mode or approval.
    /// Returns nil when the action is out of floor scope.
    static func floorReason(_ action: PolicyAction) -> String? {
        // The settings-file rule only guards writes and shell (reads short-circuit earlier).
        if action.command.contains(".claude/settings.json") {
            return "never writes ~/.claude/settings.json"
        }
        let cmd = action.command
        if cmd.range(of: #"\bsudo\b"#, options: .regularExpression) != nil {
            return "sudo is never allowed"
        }
        if isDestructiveRm(cmd) {
            return "refusing to delete root paths (rm -rf)"
        }
        if hasDiskutilErase(cmd) {
            return "refusing to erase disks"
        }
        if isPipeToShell(cmd) {
            return "refusing to pipe downloads into a shell"
        }
        return nil
    }

    /// `rm` with both r and f flags targeting /, ~ or $HOME.
    static func isDestructiveRm(_ cmd: String) -> Bool {
        let tokens = cmd.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard let rmIdx = tokens.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") }) else { return false }
        var sawR = false, sawF = false
        var target: String? = nil
        for token in tokens[(rmIdx + 1)...] {
            if token.hasPrefix("-") {
                for ch in token.dropFirst() {
                    if ch == "r" || ch == "R" { sawR = true }
                    if ch == "f" || ch == "F" { sawF = true }
                }
            } else if target == nil {
                target = token
            } else {
                break // multiple targets — only flag the single-target root case
            }
        }
        guard sawR, sawF, let t = target else { return false }
        return t == "/" || t == "/*" || t == "~" || t == "~/"
            || t.hasPrefix("~/") || t == "$HOME" || t.hasPrefix("$HOME/")
    }

    static func hasDiskutilErase(_ cmd: String) -> Bool {
        let tokens = cmd.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard tokens.contains(where: { $0 == "diskutil" || $0.hasSuffix("/diskutil") }) else { return false }
        return tokens.contains { $0.hasPrefix("erase") }
    }

    /// curl/wget (or anything) piped straight into sh/bash/zsh/ksh.
    static func isPipeToShell(_ cmd: String) -> Bool {
        let pattern = #"\|\s*(/usr/bin/|/bin/)?(ba|z|k)?sh\b"#
        guard cmd.range(of: pattern, options: .regularExpression) != nil else { return false }
        let lhs = cmd.components(separatedBy: "|").first ?? ""
        return lhs.contains("curl") || lhs.contains("wget") || lhs.contains("http")
    }
}
