import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private(set) var islandController: IslandWindowController?
    private(set) var mcpBridge: MCPBridge?
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — prevents crash when nb-hook closes socket before we write response
        signal(SIGPIPE, SIG_IGN)

        // Prevent App Nap from freezing the event loop & polling timers during idle periods
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Coucou UI responsiveness and notch hover interaction"
        )

        NSApp.setActivationPolicy(.accessory)

        // Setup menu bar first so app appears immediately
        setupMenuBarItem()

        // Do heavy initialization asynchronously to avoid blocking UI
        Task { @MainActor in
            do {
                try await setupIslandAsync()
            } catch {
                print("⚠️ Island setup error: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func setupIslandAsync() async {
        // Warm up Keychain cache
        _ = KeychainStore.shared

        // Load MCP server config
        if let data = UserDefaults.standard.data(forKey: "mcpServers"),
           let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            AppState.shared.mcpServers = servers
        }

        // Install crash reporter
        CrashReporter.shared.install()

        // Setup island panel
        islandController = IslandWindowController()
        islandController?.showWindow(nil)
        islandController?.fsm.launch()

        // Start hook server (Unix socket for Claude Code hooks)
        HookServer.shared.start()

        // Start existing integration pollers
        N8nPoller.shared.start()
        VercelPoller.shared.start()
        ResendPoller.shared.start()
        GithubPoller.shared.start()
        StripePoller.shared.start()
        CalcomPoller.shared.start()
        NotionPoller.shared.start()

        // Start generic integration pollers for all active integrations
        for config in AgentTask.integrationPollConfigs {
            GenericIntegrationPoller.shared.start(for: config)
        }

        // Setup MCP bridge for external agent communication
        let bridge = MCPBridge()
        bridge.server.register(name: "notch.expand") { _ in
            await Task { @MainActor in
                AppState.shared.mode = .expanded
                AppState.shared.view = .overview
            }.value
            return .string("expanded")
        }
        bridge.server.register(name: "notch.collapse") { _ in
            await Task { @MainActor in
                AppState.shared.mode = .hidden
            }.value
            return .string("hidden")
        }
        bridge.server.register(name: "notch.setView") { params in
            guard let params,
                  case .string(let viewName) = params["view"] ?? .null else {
                throw MCPError.request("missing view")
            }
            await Task { @MainActor in
                AppState.shared.mode = .expanded
                switch viewName {
                case "prompt":   AppState.shared.view = .prompt
                case "overview": AppState.shared.view = .overview
                case "result":   AppState.shared.view = .result
                case "note":     AppState.shared.view = .note
                case "approval": AppState.shared.view = .approval
                default:         AppState.shared.view = .overview
                }
            }.value
            return .string(viewName)
        }
        bridge.server.register(name: "chat.send") { params in
            guard let params,
                  case .string(let text) = params["text"] ?? .null,
                  !text.isEmpty else {
                throw MCPError.request("missing text")
            }
            await Task { @MainActor in
                AppState.shared.chatHistory.append(ChatMessage(role: .user, content: text))
                AppState.shared.stateOverride = .thinking
                AppState.shared.view = .prompt
                await ClaudeService.shared.chat(query: text, context: nil, state: AppState.shared)
            }.value
            return .string("sent")
        }
        bridge.server.register(name: "chat.history") { _ in
            let history = await Task { @MainActor in
                AppState.shared.chatHistory
            }.value
            return .array(history.map { msg in
                .object([
                    "role": .string(msg.role == .user ? "user" : "assistant"),
                    "content": .string(msg.content),
                ])
            })
        }
        self.mcpBridge = bridge

        // Setup task scheduler for autonomous tasks
        TaskScheduler.shared.isHidden = { AppState.shared.mode == .hidden }
        TaskScheduler.shared.onTaskAdded = { task in
            Task { @MainActor in
                await AutonomousAgent.shared.submit(goal: task.goal, source: "scheduler")
            }
        }
        TaskScheduler.shared.start()

        // Setup ProactiveEngine, Ambient Context Observer, Idle Detection, & Sensory Event Hub (Clipboard & FS)
        ProactiveEngine.shared.refresh()
        AppState.shared.proactiveChips = ProactiveEngine.shared.chips
        AmbientContextObserver.shared.start()
        IdleDetectionEngine.shared.start()
        SensoryEventHub.shared.start()
        TelegramGatewayService.shared.start()
        _ = NightShiftWorker.shared

        NotificationCenter.default.addObserver(forName: .proactiveEngineRefresh, object: nil, queue: .main) { _ in
            Task { @MainActor in
                ProactiveEngine.shared.refresh()
                AppState.shared.proactiveChips = ProactiveEngine.shared.chips
            }
        }

        // Show onboarding on first launch
        if !AppState.shared.hasOnboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openOnboarding()
            }
        }

        // Handle openFullSettings from notch UI
        NotificationCenter.default.addObserver(forName: .openFullSettings, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
        }
    }

    // MARK: - Menu bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Coucou")
        button.image?.size = NSSize(width: 24, height: 18)
        button.image?.accessibilityDescription = "Coucou"
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Coucou", action: #selector(openIsland), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openIsland() {
        islandController?.expand(to: .overview)
    }

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    @objc private func openSettings() {
        if AppState.shared.mode == .expanded { islandController?.collapse() }

        if let w = settingsWindow, w.isVisible {
            placeBelowIsland(w)
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 740),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Settings — Coucou"
        let host = NSHostingView(rootView: SettingsView())
        host.sizingOptions = [.minSize]
        win.contentView = host
        win.contentMinSize = NSSize(width: 500, height: 420)
        win.isReleasedWhenClosed = false
        placeBelowIsland(win)
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openOnboarding() {
        if let w = onboardingWindow, w.isVisible {
            placeBelowIsland(w)
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Setup — Coucou"
        let host = NSHostingView(rootView: OnboardingView(state: AppState.shared))
        host.sizingOptions = [.minSize]
        win.contentView = host
        win.contentMinSize = NSSize(width: 460, height: 560)
        win.isReleasedWhenClosed = false
        placeBelowIsland(win)
        onboardingWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func placeBelowIsland(_ win: NSWindow) {
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main ?? win.screen
        guard let screen else { win.center(); return }
        let visible = screen.visibleFrame
        let islandBottom = screen.frame.maxY - 320 - 12
        let top = min(visible.maxY, islandBottom)
        var frame = win.frame
        frame.size.height = min(frame.height, max(top - visible.minY - 12, win.minSize.height))
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = max(visible.minY + 12, top - frame.height)
        win.setFrame(frame, display: true)
    }
}
