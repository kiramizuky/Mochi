import Foundation

@main
enum InternetAppTests {
    // MARK: - Fixtures

    static let ddgHTML = """
    <html><body>
    <div class="result"><a class="result__a" href="https://example.com/page">Example <b>Title</b></a>\
    <a class="result__snippet" href="https://example.com/page">Snippet with &amp; entity</a></div>
    <div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fblog%2F%3Futm%3D1&amp;rut=abc">Swift Blog</a>\
    <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fblog%2F%3Futm%3D1&amp;rut=abc">Second snippet</a></div>
    </body></html>
    """

    static let apps = [
        RunningAppInfo(name: "Safari", bundleID: "com.apple.Safari", pid: 10, isActive: true),
        RunningAppInfo(name: "Terminal", bundleID: "com.apple.Terminal", pid: 20, isActive: false),
        RunningAppInfo(name: "Notes", bundleID: "com.apple.Notes", pid: 101, isActive: false),
        RunningAppInfo(name: "Notion", bundleID: "notion.id", pid: 102, isActive: true),
    ]

    // MARK: - Mock

    final class MockWorkspace: WorkspaceControlling, @unchecked Sendable {
        var terminated: [Int32] = []
        private let apps: [RunningAppInfo]
        init(apps: [RunningAppInfo]) { self.apps = apps }
        func listRunningApplications() -> [RunningAppInfo] { apps }
        func terminate(pid: Int32) -> Bool {
            terminated.append(pid)
            return true
        }
    }

    // MARK: - Tests

    static func main() async throws {
        try await testParsing()
        testResolveRedirect()
        testDecodeEntities()
        testReadableText()
        testFormatForContext()
        testMatch()
        testFormatList()
        try testCloseAndList()
        await testToolSurface()

        print("Internet+apps: all cases passed")
    }

    static func testParsing() async throws {
        // Two results, entity in snippet, <b> stripped from title, uddg redirect resolved.
        let two = InternetService.searchResults(from: ddgHTML)
        precondition(two.count == 2, "expected 2 results, got \(two.count)")
        precondition(two[0].title == "Example Title", "got: \(two[0].title)")
        precondition(two[0].url == "https://example.com/page", "got: \(two[0].url)")
        precondition(two[0].snippet == "Snippet with & entity", "got: \(two[0].snippet)")
        precondition(two[1].title == "Swift Blog", "got: \(two[1].title)")
        precondition(two[1].url == "https://swift.org/blog/?utm=1", "got: \(two[1].url)")
        precondition(two[1].snippet == "Second snippet", "got: \(two[1].snippet)")

        // limit = 1 keeps only the first result.
        let one = InternetService.searchResults(from: ddgHTML, limit: 1)
        precondition(one.count == 1 && one[0].title == "Example Title")

        // Empty HTML → no results.
        precondition(InternetService.searchResults(from: "").isEmpty)
        precondition(InternetService.searchResults(from: "<html></html>").isEmpty)

        // Bare title (no snippet) → empty snippet, still counted.
        let bare = #"<a class="result__a" href="https://example.com/only">Only Title</a>"#
        let bareResults = InternetService.searchResults(from: bare)
        precondition(bareResults.count == 1)
        precondition(bareResults[0].title == "Only Title")
        precondition(bareResults[0].snippet == "")

        // href before class in the attribute list still matches (order-agnostic).
        let reversed = #"<a href="https://swift.org/blog/" class="result__a">Swift Blog</a>"# +
            #"<a href="https://swift.org/blog/" class="result__snippet">A snippet</a>"#
        let reversedResults = InternetService.searchResults(from: reversed)
        precondition(reversedResults.count == 1)
        precondition(reversedResults[0].title == "Swift Blog")
        precondition(reversedResults[0].snippet == "A snippet")

        // Invalid query over the network API throws before any request.
        do {
            _ = try await InternetService.search("   ")
            precondition(false, "empty query must throw")
        } catch let error as InternetError {
            precondition(error == .invalidQuery, "got \(error)")
        }

        // Non-web URL on fetchPage throws locally.
        do {
            _ = try await InternetService.fetchPage("file:///etc/hosts")
            precondition(false, "file URL must throw")
        } catch let error as InternetError {
            precondition(error == .invalidURL("file:///etc/hosts"), "got \(error)")
        }
    }

    static func testResolveRedirect() {
        precondition(InternetService.resolveRedirect("https://example.com/x")?.absoluteString
            == "https://example.com/x")
        precondition(InternetService.resolveRedirect("//example.com/a&amp;b")?.absoluteString
            == "https://example.com/a&b")
        precondition(InternetService.resolveRedirect("/relative") == nil)
        precondition(InternetService.resolveRedirect("javascript:alert(1)") == nil)
        precondition(InternetService.resolveRedirect("") == nil)
    }

    static func testDecodeEntities() {
        precondition(InternetService.decodeEntities("A &amp; B &lt;x&gt; &quot;q&quot;")
            == "A & B <x> \"q\"")
        precondition(InternetService.decodeEntities("it&#39;s") == "it's")
        precondition(InternetService.decodeEntities("&#x27;") == "'")
        precondition(InternetService.decodeEntities("&foo;") == "&foo;")
        precondition(InternetService.decodeEntities("no entities here") == "no entities here")
    }

    static func testReadableText() {
        precondition(
            InternetService.readableText(
                from: "<p>Hello</p><script>var x = 1;</script><p>World &amp; Co</p>")
            == "Hello\nWorld & Co")

        precondition(
            InternetService.readableText(
                from: "<header>line1</header><div>line2<br></div><footer>nav</footer>")
            == "line2")

        let capped = InternetService.readableText(
            from: "<p>\(String(repeating: "a", count: 11))</p>", maxChars: 10)
        precondition(capped == String(repeating: "a", count: 10) + "…", "got: \(capped)")

        precondition(InternetService.readableText(from: "") == "")
    }

    static func testFormatForContext() {
        precondition(InternetService.formatForContext([], query: "q") == "No web results found.")

        let eight = (1...8).map {
            WebSearchResult(title: "T\($0)", url: "https://e.com/\($0)", snippet: "s")
        }
        let capped = InternetService.formatForContext(eight, query: "q")
        precondition(capped.contains("\n6. T6"), "limit not applied")
        precondition(!capped.contains("\n7. T7"), "limit not applied")

        let longSnippet = String(repeating: "x", count: 300)
        let snippetCapped = InternetService.formatForContext(
            [WebSearchResult(title: "T", url: "https://e.com", snippet: longSnippet)], query: "q")
        precondition(snippetCapped.contains(String(repeating: "x", count: 240)))
        precondition(!snippetCapped.contains(String(repeating: "x", count: 241)))
    }

    static func testMatch() {
        precondition(AppController.match(query: "SAFARI", in: apps)?.name == "Safari")
        precondition(AppController.match(query: "com.apple.Safari", in: apps)?.name == "Safari")
        precondition(AppController.match(query: "Safari.app", in: apps)?.name == "Safari")
        precondition(AppController.match(query: "erminal", in: apps)?.name == "Terminal")
        // Prefix match prefers the active app ("Notes" vs "Notion").
        precondition(AppController.match(query: "not", in: apps)?.name == "Notion")
        precondition(AppController.match(query: "firefox", in: apps) == nil)
        precondition(AppController.match(query: "", in: apps) == nil)
        precondition(AppController.match(query: "   ", in: apps) == nil)
    }

    static func testFormatList() {
        precondition(AppController.formatList([]) == "No regular applications are running.")

        let four = [
            RunningAppInfo(name: "A", bundleID: "a.id", pid: 1, isActive: false),
            RunningAppInfo(name: "B", bundleID: "b.id", pid: 2, isActive: true),
            RunningAppInfo(name: "C", bundleID: "c.id", pid: 3, isActive: false),
            RunningAppInfo(name: "D", bundleID: "d.id", pid: 4, isActive: false),
        ]
        let limited = AppController.formatList(four, limit: 3)
        precondition(limited.hasPrefix("Running applications (4):"))
        precondition(limited.contains("- A"))
        precondition(limited.contains("- B (frontmost)"))
        precondition(limited.contains("- C — c.id"))
        precondition(!limited.contains("- D"))
        precondition(limited.contains("and 1 more"))
    }

    static func testCloseAndList() throws {
        let mock = MockWorkspace(apps: apps)
        let controller = AppController(workspace: mock)

        let message = try controller.close("terminal")
        precondition(message == "Quit requested for Terminal.", "got: \(message)")
        precondition(mock.terminated == [20], "terminated pids: \(mock.terminated)")

        var threwNoMatch = false
        do {
            _ = try controller.close("firefox")
        } catch let error as AppError {
            if case .noMatch(let value) = error { threwNoMatch = (value == "firefox") }
        }
        precondition(threwNoMatch, "close of unknown app must throw noMatch")

        let list = controller.list(filter: "term")
        precondition(list == "Running applications (1):\n- Terminal — com.apple.Terminal",
                     "got: \(list)")
        precondition(controller.list(filter: "zzz") == "No regular applications are running.")
        precondition(controller.list(filter: nil).hasPrefix("Running applications (4):"))
    }

    static func testToolSurface() async {
        let names = ToolExecutor.tools.map(\.name)
        precondition(
            names == ["shell_run", "file_read", "file_write", "app_open",
                      "web_search", "web_fetch", "app_list", "app_close", "app_screenshot",
                      "ax_read", "ax_act", "memory_save", "claude_run", "automation_run", "window_list", "window_act",
                      "node_http_request", "node_file_system", "node_cron_schedule", "node_if_else",
                      "node_json_transform", "node_desktop_notification", "node_clipboard", "node_run_shell"],
            "tool names: \(names)")

        for def in ToolExecutor.tools {
            precondition(!def.description.isEmpty, "empty description for \(def.name)")
            if case .object(let schema) = def.inputSchema {
                precondition(schema["type"] != nil, "no type in \(def.name) schema")
                precondition(schema["properties"] != nil, "no properties in \(def.name) schema")
            } else {
                precondition(false, "schema is not an object for \(def.name)")
            }
        }

        precondition(ToolExecutor.targetDescription(
            name: "web_search", input: .object(["query": .string("swift concurrency")]))
            == "swift concurrency")
        precondition(ToolExecutor.targetDescription(
            name: "web_fetch", input: .object(["url": .string("https://example.com")]))
            == "https://example.com")
        precondition(ToolExecutor.targetDescription(
            name: "app_close", input: .object(["name": .string("Safari")])) == "Safari")
        precondition(ToolExecutor.targetDescription(
            name: "app_screenshot", input: .object(["name": .string("Safari")])) == "Safari")

        // Missing required argument is rejected before any network call.
        let executor = ToolExecutor()
        let missing = await executor.execute(name: "web_search", input: .object([:]))
        precondition(missing.isError, "missing argument must be an error")
        precondition(missing.output.contains("Missing required argument"),
                     "got: \(missing.output)")
    }
}
