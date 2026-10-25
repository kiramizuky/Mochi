import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var voice = VoiceManager.shared
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
    @State private var launchAtStartup: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var statusMessage: String = ""
    @State private var showDiff: Bool = false
    @State private var pendingHookJSON: String = ""
    @State private var hookNeedsUpdate: Bool = HookServer.hooksNeedUpdate()

    // Auto-update
    @State private var updateAvailable: AppRelease?
    @State private var showUpdateAlert: Bool = false

    // MCP client add form
    @State private var mcpNewName: String = ""
    @State private var mcpNewCommand: String = ""

    // Integration keys
    @State private var resendKey: String    = KeychainStore.shared.get("resend-api-key")  ?? ""
    @State private var resendFrom: String   = KeychainStore.shared.get("resend-from")     ?? ""
    @State private var n8nUrl: String       = KeychainStore.shared.get("n8n-url")         ?? ""
    @State private var n8nKey: String       = KeychainStore.shared.get("n8n-api-key")     ?? ""
    @State private var vercelToken: String  = KeychainStore.shared.get("vercel-token")    ?? ""
    @State private var githubToken: String  = KeychainStore.shared.get("github-token")    ?? ""
    @State private var stripeKey: String    = KeychainStore.shared.get("stripe-api-key")  ?? ""
    @State private var calcomKey: String    = KeychainStore.shared.get("calcom-api-key")  ?? ""
    @State private var notionKey: String    = KeychainStore.shared.get("notion-api-key")  ?? ""
    @State private var elevenLabsKey: String = KeychainStore.shared.get("elevenlabs-api-key") ?? ""

    // Hotkey
    @State private var hotkeyFlags: UInt    = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16   = AppState.shared.hotkeyCode

    // Vercel project filter
    @State private var vercelProjects: [String] = []
    @State private var loadingVercel: Bool = false

    // n8n workflow filter
    @State private var n8nWorkflows: [String] = []
    @State private var loadingN8n: Bool = false

    // Autonomous & Local SLM states
    @State private var ollamaStatus: String = ""
    @State private var nightShiftRunning: Bool = false
    @State private var accessibilityGranted: Bool = AXIsProcessTrusted()

    // Bindings in minutes for the absence field
    private var absenceMinutes: Binding<Double> {
        Binding(
            get: { state.absenceInterval / 60 },
            set: { state.absenceInterval = max(1, $0) * 60 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                // MARK: API
                GroupBox("AI Provider") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Provider", selection: $selectedProviderId) {
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
                            Button("Save") {
                                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !key.isEmpty else { return }
                                KeychainStore.shared.set("\(selectedProviderId)-api-key", value: key)
                                ProviderRegistry.shared.addKey(providerId: selectedProviderId, label: "Primary Key", secret: key)
                                refreshPoolKeys()
                                statusMessage = "✓ Key saved."
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Test connection") { testConnection() }
                                .buttonStyle(.bordered)
                        }

                        // Multi-Key Pool Section
                        Divider().padding(.vertical, 2)
                        HStack {
                            Text("Key Pool (\(poolKeys.count) terdaftar)")
                                .font(.system(size: 11, weight: .semibold))
                            Spacer()
                            Button(showAddKeyForm ? "Tutup" : "+ Tambah Key") {
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
                                                Text("Terakhir dipakai: \(last.formatted(.relative(presentation: .named)))")
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
                                    .padding(4)
                                    .background(Color.secondary.opacity(0.08))
                                    .cornerRadius(6)
                                }
                            }
                        }

                        if showAddKeyForm {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    TextField("Label (Key 2, Backup)", text: $newKeyLabel)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 140)
                                    SecureField(keyPlaceholder, text: $newKeySecret)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Tambah") {
                                        let sec = newKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !sec.isEmpty else { return }
                                        ProviderRegistry.shared.addKey(providerId: selectedProviderId, label: newKeyLabel, secret: sec)
                                        newKeyLabel = ""
                                        newKeySecret = ""
                                        showAddKeyForm = false
                                        refreshPoolKeys()
                                        statusMessage = "✓ Key ditambahkan ke pool."
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(newKeySecret.isEmpty)
                                }
                            }
                            .padding(6)
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(6)
                        }

                        Divider().padding(.vertical, 2)

                        Picker("Model", selection: $modelChoice) {
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
                            TextField("Model ID (e.g. \(selectedProvider.defaultModel))", text: $customModel)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: customModel) { _, value in applyCustomModel(value) }
                        }

                        Text("Used by the chat. The list comes from your \(selectedProvider.displayName) account.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                // MARK: Hooks
                GroupBox("Claude Code Hooks") {
                    VStack(alignment: .leading, spacing: 10) {
                        if hookNeedsUpdate {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Hook timeout outdated — update to fix approvals")
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
                            .frame(height: 140)
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

                // MARK: Integrations
                GroupBox("Integrations") {
                    VStack(alignment: .leading, spacing: 14) {

                        // Resend
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#22C55E")).frame(width: 8, height: 8)
                                Text("Resend").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("API key  (re_…)", text: $resendKey)
                                .textFieldStyle(.roundedBorder)
                            TextField("From address  (you@yourdomain.com)", text: $resendFrom)
                                .textFieldStyle(.roundedBorder)
                        }

                        // n8n
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#F29B38")).frame(width: 8, height: 8)
                                Text("n8n").font(.system(size: 12, weight: .semibold))
                            }
                            TextField("Instance URL  (https://…)", text: $n8nUrl)
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
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#7C5CFF")).frame(width: 8, height: 8)
                                Text("Vercel").font(.system(size: 12, weight: .semibold))
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
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#F4505E")).frame(width: 8, height: 8)
                                Text("GitHub").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("Personal Access Token", text: $githubToken)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Stripe
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#0570DE")).frame(width: 8, height: 8)
                                Text("Stripe").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("Secret key  (sk_live_… or sk_test_…)", text: $stripeKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Cal.com
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#C9956A")).frame(width: 8, height: 8)
                                Text("Cal.com").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("API key  (cal_live_…)", text: $calcomKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        // Notion
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#E8E8E8")).frame(width: 8, height: 8)
                                Text("Notion").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("Integration token  (secret_…)", text: $notionKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button("Save integrations") { saveIntegrations() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(6)
                }

                // MARK: Son
                GroupBox("Sound") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable sounds", isOn: $state.soundEnabled)
                        HStack(spacing: 8) {
                            Text("Volume")
                                .frame(width: 56, alignment: .leading)
                            Slider(value: $state.soundVolume, in: 0...0.2)
                                .disabled(!state.soundEnabled)
                            let volPct = Int(state.soundVolume / 0.2 * 100.0)
                            Text("\(volPct) %")
                                .frame(width: 36, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                    .padding(6)
                }

                // MARK: Voice
                GroupBox("Voice & Speech") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Speak answers", isOn: $voice.speakAnswers)
                        Toggle("Wake word «Mochi»", isOn: $voice.wakeWordEnabled)
                            .onChange(of: voice.wakeWordEnabled) { _, on in
                                voice.setWakeWord(enabled: on)
                            }
                        if voice.wakeWordEnabled {
                            Text("Keeps the microphone active while the app runs (small CPU cost).")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Divider().padding(.vertical, 2)

                        // TTS Engine Selection
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("TTS Engine:")
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
                                    .fixedSize(horizontal: false, vertical: true)
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
                                        .fixedSize(horizontal: false, vertical: true)
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
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                Text("Synthesizer bawaan macOS lokal (cepat & offline).")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // Test voice button
                            Button(action: {
                                voice.speak("Halo! Saya Mochi, asisten pribadi Anda. Ada yang bisa saya bantu hari ini?")
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "speaker.wave.2.fill")
                                    Text("Tes Suara")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.top, 4)

                            Divider().padding(.vertical, 4)

                            // Voice Duplex & Barge-In
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Toggle("Voice Duplex (Natural Barge-In)", isOn: Binding(
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
                                        Circle().fill(Color.green).frame(width: 8, height: 8)
                                        Text("Aktif")
                                            .font(.system(size: 10))
                                            .foregroundColor(.green)
                                    }
                                }
                                Text("Menyela pembicaraan asisten secara instan cukup dengan mulai berbicara.")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)

                                HStack(spacing: 8) {
                                    Text("Intonasi Suara:")
                                        .font(.system(size: 11))
                                    Picker("", selection: Binding(
                                        get: { VoiceDuplexEngine.shared.emotionalTone },
                                        set: { VoiceDuplexEngine.shared.setTone($0) }
                                    )) {
                                        Text("Attentive (Ramah)").tag(VoiceDuplexEngine.EmotionalTone.attentive)
                                        Text("Focused (Fokus Kerja)").tag(VoiceDuplexEngine.EmotionalTone.focused)
                                        Text("Caution (Peringatan)").tag(VoiceDuplexEngine.EmotionalTone.caution)
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 180)
                                }
                            }
                        }
                    }
                    .padding(6)
                }

                // MARK: MCP
                GroupBox("MCP") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Expose Coucou as MCP server (stdio)", isOn: $state.mcpServerEnabled)
                        HStack(spacing: 8) {
                            Text("Port")
                            TextField("18765", value: $state.mcpServerPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("(digunakan oleh agen eksternal)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Divider().padding(.vertical, 2)
                        Text("Server klien (Coucou memanggil alat mereka)")
                            .font(.system(size: 12, weight: .semibold))
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
                            TextField("nama server", text: $mcpNewName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                            TextField("perintah", text: $mcpNewCommand)
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
                                mcpNewName = ""; mcpNewCommand = ""
                            }
                            .buttonStyle(.bordered)
                            .disabled(mcpNewCommand.isEmpty)
                        }
                    }
                    .padding(6)
                }

                // MARK: Structured Playbooks
                GroupBox("Structured Playbooks (SOPs)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Alur kerja multi-langkah otonom untuk tugas kantor dan sistem.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        ForEach(PlaybookEngine.shared.allPlaybooks) { pb in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .center, spacing: 8) {
                                    Image(systemName: pb.category == "Office" ? "doc.richtext" : (pb.category == "Research" ? "globe" : "gearshape.2"))
                                        .font(.system(size: 14))
                                        .foregroundColor(.accentColor)
                                        .frame(width: 20)

                                    Text(pb.name)
                                        .font(.system(size: 12, weight: .semibold))

                                    Spacer()

                                    Text("\(pb.steps.count) langkah")
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12))
                                        .cornerRadius(4)

                                    Button("Jalankan") {
                                        Task { @MainActor in
                                            _ = await PlaybookEngine.shared.run(
                                                playbookId: pb.id,
                                                context: ["topic": "Tren AI & Teknologi Terkini"],
                                                toolExecutor: ToolExecutor()
                                            )
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                Text(pb.description)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    .padding(6)
                }

                // MARK: Enterprise / Produksi
                GroupBox("Enterprise / Produksi") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Mode otopilot (JARVIS)", isOn: $state.autopilotEnabled)
                            .onChange(of: state.autopilotEnabled) { _, _ in
                                state.applyAutopilotMode()
                            }
                        Text("Autopilot menjalankan aksi non-kritis (shell, email, web) otomatis. Hard floor (sudo, rm -rf, pipe-to-shell, ~/.claude/settings.json) selalu aktif dan tidak bisa di-override.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        Divider().padding(.vertical, 2)

                        HStack(spacing: 8) {
                            Text("Batas langkah agent")
                            TextField("12", value: $state.agentStepLimit, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("langkah per permintaan")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Divider().padding(.vertical, 2)

                        HStack(spacing: 8) {
                            Text("Audit log")
                            TextField("path", text: .constant(AuditLog.defaultURL().path))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .disabled(true)
                            Button("Buka folder") {
                                NSWorkspace.shared.open(AuditLog.defaultURL().deletingLastPathComponent())
                            }
                            .buttonStyle(.bordered)
                        }

                        Divider().padding(.vertical, 2)

                        HStack(spacing: 8) {
                            Button("Cek pembaruan") {
                                Task {
                                    if let release = await AutoUpdate.shared.checkForUpdates(),
                                       release.version > AutoUpdate.shared.currentVersion {
                                        updateAvailable = release
                                        showUpdateAlert = true
                                    } else {
                                        statusMessage = "Versi terbaru sudah terpasang."
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            if let updateAvailable {
                                Text("Tersedia v\(updateAvailable.version)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(hex: "#22C55E"))
                            }
                        }
                    }
                    .padding(6)
                }

                // MARK: OS-Level GUI Driving & Autonomous Workers
                GroupBox("Computer Control & Autonomous Workers (CUA & Night Shift)") {
                    VStack(alignment: .leading, spacing: 10) {
                        // CUA Status & Accessibility
                        HStack(spacing: 8) {
                            Circle().fill(accessibilityGranted ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text("Izin Aksesibilitas macOS:")
                                .font(.system(size: 11, weight: .semibold))
                            Text(accessibilityGranted ? "Terverifikasi (CGEvent Aktif)" : "Belum Diberikan")
                                .font(.system(size: 11))
                                .foregroundColor(accessibilityGranted ? .secondary : .orange)
                            Spacer()
                            Button(action: {
                                accessibilityGranted = AXIsProcessTrusted()
                                if accessibilityGranted {
                                    statusMessage = "✓ Izin Aksesibilitas terverifikasi aktif!"
                                } else {
                                    statusMessage = "Izin belum terdeteksi. Buka Pengaturan Sistem untuk memeriksa."
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Cek Ulang")
                                }
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

                        if !accessibilityGranted {
                            Text("💡 Tips macOS: Jika di Pengaturan Sistem toggle Coucou sudah ON tetapi di sini masih 'Belum Diberikan', matikan lalu nyalakan kembali (toggle OFF lalu ON) toggle Coucou di Pengaturan Sistem, lalu klik 'Cek Ulang'.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(6)
                                .background(Color.orange.opacity(0.08))
                                .cornerRadius(4)
                        }

                        Text("JARVIS dapat mengendalikan kursor, klik tombol, scroll, dan mengetik pada aplikasi apapun di Mac (termasuk Canva, ERP, atau Web tanpa API) menggunakan CoreGraphics.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Text("Panic Guardrail:")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Sensitif (> 40px gerakan mouse fisik otomatis membatalkan bot)")
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

                        Divider().padding(.vertical, 2)

                        // Night Shift
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Autonomous Night-Shift")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Otomatis merapikan Downloads/Desktop dan audit disk saat Mac idle > 15 menit (22:00 - 05:00).")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(nightShiftRunning ? "Sedang Bekerja..." : "Jalankan Night Shift Sekarang") {
                                runNightShiftManual()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(nightShiftRunning)
                        }

                        if let report = NightShiftWorker.shared.latestReport {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Laporan Terakhir: \(report.timestamp.formatted(.relative(presentation: .named)))")
                                    .font(.system(size: 10, weight: .medium))
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

                // MARK: Hybrid Edge-Cloud & Local MLX Engine
                GroupBox("Hybrid Edge-Cloud & Local SLM Engine") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Privasi total & respons instan <50ms dengan Apple Silicon Native inference.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Text("Smart Intent Router:")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Perintah rutin → Local SLM (0ms internet). Penalaran rumit → Cloud LLM.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }

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

                // MARK: Timings
                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Close after")
                            TextField("60", value: $state.autoCloseInterval, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("s inactive")
                        }
                        HStack(spacing: 8) {
                            Text("Hide after")
                            TextField("3", value: absenceMinutes, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 48)
                            Text("min without movement")
                        }
                    }
                    .padding(6)
                }

                // MARK: Editor & Coding Agents
                GroupBox("Editor & Coding Agents") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Izinkan Semua Editor & Terminal", isOn: $state.allowAllEditors)
                        Text("Terima event Claude Code / Coding Agent dari Antigravity, Cursor, Windsurf, VS Code, iTerm, Warp, Terminal, Codex, dll.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

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

                // MARK: Active Slots
                GroupBox("Slot Integrasi Aplikasi Aktif (Active Slots)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pilih hingga 4 integrasi (seperti GitHub, Linear, Slack, WhatsApp, PyCharm, Word, Excel, dll.) untuk dimunculkan sebagai pill di Notch Island.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Text("Coding Agent (Claude Code)")
                                .font(.system(size: 12, weight: .semibold))
                            Circle().fill(Color(hex: "#F5F6F8")).frame(width: 8, height: 8)
                            Spacer()
                            Text("Always active")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        Text("\(state.activeIntegrations.count)/4 slots used")
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
                                    .frame(width: 10, height: 10)
                                Text(task.name)
                                    .font(.system(size: 12))
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

                // MARK: Hotkey
                GroupBox("Hotkey") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show island with shortcut", isOn: $state.hotkeyEnabled)
                        if state.hotkeyEnabled {
                            HStack(spacing: 8) {
                                Text("Shortcut")
                                    .frame(width: 70, alignment: .leading)
                                ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode)
                                    .onChange(of: hotkeyFlags) { _, v in state.hotkeyFlags = v }
                                    .onChange(of: hotkeyCode)  { _, v in state.hotkeyCode  = v }
                                Text("presses this → island opens")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(6)
                }

                // MARK: Startup
                GroupBox("Startup") {
                    Toggle("Launch at Mac startup", isOn: $launchAtStartup)
                        .onChange(of: launchAtStartup) { _, on in toggleStartup(on) }
                        .padding(6)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(statusMessage.hasPrefix("❌") ? .red : .secondary)
                        .padding(.horizontal, 2)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
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
            accessibilityGranted = AXIsProcessTrusted()
            selectedProviderId = ProviderRegistry.shared.activeProviderId
            apiKey = KeychainStore.shared.get("\(selectedProviderId)-api-key") ?? ""
            refreshPoolKeys()
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
        .frame(minWidth: 500, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func applyCustomModel(_ value: String) {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { state.claudeModel = id }
    }

    /// Re-syncs the model pickers against the current model + fetched list.
    /// Sets `customModel` BEFORE `modelChoice` so the onChange handler reads the right value.
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

    /// Switches the active provider: reloads its key, resets the model list and the
    /// chosen model (a model from the previous provider is meaningless here).
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
        statusMessage = "Switched to \(provider.displayName)."

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

    /// Saves the key and verifies it by listing the provider's models.
    private func testConnection() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusMessage = "❌ Enter an API key first."
            return
        }
        KeychainStore.shared.set("\(selectedProviderId)-api-key", value: key)
        statusMessage = "Testing…"
        let providerId = selectedProviderId
        Task {
            guard let provider = ProviderRegistry.shared.provider(id: providerId) else { return }
            let models = await provider.listModels()
            await MainActor.run {
                guard selectedProviderId == providerId else { return }
                if models.isEmpty {
                    statusMessage = "❌ Connection failed — check the key."
                } else {
                    fetchedModels = models
                    syncModelChoice()
                    statusMessage = "✓ Connected (\(models.count) models)"
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

    // MARK: - App Store: hooks via NSOpenPanel + security-scoped bookmark

    #if APPSTORE
    /// Opens NSOpenPanel to select ~/.claude, then writes hooks directly.
    /// NSOpenPanel grants sandbox access immediately — no security-scoped bookmark needed.
    private func pickClaudeFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Select your .claude folder (press ⇧⌘. to show hidden files)"
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // getpwuid bypasses CFFIXED_USER_HOME and always returns the real user home
        let realHomePath = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? "/Users/\(NSUserName())"
        panel.directoryURL = URL(fileURLWithPath: realHomePath)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.lastPathComponent == ".claude" else {
            statusMessage = "❌ Select the .claude folder (hidden, in your Home directory)."
            return nil
        }
        return url
    }

    private func installHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        let alert = NSAlert()
        alert.messageText = "Install Coucou hooks in ~/.claude?"
        alert.informativeText = "Will write:\n• ~/.claude/coucou/nb-hook\n• ~/.claude/settings.json (backup created first)"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookServer.shared.installAndWriteClaudeHooksAppStore(claudeURL: claudeURL)
            hookNeedsUpdate = false
            statusMessage = "✓ Hooks installed — restart VS Code to activate."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func uninstallHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        do {
            try HookServer.shared.uninstallClaudeHooksAppStore(claudeURL: claudeURL)
            statusMessage = "✓ Hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif

    private func installHooks() {
        do {
            pendingHookJSON = try HookServer.shared.previewClaudeHooks()
            showDiff = true
            statusMessage = "Review the JSON below before confirming."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmInstall() {
        do {
            try HookServer.shared.writeClaudeHooks()
            showDiff = false
            statusMessage = "✓ Hooks installed in ~/.claude/settings.json"
            pendingHookJSON = ""
            hookNeedsUpdate = false
        } catch {
            statusMessage = "❌ Write error: \(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            try HookServer.shared.uninstallClaudeHooks()
            statusMessage = "✓ Hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
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
        statusMessage = "✓ Integration keys saved."
    }

    /// Saves non-empty value; removes only if key was previously set (explicit user clear).
    private func saveKey(_ key: String, value: String) {
        if value.isEmpty {
            KeychainStore.shared.remove(key)
        } else {
            KeychainStore.shared.set(key, value: value)
        }
    }

    // MARK: - Vercel project list

    private func loadVercelProjects() {
        guard let token = KeychainStore.shared.get("vercel-token") else {
            statusMessage = "❌ Save Vercel token first."
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
                if names.isEmpty { self.statusMessage = "❌ No Vercel projects found." }
            }
        }.resume()
    }

    // MARK: - n8n workflow list

    private func loadN8nWorkflows() {
        guard let apiKey  = KeychainStore.shared.get("n8n-api-key"),
              let rawBase = KeychainStore.shared.get("n8n-url") else {
            statusMessage = "❌ Save n8n URL and API key first."
            return
        }
        loadingN8n = true
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urls = ["\(base)/api/v1/workflows?limit=100", "\(base)/rest/workflows?limit=100"]
        fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: 0)
    }

    private func fetchN8nWorkflows(urls: [String], apiKey: String, idx: Int) {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            DispatchQueue.main.async { self.loadingN8n = false; self.statusMessage = "❌ No n8n workflows found." }
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
                if names.isEmpty { self.statusMessage = "❌ No n8n workflows found." }
            }
        }.resume()
    }

    // MARK: - Autonomous Helpers
    private var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    private func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
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
}

// MARK: - Integration filter row (reusable for Vercel / n8n)

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
                    Button(items.isEmpty ? "Load list" : "Refresh") { onLoad() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                if !filter.isEmpty {
                    Button("Clear") { filter = [] }
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
                                    // First click on any item: switch from "all" to explicit set
                                    if filter.isEmpty { filter = Set(items).subtracting([item]) }
                                    else { filter.remove(item) }
                                    if filter.count == items.count { filter = [] } // all = empty
                                }
                            }
                        ))
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 4)
                if !filter.isEmpty {
                    Text("Watching \(filter.count) of \(items.count)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Shortcut recorder button

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
            Text(isRecording ? "Press keys…" : shortcutLabel)
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
