import Foundation

// MARK: - Phase 9: Run & Access Applications (automation + window + media)

@main enum Phase9Tests {
    static func main() async throws {
        testAppAutomationApplescript()
        testAppAutomationJavascript()
        testAppAutomationError()
        testWindowControllerList()
        testWindowControllerFocusMoveResize()
        await testToolExecutorAutomationRun()
        await testToolExecutorWindowList()
        await testToolExecutorWindowAct()
        print("Phase9Tests: all cases passed")
    }
}

// MARK: - AppAutomation

func testAppAutomationApplescript() {
    let output = try? AppAutomation.run("return \"hello from applescript\"", language: .applescript)
    precondition(output == "hello from applescript", "unexpected: \(output as Any)")
}

func testAppAutomationJavascript() {
    let output = try? AppAutomation.run("42", language: .javascript)
    precondition(output == "42", "unexpected: \(output as Any)")
}

func testAppAutomationError() {
    do {
        _ = try AppAutomation.run("this is not valid applescript ::::", language: .applescript)
        preconditionFailure("expected osascript error")
    } catch let e as AppAutomationError {
        precondition(e.description.contains("Automation error"), "got: \(e)")
    } catch {
        preconditionFailure("wrong error type: \(error)")
    }
}

// MARK: - WindowController

func testWindowControllerList() {
    let windows = SystemWindowController().listWindows()
    // Should not crash; may be empty in headless test env.
    precondition(windows.allSatisfy { !$0.appName.isEmpty }, "bad window info: \(windows)")
    for w in windows.prefix(5) {
        _ = w.windowNumber
        _ = w.bounds
        _ = w.isMain
        _ = w.isMinimized
    }
}

func testWindowControllerFocusMoveResize() {
    let controller = SystemWindowController()
    // Non-existent window number → false (no crash).
    precondition(!controller.focus(windowNumber: 999999))
    precondition(!controller.move(windowNumber: 999999, to: .zero))
    precondition(!controller.resize(windowNumber: 999999, size: .zero))
}

// MARK: - ToolExecutor

func testToolExecutorAutomationRun() async {
    let executor = ToolExecutor(confirmHandler: { _ in true })
    let result = await executor.execute(name: "automation_run", input: .object([
        "script": .string("return \"automation-ok\""),
        "language": .string("applescript"),
    ]))
    precondition(!result.isError, "automation_run failed: \(result.output)")
    precondition(result.output.contains("automation-ok"), "output: \(result.output)")

    // Missing script → error.
    let missing = await executor.execute(name: "automation_run", input: .object([:]))
    precondition(missing.isError && missing.output.contains("Missing required argument"))
}

func testToolExecutorWindowList() async {
    let executor = ToolExecutor(confirmHandler: { _ in true })
    let result = await executor.execute(name: "window_list", input: .object([:]))
    precondition(!result.isError, "window_list failed: \(result.output)")
    precondition(result.output.contains("Visible windows") || result.output.contains("No visible windows"))
}

func testToolExecutorWindowAct() async {
    let executor = ToolExecutor(confirmHandler: { _ in true })
    // Non-existent window → error result (not crash).
    let focus = await executor.execute(name: "window_act", input: .object([
        "action": .string("focus"),
        "window": .number(999999),
    ]))
    precondition(focus.isError || !focus.output.contains("Focused window [999999]"),
                 "should not succeed on nonexistent window: \(focus.output)")

    // Invalid action → error.
    let bad = await executor.execute(name: "window_act", input: .object([
        "action": .string("fly"),
        "window": .number(1),
    ]))
    precondition(bad.isError && bad.output.contains("Unknown window_act action"), "got: \(bad.output)")

    // move without x/y → error.
    let move = await executor.execute(name: "window_act", input: .object([
        "action": .string("move"),
        "window": .number(1),
    ]))
    precondition(move.isError && move.output.contains("requires numeric"), "got: \(move.output)")
}
