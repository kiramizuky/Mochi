import SwiftUI
import ServiceManagement
import AppKit

// MARK: - Settings Tab Definition

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "Umum"
    case persona = "Persona & Suara"
    case models = "AI & Model"
    case autonomous = "Otonom & Sensor"
    case tools = "Dynamic Tools"
    case telegram = "Mobile & Telegram"
    case integrations = "Integrasi & MCP"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:      return "gearshape.fill"
        case .persona:      return "face.smiling.fill"
        case .models:       return "cpu.fill"
        case .autonomous:   return "bolt.shield.fill"
        case .tools:        return "wrench.and.screwdriver.fill"
        case .telegram:     return "paperplane.fill"
        case .integrations: return "puzzlepiece.extension.fill"
        }
    }
}

// MARK: - Main Settings View

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var voice = VoiceManager.shared

    @State private var selectedTab: SettingsTab = .general

    // Status Message Feedback
    @State private var statusMessage: String = ""

    // AI & Providers
    @State private var selectedProviderId: String = ProviderRegistry.shared.activeProviderId
    @State private var apiKey: String = KeychainStore.shared.get(
        ProviderRegistry.shared.activeProviderId + "-api-key") ?? ""
    @State private var poolKeys: [AIKeyItem] = ProviderRegistry.shared.keys(for: ProviderRegistry.shared.activeProviderId)
    @State private var newKeyLabel: String = ""
    @State private var newKeySecret: String = ""
    @State private var showAddKeyForm: Bool = false

    private static let customModelTag = "__custom__"
    @State private var fetchedModels: [(id: String, label: String)] = []
    @State private var modelChoice: String = {
        let m = AppState.shared.claudeModel
        let fb = ProviderRegistry.shared.activeProvider.fallbackModels
        return fb.contains { $0.id == m } ? m : SettingsView.customModelTag
    }()
    @State private var customModel: String = {
        let m = AppState.shared.claudeModel
        let fb = ProviderRegistry.shared.activeProvider.fallbackModels
        return fb.contains { $0.id == m } ? "" : m
    }()

    private var displayModels: [(id: String, label: String)] {
        fetchedModels.isEmpty ? selectedProvider.fallbackModels : fetchedModels
    }
    private var providers: [(id: String, name: String)] {
        ProviderRegistry.shared.available.map { ($0.id, $0.displayName) }
    }
    private var selectedProvider: any LLMProvider {
        ProviderRegistry.shared.provider(id: selectedProviderId) ?? ProviderRegistry.shared.activeProvider
    }
    private var keyPlaceholder: String {
        switch selectedProviderId {
        case "openai": return "API key (sk-…)"
        case "gemini": return "API key (AIza…)"
        case "groq":   return "API key (gsk_…)"
        default:       return "API key (sk-ant-…)"
        }
    }

    // Smart Intent Router & Ollama
    @AppStorage("smartIntentRoutingEnabled") private var smartIntentRoutingEnabled: Bool = true
    @State private var ollamaStatus: String = ""

    // General & Startup
    @State private var launchAtStartup: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var hotkeyFlags: UInt    = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16   = AppState.shared.hotkeyCode

    // Auto-update
    @State private var updateAvailable: AppRelease?
    @State private var showUpdateAlert: Bool = false

    // Autonomous, CUA & Sensory Watchers
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()
    @State private var nightShiftRunning: Bool = false
    @AppStorage("fileSystemWatcherEnabled") private var fileSystemWatcherEnabled: Bool = true
    @AppStorage("clipboardWatcherEnabled") private var clipboardWatcherEnabled: Bool = true

    // Visual Perception, Face & CCTV
    @State private var isEnrollingFace: Bool = false
    @State private var faceEnrollmentStatus: Bool = FaceRecognitionService.shared.isOwnerEnrolled
    @State private var cctvCamerasList: [CCTVCameraConfig] = CCTVGatewayService.shared.listCameras()
    @State private var newCCTVName: String = ""
    @State private var newCCTVLocation: String = ""
    @State private var newCCTVUrl: String = ""
    @State private var isTestingCCTV: Bool = false

    // Proactive Sentry & Autonomous Health Watchers (Paket 11)
    @State private var sentryAwayMode: Bool = ProactiveSentryService.shared.isAwayModeActive
    @State private var sentryWifiWatcher: Bool = ProactiveSentryService.shared.isWifiWatcherEnabled
    @State private var sentryAutoHeal: Bool = ProactiveSentryService.shared.isAutoHealEnabled
    @State private var sentryAutoHealRestartDocker: Bool = ProactiveSentryService.shared.autoHealRestartDocker
    @State private var isRunningSentryCheck: Bool = false

    // Dynamic Tools
    @State private var dynamicToolsList: [DynamicTool] = DynamicToolSynthesizer.shared.allTools
    @State private var toolTestResult: String = ""
    @State private var isExecutingTool: Bool = false
    @State private var showCreateToolForm: Bool = false
    @State private var newToolId: String = ""
    @State private var newToolName: String = ""
    @State private var newToolDesc: String = ""
    @State private var newToolLang: DynamicToolLanguage = .bash
    @State private var newToolScript: String = ""
    @State private var newToolParams: String = ""

    // Docker & Remote Server SSH Gateway
    @State private var isDockerAvailable: Bool = false
    @State private var dockerContainersCount: Int = 0
    @State private var isCheckingDocker: Bool = false
    @State private var remoteServersList: [RemoteServerConfig] = SSHServerGatewayService.shared.listServers()
    @State private var newServerName: String = ""
    @State private var newServerHost: String = ""
    @State private var newServerPort: String = "22"
    @State private var newServerUsername: String = "ubuntu"
    @State private var newServerKeyPath: String = "~/.ssh/id_rsa"
    @State private var isAuditingServer: Bool = false

    // Kubernetes & Database Command Center
    @State private var isK8sAvailable: Bool = false
    @State private var k8sContext: String = ""
    @State private var isCheckingK8s: Bool = false
    @State private var isSqliteAvailable: Bool = true
    @State private var isPsqlAvailable: Bool = false
    @State private var isMysqlAvailable: Bool = false
    @State private var isRedisAvailable: Bool = false

    // Mobile & Telegram
    @State private var telegramToken: String = KeychainStore.shared.get("telegram-bot-token")
        ?? UserDefaults.standard.string(forKey: "telegramBotToken") ?? ""
    @State private var telegramRunning: Bool = TelegramGatewayService.shared.isRunning
    @State private var telegramAllowedChatId: String? = TelegramGatewayService.shared.allowedChatId

    // Integrations & MCP
    @State private var resendKey: String     = KeychainStore.shared.get("resend-api-key")  ?? ""
    @State private var resendFrom: String    = KeychainStore.shared.get("resend-from")     ?? ""
    @State private var n8nUrl: String        = KeychainStore.shared.get("n8n-url")         ?? ""
    @State private var n8nKey: String        = KeychainStore.shared.get("n8n-api-key")     ?? ""
    @State private var vercelToken: String   = KeychainStore.shared.get("vercel-token")    ?? ""
    @State private var githubToken: String   = KeychainStore.shared.get("github-token")    ?? ""
    @State private var stripeKey: String     = KeychainStore.shared.get("stripe-api-key")  ?? ""
    @State private var calcomKey: String     = KeychainStore.shared.get("calcom-api-key")  ?? ""
    @State private var notionKey: String     = KeychainStore.shared.get("notion-api-key")  ?? ""
    @State private var elevenLabsKey: String = KeychainStore.shared.get("elevenlabs-api-key") ?? ""

    @State private var vercelProjects: [String] = []
    @State private var loadingVercel: Bool = false
    @State private var n8nWorkflows: [String] = []
    @State private var loadingN8n: Bool = false

    @State private var mcpNewName: String = ""
    @State private var mcpNewCommand: String = ""

    // Claude Code Hooks
    @State private var showDiff: Bool = false
    @State private var pendingHookJSON: String = ""
    @State private var hookNeedsUpdate: Bool = HookServer.hooksNeedUpdate()

    // Bindings in minutes for the absence field
    private var absenceMinutes: Binding<Double> {
        Binding(
            get: { state.absenceInterval / 60 },
            set: { state.absenceInterval = max(1, $0) * 60 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Tab Bar
            tabHeaderView

            Divider()

            // Active Tab Content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .general:
                        generalTabView
                    case .persona:
                        personaTabView
                    case .models:
                        modelsTabView
                    case .autonomous:
                        autonomousTabView
                    case .tools:
                        toolsTabView
                    case .telegram:
                        telegramTabView
                    case .integrations:
                        integrationsTabView
                    }

                    Spacer(minLength: 16)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Bottom Status Bar
            bottomStatusBar
        }
        .alert("Pembaruan tersedia", isPresented: $showUpdateAlert) {
            Button("Instal & Mulai Ulang") {
                Task {
                    if let release = updateAvailable,
                       let url = await AutoUpdate.shared.downloadUpdate(release) {
                        AutoUpdate.shared.install(url)
                    } else {
                        statusMessage = "❌ Gagal mengunduh atau memverifikasi pembaruan."
                    }
                }
            }
            Button("Nanti", role: .cancel) { }
        } message: {
            Text("Versi \(updateAvailable?.version ?? "?"): \(updateAvailable?.notes ?? "")")
        }
        .onAppear {
            selectedTab = state.selectedSettingsTab
            accessibilityGranted = AXIsProcessTrusted()
            selectedProviderId = ProviderRegistry.shared.activeProviderId
            apiKey = KeychainStore.shared.get("\(selectedProviderId)-api-key") ?? ""
            refreshPoolKeys()
            refreshDynamicTools()
            telegramRunning = TelegramGatewayService.shared.isRunning
            telegramAllowedChatId = TelegramGatewayService.shared.allowedChatId

            Task {
                let avail = await DockerIntegrationService.shared.isDockerAvailable()
                let result = await DockerIntegrationService.shared.listContainers(all: false)
                let k8sAvail = await KubernetesIntegrationService.shared.isKubectlAvailable()
                let k8sCtx = await KubernetesIntegrationService.shared.getCurrentContext()
                let psqlAvail = DatabaseIntegrationService.shared.isClientAvailable(engine: .postgres)
                let mysqlAvail = DatabaseIntegrationService.shared.isClientAvailable(engine: .mysql)
                let redisAvail = DatabaseIntegrationService.shared.isClientAvailable(engine: .redis)
                await MainActor.run {
                    isDockerAvailable = avail
                    dockerContainersCount = result.containers.count
                    remoteServersList = SSHServerGatewayService.shared.listServers()
                    isK8sAvailable = k8sAvail
                    k8sContext = k8sCtx
                    isPsqlAvailable = psqlAvail
                    isMysqlAvailable = mysqlAvail
                    isRedisAvailable = redisAvail
                }
            }

            guard fetchedModels.isEmpty,
                  let key = KeychainStore.shared.get("\(selectedProviderId)-api-key"), !key.isEmpty else { return }
            let providerId = selectedProviderId
            Task {
                guard let provider = ProviderRegistry.shared.provider(id: providerId) else { return }
                let models = await provider.listModels()
                guard !models.isEmpty else { return }
                await MainActor.run {
                    guard selectedProviderId == providerId else { return }
                    fetchedModels = models
                    syncModelChoice()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFullSettings)) { notification in
            if let tabName = notification.userInfo?["tab"] as? String,
               let tab = SettingsTab(rawValue: tabName) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    selectedTab = tab
                }
            } else {
                withAnimation(.easeInOut(duration: 0.16)) {
                    selectedTab = state.selectedSettingsTab
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            telegramRunning = TelegramGatewayService.shared.isRunning
            telegramAllowedChatId = TelegramGatewayService.shared.allowedChatId
        }
        .frame(minWidth: 540, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    // MARK: - Header Tab Bar

    private var tabHeaderView: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedTab = tab
                    }
                }) {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundColor(selectedTab == tab ? .accentColor : .secondary)

                        Text(tab.rawValue)
                            .font(.system(size: 10.5, weight: selectedTab == tab ? .semibold : .medium))
                            .foregroundColor(selectedTab == tab ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Bottom Status Bar

    private var bottomStatusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if !statusMessage.isEmpty {
                    Image(systemName: statusMessage.hasPrefix("✓") ? "checkmark.circle.fill" : (statusMessage.hasPrefix("❌") ? "xmark.circle.fill" : "info.circle.fill"))
                        .font(.system(size: 11))
                        .foregroundColor(statusMessage.hasPrefix("✓") ? Color(hex: "#22C55E") : (statusMessage.hasPrefix("❌") ? .red : .accentColor))

                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(statusMessage.hasPrefix("❌") ? .red : .primary)
                        .lineLimit(1)
                } else {
                    Text("Coucou • Asisten AI Otonom Super macOS")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("v\(AutoUpdate.shared.currentVersion)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        }
    }

    // MARK: - Tab 1: General (Umum)

    private var generalTabView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Perilaku Notch Island & Waktu
            GroupBox("Perilaku Notch & Layar") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Tutup otomatis setelah:")
                            .frame(width: 170, alignment: .leading)
                        TextField("15", value: $state.autoCloseInterval, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("detik tidak aktif")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("Sembunyikan bot setelah:")
                            .frame(width: 170, alignment: .leading)
                        TextField("3", value: absenceMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("menit tanpa gerakan mouse")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("Sapa ulang setelah absen:")
                            .frame(width: 170, alignment: .leading)
                        TextField("120", value: $state.greetThresholdSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("detik")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(6)
            }

            // Pintasan Global (Hotkey)
            GroupBox("Pintasan Global (Hotkey)") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Buka Notch Island dengan Keyboard Shortcut", isOn: $state.hotkeyEnabled)

                    if state.hotkeyEnabled {
                        HStack(spacing: 10) {
                            Text("Kombinasi Tombol:")
                                .font(.system(size: 11))
                            ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode)
                                .onChange(of: hotkeyFlags) { _, v in state.hotkeyFlags = v }
                                .onChange(of: hotkeyCode)  { _, v in state.hotkeyCode  = v }
                            Text("Menekan tombol ini akan langsung membuka pulau notch dari aplikasi mana pun.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(6)
            }

            // Peluncuran & Setup Wizard
            GroupBox("Peluncuran & Onboarding") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Jalankan otomatis saat Mac menyala (Launch at Startup)", isOn: $launchAtStartup)
                        .onChange(of: launchAtStartup) { _, on in toggleStartup(on) }

                    Divider().padding(.vertical, 2)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Setup Wizard Onboarding")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Jalankan kembali panduan pengaturan awal untuk menghubungkan API dan izin sistem.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Buka Setup Wizard") {
                            restartOnboarding()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(6)
            }

            // Pembaruan Aplikasi
            GroupBox("Pembaruan Perangkat Lunak") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Versi Terpasang: \(AutoUpdate.shared.currentVersion)")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Pembaruan berkala memastikan kapabilitas otonom, patch keamanan, dan provider LLM terbaru.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Cek Pembaruan") {
                            checkForUpdates()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    if let updateAvailable {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundColor(Color(hex: "#22C55E"))
                            Text("Tersedia versi baru: v\(updateAvailable.version)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "#22C55E"))
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - Tab 2: Persona & Voice

    private var personaTabView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Emote Tester & Preview
            GroupBox("Karakter Mochi & Mood Tester") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        // Visual Avatar Badge
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color.accentColor.opacity(0.3), Color.purple.opacity(0.2)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 50, height: 50)

                            Text(currentEmoteSymbol)
                                .font(.system(size: 24))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("Ekspresi Saat Ini:")
                                    .font(.system(size: 11))
                                Text(state.effectiveState.rawValue.capitalized)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.accentColor)
                            }
                            Text("Mochi mengubah ekspresi wajah secara adaptif sesuai konteks tugas, emosi suara, dan interaksi Anda.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if state.stateOverride != nil {
                            Button("Reset Normal") {
                                state.stateOverride = nil
                                statusMessage = "Ekspresi Mochi kembali otomatis."
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    Text("Uji Reaksi Ekspresi Mochi di Notch:")
                        .font(.system(size: 11, weight: .semibold))

                    HStack(spacing: 6) {
                        Button("🤔 Berpikir") { state.stateOverride = .thinking }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("❓ Tanya") { state.stateOverride = .question }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("💻 Bekerja") { state.stateOverride = .working }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("🔍 Cari") { state.stateOverride = .searching }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("😴 Tidur") { state.stateOverride = .sleeping }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("💫 Pusing") { state.stateOverride = .dizzy }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(6)
            }

            // Suara & Speech
            GroupBox("Sintesis Suara (TTS) & Wake Word") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Bicara saat Menjawab (Voice Answers)", isOn: $voice.speakAnswers)

                    Toggle("Kata Pemicu Suara «Mochi» (Wake Word)", isOn: $voice.wakeWordEnabled)
                        .onChange(of: voice.wakeWordEnabled) { _, on in
                            voice.setWakeWord(enabled: on)
                        }

                    if voice.wakeWordEnabled {
                        Text("Mikrofon tetap aktif mendengarkan kata pemicu «Mochi» secara hemat daya.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Divider().padding(.vertical, 2)

                    // Engine Picker
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Mesin Suara (TTS Engine):")
                                .font(.system(size: 11, weight: .semibold))
                            Picker("", selection: $voice.ttsEngine) {
                                ForEach(TTSEngineType.allCases) { eng in
                                    Text(eng.displayName).tag(eng)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 240)
                        }

                        if voice.ttsEngine == .openAI {
                            HStack(spacing: 8) {
                                Text("Pilihan Suara:")
                                    .font(.system(size: 11))
                                Picker("", selection: $voice.openAIVoice) {
                                    Text("Nova (Warm & Friendly)").tag("nova")
                                    Text("Alloy (Balanced)").tag("alloy")
                                    Text("Shimmer (Clear & Expressive)").tag("shimmer")
                                    Text("Echo (Smooth & Calm)").tag("echo")
                                    Text("Onyx (Deep & Professional)").tag("onyx")
                                    Text("Fable (British)").tag("fable")
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 220)
                            }
                            Text("Menggunakan OpenAI TTS model tts-1 (suara alami seperti manusia sungguhan).")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        } else if voice.ttsEngine == .elevenLabs {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("API Key:")
                                        .font(.system(size: 11))
                                    SecureField("xi-api-key (xi_...)", text: $elevenLabsKey)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 220)
                                    Button("Simpan") {
                                        let trimmed = elevenLabsKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if trimmed.isEmpty {
                                            KeychainStore.shared.remove("elevenlabs-api-key")
                                            statusMessage = "ElevenLabs Key dihapus."
                                        } else {
                                            KeychainStore.shared.set("elevenlabs-api-key", value: trimmed)
                                            statusMessage = "✓ ElevenLabs Key tersimpan."
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                HStack(spacing: 8) {
                                    Text("Voice ID:")
                                        .font(.system(size: 11))
                                    TextField("21m00Tcm4TlvDq8ikWAM", text: $voice.elevenLabsVoiceId)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 220)
                                }
                                Text("Memerlukan ElevenLabs API Key. Model eleven_flash_v2_5 untuk latensi super rendah.")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        } else if voice.ttsEngine == .groq {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("Model TTS:")
                                        .font(.system(size: 11))
                                    Picker("", selection: $voice.groqModel) {
                                        Text("Orpheus English (canopylabs)").tag("canopylabs/orpheus-v1-english")
                                        Text("Orpheus Arabic Saudi (canopylabs)").tag("canopylabs/orpheus-arabic-saudi")
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 240)
                                }
                                HStack(spacing: 8) {
                                    Text("Pilihan Suara:")
                                        .font(.system(size: 11))
                                    Picker("", selection: $voice.groqVoice) {
                                        Text("Autumn (Warm & Natural - Default)").tag("autumn")
                                        Text("Diana (Expressive Female)").tag("diana")
                                        Text("Hannah (Bright Female)").tag("hannah")
                                        Text("Austin (Confident Male)").tag("austin")
                                        Text("Daniel (Deep Male)").tag("daniel")
                                        Text("Troy (Conversational Male)").tag("troy")
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 240)
                                }
                                Text("Menggunakan Groq TTS (Canopy Labs Orpheus) dengan auto-rotate Multi-Key saat limit kuota tercapai.")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("Synthesizer bawaan macOS lokal (cepat, offline & hemat daya).")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Button(action: {
                            voice.speak("Halo! Saya Mochi, asisten pribadi Anda. Ada yang bisa saya bantu hari ini?")
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2.fill")
                                Text("Tes Bicara Suara")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
                .padding(6)
            }

            // Duplex & Intonasi
            GroupBox("Natural Duplex & Interupsi Spontan (Barge-In)") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Aktifkan Voice Duplex (Interupsi Alami)", isOn: Binding(
                            get: { VoiceDuplexEngine.shared.isDuplexActive },
                            set: { on in
                                if on {
                                    VoiceDuplexEngine.shared.startDuplex()
                                } else {
                                    VoiceDuplexEngine.shared.stopDuplex()
                                }
                            }
                        ))
                        Spacer()
                        if VoiceDuplexEngine.shared.isDuplexActive {
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 7, height: 7)
                                Text("Duplex Aktif")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    Text("Anda dapat menyela pembicaraan asisten secara instan cukup dengan mulai berbicara tanpa menunggu bot selesai.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Text("Intonasi Emosi Suara:")
                            .font(.system(size: 11))
                        Picker("", selection: Binding(
                            get: { VoiceDuplexEngine.shared.emotionalTone },
                            set: { VoiceDuplexEngine.shared.setTone($0) }
                        )) {
                            Text("Attentive (Ramah & Hangat)").tag(VoiceDuplexEngine.EmotionalTone.attentive)
                            Text("Focused (Fokus Kerja Cepat)").tag(VoiceDuplexEngine.EmotionalTone.focused)
                            Text("Caution (Peringatan & Tegas)").tag(VoiceDuplexEngine.EmotionalTone.caution)
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                    }
                }
                .padding(6)
            }

            // Sound Effects
            GroupBox("Efek Suara Sistem (Chime & Pops)") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Aktifkan Bunyi Efek UI", isOn: $state.soundEnabled)
                    HStack(spacing: 8) {
                        Text("Volume:")
                            .frame(width: 60, alignment: .leading)
                        Slider(value: $state.soundVolume, in: 0...0.2)
                            .disabled(!state.soundEnabled)
                        let volPct = Int(state.soundVolume / 0.2 * 100.0)
                        Text("\(volPct) %")
                            .frame(width: 40, alignment: .trailing)
                            .monospacedDigit()
                        Button("Tes Bunyi") {
                            SoundEngine.shared.play("pop")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!state.soundEnabled)
                    }
                }
                .padding(6)
            }
        }
    }

    private var currentEmoteSymbol: String {
        switch state.effectiveState {
        case .thinking:  return "🤔"
        case .question:  return "❓"
        case .working:   return "💻"
        case .searching: return "🔍"
        case .sleeping:  return "😴"
        case .dizzy:     return "💫"
        case .error:     return "⚠️"
        case .finished:  return "✅"
        case .ratelimit: return "⏳"
        case .approval:  return "✋"
        case .idle:      return "🐱"
        }
    }

    // MARK: - Tab 3: AI & Models

    private var modelsTabView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // AI Provider & Primary Key
            GroupBox("Penyedia AI (AI Provider)") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Provider Aktif", selection: $selectedProviderId) {
                        ForEach(providers, id: \.id) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .onChange(of: selectedProviderId) { _, newId in
                        switchProvider(to: newId)
                    }

                    SecureField(keyPlaceholder, text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("Simpan Kunci") {
                            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty else { return }
                            KeychainStore.shared.set("\(selectedProviderId)-api-key", value: key)
                            ProviderRegistry.shared.addKey(providerId: selectedProviderId, label: "Primary Key", secret: key)
                            refreshPoolKeys()
                            statusMessage = "✓ Kunci \(selectedProvider.displayName) tersimpan."
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Uji Koneksi") { testConnection() }
                            .buttonStyle(.bordered)
                    }

                    // Multi-Key Pool Section
                    Divider().padding(.vertical, 2)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Multi-Key Pool (\(poolKeys.count) kunci terdaftar)")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Auto-rotate kunci secara otomatis saat kuota limit (HTTP 429) tercapai.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(showAddKeyForm ? "Tutup Form" : "+ Tambah Kunci") {
                            showAddKeyForm.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }

                    if !poolKeys.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(poolKeys) { item in
                                HStack(spacing: 6) {
                                    Toggle("", isOn: Binding(
                                        get: { item.isEnabled },
                                        set: {
                                            ProviderRegistry.shared.setKeyEnabled(id: item.id, enabled: $0)
                                            refreshPoolKeys()
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(item.label)
                                                .font(.system(size: 11, weight: .medium))
                                            if !item.isAvailable {
                                                Text("(Cooldown 429)")
                                                    .font(.system(size: 9))
                                                    .foregroundColor(.orange)
                                            }
                                        }
                                        if let last = item.lastUsed {
                                            Text("Dipakai: \(last.formatted(.relative(presentation: .named)))")
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Spacer(minLength: 0)

                                    Button(action: {
                                        ProviderRegistry.shared.removeKey(id: item.id)
                                        refreshPoolKeys()
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10))
                                            .foregroundColor(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(5)
                                .background(Color.secondary.opacity(0.08))
                                .cornerRadius(6)
                            }
                        }
                    }

                    if showAddKeyForm {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                TextField("Label (Key 2, Backup)", text: $newKeyLabel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 140)
                                SecureField(keyPlaceholder, text: $newKeySecret)
                                    .textFieldStyle(.roundedBorder)
                                Button("Tambah") {
                                    let sec = newKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !sec.isEmpty else { return }
                                    ProviderRegistry.shared.addKey(providerId: selectedProviderId, label: newKeyLabel.isEmpty ? "Backup Key" : newKeyLabel, secret: sec)
                                    newKeyLabel = ""
                                    newKeySecret = ""
                                    showAddKeyForm = false
                                    refreshPoolKeys()
                                    statusMessage = "✓ Kunci ditambahkan ke pool."
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(newKeySecret.isEmpty)
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(6)
                    }

                    Divider().padding(.vertical, 2)

                    // Model Choice
                    Picker("Pilihan Model", selection: $modelChoice) {
                        ForEach(displayModels, id: \.id) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                        Text("Custom…").tag(Self.customModelTag)
                    }
                    .onChange(of: modelChoice) { _, choice in
                        if choice != Self.customModelTag {
                            state.claudeModel = choice
                        } else {
                            applyCustomModel(customModel)
                        }
                    }

                    if modelChoice == Self.customModelTag {
                        TextField("Model ID spesifik (misal: \(selectedProvider.defaultModel))", text: $customModel)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: customModel) { _, value in applyCustomModel(value) }
                    }
                }
                .padding(6)
            }

            // Smart Intent Router
            GroupBox("Smart Intent Router (Edge vs Cloud Hybrid)") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Aktifkan Hybrid Intent Routing", isOn: $smartIntentRoutingEnabled)
                    Text("Perintah sistem & aksi lokal langsung dieksekusi instan on-device tanpa internet (0ms & bebas biaya API). Pertanyaan konseptual dan perencanaan rumit dialihkan otomatis ke Cloud LLM.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }

            // On-Device Local SLM / Ollama
            GroupBox("Local SLM & MLX Engine (Privasi Penuh)") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Ollama / Local Endpoint:")
                            .font(.system(size: 11))
                        Text("http://127.0.0.1:11434")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                        Spacer()
                        Button("Cek Koneksi Ollama") {
                            testOllama()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !ollamaStatus.isEmpty {
                        Text(ollamaStatus)
                            .font(.system(size: 10.5))
                            .foregroundColor(ollamaStatus.hasPrefix("✓") ? Color(hex: "#22C55E") : .orange)
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - Tab 4: Autonomous & Sensory

    private var autonomousTabView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Mode Otonom Penuh & Otopilot
            GroupBox("Mode Operasional Otonom & Guardrails") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Mode Otonom Penuh (Autonomous Agent)", isOn: $state.autonomousEnabled)
                    Text("Mengizinkan asisten menyelesaikan tugas multi-langkah secara mandiri tanpa harus menanyakan izin pada setiap sub-langkah rutin.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)

                    Divider()

                    Toggle("Mode Otopilot JARVIS (PolicyEngine Autopilot)", isOn: $state.autopilotEnabled)
                        .onChange(of: state.autopilotEnabled) { _, _ in
                            state.applyAutopilotMode()
                        }
                    Text("Menjalankan aksi non-kritis (shell aman, web fetch, pembacaan file) otomatis. Hard safety floor (sudo, rm -rf, destructive write) selalu aktif dan tidak bisa dilewati.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Divider()

                    HStack(spacing: 8) {
                        Text("Batas langkah otonom per permintaan:")
                            .font(.system(size: 11))
                        TextField("12", value: $state.agentStepLimit, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("langkah maksimal")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(6)
            }

            // Sensory Watchers
            GroupBox("Sensory Event Hub (Persepsi Pasif Cerdas)") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Memantau lingkungan kerja Anda secara pasif (0% CPU) untuk memberikan rekomendasi bantuan proaktif di Notch.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)

                    Toggle("📁 File System Watcher (~/Downloads & ~/Desktop)", isOn: Binding(
                        get: { fileSystemWatcherEnabled },
                        set: {
                            fileSystemWatcherEnabled = $0
                            SensoryEventHub.shared.isFileSystemWatcherEnabled = $0
                        }
                    ))
                    Text("Mendeteksi file faktur invoice baru, data CSV/Excel, atau screenshot untuk langsung ditawarkan analisis cerdas.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.leading, 18)

                    Toggle("📋 Smart Clipboard Watcher (0% CPU)", isOn: Binding(
                        get: { clipboardWatcherEnabled },
                        set: {
                            clipboardWatcherEnabled = $0
                            SensoryEventHub.shared.isClipboardWatcherEnabled = $0
                        }
                    ))
                    Text("Mendeteksi stack trace error, URL web, atau query SQL di clipboard. Data sensitif dan password diabaikan secara mutlak.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.leading, 18)
                }
                .padding(6)
            }

            // Computer Control & Aksesibilitas
            GroupBox("Computer Control (CUA & Gerakan Kursor)") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(accessibilityGranted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text("Izin Aksesibilitas macOS:")
                            .font(.system(size: 11, weight: .semibold))
                        Text(accessibilityGranted ? "Terverifikasi (CGEvent Aktif)" : "Belum Diberikan")
                            .font(.system(size: 11))
                            .foregroundColor(accessibilityGranted ? .secondary : .orange)
                        Spacer()
                        Button("Cek Ulang") {
                            accessibilityGranted = AXIsProcessTrusted()
                            statusMessage = accessibilityGranted ? "✓ Aksesibilitas aktif." : "Belum terdeteksi."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if !accessibilityGranted {
                            Button("Buka Pengaturan Sistem") {
                                requestAccessibility()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    HStack(spacing: 8) {
                        Text("Safety Panic Guardrail:")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Gerakan mouse fisik manual > 40px akan langsung membatalkan kendali bot.")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Reset Panic") {
                            OSComputerControl.shared.resetPanic()
                            statusMessage = "✓ Safety Panic Guardrail direset."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(6)
            }

            // Night-Shift Worker
            GroupBox("Autonomous Night-Shift") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pembersihan & Audit Malam Hari (22:00 - 05:00)")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Otomatis merapikan Downloads/Desktop dan audit sisa ruang disk saat Mac idle > 15 menit.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(nightShiftRunning ? "Sedang Bekerja..." : "Jalankan Sekarang") {
                            runNightShiftManual()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(nightShiftRunning)
                    }

                    if let report = NightShiftWorker.shared.latestReport {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Laporan Terakhir: \(report.timestamp.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(report.summaryText)
                                .font(.system(size: 10.5))
                        }
                        .padding(6)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)
                    }
                }
                .padding(6)
            }

            // Structured Playbooks (SOPs)
            GroupBox("Structured Playbooks (SOPs)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Alur kerja multi-langkah otonom untuk tugas kantor, riset, dan sistem.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)

                    ForEach(PlaybookEngine.shared.allPlaybooks) { pb in
                        HStack(spacing: 8) {
                            Image(systemName: pb.category == "Office" ? "doc.richtext" : (pb.category == "Research" ? "globe" : "gearshape.2"))
                                .font(.system(size: 13))
                                .foregroundColor(.accentColor)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(pb.name)
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(pb.description)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text("\(pb.steps.count) langkah")
                                .font(.system(size: 9.5))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)

                            Button("Jalankan") {
                                Task { @MainActor in
                                    _ = await PlaybookEngine.shared.run(
                                        playbookId: pb.id,
                                        context: ["topic": "Tren AI Terkini"],
                                        toolExecutor: ToolExecutor()
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
                .padding(6)
            }

            // Visual Perception & Face Recognition
            GroupBox("Persepsi Visual & Biometrik Wajah (Apple Neural Engine)") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: faceEnrollmentStatus ? "faceid" : "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 16))
                            .foregroundColor(faceEnrollmentStatus ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(faceEnrollmentStatus ? "Wajah Pemilik Terdaftar ✓" : "Wajah Pemilik Belum Terdaftar")
                                .font(.system(size: 11, weight: .semibold))
                            Text(faceEnrollmentStatus
                                 ? "Presence Guard aktif: Mochi menyapa saat Anda datang dan memperingatkan jika ada pengintip layar."
                                 : "Daftarkan wajah Anda agar Mochi mengenali Anda saat kembali ke MacBook dan memproteksi layar.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if faceEnrollmentStatus {
                            Button("Reset Wajah") {
                                FaceRecognitionService.shared.resetOwnerFace()
                                faceEnrollmentStatus = false
                                statusMessage = "Data wajah berhasil dihapus."
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button(isEnrollingFace ? "Mengambil Foto..." : "Daftarkan Wajah") {
                                isEnrollingFace = true
                                Task {
                                    do {
                                        let capture = try await WebcamCaptureService.shared.capturePhoto()
                                        let enroll = try await FaceRecognitionService.shared.enrollOwnerFace(imageData: capture.data)
                                        await MainActor.run {
                                            isEnrollingFace = false
                                            faceEnrollmentStatus = enroll.isSuccess
                                            statusMessage = enroll.message
                                        }
                                    } catch {
                                        await MainActor.run {
                                            isEnrollingFace = false
                                            statusMessage = "Gagal: \(error.localizedDescription)"
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isEnrollingFace)
                        }
                    }
                }
                .padding(6)
            }

            // CCTV & IP Camera Gateway
            GroupBox("Pemantauan CCTV & IP Camera (RTSP / ONVIF)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Kelola kamera CCTV rumah/kantor untuk pemantauan cerdas langsung di Canvas.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)

                    if cctvCamerasList.isEmpty {
                        Text("Belum ada kamera CCTV yang terdaftar.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 2)
                    } else {
                        ForEach(cctvCamerasList) { cam in
                            HStack(spacing: 8) {
                                Image(systemName: "video.fill")
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(cam.name) (\(cam.location))")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(cam.streamUrl)
                                        .font(.system(size: 9.5))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("Hapus") {
                                    CCTVGatewayService.shared.removeCamera(id: cam.id)
                                    cctvCamerasList = CCTVGatewayService.shared.listCameras()
                                    statusMessage = "Kamera \(cam.name) dihapus."
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Divider()
                        }
                    }

                    // Tambah CCTV Form
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tambah Kamera Baru:")
                            .font(.system(size: 10.5, weight: .medium))
                        HStack(spacing: 6) {
                            TextField("Nama (Pintu Depan)", text: $newCCTVName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5))
                            TextField("Lokasi (Garasi)", text: $newCCTVLocation)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5))
                        }
                        HStack(spacing: 6) {
                            TextField("URL (rtsp:// atau http://snapshot)", text: $newCCTVUrl)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5))
                            Button("Simpan") {
                                guard !newCCTVName.isEmpty, !newCCTVUrl.isEmpty else { return }
                                let cam = CCTVCameraConfig(
                                    name: newCCTVName,
                                    location: newCCTVLocation.isEmpty ? "Utama" : newCCTVLocation,
                                    streamUrl: newCCTVUrl,
                                    snapshotUrl: newCCTVUrl.hasPrefix("http") ? newCCTVUrl : nil
                                )
                                CCTVGatewayService.shared.addOrUpdateCamera(cam)
                                cctvCamerasList = CCTVGatewayService.shared.listCameras()
                                newCCTVName = ""
                                newCCTVLocation = ""
                                newCCTVUrl = ""
                                statusMessage = "Kamera \(cam.name) berhasil ditambahkan."
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newCCTVName.isEmpty || newCCTVUrl.isEmpty)
                        }
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }
                .padding(6)
            }

            // Proactive Sentry & Autonomous Health Watchers (Paket 11)
            GroupBox("🛡️ Proactive Sentry & Autonomous Health Watchers") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pengawasan keamanan proaktif menyeluruh: deteksi penyusup fisik via kamera senyap, pengawas perangkat asing di Wi-Fi, dan pemulih otomatis service container yang crash.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)

                    // 1. Away Sentry
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("🛡️ Away Sentry Mode (Pengawas Anti-Maling & Penyusup)", isOn: $sentryAwayMode)
                            .onChange(of: sentryAwayMode) { _, val in
                                if val {
                                    _ = ProactiveSentryService.shared.enableAwayMode()
                                    statusMessage = "Away Sentry diaktifkan: Mengawasi laptop saat terkunci."
                                } else {
                                    _ = ProactiveSentryService.shared.disableAwayMode()
                                    statusMessage = "Away Sentry dinonaktifkan."
                                }
                            }
                        Text("Saat Mac terkunci atau Anda meninggalkan laptop di kafe/kantor, kamera memotret orang asing yang menatap layar dan mengirimkan foto darurat ke Telegram.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.leading, 18)
                    }

                    Divider()

                    // 2. Wi-Fi Watcher
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle("📡 LAN New-Device Sentry (Wi-Fi Watcher)", isOn: $sentryWifiWatcher)
                                .onChange(of: sentryWifiWatcher) { _, val in
                                    ProactiveSentryService.shared.isWifiWatcherEnabled = val
                                }
                            Spacer()
                            Button("Pindai Wi-Fi Sekarang") {
                                isRunningSentryCheck = true
                                Task {
                                    let r = await ProactiveSentryService.shared.scanWifiForIntruders()
                                    isRunningSentryCheck = false
                                    statusMessage = "Pemindaian Wi-Fi selesai: \(r.newDevices.count) perangkat baru terdeteksi."
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isRunningSentryCheck)
                        }
                        Text("Mendeteksi perangkat baru/asing yang terhubung ke jaringan Wi-Fi lokal secara pasif dan menampilkan alert chip di Notch.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.leading, 18)
                    }

                    Divider()

                    // 3. Auto-Healer
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle("🩺 Container & Server Crash Auto-Healer", isOn: $sentryAutoHeal)
                                .onChange(of: sentryAutoHeal) { _, val in
                                    ProactiveSentryService.shared.isAutoHealEnabled = val
                                }
                            Spacer()
                            Button("Audit Kesehatan Sekarang") {
                                isRunningSentryCheck = true
                                Task {
                                    let r = await ProactiveSentryService.shared.runAutoHealAudit()
                                    isRunningSentryCheck = false
                                    statusMessage = "Audit selesai: \(r.crashedContainersFound.count) container crash, \(r.healedContainers.count) dipulihkan."
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isRunningSentryCheck)
                        }

                        if sentryAutoHeal {
                            Toggle("Otomatis restart Docker container yang crash (Exit code != 0)", isOn: $sentryAutoHealRestartDocker)
                                .font(.system(size: 10.5))
                                .padding(.leading, 18)
                                .onChange(of: sentryAutoHealRestartDocker) { _, val in
                                    ProactiveSentryService.shared.autoHealRestartDocker = val
                                }
                        }

                        Text("Memantau Docker container dan server SSH terdaftar berkala. Memulihkan service mati secara otonom.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.leading, 18)
                    }
                }
                .padding(6)
            }

            // Audit Log
            GroupBox("Audit Log Otonom") {
                HStack(spacing: 8) {
                    Text("Lokasi Log:")
                        .font(.system(size: 11))
                    TextField("path", text: .constant(AuditLog.defaultURL().path))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button("Buka Folder") {
                        NSWorkspace.shared.open(AuditLog.defaultURL().deletingLastPathComponent())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(6)
            }
        }
    }

    // MARK: - Tab 5: Dynamic Tools (JIT Synthesizer)

    private var toolsTabView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header Info
            GroupBox("JIT Tool Synthesizer (Metacognitive Maker)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundColor(.accentColor)
                        Text("Metacognitive Self-Synthesized Tools")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("Saat Mochi menghadapi tugas yang belum memiliki alat bawaan, asisten dapat mengarang, mengompilasi JIT (Swift, Python, Bash, JS), dan mendaftarkan alat baru secara mandiri di dalam sandbox aman.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                .padding(6)
            }

            // Tools List
            GroupBox("Daftar Dynamic Tools Terdaftar (\(dynamicToolsList.count))") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: refreshDynamicTools) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Segarkan")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Button(action: { showCreateToolForm.toggle() }) {
                            HStack(spacing: 4) {
                                Image(systemName: showCreateToolForm ? "xmark" : "plus")
                                Text(showCreateToolForm ? "Tutup Form" : "+ Buat Alat Baru")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    if showCreateToolForm {
                        manualToolCreationForm
                    }

                    if dynamicToolsList.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary)
                            Text("Belum ada alat dinamis yang terdaftar.")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("Mochi akan otomatis menciptakan alat baru saat Anda memberikan instruksi khusus yang memerlukan skrip otomasi.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(dynamicToolsList) { tool in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(tool.name)
                                            .font(.system(size: 12, weight: .semibold))

                                        Text(tool.language.rawValue.uppercased())
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(languageBadgeColor(tool.language).opacity(0.15))
                                            .foregroundColor(languageBadgeColor(tool.language))
                                            .cornerRadius(4)

                                        Spacer()

                                        Text("Dipakai: \(tool.executionCount)x")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)

                                        Button("Uji Alat") {
                                            testDynamicTool(tool)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)

                                        Button(action: {
                                            deleteDynamicTool(tool)
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 10))
                                                .foregroundColor(.red.opacity(0.8))
                                        }
                                        .buttonStyle(.borderless)
                                    }

                                    Text(tool.description)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(.secondary)

                                    if !tool.parameterNames.isEmpty {
                                        Text("Parameter: \(tool.parameterNames.joined(separator: ", "))")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.8))
                                    }
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.06))
                                .cornerRadius(6)
                            }
                        }
                    }

                    if !toolTestResult.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Hasil Pengujian Terakhir:")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Spacer()
                                Button("Tutup") { toolTestResult = "" }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 10))
                            }
                            ScrollView {
                                Text(toolTestResult)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                            .padding(6)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(4)
                        }
                    }
                }
                .padding(6)
            }

            // Sandbox Guardrails
            GroupBox("Dynamic Sandbox Security Constraints") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.checkerboard")
                            .foregroundColor(.green)
                        Text("Hard Safety Sandbox Aktif")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text("• Timeout eksekusi 15 detik per skrip.\n• Blokir perintah berbahaya: sudo, rm -rf, mkfs, dd, fork bomb.\n• Cache Swift modular terisolasi.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(6)
            }
        }
    }

    private var manualToolCreationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tambah Alat Dinamis Baru")
                .font(.system(size: 11, weight: .semibold))

            HStack(spacing: 8) {
                TextField("ID (misal: my_custom_tool)", text: $newToolId)
                    .textFieldStyle(.roundedBorder)
                TextField("Nama Alat", text: $newToolName)
                    .textFieldStyle(.roundedBorder)
                Picker("Bahasa", selection: $newToolLang) {
                    ForEach(DynamicToolLanguage.allCases, id: \.self) { l in
                        Text(l.rawValue.capitalized).tag(l)
                    }
                }
                .frame(width: 110)
            }

            TextField("Deskripsi singkat alat", text: $newToolDesc)
                .textFieldStyle(.roundedBorder)

            TextField("Parameter names (pisahkan dengan koma)", text: $newToolParams)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $newToolScript)
                .font(.system(size: 10.5, design: .monospaced))
                .frame(height: 90)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3), lineWidth: 1))

            HStack {
                Button("Daftarkan & Simpan Alat") {
                    createManualTool()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newToolId.isEmpty || newToolScript.isEmpty)

                Button("Batal") {
                    showCreateToolForm = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    private func languageBadgeColor(_ lang: DynamicToolLanguage) -> Color {
        switch lang {
        case .swift: return .orange
        case .python: return .blue
        case .bash: return .green
        case .javascript: return .yellow
        }
    }

    private func refreshDynamicTools() {
        dynamicToolsList = DynamicToolSynthesizer.shared.allTools
    }

    private func deleteDynamicTool(_ tool: DynamicTool) {
        if DynamicToolSynthesizer.shared.removeTool(id: tool.id) {
            refreshDynamicTools()
            statusMessage = "✓ Alat '\(tool.name)' berhasil dihapus."
        }
    }

    private func testDynamicTool(_ tool: DynamicTool) {
        toolTestResult = "Menjalankan \(tool.id)..."
        Task {
            let res = await DynamicToolSynthesizer.shared.executeTool(id: tool.id, arguments: [:])
            await MainActor.run {
                toolTestResult = res.isError ? "❌ Error: \(res.output)" : "✓ Output:\n\(res.output)"
                refreshDynamicTools()
            }
        }
    }

    private func createManualTool() {
        let params = newToolParams.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let res = DynamicToolSynthesizer.shared.registerTool(
            id: newToolId,
            name: newToolName.isEmpty ? newToolId : newToolName,
            description: newToolDesc,
            language: newToolLang,
            scriptSource: newToolScript,
            parameterNames: params
        )

        switch res {
        case .success(let tool):
            refreshDynamicTools()
            showCreateToolForm = false
            newToolId = ""
            newToolName = ""
            newToolDesc = ""
            newToolScript = ""
            newToolParams = ""
            statusMessage = "✓ Alat '\(tool.name)' berhasil didaftarkan!"
        case .failure(let err):
            statusMessage = "❌ Gagal: \(err.localizedDescription)"
        }
    }

    // MARK: - Tab 6: Mobile & Telegram

    private var telegramTabView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Status Gateway
            GroupBox("Telegram Encrypted Gateway (Pilar D: Mobile On-The-Go)") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(telegramRunning ? Color.green : Color.secondary)
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(telegramRunning ? "Layanan Aktif & Terhubung" : "Layanan Berhenti")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(telegramRunning ? .primary : .secondary)
                            Text("Kontrol Mac Anda dari smartphone via Telegram Bot API dari mana saja.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if telegramRunning {
                            Button("Hentikan Layanan") {
                                toggleTelegramGateway()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button("Mulai Layanan") {
                                toggleTelegramGateway()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(6)
            }

            // Kredensial Bot
            GroupBox("Kredensial Bot Telegram") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Masukkan token bot dari @BotFather di Telegram:")
                        .font(.system(size: 11))

                    HStack(spacing: 8) {
                        SecureField("123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ", text: $telegramToken)
                            .textFieldStyle(.roundedBorder)

                        Button("Simpan Token") {
                            TelegramGatewayService.shared.setBotToken(telegramToken)
                            telegramRunning = TelegramGatewayService.shared.isRunning
                            statusMessage = "✓ Token bot Telegram tersimpan."
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(6)
            }

            // Status Pairing Smartphone
            GroupBox("Status Pairing Smartphone") {
                VStack(alignment: .leading, spacing: 10) {
                    if let chatId = telegramAllowedChatId, !chatId.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(.green)
                            Text("Terhubung ke Chat ID: \(chatId)")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Button("Putuskan Pairing (Unlink)") {
                                TelegramGatewayService.shared.unlinkPairing()
                                telegramAllowedChatId = nil
                                statusMessage = "Pairing smartphone diputuskan."
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "link.badge.plus")
                                    .foregroundColor(.accentColor)
                                Text("Belum Ada Perangkat yang Terhubung")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text("Cara Menghubungkan Smartphone Anda:\n1. Buka bot Anda di aplikasi Telegram smartphone.\n2. Kirim perintah `/start`.\n3. PIN 6-digit verifikasi akan muncul di Notch Island Mac Anda untuk diinputkan.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(6)
            }

            // Panduan Perintah Remote
            GroupBox("Perintah Remote yang Didukung") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("/status")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .frame(width: 80, alignment: .leading)
                        Text("Melihat status Mac, CPU, baterai, dan tugas yang sedang berjalan.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("/screenshot")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .frame(width: 80, alignment: .leading)
                        Text("Mengirim tangkapan layar desktop Mac langsung ke chat Telegram.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("/canvas")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .frame(width: 80, alignment: .leading)
                        Text("Mengirim konten Canvas Artifacts yang sedang terbuka.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("/cancel")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .frame(width: 80, alignment: .leading)
                        Text("Membatalkan eksekusi tugas otonom yang sedang berjalan.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("Perintah Bebas")
                            .font(.system(size: 10.5, weight: .bold))
                            .frame(width: 80, alignment: .leading)
                        Text("Ketik perintah apa pun untuk dikerjakan otonom oleh Mac Anda.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(6)
            }
        }
    }

    private func toggleTelegramGateway() {
        if telegramRunning {
            TelegramGatewayService.shared.stop()
            telegramRunning = false
            statusMessage = "Telegram Gateway dihentikan."
        } else {
            TelegramGatewayService.shared.start()
            telegramRunning = TelegramGatewayService.shared.isRunning
            statusMessage = telegramRunning ? "✓ Telegram Gateway aktif." : "❌ Masukkan token bot terlebih dahulu."
        }
    }

    // MARK: - Tab 7: Integrations & MCP

    private var integrationsTabView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Editor & Coding Agents
            GroupBox("Editor & Coding Agents") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Izinkan Semua Editor & Terminal", isOn: $state.allowAllEditors)
                    Text("Menerima event Claude Code / Coding Agent dari Antigravity, Cursor, Windsurf, VS Code, iTerm, Warp, Terminal, dll.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Divider().padding(.vertical, 2)

                    HStack(spacing: 8) {
                        Text("Editor Utama:")
                            .font(.system(size: 11, weight: .semibold))
                        Picker("", selection: $state.preferredEditor) {
                            Text("Auto-detect (Aktif / Terinstal)").tag("auto")
                            Text("Antigravity").tag("antigravity")
                            Text("Cursor").tag("cursor")
                            Text("Visual Studio Code").tag("vscode")
                            Text("Windsurf").tag("windsurf")
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 240)
                    }
                    Text("Editor yang akan dibuka saat Anda mengklik tombol 'Open in Editor' di notch.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(6)
            }

            // Claude Code Hooks
            GroupBox("Claude Code Hooks") {
                VStack(alignment: .leading, spacing: 10) {
                    if hookNeedsUpdate {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Hook timeout perlu diperbarui untuk persetujuan alat yang lancar.")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                        #if APPSTORE
                        Button("Update hooks") { installHooksAppStore() }
                        #else
                        Button("Update hooks") { installHooks() }
                        #endif
                    }
                    #if APPSTORE
                    Text("~/.claude/coucou/nb-hook")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    HStack(spacing: 10) {
                        Button("Install hooks") { installHooksAppStore() }
                            .buttonStyle(.borderedProminent)
                        Button("Uninstall") { uninstallHooksAppStore() }
                            .buttonStyle(.bordered)
                    }
                    #else
                    Text("nb-hook : \(HookServer.hookScriptPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    HStack(spacing: 10) {
                        Button("Install hooks") { installHooks() }
                            .buttonStyle(.borderedProminent)
                        Button("Uninstall") { uninstallHooks() }
                            .buttonStyle(.bordered)
                    }
                    #endif

                    #if !APPSTORE
                    if showDiff {
                        ScrollView {
                            Text(pendingHookJSON)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)

                        HStack {
                            Button("Confirm & write") { confirmInstall() }
                                .buttonStyle(.borderedProminent)
                            Button("Cancel") { showDiff = false; pendingHookJSON = "" }
                                .buttonStyle(.bordered)
                        }
                    }
                    #endif
                }
                .padding(6)
            }

            // Slot Integrasi Notch Island (Active Slots)
            GroupBox("Slot Integrasi Notch Island (Maksimal 4)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pilih hingga 4 integrasi untuk ditampilkan sebagai pill monitoring di Notch Island:")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)

                    HStack {
                        Text("Coding Agent (Claude Code)")
                            .font(.system(size: 11, weight: .semibold))
                        Circle().fill(Color(hex: "#F5F6F8")).frame(width: 8, height: 8)
                        Spacer()
                        Text("Selalu Aktif")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Text("\(state.activeIntegrations.count)/4 slot digunakan")
                        .font(.system(size: 11))
                        .foregroundColor(state.activeIntegrations.count >= 4 ? .orange : .secondary)

                    ForEach(AgentTask.toggleableIntegrationIds, id: \.self) { id in
                        let task = AgentTask.integrationAgents.first { $0.id == id } ?? AgentTask(
                            id: id, name: id, color: "#8E939C", state: .idle, steps: [],
                            source: .n8n, isIntegration: true)
                        let isOn = state.activeIntegrations.contains(id)
                        let atMax = state.activeIntegrations.count >= 4 && !isOn
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: task.color))
                                .frame(width: 9, height: 9)
                            Text(task.name)
                                .font(.system(size: 11))
                                .foregroundColor(atMax ? .secondary : .primary)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { isOn },
                                set: { _ in state.toggleIntegration(id) }
                            ))
                            .labelsHidden()
                            .disabled(atMax)
                        }
                    }
                }
                .padding(6)
            }

            // Layanan Eksternal & API Keys
            GroupBox("Kunci API Layanan Eksternal") {
                VStack(alignment: .leading, spacing: 14) {
                    // Resend
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: "#22C55E")).frame(width: 8, height: 8)
                            Text("Resend").font(.system(size: 11, weight: .semibold))
                        }
                        SecureField("API key (re_…)", text: $resendKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("From address (you@yourdomain.com)", text: $resendFrom)
                            .textFieldStyle(.roundedBorder)
                    }

                    // n8n
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: "#F29B38")).frame(width: 8, height: 8)
                            Text("n8n").font(.system(size: 11, weight: .semibold))
                        }
                        TextField("Instance URL (https://…)", text: $n8nUrl)
                            .textFieldStyle(.roundedBorder)
                        SecureField("API key", text: $n8nKey)
                            .textFieldStyle(.roundedBorder)
                        IntegrationFilterRow(
                            label: "Workflows",
                            items: n8nWorkflows,
                            filter: $state.n8nWorkflowFilter,
                            loading: loadingN8n,
                            onLoad: loadN8nWorkflows
                        )
                    }

                    // Vercel
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: "#7C5CFF")).frame(width: 8, height: 8)
                            Text("Vercel").font(.system(size: 11, weight: .semibold))
                        }
                        SecureField("Token", text: $vercelToken)
                            .textFieldStyle(.roundedBorder)
                        IntegrationFilterRow(
                            label: "Projects",
                            items: vercelProjects,
                            filter: $state.vercelProjectFilter,
                            loading: loadingVercel,
                            onLoad: loadVercelProjects
                        )
                    }

                    // GitHub
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: "#F4505E")).frame(width: 8, height: 8)
                            Text("GitHub").font(.system(size: 11, weight: .semibold))
                        }
                        SecureField("Personal Access Token", text: $githubToken)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Stripe
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: "#0570DE")).frame(width: 8, height: 8)
                            Text("Stripe").font(.system(size: 11, weight: .semibold))
                        }
                        SecureField("Secret key (sk_live_… / sk_test_…)", text: $stripeKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Cal.com
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: "#C9956A")).frame(width: 8, height: 8)
                            Text("Cal.com").font(.system(size: 11, weight: .semibold))
                        }
                        SecureField("API key (cal_live_…)", text: $calcomKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Notion
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: "#E8E8E8")).frame(width: 8, height: 8)
                            Text("Notion").font(.system(size: 11, weight: .semibold))
                        }
                        SecureField("Integration token (secret_…)", text: $notionKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button("Simpan Semua Kunci Integrasi") { saveIntegrations() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(6)
            }

            // MCP Server & Clients
            GroupBox("Model Context Protocol (MCP)") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Expose Coucou sebagai MCP Server (stdio)", isOn: $state.mcpServerEnabled)
                    HStack(spacing: 8) {
                        Text("Port:")
                            .font(.system(size: 11))
                        TextField("18765", value: $state.mcpServerPort, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("(digunakan oleh agen eksternal)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Divider().padding(.vertical, 2)

                    Text("Klien MCP Eksternal (Coucou memanggil tools mereka):")
                        .font(.system(size: 11, weight: .semibold))

                    ForEach(Array(state.mcpServers.enumerated()), id: \.element.id) { idx, server in
                        HStack(spacing: 8) {
                            Toggle(server.name, isOn: Binding(
                                get: { state.mcpServers[idx].enabled },
                                set: { state.mcpServers[idx].enabled = $0 }
                            ))
                            Text(server.transport.description)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer(minLength: 0)
                        }
                    }

                    HStack(spacing: 6) {
                        TextField("Nama Server", text: $mcpNewName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        TextField("Perintah (command)", text: $mcpNewCommand)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                        Button("Tambah") {
                            let config = MCPServerConfig(
                                id: UUID().uuidString,
                                name: mcpNewName.isEmpty ? "Server \(state.mcpServers.count + 1)" : mcpNewName,
                                transport: .stdio(command: mcpNewCommand, args: []),
                                enabled: true
                            )
                            state.mcpServers.append(config)
                            mcpNewName = ""
                            mcpNewCommand = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(mcpNewCommand.isEmpty)
                    }
                }
                .padding(6)
            }

            // Docker & Container Engine
            GroupBox("Docker & Container Engine") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: isDockerAvailable ? "shippingbox.fill" : "shippingbox")
                            .foregroundColor(isDockerAvailable ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Docker Daemon:")
                                .font(.system(size: 11, weight: .semibold))
                            Text(isDockerAvailable ? "Aktif & Tersedia (\(dockerContainersCount) container berjalan)" : "Tidak terdeteksi atau daemon belum aktif")
                                .font(.system(size: 10))
                                .foregroundColor(isDockerAvailable ? .green : .secondary)
                        }
                        Spacer()
                        Button(isCheckingDocker ? "Memeriksa..." : "Refresh Status") {
                            isCheckingDocker = true
                            Task {
                                let avail = await DockerIntegrationService.shared.isDockerAvailable()
                                let res = await DockerIntegrationService.shared.listContainers(all: true)
                                await MainActor.run {
                                    isDockerAvailable = avail
                                    dockerContainersCount = res.containers.filter { $0.status.lowercased().hasPrefix("up") }.count
                                    isCheckingDocker = false
                                    statusMessage = avail ? "Docker terdeteksi (\(res.containers.count) container)." : "Docker binary tidak ditemukan."
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCheckingDocker)

                        Button("Lihat di Canvas") {
                            Task {
                                _ = await DockerIntegrationService.shared.listContainers(all: true)
                                await MainActor.run {
                                    if let art = CanvasManager.shared.currentArtifact {
                                        CanvasManager.shared.present(artifact: art)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isDockerAvailable)
                    }
                }
                .padding(6)
            }

            // Remote Server SSH Gateway
            GroupBox("Remote Server SSH Gateway") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Kelola server Linux / Cloud jarak jauh. Mochi dapat mengaudit performa, beban server, dan membaca log.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    if remoteServersList.isEmpty {
                        Text("Belum ada remote server yang didaftarkan.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 2)
                    } else {
                        ForEach(remoteServersList) { srv in
                            HStack(spacing: 8) {
                                Image(systemName: "server.rack")
                                    .foregroundColor(.purple)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(srv.name)")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("\(srv.username)@\(srv.host):\(srv.port) (Key: \(srv.keyPath))")
                                        .font(.system(size: 9.5))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Audit") {
                                    isAuditingServer = true
                                    Task {
                                        let (_, summary) = await SSHServerGatewayService.shared.checkServerHealth(identifier: srv.id)
                                        await MainActor.run {
                                            isAuditingServer = false
                                            statusMessage = "Audit \(srv.name) selesai: \(summary.prefix(30))..."
                                            if let art = CanvasManager.shared.currentArtifact {
                                                CanvasManager.shared.present(artifact: art)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Hapus") {
                                    SSHServerGatewayService.shared.removeServer(id: srv.id)
                                    remoteServersList = SSHServerGatewayService.shared.listServers()
                                    statusMessage = "Server \(srv.name) dihapus."
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Divider()
                        }
                    }

                    // Tambah Server Form
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Daftarkan Server Baru:")
                            .font(.system(size: 10.5, weight: .medium))
                        HStack(spacing: 6) {
                            TextField("Label (Prod Web)", text: $newServerName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5))
                            TextField("Host / IP", text: $newServerHost)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5))
                            TextField("Port", text: $newServerPort)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5))
                                .frame(width: 50)
                        }
                        HStack(spacing: 6) {
                            TextField("User (ubuntu)", text: $newServerUsername)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5))
                                .frame(width: 100)
                            TextField("Key Path (~/.ssh/id_rsa)", text: $newServerKeyPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5))
                            Button("Daftarkan") {
                                let portInt = Int(newServerPort.trimmingCharacters(in: .whitespaces)) ?? 22
                                let srv = RemoteServerConfig(
                                    id: UUID().uuidString,
                                    name: newServerName.trimmingCharacters(in: .whitespaces),
                                    host: newServerHost.trimmingCharacters(in: .whitespaces),
                                    port: portInt,
                                    username: newServerUsername.trimmingCharacters(in: .whitespaces),
                                    keyPath: newServerKeyPath.trimmingCharacters(in: .whitespaces)
                                )
                                SSHServerGatewayService.shared.addOrUpdateServer(srv)
                                remoteServersList = SSHServerGatewayService.shared.listServers()
                                newServerName = ""
                                newServerHost = ""
                                statusMessage = "Server \(srv.name) berhasil didaftarkan."
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(newServerName.isEmpty || newServerHost.isEmpty)
                        }
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(6)
                }
                .padding(6)
            }

            // Kubernetes Cluster Sentinel
            GroupBox("Kubernetes Cluster Sentinel") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: isK8sAvailable ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted")
                            .foregroundColor(isK8sAvailable ? .cyan : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kubectl & Cluster Context:")
                                .font(.system(size: 11, weight: .semibold))
                            Text(isK8sAvailable ? "Aktif: \(k8sContext)" : "Kubectl tidak terdeteksi atau cluster belum terhubung")
                                .font(.system(size: 10))
                                .foregroundColor(isK8sAvailable ? .green : .secondary)
                        }
                        Spacer()
                        Button(isCheckingK8s ? "Cek..." : "Refresh") {
                            isCheckingK8s = true
                            Task {
                                let avail = await KubernetesIntegrationService.shared.isKubectlAvailable()
                                let ctx = await KubernetesIntegrationService.shared.getCurrentContext()
                                await MainActor.run {
                                    isK8sAvailable = avail
                                    k8sContext = ctx
                                    isCheckingK8s = false
                                    statusMessage = avail ? "Cluster Kubernetes: \(ctx)" : "Kubectl tidak aktif."
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCheckingK8s)

                        Button("Periksa Pods di Canvas") {
                            Task {
                                _ = await KubernetesIntegrationService.shared.getPods(namespace: nil)
                                await MainActor.run {
                                    if let art = CanvasManager.shared.currentArtifact {
                                        CanvasManager.shared.present(artifact: art)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isK8sAvailable)
                    }
                }
                .padding(6)
            }

            // Database Safe Explorer & Query
            GroupBox("Database Safe Explorer (Read-Only Guardrail)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Jelajahi skema dan jalankan query analitik secara aman dengan proteksi pemblokiran perintah destruktif.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text("SQLite (Bawaan)").font(.system(size: 10))
                        }
                        HStack(spacing: 4) {
                            Circle().fill(isPsqlAvailable ? Color.green : Color.gray).frame(width: 7, height: 7)
                            Text("PostgreSQL").font(.system(size: 10))
                        }
                        HStack(spacing: 4) {
                            Circle().fill(isMysqlAvailable ? Color.green : Color.gray).frame(width: 7, height: 7)
                            Text("MySQL").font(.system(size: 10))
                        }
                        HStack(spacing: 4) {
                            Circle().fill(isRedisAvailable ? Color.green : Color.gray).frame(width: 7, height: 7)
                            Text("Redis").font(.system(size: 10))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(6)
            }
        }
    }

    // MARK: - Actions & Helpers

    private func applyCustomModel(_ value: String) {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { state.claudeModel = id }
    }

    private func syncModelChoice() {
        let m = state.claudeModel
        if displayModels.contains(where: { $0.id == m }) {
            customModel = ""
            modelChoice = m
        } else {
            customModel = m
            modelChoice = Self.customModelTag
        }
    }

    private func switchProvider(to newId: String) {
        ProviderRegistry.shared.setActiveProvider(id: newId)
        apiKey = KeychainStore.shared.get("\(newId)-api-key") ?? ""
        refreshPoolKeys()
        fetchedModels = []

        let provider = ProviderRegistry.shared.provider(id: newId) ?? ProviderRegistry.shared.activeProvider
        if !provider.fallbackModels.contains(where: { $0.id == state.claudeModel }) {
            state.claudeModel = provider.defaultModel
        }
        syncModelChoice()
        statusMessage = "Beralih ke \(provider.displayName)."

        if let key = KeychainStore.shared.get("\(newId)-api-key"), !key.isEmpty {
            Task {
                let models = await provider.listModels()
                guard !models.isEmpty else { return }
                await MainActor.run {
                    guard selectedProviderId == newId else { return }
                    fetchedModels = models
                    syncModelChoice()
                }
            }
        }
    }

    private func refreshPoolKeys() {
        poolKeys = ProviderRegistry.shared.keys(for: selectedProviderId)
    }

    private func testConnection() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusMessage = "❌ Masukkan kunci API terlebih dahulu."
            return
        }
        KeychainStore.shared.set("\(selectedProviderId)-api-key", value: key)
        statusMessage = "Menguji koneksi ke \(selectedProvider.displayName)..."
        let providerId = selectedProviderId
        Task {
            guard let provider = ProviderRegistry.shared.provider(id: providerId) else { return }
            let models = await provider.listModels()
            await MainActor.run {
                guard selectedProviderId == providerId else { return }
                if models.isEmpty {
                    statusMessage = "❌ Koneksi gagal — periksa API key."
                } else {
                    fetchedModels = models
                    syncModelChoice()
                    statusMessage = "✓ Terhubung (\(models.count) model tersedia)"
                }
            }
        }
    }

    private func toggleStartup(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            statusMessage = "❌ Startup: \(error.localizedDescription)"
            launchAtStartup = !on
        }
    }

    private func restartOnboarding() {
        AppState.shared.hasOnboarded = false
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.perform(Selector(("openOnboarding")))
        }
        statusMessage = "Setup Wizard Onboarding dibuka."
    }

    private func checkForUpdates() {
        Task {
            if let release = await AutoUpdate.shared.checkForUpdates(),
               release.version > AutoUpdate.shared.currentVersion {
                updateAvailable = release
                showUpdateAlert = true
            } else {
                statusMessage = "Versi terbaru (\(AutoUpdate.shared.currentVersion)) sudah terpasang."
            }
        }
    }

    private func runNightShiftManual() {
        nightShiftRunning = true
        Task {
            let rep = await NightShiftWorker.shared.executeNightShift()
            await MainActor.run {
                nightShiftRunning = false
                statusMessage = "✓ Night Shift selesai: \(rep.filesOrganized) file dirapikan."
            }
        }
    }

    private func testOllama() {
        ollamaStatus = "Mengecek Ollama (http://127.0.0.1:11434)..."
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = json["models"] as? [[String: Any]] {
                        let names = models.compactMap { $0["name"] as? String }
                        await MainActor.run {
                            ollamaStatus = "✓ Ollama Terhubung! Model: " + (names.isEmpty ? "Belum ada model" : names.joined(separator: ", "))
                        }
                    } else {
                        await MainActor.run {
                            ollamaStatus = "✓ Ollama Aktif (HTTP 200)"
                        }
                    }
                } else {
                    await MainActor.run {
                        ollamaStatus = "❌ Gagal koneksi (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))"
                    }
                }
            } catch {
                await MainActor.run {
                    ollamaStatus = "❌ Ollama offline (Pastikan 'ollama serve' berjalan)"
                }
            }
        }
    }

    private func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func saveIntegrations() {
        saveKey("resend-api-key",  value: resendKey)
        saveKey("resend-from",     value: resendFrom)
        saveKey("n8n-url",         value: n8nUrl)
        saveKey("n8n-api-key",     value: n8nKey)
        saveKey("vercel-token",    value: vercelToken)
        saveKey("github-token",    value: githubToken)
        saveKey("stripe-api-key",  value: stripeKey)
        saveKey("calcom-api-key",  value: calcomKey)
        saveKey("notion-api-key",  value: notionKey)
        saveKey("elevenlabs-api-key", value: elevenLabsKey)
        statusMessage = "✓ Kunci integrasi tersimpan."
    }

    private func saveKey(_ key: String, value: String) {
        if value.isEmpty {
            KeychainStore.shared.remove(key)
        } else {
            KeychainStore.shared.set(key, value: value)
        }
    }

    private func loadVercelProjects() {
        guard let token = KeychainStore.shared.get("vercel-token") else {
            statusMessage = "❌ Simpan token Vercel terlebih dahulu."
            return
        }
        loadingVercel = true
        guard let url = URL(string: "https://api.vercel.com/v9/projects?limit=100") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let names: [String]
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let projects = json["projects"] as? [[String: Any]] {
                names = projects.compactMap { $0["name"] as? String }.sorted()
            } else {
                names = []
            }
            DispatchQueue.main.async {
                self.vercelProjects = names
                self.loadingVercel = false
                if names.isEmpty { self.statusMessage = "❌ Tidak ada proyek Vercel yang ditemukan." }
            }
        }.resume()
    }

    private func loadN8nWorkflows() {
        guard let apiKey  = KeychainStore.shared.get("n8n-api-key"),
              let rawBase = KeychainStore.shared.get("n8n-url") else {
            statusMessage = "❌ Simpan URL dan API key n8n terlebih dahulu."
            return
        }
        loadingN8n = true
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urls = ["\(base)/api/v1/workflows?limit=100", "\(base)/rest/workflows?limit=100"]
        fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: 0)
    }

    private func fetchN8nWorkflows(urls: [String], apiKey: String, idx: Int) {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            DispatchQueue.main.async { self.loadingN8n = false; self.statusMessage = "❌ Tidak ada workflow n8n ditemukan." }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-N8N-API-KEY")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                self.fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: idx + 1)
                return
            }
            let items: [[String: Any]]
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = obj["data"] as? [[String: Any]] { items = arr }
            else if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] { items = arr }
            else { items = [] }
            let names = items.compactMap { $0["name"] as? String }.sorted()
            DispatchQueue.main.async {
                self.n8nWorkflows = names
                self.loadingN8n = false
                if names.isEmpty { self.statusMessage = "❌ Tidak ada workflow n8n ditemukan." }
            }
        }.resume()
    }

    // MARK: - Hooks Install Helpers

    #if APPSTORE
    private func installHooksAppStore() {
        let panel = NSOpenPanel()
        panel.message = "Pilih folder .claude Anda (tekan ⇧⌘. untuk menampilkan folder tersembunyi)"
        panel.prompt = "Pilih"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        let realHome = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) } ?? "/Users/\(NSUserName())"
        panel.directoryURL = URL(fileURLWithPath: realHome)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent == ".claude" else {
            statusMessage = "❌ Pilih folder .claude di Home directory Anda."
            return
        }
        do {
            try HookServer.shared.installAndWriteClaudeHooksAppStore(claudeURL: url)
            hookNeedsUpdate = false
            statusMessage = "✓ Hooks terpasang — mulai ulang VS Code."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func uninstallHooksAppStore() {
        let panel = NSOpenPanel()
        panel.message = "Pilih folder .claude untuk mencopot hooks"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HookServer.shared.uninstallClaudeHooksAppStore(claudeURL: url)
            statusMessage = "✓ Hooks dicopot."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #else
    private func installHooks() {
        do {
            pendingHookJSON = try HookServer.shared.previewClaudeHooks()
            showDiff = true
            statusMessage = "Tinjau JSON hook di bawah sebelum mengonfirmasi."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmInstall() {
        do {
            try HookServer.shared.writeClaudeHooks()
            showDiff = false
            statusMessage = "✓ Hooks terpasang di ~/.claude/settings.json"
            pendingHookJSON = ""
            hookNeedsUpdate = false
        } catch {
            statusMessage = "❌ Write error: \(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            try HookServer.shared.uninstallClaudeHooks()
            statusMessage = "✓ Hooks dicopot."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif
}

// MARK: - Reusable Integration Filter Row

struct IntegrationFilterRow: View {
    let label: String
    let items: [String]
    @Binding var filter: Set<String>
    let loading: Bool
    let onLoad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if loading {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button(items.isEmpty ? "Muat Daftar" : "Segarkan") { onLoad() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                if !filter.isEmpty {
                    Button("Semua") { filter = [] }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundColor(.secondary)
                }
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.self) { item in
                        Toggle(item, isOn: Binding(
                            get: { filter.isEmpty || filter.contains(item) },
                            set: { on in
                                if on { filter.insert(item) }
                                else  {
                                    if filter.isEmpty { filter = Set(items).subtracting([item]) }
                                    else { filter.remove(item) }
                                    if filter.count == items.count { filter = [] }
                                }
                            }
                        ))
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 4)
                if !filter.isEmpty {
                    Text("Memantau \(filter.count) dari \(items.count)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Shortcut Recorder Button

struct ShortcutRecorderButton: View {
    @Binding var flags: UInt
    @Binding var code: UInt16
    @State private var isRecording = false

    var body: some View {
        Button {
            guard !isRecording else { return }
            isRecording = true
            var token: Any?
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard !mods.isEmpty else { return event }
                DispatchQueue.main.async {
                    self.flags = mods.rawValue
                    self.code = event.keyCode
                    self.isRecording = false
                    if let t = token { NSEvent.removeMonitor(t) }
                }
                return nil
            }
        } label: {
            Text(isRecording ? "Tekan tombol…" : shortcutLabel)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isRecording ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var shortcutLabel: String {
        let f = NSEvent.ModifierFlags(rawValue: flags)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += keyChar(code)
        return s.isEmpty ? "None" : s
    }

    private func keyChar(_ c: UInt16) -> String {
        let map: [UInt16: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 31:"O", 32:"U",
            34:"I", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M", 49:"Space", 50:"`", 27:"-"
        ]
        return map[c] ?? "·"
    }
}