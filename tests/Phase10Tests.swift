import Foundation

// MARK: - Phase 10: Scheduler + Workflow Engine + Autonomous Agent

@main enum Phase10Tests {
    static func main() async throws {
        testAutonomousTaskModel()
        testTaskSchedulerDueAt()
        testTaskSchedulerNextRun()
        testTaskSchedulerAddRemoveEnable()
        testWorkflowEnginePlan()
        await testWorkflowEnginePlanAutonomous()
        await testWorkflowEngineRunShell()
        print("Phase10Tests: all cases passed")
    }
}

// MARK: - AutonomousTask

func testAutonomousTaskModel() {
    let task = AutonomousTask(
        id: "t1",
        goal: "cari cara install node js",
        createdAt: .distantPast,
        source: "user"
    )
    precondition(task.id == "t1")
    precondition(task.goal == "cari cara install node js")
    precondition(task.status == .pending)
    precondition(task.steps.isEmpty)

    var t2 = task
    t2.status = .running
    t2.steps = [AutonomousStep(id: "s1", name: "search", tool: "web_search",
                               input: ["query": .string("node")])]
    precondition(t2.status == .running)
    precondition(t2.steps.count == 1)
    precondition(t2.steps[0].tool == "web_search")
}

// MARK: - TaskScheduler

func testTaskSchedulerDueAt() {
    let scheduler = TaskScheduler.shared
    let cal = Calendar.current
    var comps = DateComponents()
    comps.year = 2026; comps.month = 10; comps.day = 19
    comps.hour = 14; comps.minute = 30; comps.second = 0
    let now = cal.date(from: comps)!

    // Daily 14:30, now 14:30 → due.
    let daily = ScheduledTask(id: "d1", goal: "test", frequency: "daily", hour: 14, minute: 30)
    precondition(scheduler.dueAt(daily, now: now), "daily 14:30 should be due at 14:30")

    // Daily 14:30, now 14:29 → not due.
    var comps29 = comps; comps29.minute = 29
    let now29 = cal.date(from: comps29)!
    precondition(!scheduler.dueAt(daily, now: now29), "daily 14:30 should not be due at 14:29")

    // Weekly Monday (2), now Monday 14:30 → due.
    let weekly = ScheduledTask(id: "w1", goal: "test", frequency: "weekly", hour: 14, minute: 30, weekday: 2)
    precondition(scheduler.dueAt(weekly, now: now), "weekly Mon 14:30 should be due on Monday")

    // Weekly Monday, now Tuesday (Oct 20) → not due.
    var compsTue = DateComponents()
    compsTue.year = 2026; compsTue.month = 10; compsTue.day = 20
    compsTue.hour = 14; compsTue.minute = 30; compsTue.second = 0
    let nowTue = cal.date(from: compsTue)!
    precondition(!scheduler.dueAt(weekly, now: nowTue), "weekly Mon should not be due on Tuesday")

    // Disabled task is handled by caller (dueAt ignores enabled), but lastRun same minute → not due.
    let sameMin = ScheduledTask(id: "s1", goal: "test", frequency: "daily", hour: 14, minute: 30)
    var withLast = sameMin
    withLast.lastRun = now
    // dueAt checks lastRun same hour+minute → false.
    precondition(!scheduler.dueAt(withLast, now: now), "already run this minute → not due")
}

func testTaskSchedulerNextRun() {
    let scheduler = TaskScheduler.shared
    let cal = Calendar.current
    var comps = DateComponents()
    comps.year = 2026; comps.month = 10; comps.day = 19
    comps.hour = 10; comps.minute = 0; comps.second = 0
    let now = cal.date(from: comps)!

    // Daily 14:00 from 10:00 → today 14:00.
    let daily = ScheduledTask(id: "d1", goal: "test", frequency: "daily", hour: 14, minute: 0)
    let next = scheduler.nextRun(after: now, for: daily)
    let nextComps = cal.dateComponents([.hour, .minute], from: next)
    precondition(nextComps.hour == 14 && nextComps.minute == 0, "next daily should be 14:00, got \(nextComps)")

    // Daily 09:00 from 10:00 → tomorrow 09:00.
    let dailyEarly = ScheduledTask(id: "d2", goal: "test", frequency: "daily", hour: 9, minute: 0)
    let next2 = scheduler.nextRun(after: now, for: dailyEarly)
    let next2Comps = cal.dateComponents([.hour, .minute], from: next2)
    precondition(next2Comps.hour == 9 && next2Comps.minute == 0, "next daily early should be 09:00 tomorrow")
    precondition(cal.isDate(next2, inSameDayAs: cal.date(byAdding: .day, value: 1, to: now)!),
                 "next daily early should be tomorrow")
}

func testTaskSchedulerAddRemoveEnable() {
    let scheduler = TaskScheduler.shared
    // Bersihkan dulu untuk isolasi tes.
    scheduler.remove(id: "a")
    precondition(scheduler.all.isEmpty)

    let t1 = ScheduledTask(id: "a", goal: "g1", frequency: "daily", hour: 8, minute: 0)
    scheduler.add(t1)
    precondition(scheduler.all.count == 1)
    precondition(scheduler.all[0].enabled == true)

    scheduler.setEnabled(id: "a", enabled: false)
    precondition(scheduler.all[0].enabled == false)

    scheduler.setEnabled(id: "a", enabled: true)
    precondition(scheduler.all[0].enabled == true)

    scheduler.remove(id: "a")
    precondition(scheduler.all.isEmpty)

    // Add duplicate id replaces.
    scheduler.add(t1)
    scheduler.add(ScheduledTask(id: "a", goal: "g2", frequency: "daily", hour: 9, minute: 0))
    precondition(scheduler.all.count == 1)
    precondition(scheduler.all[0].goal == "g2")
}

// MARK: - WorkflowEngine

func testWorkflowEnginePlan() {
    let engine = WorkflowEngine.shared

    // "cari ..." → web_search.
    let s1 = engine.plan(goal: "cari cara install node js")
    precondition(s1.contains { $0.tool == "web_search" }, "plan should include web_search: \(s1)")

    // "buka Safari" → app_open.
    let s2 = engine.plan(goal: "buka Safari")
    precondition(s2.contains { $0.tool == "app_open" }, "plan should include app_open: \(s2)")
    precondition(s2.contains { $0.input["target"]?.stringValue == "Safari" },
                 "app_open target should be Safari: \(s2)")

    // "tulis file ke ~/note.txt dengan isi halo" → file_write.
    let s3 = engine.plan(goal: "tulis file ke ~/note.txt dengan isi halo dunia")
    precondition(s3.contains { $0.tool == "file_write" }, "plan should include file_write: \(s3)")
    precondition(s3.contains { $0.input["path"]?.stringValue == "~/note.txt" },
                 "file_write path should be ~/note.txt: \(s3)")

    // Default → shell_run.
    let s4 = engine.plan(goal: "halo apa kabar")
    precondition(s4.contains { $0.tool == "shell_run" }, "default should be shell_run: \(s4)")
}

final class ScriptedPlannerProvider: LLMProvider, @unchecked Sendable {
    let id = "scripted_planner"
    let displayName = "Scripted Planner"
    let defaultModel = "mock"
    let fallbackModels: [(id: String, label: String)] = [("mock", "Mock")]

    var responseText: String
    init(responseText: String) { self.responseText = responseText }

    func isConfigured() -> Bool { true }
    func listModels() async -> [(id: String, label: String)] { [("mock", "Mock")] }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(content: [.text(responseText)], stopReason: .endTurn)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(LLMResponse(content: [.text(self.responseText)], stopReason: .endTurn)))
            continuation.finish()
        }
    }
}

func testWorkflowEnginePlanAutonomous() async {
    let engine = WorkflowEngine.shared

    // 1. Valid JSON returned by LLM planner
    let jsonPlan = """
    [
      {"name": "Cari data", "tool": "web_search", "input": {"query": "berita hari ini"}},
      {"name": "Tulis ringkasan", "tool": "file_write", "input": {"path": "~/berita.txt", "content": "konten"}}
    ]
    """
    let provider = ScriptedPlannerProvider(responseText: jsonPlan)
    let steps = await engine.planAutonomous(goal: "cari berita lalu simpan", provider: provider, model: "mock")
    precondition(steps.count == 2, "planAutonomous should return 2 steps, got \(steps.count)")
    precondition(steps[0].tool == "web_search", "first step tool should be web_search")
    precondition(steps[0].input["query"]?.stringValue == "berita hari ini", "query should match")
    precondition(steps[1].tool == "file_write", "second step tool should be file_write")

    // 2. Invalid JSON from LLM -> fallback to deterministic plan
    let badProvider = ScriptedPlannerProvider(responseText: "bukan json valid sama sekali")
    let fallbackSteps = await engine.planAutonomous(goal: "cari cara install node js", provider: badProvider, model: "mock")
    precondition(!fallbackSteps.isEmpty, "should fallback to deterministic plan")
    precondition(fallbackSteps.contains { $0.tool == "web_search" }, "fallback should have web_search")
}

func testWorkflowEngineRunShell() async {
    let executor = ToolExecutor(confirmHandler: { _ in true })
    let result = await executor.execute(name: "shell_run", input: .object([
        "command": .string("echo phase10-ok")
    ]))
    precondition(!result.isError, "shell_run should succeed: \(result.output)")
    precondition(result.output.contains("phase10-ok"), "output should contain phase10-ok: \(result.output)")
    precondition(result.exitCode == 0, "exit code should be 0: \(result.exitCode as Any)")
}
