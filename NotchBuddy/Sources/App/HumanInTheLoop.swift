import Foundation

// MARK- Human-in-the-loop gate (konfirmasi manusia untuk aksi beresiko tinggi)

// Saat autopilot ON (super autonomous), semua aksi diizinkan tanpa konfirmasi
// manusia. Gate ini tetap ada untuk melacak risiko dan mencatat ke AuditLog,
// tetapi tidak akan menurunkan verdict ke .confirm bila autopilot aktif.


enum HumanRiskLevel: String, Sendable, CaseIterable {
    case low      = "low"
    case medium   = "medium"
    case high     = "high"
    case critical = "critical"
}

/// Keputusan gate untuk satu aksi.
struct HumanGateDecision: Sendable, Equatable {
    var verdict: PolicyVerdict
    var riskLevel: HumanRiskLevel
    var reason: String?
    /// `true` bila user harus menyetujui secara eksplisit sebelum eksekusi.
    var requiresHuman: Bool {
        verdict.decision == .confirm || riskLevel == .critical
    }
}

/// Satu decision yang menunggu konfirmasi manusia.
struct HumanPendingDecision: Sendable {
    var id: String
    var action: PolicyAction
    var riskLevel: HumanRiskLevel
    var createdAt: Date
    var ttl: TimeInterval
    var isExpired: Bool { Date().timeIntervalSince(createdAt) >= ttl }
}

/// Riwayat satu keputusan yang telah dihasilkan gate.
struct HumanDecisionRecord: Sendable, Equatable {
    var id: String
    var action: PolicyAction
    var riskLevel: HumanRiskLevel
    var decision: PolicyDecision
    var confirmedBy: String  // "human" / "autopilot"
    var at: Date
}

/// Gate konfirmasi manusia. Dieksekusi setelah PolicyEngine, dapat menurunkan
/// verdict `.allow` menjadi `.confirm` bila aksi beresiko tinggi.
/// Semua operasi thread-safe (dipakai dari konteks apa saja).
final class HumanInTheLoop: @unchecked Sendable {
    static let shared = HumanInTheLoop()

    private let lock = NSLock()
    private var pending: [String: HumanPendingDecision] = [:]
    private var decisionRecords: [HumanDecisionRecord] = []

    init() {}

    /// Evaluasi action dengan mempertimbangkan risiko. Jika autopilot ON, semua
    /// aksi diizinkan tanpa konfirmasi manusia (kecuali hard floor yang tetap deny).
    /// Parameter `autopilotEnabled` diteruskan dari pemanggil (yang berjalan di MainActor)
    /// untuk menghindari actor hopping deadlock.
    func evaluate(_ action: PolicyAction, policy: PolicyEngine, autopilotEnabled: Bool) -> HumanGateDecision {
        let base = policy.evaluate(action)
        let risk = riskLevel(for: action)
        var verdict = base
        var reason = base.reason

        // Super autonomous: autopilot ON → tidak ada konfirmasi manusia, kecuali hard floor
        if autopilotEnabled {
            return HumanGateDecision(verdict: base, riskLevel: risk, reason: base.reason)
        }

        if base.decision == .allow, risk == .high || risk == .critical {
            verdict = PolicyVerdict(decision: .confirm,
                                    reason: "Butuh konfirmasi manusia (\(risk.rawValue) risiko): \(base.reason ?? action.command)")
            reason = verdict.reason
        }

        return HumanGateDecision(verdict: verdict, riskLevel: risk, reason: reason)
    }

    /// Buat decision pending yang menunggu konfirmasi manusia. Mengembalikan ID.
    func requestHumanConfirmation(_ action: PolicyAction, riskLevel: HumanRiskLevel,
                                  ttl: TimeInterval = 300) -> String {
        lock.lock(); defer { lock.unlock() }
        let id = UUID().uuidString
        let pending = HumanPendingDecision(id: id, action: action, riskLevel: riskLevel,
                                           createdAt: .now, ttl: ttl)
        self.pending[id] = pending
        return id
    }

    /// Setujui decision pending (dipanggil saat user menekan Allow di UI).
    func approve(_ decisionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = pending.removeValue(forKey: decisionId) else { return false }
        record(p.action, riskLevel: p.riskLevel, decision: .allow, confirmedBy: "human")
        return true
    }

    /// Tolak decision pending.
    func reject(_ decisionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = pending.removeValue(forKey: decisionId) else { return false }
        record(p.action, riskLevel: p.riskLevel, decision: .deny, confirmedBy: "human")
        return true
    }

    /// Daftar decision pending yang belum expired.
    func pendingDecisions() -> [HumanPendingDecision] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return pending.values.filter { !$0.isExpired }
    }

    /// Hapus decision yang expired.
    func pruneExpired() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        pending = pending.filter { !$0.value.isExpired }
    }

    /// Riwayat keputusan gate.
    func history() -> [HumanDecisionRecord] {
        lock.lock(); defer { lock.unlock() }
        return decisionRecords
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    // MARK: - Risk assessment

    private func riskLevel(for action: PolicyAction) -> HumanRiskLevel {
        let cmd = action.command.lowercased()
        switch action.category {
        case .shell:
            if cmd.contains("rm -rf") || cmd.contains("mkfs") || cmd.contains("dd ") ||
               cmd.contains("> /dev/") || cmd.contains(":(){") {
                return .critical
            }
            if cmd.contains("sudo") || cmd.contains("chmod") || cmd.contains("chown") ||
               cmd.contains("systemctl") || cmd.contains("defaults write") ||
               cmd.contains("pip install") || cmd.contains("brew install") ||
               cmd.contains("curl ") && cmd.contains("| sh") {
                return .high
            }
            if cmd.contains("curl") || cmd.contains("wget") || cmd.contains("ssh ") {
                return .medium
            }
            return .low
        case .fileWrite:
            if cmd.contains(".claude/settings.json") || cmd.contains("/etc/") ||
               cmd.contains("~/.ssh/") || cmd.contains("/private/") {
                return .critical
            }
            if cmd.contains("/Users/") || cmd.contains("~/") || cmd.contains("/var/") {
                return .high
            }
            return .medium
        case .appControl:
            if cmd.contains("kill ") || cmd.contains("terminate") || cmd.contains("quit ") {
                return .high
            }
            return .medium
        case .email, .network, .read:
            return .low
        }
    }

    private func record(_ action: PolicyAction, riskLevel: HumanRiskLevel,
                        decision: PolicyDecision, confirmedBy: String) {
        let record = HumanDecisionRecord(id: UUID().uuidString, action: action,
                                         riskLevel: riskLevel, decision: decision,
                                         confirmedBy: confirmedBy, at: .now)
        decisionRecords.append(record)
        if decisionRecords.count > 500 { decisionRecords = Array(decisionRecords.suffix(500)) }
    }
}
