import Foundation

@main
enum PerceptionMemoryTests {
    // MARK: - Fixtures

    static let snapshot = AXSnapshot(
        appName: "Safari",
        focused: "Button \"OK\"",
        elements: [
            AXElementInfo(role: "Button", title: "OK", value: nil, description: nil,
                          actions: ["AXPress"]),
            AXElementInfo(role: "TextField", title: nil, value: "search", description: nil,
                          actions: []),
            AXElementInfo(role: "StaticText", title: String(repeating: "x", count: 80),
                          value: nil, description: nil, actions: []),
            AXElementInfo(role: "Group", title: nil, value: nil, description: nil,
                          actions: ["AXShowMenu"]),
        ])

    // MARK: - Mock

    final class MockAX: AXClientProtocol, @unchecked Sendable {
        var snapshotResult: AXSnapshot
        var performError: Error?
        private(set) var performed: [AXAction] = []

        init(snapshotResult: AXSnapshot) { self.snapshotResult = snapshotResult }

        func snapshot() throws -> AXSnapshot { snapshotResult }

        func perform(_ action: AXAction) throws -> String {
            if let performError { throw performError }
            performed.append(action)
            return "mock: \(action.target)"
        }
    }

    // MARK: - Tests

    static func main() async throws {
        testAXSummary()
        testAXActionParsing()
        try testMemoryService()
        testPolicyFloor()
        try await testExecutorWithMockAX()
        testFollowUpMessages()
        print("Perception+memory: all cases passed")
    }

    static func testAXSummary() {
        let summary = snapshot.summary()
        let lines = summary.components(separatedBy: "\n")
        precondition(lines[0] == "App: Safari")
        precondition(lines[1] == "Focused: Button \"OK\"")
        precondition(lines[2] == "Elements (4):")
        precondition(lines[3] == "[0] Button \"OK\"")
        precondition(lines[4] == "[1] TextField \"search\"")
        precondition(lines[5] == "[2] StaticText \"\(String(repeating: "x", count: 60))\"")
        precondition(lines[6] == "[3] Group")
        precondition(lines.count == 7, "got \(lines.count) lines")

        // No focused element → no Focused line.
        var unfocused = snapshot
        unfocused.focused = nil
        let plain = unfocused.summary().components(separatedBy: "\n")
        precondition(plain.count == 6 && plain[1].hasPrefix("Elements ("))

        // Prefix truncation keeps the output tool-sized.
        let short = snapshot.summary(maxElements: 1).components(separatedBy: "\n")
        precondition(short.count == 4 && short[3] == "[0] Button \"OK\"")

        // The label itself caps at 60 characters inside the quotes.
        precondition(snapshot.elements[2].label.count == "StaticText \"\"".count + 60)
        precondition(snapshot.elements[0].hasText && !snapshot.elements[3].hasText)
    }

    static func testAXActionParsing() {
        precondition((try? AXAction(input: .object(["action": .string("press"),
                                                    "index": .number(3)]))) == .press(index: 3))
        precondition((try? AXAction(input: .object(["action": .string("type"),
                                                    "text": .string("hello")]))) == .typeText("hello"))
        precondition((try? AXAction(input: .object(["action": .string("key"),
                                                    "key": .string("return")]))) == .key("return"))

        func rejected(_ input: JSONValue) -> Bool {
            do { _ = try AXAction(input: input); return false }
            catch { return true }
        }
        precondition(rejected(.object([:])), "missing action must throw")
        precondition(rejected(.object(["action": .string("banana")])), "unknown action must throw")
        precondition(rejected(.object(["action": .string("press")])), "press without index must throw")
        precondition(rejected(.object(["action": .string("press"), "index": .string("0")])),
                     "string index must throw")
        precondition(rejected(.object(["action": .string("press"), "index": .number(-1)])),
                     "negative index must throw")
        precondition(rejected(.object(["action": .string("press"), "index": .number(1.5)])),
                     "fractional index must throw")
        precondition(rejected(.object(["action": .string("type"), "text": .string("")])),
                     "empty text must throw")
        precondition(rejected(.object(["action": .string("key"), "key": .string("bogus")])),
                     "unknown key must throw")

        precondition(AXAction.keyCodes["return"] == 36 && AXAction.keyCodes["up"] == 126)
        precondition((try? AXAction(input: .object(["action": .string("press"),
                                                    "index": .number(0)])))!.target == "press [0]")
        precondition((try? AXAction(input: .object(["action": .string("type"),
                                                    "text": .string("hi")])))!.target == "type hi")
        precondition((try? AXAction(input: .object(["action": .string("key"),
                                                    "key": .string("tab")])))!.target == "key tab")
    }

    static func testMemoryService() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("memory.json")

        let memory = MemoryService(url: url)
        precondition(memory.all().isEmpty && memory.formatForSystemPrompt() == "")

        // Sanitize collapses whitespace; new fact is stored newest-first.
        let firstFact = try memory.remember("  my project\n is  Coucou ")
        precondition(firstFact == true)
        precondition(memory.all().map(\.text) == ["my project is Coucou"])

        // Case-insensitive duplicate bumps the entry instead of growing the list.
        let duplicate = try memory.remember("My Project Is Coucou")
        precondition(duplicate == false)
        precondition(memory.all().count == 1)
        let secondFact = try memory.remember("prefers dark mode")
        precondition(secondFact == true)
        precondition(memory.all().map(\.text) == ["prefers dark mode", "my project is Coucou"])

        let digest = memory.formatForSystemPrompt()
        precondition(digest.hasPrefix("Facts you remember about the user:\n- prefers dark mode"))
        precondition(digest.contains("- my project is Coucou"))
        precondition(memory.formatForSystemPrompt(maxChars: 10) == "")

        // Round trip: a fresh instance reads the same file.
        let reloaded = MemoryService(url: url)
        precondition(reloaded.all().map(\.text) == memory.all().map(\.text))

        // Corrupt file degrades to empty instead of crashing.
        try Data("{not json".utf8).write(to: url)
        let broken = MemoryService(url: url)
        precondition(broken.all().isEmpty && broken.formatForSystemPrompt() == "")

        // forget() removes by id and persists.
        let keep = MemoryService(url: url)
        try keep.remember("one")
        let id = keep.all()[0].id
        try keep.forget(id)
        precondition(keep.all().isEmpty)
        precondition(MemoryService(url: url).all().isEmpty)

        precondition(MemoryService.sanitize("a\n\tb   c") == "a b c")
        precondition(MemoryService.sanitize("   ") == "")
    }

    static func testPolicyFloor() {
        // The hard floor matches shell commands; memory_save never passes fact
        // text through it, so a remembered fact containing "sudo" is not denied.
        precondition(PolicyEngine.floorReason(
            PolicyAction(category: .shell, command: "sudo whoami")) == "sudo is never allowed")
        precondition(PolicyEngine.floorReason(
            PolicyAction(category: .fileWrite, command: "memory_save")) == nil)
        precondition(PolicyEngine.floorReason(
            PolicyAction(category: .fileWrite, command: "use sudo whoami")) != nil)

        var policy = PolicyEngine()
        precondition(policy.evaluate(PolicyAction(category: .read, command: "")).decision == .allow)
        precondition(policy.evaluate(PolicyAction(category: .shell, command: "ls")).decision == .allow)
        precondition(policy.evaluate(PolicyAction(category: .fileWrite,
                                                  command: "memory_save")).decision == .confirm)
        policy.confirm(.fileWrite)
        precondition(policy.evaluate(PolicyAction(category: .fileWrite,
                                                  command: "memory_save")).decision == .allow)
    }

    static func testExecutorWithMockAX() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ax = MockAX(snapshotResult: snapshot)
        let memory = MemoryService(url: dir.appendingPathComponent("memory.json"))
        let audit = AuditLog(url: dir.appendingPathComponent("audit.jsonl"))
        var policy = PolicyEngine()
        policy.confirm(.appControl)
        policy.confirm(.fileWrite)
        let executor = ToolExecutor(policy: policy, audit: audit, confirmHandler: { _ in false },
                                    ax: ax, memory: memory)

        // ax_read: no argument, always allowed (read category).
        let read = await executor.execute(name: "ax_read", input: .object([:]))
        precondition(!read.isError, "ax_read failed: \(read.output)")
        precondition(read.output.hasPrefix("App: Safari\n") && read.output.contains("[0] Button"))
        precondition(ToolExecutor.targetDescription(name: "ax_read", input: .object([:])) == "ax_read")

        // ax_act press: routed to the AX client with the parsed action.
        let press = await executor.execute(name: "ax_act",
            input: .object(["action": .string("press"), "index": .number(1)]))
        precondition(!press.isError, "ax_act failed: \(press.output)")
        precondition(ax.performed == [.press(index: 1)])
        precondition(press.output == "mock: press [1]")
        precondition(ToolExecutor.targetDescription(
            name: "ax_act", input: .object(["action": .string("press"),
                                            "index": .number(1)])) == "press [1]")

        // Missing "action" fails before policy/audit sees a target.
        let missing = await executor.execute(name: "ax_act", input: .object([:]))
        precondition(missing.isError && missing.output.contains("Missing required argument"))

        // Invalid action is rejected at parse time (never reaches the AX API).
        let invalid = await executor.execute(name: "ax_act",
            input: .object(["action": .string("banana")]))
        precondition(invalid.isError && invalid.output.contains("Invalid action"))
        precondition(ax.performed.count == 1, "no extra AX calls after parse failure")

        // memory_save: fact text with "sudo" still saves (no floor on facts).
        let saved = await executor.execute(name: "memory_save",
            input: .object(["text": .string("use sudo whoami for root")]))
        precondition(!saved.isError && saved.output == "Remembered.")
        precondition(memory.all().map(\.text) == ["use sudo whoami for root"])
        precondition(ToolExecutor.targetDescription(
            name: "memory_save", input: .object(["text": .string("use sudo whoami for root")]))
            == "use sudo whoami for root")

        let again = await executor.execute(name: "memory_save",
            input: .object(["text": .string("use sudo whoami for root")]))
        precondition(!again.isError && again.output.hasPrefix("Already remembered"))
        precondition(memory.all().count == 1)

        // The same text as a shell command is still floored.
        let blocked = await executor.execute(name: "shell_run",
            input: .object(["command": .string("sudo whoami")]))
        precondition(blocked.isError && blocked.output.contains("sudo is never allowed"))
        precondition(memory.all().count == 1, "denied shell must not touch memory")

        // Audit trail: allows, parse deny and floor deny all recorded.
        let entries = audit.entries()
        precondition(entries.contains { $0.action == "ax_read" && $0.decision == "allow"
                                        && $0.category == "read" })
        precondition(entries.contains { $0.action == "ax_act" && $0.decision == "allow"
                                        && $0.target == "press [1]" })
        precondition(entries.contains { $0.action == "ax_act" && $0.decision == "deny"
                                        && $0.reason == "invalid action" })
        precondition(entries.contains { $0.action == "memory_save" && $0.decision == "allow"
                                        && $0.target == "use sudo whoami for root" })
        precondition(entries.contains { $0.action == "shell_run" && $0.decision == "deny"
                                        && $0.reason == "sudo is never allowed" })

        // Permission errors surface as readable tool output, not crashes.
        ax.performError = AccessibilityError.permissionDenied
        let denied = await executor.execute(name: "ax_act",
            input: .object(["action": .string("press"), "index": .number(0)]))
        precondition(denied.isError && denied.output.contains("Accessibility permission"))
    }

    static func testFollowUpMessages() {
        precondition(Array(ToolExecutor.tools.map(\.name).suffix(15))
            == ["ax_read", "ax_act", "memory_save", "claude_run", "automation_run", "window_list", "window_act",
                "node_http_request", "node_file_system", "node_cron_schedule",
                "node_if_else", "node_json_transform", "node_desktop_notification",
                "node_clipboard", "node_run_shell"])
        precondition(ToolExecutor.tools.count == 24)

        precondition(AgentController.followUpMessages(images: []).isEmpty)

        let images = [
            ToolImage(mediaType: "image/png", base64: "AAAA"),
            ToolImage(mediaType: "image/png", base64: "BBBB"),
        ]
        let messages = AgentController.followUpMessages(images: images)
        precondition(messages.count == 2)
        precondition(messages.allSatisfy { $0.role == .user })
        precondition(messages[0].content.count == 2)
        guard case .text(let caption) = messages[0].content[0] else {
            preconditionFailure("first block must be the caption")
        }
        precondition(caption == "Screenshot from app_screenshot:")
        guard case .image(let mediaType, let base64) = messages[0].content[1] else {
            preconditionFailure("second block must be the image")
        }
        precondition(mediaType == "image/png" && base64 == "AAAA")
        guard case .image(_, let second) = messages[1].content[1] else {
            preconditionFailure("second message must carry its own image")
        }
        precondition(second == "BBBB")
    }
}
