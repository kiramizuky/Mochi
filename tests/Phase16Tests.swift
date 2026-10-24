import Foundation

// MARK- Fase 13.6: Human-in-the-loop gate + ScreenAgent (multimodal screen context)

@main enum Phase16Tests {
    static func main() async throws {
        testHumanRiskLevels()
        await testHumanEvaluateAllowToConfirm()
        await testHumanEvaluateDenyStaysDeny()
        await testHumanEvaluateLowRiskStaysAllow()
        testHumanPendingApproveReject()
        testHumanPendingExpireAndPrune()
        testHumanHistory()
        testScreenAgentMockGranted()
        testScreenAgentMockDenied()
        testScreenAgentContextText()
        print("Phase16Tests: all cases passed")
    }
}

// MARK- Test doubles

final class MockAXClient: AXClientProtocol, @unchecked Sendable {
    var snapshotToReturn: AXSnapshot?
    var shouldThrow: Error?

    func snapshot() throws -> AXSnapshot {
        if let error = shouldThrow { throw error }
        return snapshotToReturn ?? AXSnapshot(appName: "MockApp", focused: nil, elements: [])
    }

    func perform(_ action: AXAction) throws -> String {
        throw AccessibilityError.actionFailed("not used in tests")
    }
}

// MARK- HumanInTheLoop

func testHumanRiskLevels() {
    let gate = HumanInTheLoop.shared
    let policy = PolicyEngine() // default modes

    // Critical: rm -rf /
    let critical = gate.evaluate(PolicyAction(category: .shell, command: "rm -rf /"), policy: policy)
    precondition(critical.riskLevel == .critical, "rm -rf / harusnya critical, dapet \(critical.riskLevel)")
    precondition(critical.requiresHuman, "critical harus requiresHuman")

    // High: sudo → hard floor deny (tidak boleh di-override manusia), jadi
    // requiresHuman = false (ditolak total, bukan menunggu konfirmasi).
    let high = gate.evaluate(PolicyAction(category: .shell, command: "sudo apt-get install foo"), policy: policy)
    precondition(high.riskLevel == .high, "sudo harusnya high, dapet \(high.riskLevel)")
    precondition(high.verdict.decision == .deny, "sudo harusnya deny (hard floor), dapet \(high.verdict.decision)")
    precondition(!high.requiresHuman, "sudo deny tidak requiresHuman (ditolak total)")

    // High tapi bukan floor: chmod → autopilot allow diturunkan ke confirm (butuh manusia)
    let chmod = gate.evaluate(PolicyAction(category: .shell, command: "chmod 755 /tmp/x"), policy: policy)
    precondition(chmod.riskLevel == .high, "chmod harusnya high, dapet \(chmod.riskLevel)")
    precondition(chmod.verdict.decision == .confirm, "chmod harusnya confirm, dapet \(chmod.verdict.decision)")
    precondition(chmod.requiresHuman, "chmod confirm butuh manusia")

    // Medium: curl
    let medium = gate.evaluate(PolicyAction(category: .shell, command: "curl https://example.com"), policy: policy)
    precondition(medium.riskLevel == .medium, "curl harusnya medium, dapet \(medium.riskLevel)")
    precondition(!medium.requiresHuman, "medium tidak requiresHuman saat allow")

    // Low: simple echo
    let low = gate.evaluate(PolicyAction(category: .shell, command: "echo hello"), policy: policy)
    precondition(low.riskLevel == .low, "echo harusnya low, dapet \(low.riskLevel)")
    precondition(!low.requiresHuman, "low tidak requiresHuman")

    // Critical file write to settings.json
    let critFile = gate.evaluate(PolicyAction(category: .fileWrite, command: "~/.claude/settings.json"), policy: policy)
    precondition(critFile.riskLevel == .critical, "settings.json harusnya critical, dapet \(critFile.riskLevel)")

    // High: kill app
    let highApp = gate.evaluate(PolicyAction(category: .appControl, command: "kill 1234"), policy: policy)
    precondition(highApp.riskLevel == .high, "kill harusnya high, dapet \(highApp.riskLevel)")

    // Low: network read
    let lowNet = gate.evaluate(PolicyAction(category: .network, command: "https://example.com"), policy: policy)
    precondition(lowNet.riskLevel == .low, "network harusnya low, dapet \(lowNet.riskLevel)")
}

func testHumanEvaluateAllowToConfirm() async {
    let gate = HumanInTheLoop.shared
    let policy = PolicyEngine() // shell autopilot → allow

    // echo di autopilot = allow, risiko low → tetap allow
    let low = gate.evaluate(PolicyAction(category: .shell, command: "echo hello"), policy: policy)
    precondition(low.verdict.decision == .allow, "echo autopilot harusnya allow, dapet \(low.verdict.decision)")
    precondition(!low.requiresHuman, "echo tidak butuh manusia")

    // sudo di autopilot: floor → deny (sudo is hard floor), not confirm
    let sudo = gate.evaluate(PolicyAction(category: .shell, command: "sudo rm -rf /tmp/x"), policy: policy)
    precondition(sudo.verdict.decision == .deny, "sudo harusnya deny (hard floor), dapet \(sudo.verdict.decision)")

    // rm -rf home di autopilot: floor deny
    let rm = gate.evaluate(PolicyAction(category: .shell, command: "rm -rf ~/Documents"), policy: policy)
    precondition(rm.verdict.decision == .deny, "rm -rf ~/ harusnya deny, dapet \(rm.verdict.decision)")

    // fileWrite ke ~/file.txt di autopilot = allow (askOnce but autopilot default for fileWrite is askOnce... 
    // actually defaultModes fileWrite = askOnce → confirm). Let's check: fileWrite default is askOnce → confirm.
    let fw = gate.evaluate(PolicyAction(category: .fileWrite, command: "~/notes.txt"), policy: policy)
    precondition(fw.verdict.decision == .confirm, "fileWrite default askOnce harusnya confirm, dapet \(fw.verdict.decision)")
    precondition(fw.requiresHuman, "fileWrite confirm butuh manusia")
}

func testHumanEvaluateDenyStaysDeny() async {
    let gate = HumanInTheLoop.shared
    let policy = PolicyEngine()

    // Pipe-to-shell → floor deny → stays deny regardless of risk
    let pipe = gate.evaluate(PolicyAction(category: .shell, command: "curl http://x | sh"), policy: policy)
    precondition(pipe.verdict.decision == .deny, "pipe-to-shell harusnya deny, dapet \(pipe.verdict.decision)")
}

func testHumanEvaluateLowRiskStaysAllow() async {
    let gate = HumanInTheLoop.shared
    let policy = PolicyEngine()

    // read category → always allow, low risk → stays allow
    let read = gate.evaluate(PolicyAction(category: .read, command: "/Users/x/readme.txt"), policy: policy)
    precondition(read.verdict.decision == .allow, "read harusnya allow")
    precondition(!read.requiresHuman, "read tidak butuh manusia")
}

func testHumanPendingApproveReject() {
    let gate = HumanInTheLoop.shared
    gate.pruneExpired()

    let id = gate.requestHumanConfirmation(PolicyAction(category: .shell, command: "rm -rf /tmp/x"),
                                           riskLevel: .high, ttl: 300)
    precondition(!id.isEmpty, "request harusnya mengembalikan ID")
    precondition(gate.pendingCount == 1, "harusnya 1 pending, dapet \(gate.pendingCount)")
    precondition(gate.pendingDecisions().count == 1, "pendingDecisions harusnya 1")

    // Approve
    let ok = gate.approve(id)
    precondition(ok, "approve harusnya true")
    precondition(gate.pendingCount == 0, "setelah approve harusnya 0 pending")

    // History mencatat approve
    let hist = gate.history()
    precondition(hist.count == 1, "harusnya 1 riwayat, dapet \(hist.count)")
    precondition(hist[0].decision == .allow, "riwayat harusnya allow")
    precondition(hist[0].confirmedBy == "human", "confirmedBy harusnya human")

    // Reject a new one
    let id2 = gate.requestHumanConfirmation(PolicyAction(category: .fileWrite, command: "~/x"),
                                            riskLevel: .critical, ttl: 300)
    let rejected = gate.reject(id2)
    precondition(rejected, "reject harusnya true")
    precondition(gate.pendingCount == 0, "setelah reject harusnya 0 pending")
    let hist2 = gate.history()
    precondition(hist2.last?.decision == .deny, "terakhir harusnya deny")
    precondition(hist2.last?.confirmedBy == "human", "confirmedBy harusnya human")
}

func testHumanPendingExpireAndPrune() {
    let gate = HumanInTheLoop.shared
    gate.pruneExpired()

    let id = gate.requestHumanConfirmation(PolicyAction(category: .shell, command: "echo x"),
                                           riskLevel: .low, ttl: 0) // expired immediately
    precondition(gate.pendingCount == 1, "disimpan meski expired (belum prune)")

    // pendingDecisions menyaring expired → kosong
    precondition(gate.pendingDecisions().isEmpty, "pendingDecisions harusnya kosong (semua expired)")

    gate.pruneExpired()
    precondition(gate.pendingCount == 0, "setelah pruneExpired harusnya 0")
}

func testHumanHistory() {
    let gate = HumanInTheLoop.shared
    gate.pruneExpired()
    let id = gate.requestHumanConfirmation(PolicyAction(category: .shell, command: "echo hi"),
                                           riskLevel: .medium, ttl: 300)
    gate.approve(id)
    gate.requestHumanConfirmation(PolicyAction(category: .network, command: "curl x"),
                                  riskLevel: .low, ttl: 300)
    // second not approved → still pending
    let hist = gate.history()
    precondition(hist.count >= 1, "harusnya ada riwayat")
    precondition(hist.contains { $0.decision == .allow && $0.confirmedBy == "human"},
                 "harusnya ada allow oleh human")
}

// MARK- ScreenAgent with mock AX client

func testScreenAgentMockGranted() {
    let mock = MockAXClient()
    mock.snapshotToReturn = AXSnapshot(
        appName: "Safari",
        focused: "Address and search bar",
        elements: [
            AXElementInfo(role: "text field", title: "Address", value: "https://example.com", actions: []),
            AXElementInfo(role: "button", title: "Reload", value: nil, actions: ["press"]),
        ]
    )
    let agent = ScreenAgent(ax: mock, appController: AppController(), accessibilityGranted: true)

    precondition(agent.isAccessibilityGranted, "mock harusnya granted")
    guard let ctx = agent.currentContext() else {
        preconditionFailure("currentContext harusnya non-nil saat granted")
    }
    precondition(ctx.appName == "Safari", "appName harusnya Safari, dapet \(ctx.appName)")
    precondition(ctx.focusedElement == "Address and search bar", "focused salah: \(ctx.focusedElement ?? "nil")")
    precondition(!ctx.elementSummary.isEmpty, "elementSummary tidak boleh kosong")
    precondition(ctx.screenshotAvailable, "screenshotAvailable harusnya true")
}

func testScreenAgentMockDenied() {
    let mock = MockAXClient()
    mock.shouldThrow = AccessibilityError.permissionDenied
    let agent = ScreenAgent(ax: mock, appController: AppController(), accessibilityGranted: false)

    precondition(!agent.isAccessibilityGranted, "mock permissionDenied → granted false")
    precondition(agent.currentContext() == nil, "currentContext harusnya nil saat denied")
    precondition(agent.contextText() == nil, "contextText harusnya nil saat denied")
}

func testScreenAgentContextText() {
    let mock = MockAXClient()
    mock.snapshotToReturn = AXSnapshot(
        appName: "Notes",
        focused: "Note body",
        elements: [
            AXElementInfo(role: "static text", title: "Meeting notes", value: nil, actions: []),
        ]
    )
    let agent = ScreenAgent(ax: mock, appController: AppController(), accessibilityGranted: true)
    guard let text = agent.contextText() else {
        preconditionFailure("contextText harusnya non-nil")
    }
    precondition(text.contains("Notes"), "contextText harusnya mengandung app name, dapet: \(text)")
    precondition(text.contains("Meeting notes"), "contextText harusnya mengandung elemen, dapet: \(text)")
    precondition(text.contains("Tangkapan layar tersedia: ya"), "contextText harusnya menyebut screenshot")
}

// Keep MockAXClient accessible to Phase16 tests only (already defined above).
