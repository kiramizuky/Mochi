# JARVIS Autonomous — plan 7 fase

Transformasi Coucou (NotchBuddy) dari remote-control Claude Code menjadi autonomous AI assistant ala JARVIS: tanpa klik, bisa bicara, multi-model, menjalankan/mengakses aplikasi + internet, self-repair, memahami bahasa manusia.

## Keputusan desain (user)

- **Full Autopilot** — semua aksi jalan otomatis menurut policy, termasuk auto-approve shell & email. Hard floor keamanan tetap berlaku (tidak bisa di-override).
- **PTT + wake word opsional** — push-to-talk default; wake word "Mochi" default OFF (syarat: 0 % CPU saat island hidden).
- **Full control aplikasi sejak awal** — shell + Accessibility + screenshot + tulis file.

## Aturan yang berlaku sepanjang fase

- Swift 6, SwiftUI + AppKit, zero third-party dependency (kecuali benar-benar tak terhindarkan).
- Secrets hanya di Keychain. Tidak ada telemetry. Network hanya ke service yang dikonfigurasi user.
- Bundle ID `fr.louisraille.NotchBuddy` tidak berubah.
- Jangan pernah blokir Claude Code: kalau app tidak menjawab, hook langsung exit.
- Jangan pernah overwrite `~/.claude/settings.json`: backup bertanggal, merge, tampilkan diff, tulis hanya setelah user konfirmasi.
- 0 % CPU saat island hidden.
- Visual harus match prototype (`design/prototype/notch-buddy.html`) dan `design/captures/`.
- Test: pola `tests/*.swift` + `scripts/test-*.sh` (swiftc standalone, Foundation-only).
- Build: `cd NotchBuddy && xcodegen && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme NotchBuddy -configuration Debug build`.

## Status

| Fase | Isi | Status |
|---|---|---|
| 0 | LLMProvider abstraction + streaming chat | ✅ selesai |
| 1 | Multi-provider (OpenAI/Gemini) + Settings UI provider | ✅ selesai |
| 2 | Agent loop: ToolExecutor + PolicyEngine + AuditLog + AgentController | ✅ selesai |
| 3 | Voice: TTS + PTT speech-to-text + wake word opsional | ✅ selesai |
| 4 | Internet + kontrol aplikasi (search, AppController, shell action) | ✅ selesai |
| 5 | Perception: screenshot + Accessibility + MemoryService | ✅ selesai |
| 6 | Proactive, self-repair, language router, headless Claude, update CLAUDE.md | ✅ selesai |
| 7 | Performans, onboarding, polish visual | ⬜ |

---

## Phase 0 — LLMProvider abstraction ✅

**Tujuan:** semua LLM call melewati satu protocol → provider lain tinggal plug-in; streaming token muncul real-time di bubble chat.

Baru/berubah:

- `Sources/App/LLMProvider.swift` — `JSONValue` (dengan subscript), `LLMMessage`/`LLMContentBlock`/`LLMRequest`/`LLMResponse`/`LLMStreamEvent`/`LLMError`, `protocol LLMProvider: Sendable` (complete + stream).
- `Sources/App/AnthropicProvider.swift` — implementasi Anthropic: request body, wire encoding, SSE streaming (`URLSession.bytes` + parser satu-event), error mapping (401/404/429), `listModels()`. API key diinject via closure (Keychain di supply registry → provider tetap standalone-testable).
- `Sources/App/ProviderRegistry.swift` — registry thread-safe, provider aktif persist di UserDefaults.
- `Sources/App/ChatStore.swift` — riwayat chat multi-turn (text-only, provider-agnostik), rollback saat gagal.
- `Sources/App/ClaudeService.swift` — jadi facade tipis: signature `chat`/`search`/`fetchModels` tidak berubah, internals pakai registry + streaming.
- `Sources/App/AppState.swift` — `ChatMessage.content` `let` → `var` (bubble di-mutate per delta).
- `Sources/App/IslandViewContent.swift` — auto-scroll ikut token (onChange content, tanpa animasi).
- `tests/LLMProviderTests.swift` + `scripts/test-llm-provider.sh` — wire encoding, request body, SSE parser (termasuk guard: setelah `message_stop` tidak ada event lagi), error mapping, ChatStore.

Catatan: web search server-tool `max_uses` = 5 (sebelumnya 3).

**Verifikasi:** `test-llm-provider.sh` ✅, `test-safe-links.sh` (15) ✅, `test-screen-geometry.sh` (13) ✅, `xcodebuild` **BUILD SUCCEEDED** ✅.

---

## Phase 1 — Multi-provider + Settings UI ✅

- `OpenAIProvider.swift` (chat completions + streaming SSE), `GeminiProvider.swift` (streamGenerateContent) — implement `LLMProvider`.
- `SettingsView`: pilih provider aktif, API key per provider ditulis ke Keychain (`<provider>-api-key`), field model, tombol "Test connection" (pakai `listModels`/ping murah).
- Model picker di UI baca dari provider aktif.
- Tests: encoding request masing-masing provider + parser SSE mereka.

Baru/berubah:

- `Sources/App/OpenAIProvider.swift` — request body (stream-only key), wire encoding, SSE parser, `parseModelList` (filter prefix/exclude, sort newest), error mapping 401/429/404.
- `Sources/App/GeminiProvider.swift` — `streamGenerateContent`, SSE parser, `parseModelList` (harus `generateContent`), functionRequest/functionResponse wiring, error mapping. Fix: `functionResponse` bungkus `{content:…}` + `isError`; `finishReason: STOP` + `functionCall` → stopReason `.toolUse` (streaming & non-streaming) supaya tool loop jalan.
- `Sources/App/ProviderRegistry.swift` — register 3 provider (Anthropic default), `available`/`activeProviderId`/`activeProvider` publik.
- `Sources/App/KeychainStore.swift` — `Keychain` + `KeychainStore` dipindah keluar dari `ClaudeService.swift` (lebih dari 100 baris).
- `Sources/App/SettingsView.swift` — pemilih provider, sync model ke provider aktif, `testConnection()` per provider.
- `Sources/App/IslandViewContent.swift` — indikator apiConnected ikut provider aktif.
- `tests/MultiProviderTests.swift` + `scripts/test-multi-provider.sh` — request body, wire encoding, SSE parser, parseResponse, filter model, registry (10 test).

**Verifikasi:** `test-multi-provider.sh` ✅, `test-llm-provider.sh` ✅, `test-safe-links.sh` (15) ✅, `test-screen-geometry.sh` (13) ✅, `xcodebuild` **BUILD SUCCEEDED** ✅.

## Phase 2 — Agent loop (inti autonomous)

- `PolicyEngine.swift` — policy per kategori aksi (shell, file write, email, network, app control). Mode: `autopilot` / `askOnce` / `manual`. **Hard floor** (selalu ditolak apa pun policy): `sudo`, `rm -rf /`, `diskutil erase*`, pipe ke shell (`curl|sh`), modifikasi `~/.claude/settings.json` tanpa alur backup+diff+konfirmasi. Floor di atas policy — tidak bisa dimatikan.
- `AuditLog.swift` — JSONL append-only: timestamp, aksi, target, keputusan, exit code; dipakai self-repair & inspeksi user.
- `ToolExecutor.swift` — definisi tool JSON (schema) + eksekusi: `shell.run`, `file.read`, `file.write`, `app.open`, `web.search`, dst. Setiap eksekusi wajib melewati `PolicyEngine` lalu dicatat `AuditLog`.
- `AgentController.swift` — loop tool-use max 12 step per user request; stream teks ke bubble; hasil tiap step muncul di UI; berhenti saat `end_turn`/limit/error. `ChatStore` menyimpan ringkasan tiap step (text-only).
- Tests: PolicyEngine (floor vs mode), AuditLog format, AgentController loop dengan mock provider (fake tool_use).

Baru/berubah:

- `Sources/App/PolicyEngine.swift` — `ActionCategory` (shell/fileWrite/fileRead/email/network/appControl), mode `autopilot`/`askOnce`/`manual`, `evaluate()` murni (read selalu allow; floor di atas mode), `floorReason()` (settings.json write, sudo, destructive rm, `diskutil erase*`, pipe-to-shell), `confirm(_:)` per kategori per sesi.
- `Sources/App/AuditLog.swift` — JSONL append-only (`<Application Support>/NotchBuddy/audit.jsonl`), `record(...)`, `entries()` (lempis baris korup), injectable `url` untuk test.
- `Sources/App/ToolExecutor.swift` — 4 tool (`shell_run`, `file_read`, `file_write`, `app_open`) dengan schema valid `^[a-zA-Z0-9_-]{1,64}$`; setiap eksekusi wajib `PolicyEngine` → opsi `confirmHandler` (approval UI) → `AuditLog`. `summary(of:)` untuk transcript.
- `Sources/App/AgentController.swift` — loop max 12 step: `complete()` → kalau `toolUse` → `execute()` → append `tool_result` → lanjut; event `stepStarted`/`textDelta`/`toolStarted`/`toolFinished`/`stepLimitReached`; hasil `AgentOutcome(transcript:steps:hitStepLimit:)`.
- `Sources/App/ClaudeService.swift` — system prompt versi agent (instruksi tool, "Never ask for permission in prose", jawab dengan bahasa user), `toolExecutor` + `askToolApproval` (@MainActor, approval.wav, auto-deny 120s), `chat()` rewrite → `AgentBubbleComposer` + `AgentController`; `AgentBubbleComposer` mem-mapping 5 `AgentEvent` ke bubble + commit final.
- `Sources/App/IslandTypes.swift` — `ApprovalSource.hook/agent`. `Sources/App/AppState.swift` — `agentApproval` + `answerAgentApproval` idempoten. `IslandViewContent.swift` — path ApprovalView untuk agent.
- `tests/AgentLoopTests.swift` + `scripts/test-agent-loop.sh` — PolicyEngine matrix, AuditLog round-trip, ToolExecutor (9 kasus: echo, exit code, approval askOnce, floor sudo, deny, unknown/missing/not-found, audit), AgentController A–D (no-tool, tool round-trip, floor deny, step limit), SSE parser `tool_use`.

**Verifikasi:** `test-agent-loop.sh` ✅, `test-multi-provider.sh` ✅, `test-llm-provider.sh` ✅, `test-safe-links.sh` (15) ✅, `test-screen-geometry.sh` (13) ✅, `xcodebuild` **BUILD SUCCEEDED** (0 warning) ✅.

## Phase 3 — Voice ✅

- `VoiceManager.swift`:
  - **TTS**: `AVSpeechSynthesizer`, voice rate/pitch mengikuti persona Mochi; speak saat jawaban selesai (bisa dimatikan).
  - **STT (PTT)**: tombol tekan-tahan → `SFSpeechRecognizer` → teks masuk ke prompt field. Mic permission lewat alur biasa (Info.plist usage description).
  - **Wake word opsional** (default OFF): deteksi "Mochi" via audio ringan; hanya aktif ketika user menyalakan; tidak boleh makan CPU saat island hidden.
- Info.plist: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.
- Tests: teks normalisasi VAD sederhana (bisa diuji tanpa mic), wiring state PTT.

Baru/berubah:

- `Sources/App/VoiceCore.swift` — Foundation-only: `VoiceText.speechText(from:)` (hapus fence/link/gambar/heading/bullet/markdown, collapse whitespace, cap 700 + "…"), `containsWakeWord(_:word:)` (case + diacritic insensitive, default "mochi"), `finalizeTranscript` (whitespace-only → nil); `PTTStatus` (idle/requesting/listening/denied/failed), `PTTEvent`, reducer murni (press berulang no-op, release saat dialog permission → idle, event async telat diabaikan).
- `Sources/App/VoiceManager.swift` — `@MainActor ObservableObject` singleton: **TTS** (`speak`/`stopSpeaking`, deteksi bahasa `NLLanguageRecognizer`, rate ×0.92 pitch 1.08, voice match); **PTT** (permission via continuation → `AVAudioEngine` tap → `SFSpeechAudioBufferRecognitionRequest`, timeout 30 s, final-fallback 1.5 s bila Apple tidak kirim `isFinal`, SFX blip/tick/error dari `SoundEngine`); **wake word** (default OFF, recognizer khusus, cooldown 4 s, restart otomatis 0.4–1.5 s, matikan diri saat permission denied, resume setelah PTT); persist `speakAnswers`/`wakeWordEnabled` di UserDefaults; callback `onPartial/onFinal/onError/onWakeWord`.
- `Sources/App/ClaudeService.swift` — `stopSpeaking()` di awal `chat()`, `speak(text)` setelah jawaban final (signature tidak berubah).
- `Sources/App/IslandViewContent.swift` — `MicButton` (tekan-tahan `DragGesture` di bar prompt, merah saat listening, 28×28) + wiring callback → field / view `.note` saat error + `stopPTT()` saat view hilang.
- `Sources/App/SettingsView.swift` — GroupBox "Voice" setelah Sound: Toggle "Speak answers", Toggle "Wake word «Mochi»" (`.onChange` → `setWakeWord(enabled:)`, footnote CPU saat ON).
- `Sources/App/IslandWindowController.swift` — `Notification.Name.voiceWake` → expand island ke `.prompt` (mode hidden/compact) atau ganti view; observer pakai `Task { @MainActor in }`.
- `NotchBuddy/project.yml` — `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription` di kedua target.
- `tests/VoiceTests.swift` + `scripts/test-voice.sh` — 37 kasus: speechText (fence/link/heading/bullet/markdown/cap/empty), wake word (case/diacritic/no false positive/custom word), finalize, reducer PTT matrix.

**Verifikasi:** `test-voice.sh` (37) ✅, `test-agent-loop.sh` ✅, `test-multi-provider.sh` ✅, `test-llm-provider.sh` ✅, `test-safe-links.sh` (15) ✅, `test-screen-geometry.sh` (13) ✅, `xcodebuild` **BUILD SUCCEEDED** ✅ (0 error, kode Phase 3 0 warning).

Catatan: clean build menampilkan 17 warning lama di file yang tidak disentuh Phase 3 (deprecati `activateIgnoringOtherApps` ×4, observer MainActor nonisolated ×9, `var hb` ×1, dsb.) — muncul karena file-file itu baru di-recompile; bersihkan terpisah bila perlu. Uji manual tetap diperlukan untuk hal yang tak bisa diverifikasi dari terminal: permission mic/speech saat PTT pertama, TTS terdengar, wake word membuka island, CPU saat island hidden + wake OFF.

## Phase 4 — Internet + kontrol aplikasi ✅

- `InternetService.swift` — pencarian web (DuckDuckGo HTML, tanpa API key), fetch & ekstrak halaman (baca teks), hasil dikirim ke LLM sebagai konteks; web search server-tool Anthropic tetap dipakai kalau provider aktif mendukungnya.
- `AppController.swift` — buka/tutup/fokus aplikasi (`NSWorkspace`), list app terbuka, screenshot app target via ScreenCaptureKit (izin `NSScreenCaptureUsageDescription`).
- Tool `shell.run` sudah dari Phase 2 → bisa jalankan skrip, brew, dll.
- Tests: parser hasil search, normalisasi URL, mapping tool → NSWorkspace (dipisah di belakang protocol supaya testable tanpa GUI).

Baru/berubah:

- `Sources/App/InternetService.swift` — Foundation-only: `search(_:limit:)` (DDG HTML endpoint, 8 s timeout), `searchResults(from:limit:)` (parser anchor `result__a`/`result__snippet` order-agnostic), `fetchPage(_:)` (15 s, 1,5 MB / 12 k char cap), `resolveRedirect` (decode entities → `//`→https → guard http(s) → `uddg` via `URLComponents` → `safeWebURL`), `decodeEntities` (named + `&#NN;`/`&#xNN;`), `readableText` (buang comment/script/style/nav/header/footer, block→newline, cap + "…"), `formatForContext` (numbered, title 160 / snippet 240), `InternetError` (Equatable).
- `Sources/App/AppController.swift` — `WorkspaceControlling` protocol + `SystemWorkspace` (NSWorkspace `.regular`, sorted) supaya testable tanpa GUI; `AppController(workspace:)`: `list(filter:)`, `close(_:)` (terminate), `screenshot(_:)` (ScreenCaptureKit → PNG ke `Application Support/NotchBuddy/Screenshots/`, pesan izin Screen Recording bila gagal); `match` (bundleID → nama exact → prefix prefer aktif → contains; strip **suffix** `.app` saja — strip semua occurrence merusak `com.apple.*`), `formatList` (limit 30, "and N more").
- `Sources/App/ToolExecutor.swift` — 4 → **9 tool** (`+ web_search, web_fetch, app_list, app_close, app_screenshot`); guard missing-argument pakai `resolvedTarget` (nama tool untuk `app_list` tanpa query), audit memakai target yang sudah di-resolve; 5 runner baru (network async, app sync).
- `Sources/App/AnthropicProvider.swift` — saat `enableWebSearch`: buang tool `web_search` daftar sebelum append server tool (hindari duplikat). `Sources/App/OpenAIProvider.swift` — `wireTools` filter `web_search` sebelum encode.
- `Sources/App/ClaudeService.swift` — system prompt sebut 9 tool; `search()` suntik hasil DDG (`limit: 6`) sebagai blok teks konteks setelah jawaban provider.
- `NotchBuddy/project.yml` — `NSScreenCaptureUsageDescription` di kedua target.
- `tests/InternetAppTests.swift` + `scripts/test-internet.sh` — ~35 kasus: parser DDG (2 hasil, entity, tag, uddg resolve, limit, bare title, href-sebelum-class, empty), `resolveRedirect`/`decodeEntities`/`readableText`/`formatForContext`, `match` (8 kasus), `formatList`, MockWorkspace (close ok/noMatch, list filter), surface 9 tool + schema + missing-arg. `tests/AgentLoopTests.swift` — 3 hardcode 4-tool → 9-tool. `scripts/test-agent-loop.sh` — tambah SafeWebURL/InternetService/AppController ke chain compile.

**Verifikasi:** `test-internet.sh` ✅, `test-agent-loop.sh` ✅, `test-multi-provider.sh` ✅, `test-llm-provider.sh` ✅, `test-safe-links.sh` (15) ✅, `test-screen-geometry.sh` (13) ✅, `test-voice.sh` (37) ✅, `xcodebuild` **BUILD SUCCEEDED** ✅ (0 error, kode Phase 4 0 warning).

Catatan: bug nyata ditemukan & diperbaiki saat test — strip `.app` global memecah pencocokan bundle ID (`com.apple.Safari` → `comle.Safari`), kini hanya strip suffix `.app`. `SCScreenshotManager.captureImage` butuh label `contentFilter:configuration:` (bukan `with:`) + `SCStreamConfiguration` di-scale via `pointPixelScale`. Screenshot & kontrol app butuh uji manual (izin Screen Recording, terminate app sungguhan).

## Phase 5 — Perception + memory ✅

- `AccessibilityService.swift` — baca struktur UI aktif (AX API): fokus, teks, tombol terdekat → context untuk "apa yang sedang saya lihat"; bisa klik/ketik via AX kalau diminta.
- Screenshot → konteks visual (sudah lewat consent `.appControl` per aksi; gambar dikirim ke LLM sebagai follow-up message).
- `MemoryService.swift` — preferensi & fakta jangka panjang (JSON di Application Support; secret tetap Keychain), disuntik ke system prompt secara ringkas.
- Tests: parsing struktur AX (mock), format memori.

Baru/berubah:

- `Sources/App/AccessibilityService.swift` — `AXElementInfo` + `AXSnapshot` (app, focused, elements) + `summary(maxElements: 40)` (`"App: X"`, `"Focused: …"` hilang bila nil, `"Elements (n):"`, `"[i] label"`; label = `Role "text"` teks di-truncate 60 char, atau role saja bila tanpa teks). `AXAction` (`.press(index:)` / `.typeText` / `.key`) di-parse sekali dari input tool dengan `init(input:) throws` — action hilang/tak dikenal, index string/negatif/pecah/tanpa index, teks kosong, key tak dikenal → error. `keyCodes`: return 36, tab 48, space 49, delete 51, escape 53, forwarddelete 117, home 115, end 119, pageup 116, pagedown 121, left 123, right 124, down 125, up 126. `AXClientProtocol` + `SystemAXClient` (AXUIElement) supaya testable tanpa GUI; `AccessibilityError.permissionDenied` (pesan menyebut "Accessibility permission").
- `Sources/App/MemoryService.swift` — fakta jangka panjang di `Application Support/NotchBuddy/memory.json` (JSON atomik; secret tetap Keychain); `remember()` sanitasi whitespace + dedup case-insensitive (fakta sama → bump ke terbaru, return `false`), `all()`, `forget(id:)`, `formatForSystemPrompt(maxChars:limit:)` (header `"Facts you remember about the user:"`, kosong bila melebihi `maxChars`); file korup/hilang → daftar kosong tanpa crash. `MemoryService.shared` dipakai ClaudeService.
- `Sources/App/ToolExecutor.swift` — 9 → **12 tool**, urutan final: `shell_run, file_read, file_write, app_open, web_search, web_fetch, app_list, app_close, app_screenshot, ax_read, ax_act, memory_save`. `ToolResult.image: ToolImage?` untuk screenshot visual. `targetDescription` spesial: `ax_read` → fallback nama tool, `ax_act` → `AXAction.target` (mis. `"press [1]"`, `"type hi"`, `"key tab"`), `memory_save` → teks fakta. Kategori: `ax_read` → `.read` (bypass semua mode/floor), `ax_act` → `.appControl` (parse sekali — `action` hilang → audit deny `"missing argument"`; parse gagal → audit deny `"invalid action"` + output error **sebelum** policy), `memory_save` → `.fileWrite` dengan `policyCommand` literal `"memory_save"` (fakta ber-"sudo" tak salah-deny floor `\bsudo\b`), audit target = teks fakta. Output: `ax_read` → `snapshot.summary()`, `ax_act` gagal → `Missing required argument for ax_act.` / `error.localizedDescription`, `memory_save` → `Remembered.` / `Already remembered — refreshed.`; `maxOutputChars` 8.000. `ToolExecutor.init(policy:audit:confirmHandler:ax:memory:)`.
- `Sources/App/AgentController.swift` — screenshot visual: setelah pesan berisi `[toolResult…]`, bila ada `ToolResult.image` → `turn.append(contentsOf: Self.followUpMessages(images:))`: **satu pesan user per gambar** (`.text("Screenshot from app_screenshot:")` + `.image(...)`), image TIDAK di dalam `tool_result` (konten tool OpenAI string-only); embed bila data ≤ 1.500.000 byte.
- `Sources/App/ClaudeService.swift` — system prompt 9 → 12 tool + aturan "panggil ax_read dulu sebelum ax_act"; `systemWithMemory` = systemPrompt + `MemoryService.shared.formatForSystemPrompt()` (disisipkan hanya bila tidak kosong).
- `Sources/App/AppController.swift` — `ScreenshotCapture`/`capture` → hasil PNG menjadi `ToolImage` untuk executor.
- Tests: `tests/PerceptionMemoryTests.swift` + `scripts/test-perception.sh` — summary AX (judul/truncate 60/fallback label/maxElements/unfocused), parsing `AXAction` (3 valid + 11 rejected), `MemoryService` (sanitasi, dedup bump, format header, round-trip, JSON korup, forget, `maxChars`), floor policy (sudo shell deny, `memory_save` allow setelah confirm), executor + `MockAX` (`ax_read`/`ax_act` ok & missing & invalid, `memory_save` dedup, shell sudo floor deny, 5 assertion audit, permission denied), `followUpMessages` (count 12, suffix 3 = ax tools, caption, mediaType/base64). `tests/AgentLoopTests.swift` — 3 hardcode 9 → 12; `tests/InternetAppTests.swift` — 1 hardcode 9 → 12. `scripts/test-agent-loop.sh` + `scripts/test-internet.sh` — sisip `AccessibilityService.swift` + `MemoryService.swift` ke chain compile.

**Verifikasi:** `test-perception.sh` ✅, `test-agent-loop.sh` ✅, `test-internet.sh` ✅, `test-multi-provider.sh` ✅, `test-llm-provider.sh` ✅, `test-safe-links.sh` (15) ✅, `test-screen-geometry.sh` (13) ✅, `test-voice.sh` (37) ✅, full-directory `swiftc -typecheck -strict-concurrency=complete Sources/App/*.swift` 0 error ✅, `xcodebuild` **BUILD SUCCEEDED** ✅ (0 error; semua warning hanya di file lama yang tak disentuh — GreetingCanvasView/IslandRootView/IslandViewContent/IslandWindowController/SettingsView).

Catatan: surface 12 tool sudah **final** — menambah/mengubah tool berarti update 3 hardcode di tests + system prompt ClaudeService + surface assertions. `GeminiProvider.requestBody` sengaja tak disentuh (aturan Tools XOR search tetap berlaku). Screenshot AX butuh uji manual (izin Accessibility: ax_read/ax_act, izin Screen Recording: app_screenshot).

## Phase 6 — Proactive + self-repair + bahasa + headless ✅

- `LanguageRouter.swift` (baru) — deteksi bahasa input via heuristik stopword (`id`, `en`, `fr`, `es`, `de`, `""`); `systemInstruction(for:)` disuntik ke system prompt per-turn di `ClaudeService.chat()` hanya jika bahasa diketahui. `search()` dibiarkan bahasa Inggris (DDG).
- `HealthService.swift` (baru) — `check()` mengecek API key, mikrofon, Accessibility, Screen Recording, ruang disk (`HealthStatus`); setiap cek dicatat ke `AuditLog` (`.read`). `selfRepair()` pindah provider aktif ke alternatif yang ber-kunci bila aktif tak terkonfigurasi (`.appControl`). Semua probe diinject via closure (testable tanpa izin sistem).
- `ProactiveEngine.swift` (baru) — fakta memori yang mengandung pola waktu (`\d{1,2}[:.]\d{2}`) atau kata kunci (besok/tomorrow/meeting/…) menjadi `ProactiveChip`; strip render di `PromptView` (bawah ContextChip), klik → prefill `promptPrefill` + buka view `.prompt`; segarkan saat launch (`AppDelegate`), setiap kali view prompt muncul, dan setelah `memory_save` (notifikasi `proactiveEngineRefresh`).
- Tool ke-13 `claude_run` (deviasi: spec menyebut `claude.runHeadless`, tapi titik dilarang regex nama tool → `claude_run`). Kategori `.shell` → hard floor berlaku atas isi prompt (`sudo` = deny). Pakai `claude -p <prompt> --output-format text`, timeout 120 s, **TANPA** `--dangerously-skip-permissions`. Binary dicari di `~/.local/bin/claude`, `~/.claude/local/claude`, `/usr/local/bin/claude`, `/opt/homebrew/bin/claude`, fallback `/usr/bin/env claude`.
- `AppState.shared.promptPrefill` + `proactiveChips`.
- **Update `CLAUDE.md`**: kebijakan consent dari "never approve tanpa klik" menjadi policy-based (autopilot + hard floor tak bisa di-override); dokumentasi `audit.jsonl` & cara meninjau/mengubah mode di Settings.
- Tests: `tests/Phase6Tests.swift` + `scripts/test-phase6.sh` (router bahasa, HealthService check/self-repair + audit, ProactiveEngine chips, claude_run count 13/def/missing-arg/floor deny).

Hardcode 12 → 13 di: `tests/AgentLoopTests.swift` (3×), `tests/InternetAppTests.swift` (1×), `tests/PerceptionMemoryTests.swift` (`suffix(3)`→`suffix(4)`, `count == 12`→`count == 13`), system prompt `ClaudeService.swift`, doc comment `ToolExecutor`.

**Verifikasi:** semua `scripts/test-*.sh` ✅, `test-phase6.sh` ✅, `swiftc -typecheck -strict-concurrency=complete Sources/App/*.swift` 0 error + 0 warning baru ✅, `xcodebuild` **BUILD SUCCEEDED** ✅.

## Phase 7 — Performans, onboarding, polish ✅

- Audit CPU: 0 % saat island hidden.
  - `IslandWindowController.pollFrame()` → early-return saat `mode == .hidden`; `frameTimer` di-invalidate saat hidden, di-restart saat compact/expanded (`modeSubscription`).
  - `CountdownBar` → timer di-invalidate saat hidden, `updateBar()` guard `mode != .hidden`.
  - `BotCanvasView` sudah `TimelineView(.animation(paused: state.mode == .hidden))` (belum diubah).
  - Wake word OFF → `stopWakeWord()` melepas audio engine tap + recognition task; default OFF (`wakeWordEnabled ?? false`), 0 % CPU. ✅
- Onboarding singkat (`OnboardingView.swift`, baru): 3 langkah — (1) pilih provider + masukkan API key (Keychain), (2) izin mikrofon/Accessibility/tangkap layar dengan penjelasan, (3) mode autopilot + hard floor. Tampil di window terpisah saat pertama kali peluncuran (`AppState.hasOnboarded`, `AppDelegate.openOnboarding()`), selesai → `hasOnboarded = true` + buka island `.prompt`.
- Visual: tidak ada regresi layout (hanya gating timer + window onboarding baru yang pakai design token prototype: `#2F6BFF` focus, `#9398A1` muted, `#F5F6F8` chip). Visual tetap match `design/prototype/notch-buddy.html` & `design/captures/`.
- Verifikasi: 9/9 `scripts/test-*.sh` ✅ (termasuk `test-phase6.sh`), `swiftc -typecheck -strict-concurrency=complete` 0 error ✅, `xcodebuild` Debug **BUILD SUCCEEDED** ✅. Release build gagal hanya karena code-signing certificate `Developer ID Application` tidak tersedia di environment ini (bukan kesalahan kode).

## Milestone minima yang berguna

1. **Setelah Phase 1**: user bisa pilih OpenAI/Gemini dari Settings, streaming tetap jalan. ✅
2. **Setelah Phase 2**: "jalankan X di proyek Y" benar-benar dieksekusi + tercatat di audit. ✅
3. **Setelah Phase 4**: "cari cara … lalu buka …" jalan penuh dari teks. ✅
4. **Setelah Phase 6**: bicara → semua; JARVIS-style. ✅
5. **Setelah Phase 7**: 0 % CPU hidden, onboarding pertama kali, build lolos. ✅
6. **Setelah Phase 8**: MCP client + server + bridge terintegrasi; Coucou bisa dipanggil sebagai MCP server oleh agen eksternal (Claude Code, Cursor, IDE) via stdio, dan memanggil alat server MCP lain. ✅

## Phase 8 — MCP Integrasi (Client + Server) ✅

- `MCPClient.swift` (baru) — klien MCP Foundation-only: JSON-RPC 2.0 over stdio (server lokal) atau HTTP (server remote). `initialize`, `listTools`, `callTool`, timeout 30 s per permintaan. Tidak ada dependensi pihak ketiga.
- `MCPServer.swift` (baru) — server MCP generik over stdio: `register(name:handler:)`, `handle(method:params:)`, `serveStdio()`. Expose alat Coucou kepada agen eksternal.
- `MCPBridge.swift` (baru) — jembatan MCP server eksternal → `ToolExecutor` (policy + audit tetap berlaku). Mengekspos `tool.run`, `memory.save/all/forget`, `system.health`. Handler `notch.*`/`chat.*` (butuh `AppState`) didaftarkan di `AppDelegate`, bukan di bridge, agar bridge tetap terisolasi dan dapat diuji.
- `AppState` — `mcpServers: [MCPServerConfig]`, `mcpServerEnabled`, `mcpServerPort` (disimpan UserDefaults). `MCPServerConfig` + `MCPTransport` (stdio/http) didefinisikan di `MCPClient.swift`.
- `SettingsView` — GroupBox "MCP": toggle expose server + port, daftar server klien dengan toggle enabled, tombol tambah server (stdio command).
- `AppDelegate` — buat `MCPBridge`, daftarkan handler `notch.expand/collapse/setView` + `chat.send/history` (via `Task { @MainActor }` untuk akses `AppState`/`ClaudeService`).
- **Verifikasi:** `scripts/test-mcp.sh` ✅, semua `scripts/test-*.sh` (10/10) ✅, `swiftc -typecheck -strict-concurrency=complete` 0 error ✅, `xcodebuild` Debug **BUILD SUCCEEDED** ✅.

## Phase 9 — Run & Akses Aplikasi Lanjutan ✅

- `AppAutomation.swift` (baru) — jalankan AppleScript / JavaScript for Automation via `osascript`. Skrip ditulis ke file temp lalu dieksekusi (input pengguna **tidak** sentuh shell → tidak ada injeksi shell). Dukungan `applescript` dan `javascript`.
- `WindowController.swift` (baru) — daftar jendela terlihat (`CGWindowListCopyWindowInfo`), fokus, geser, ubah ukuran jendela (`NSWindow`). Semua akses `NSWindow`/`NSApplication` dibungkus `MainActor.assumeIsolated` agar aman dipanggil dari konteks non-isolasi.
- `AppController.swift` — `mediaControl(_:)` (play/pause/next/previous via `MPRemoteCommandCenter`, Now Playing Center).
- `ToolExecutor.swift` — 3 alat baru (total **16**): `automation_run` (kategori `.appControl`), `window_list` (`.read`), `window_act` (`.appControl`). Hardcode 13 → 16 di 3 file tes + system prompt `ClaudeService.swift` + doc komentar.
- `ClaudeService.swift` — system prompt sebut `automation_run`, `window_list`, `window_act`.
- `tests/Phase9Tests.swift` + `scripts/test-phase9.sh` — AppAutomation (applescript/javascript/error), WindowController (list/focus/move/resize non-existent → false, tidak crash), ToolExecutor (automation_run output, window_list, window_act focus/move/resize invalid-arg).
- **Verifikasi:** `scripts/test-phase9.sh` ✅, semua `scripts/test-*.sh` (10/10) ✅, `swiftc -typecheck -strict-concurrency=complete` 0 error + 0 warning baru ✅, `xcodebuild` Debug **BUILD SUCCEEDED** ✅.

## Phase 10 — Agen Otonom + Workflow Engine + Scheduler ✅

- `AutonomousTask.swift` (baru) — model tugas otonom: `goal`, `status` (pending/running/completed/failed/cancelled), `steps` (daftar `AutonomousStep` dengan tool + input), `source` (user/scheduler/proactive).
- `TaskScheduler.swift` (baru) — jadwal cron-like (daily/weekly, jam + menit, hari dalam minggu) via `DispatchSourceTimer` + `Calendar`. **Tidak berjalan saat island hidden (0 % CPU)** — `isHidden` diinject, default false, AppDelegate menyetel ke `AppState.shared.mode == .hidden`. `onTaskAdded` closure dipakai AppDelegate untuk memicu `AutonomousAgent`.
- `WorkflowEngine.swift` (baru) — perencanaan multi-langkah dari tujuan (heuristik berbasis kata kunci: cari→web_search, buka→app_open, tulis→file_write, jalankan→shell_run, default→shell_run), eksekusi via `ToolExecutor` (PolicyEngine + AuditLog tetap berlaku), verifikasi output tidak kosong, **retry otomatis hingga 3× dengan backoff 500 ms**, hentikan pada langkah pertama yang gagal.
- `AutonomousAgent.swift` (baru) — loop otonom: terima tujuan, buat `AutonomousTask`, jalankan `WorkflowEngine`, laporkan hasil ke chat island (`chatHistory` asisten) + update status tugas. Satu tugas sekiranya (mencegah lari-larian). `enabled` mengikuti `AppState.shared.autonomousEnabled`.
- `SelfRepair.swift` (baru) — memperluas `HealthService`: jika provider aktif invalid → pindah ke alternatif ber-kunci; jika izin mikrofon/Accessibility/screen hilang → catat ke AuditLog + arahkan ke System Settings; jika disk penuh → peringatan. `repairAndReport()` menampilkan hasil di island note.
- `AppState` — `autonomousTasks: [AutonomousTask]`, `autonomousEnabled: Bool` (default false; nyala setelah onboarding konfirmasi).
- `AppDelegate` — men-set `TaskScheduler.shared.isHidden` + `onTaskAdded`, memulai scheduler saat launch.
- **Verifikasi:** `scripts/test-phase10.sh` ✅, semua `scripts/test-*.sh` (11/11) ✅, `swiftc -typecheck -strict-concurrency=complete` 0 error + 0 warning baru ✅, `xcodebuild` Debug **BUILD SUCCEEDED** ✅.

## Phase 11 — Profesional & Rilis ✅

- `AutoUpdate.swift` (baru) — klien auto-update Foundation-only: cek GitHub releases latest, unduh `.dmg`, verifikasi **SHA-256**, instal ke `/Applications`, restart Coucou. Dipanggil dari Settings → Enterprise → "Cek pembaruan".
- `CrashReporter.swift` (baru) — tangkap exception tak tertangani via `NSSetUncaughtExceptionHandler`, tulis laporan ke `<Application Support>/NotchBuddy/crashes/reports.json`, tampilkan di Settings → Enterprise. Tidak ada telemetry (laporan tidak dikirim ke mana pun).
- `SettingsView` — GroupBox "Enterprise / Produksi": toggle mode otopilot (JARVIS) yang mengubah `PolicyEngine.defaultModes`, batas langkah agent (`agentStepLimit`), path audit log (tombol buka folder), tombol "Cek pembaruan".
- `scripts/release.sh` — diperpanjang: archive, export, code signing (Developer ID Application), notarisasi (`notarytool`), stapel (`stapler`), buat DMG, generate SHA-256, tag git + GitHub Release.
- `docs/DEPLOY.md` (baru) — panduan build, code signing, notarization, auto-update, crash reporter, konsent & Kebijakan, struktur direktori rilis, build dari sumber.
- `AppState` — `autopilotEnabled: Bool`, `agentStepLimit: Int` (disimpan UserDefaults); `applyAutopilotMode()` mengubah `PolicyEngine.defaultModes`.
- `AppDelegate` — memasang `CrashReporter.shared.install()` saat launch.
- `PolicyEngine` — `defaultModes` berubah menjadi `static nonisolated(unsafe) var` (mutable global state untuk konsent runtime).
- **Verifikasi:** `scripts/test-phase11.sh` ✅, semua `scripts/test-*.sh` (12/12) ✅, `swiftc -typecheck -strict-concurrency=complete` 0 error + 0 warning baru ✅, `xcodebuild` Debug **BUILD SUCCEEDED** ✅.

## Milestone minima yang berguna

1. **Setelah Phase 1**: user bisa pilih OpenAI/Gemini dari Settings, streaming tetap jalan. ✅
2. **Setelah Phase 2**: "jalankan X di proyek Y" benar-benar dieksekusi + tercatat di audit. ✅
3. **Setelah Phase 4**: "cari cara … lalu buka …" jalan penuh dari teks. ✅
4. **Setelah Phase 6**: bicara → semua; JARVIS-style. ✅
5. **Setelah Phase 7**: 0 % CPU hidden, onboarding pertama kali, build lolos. ✅
6. **Setelah Phase 8**: MCP client + server + bridge; Coucou dipanggil sebagai MCP server oleh agen eksternal. ✅
7. **Setelah Phase 9**: otomatisasi aplikasi via AppleScript/JS, kontrol jendela + media dari teks. ✅
8. **Setelah Phase 10**: tugas otonom berjalan berjadwal tanpa klik; self-repair provider & izin. ✅
9. **Setelah Phase 11**: build rilis (code signing, notarization, DMG), auto-update, crash reporter, settings enterprise. ✅

10. **Setelah Phase 12**: engine node otomatisasi (8 tipe) + JavaScriptCore; Coucou bisa menjalankan alur kerja multi-langkah (file, shell, HTTP, if/else, transform JSON, clipboard, notifikasi) melalui ToolExecutor dengan PolicyEngine + AuditLog. ✅

11. **Setelah Phase 13**: bus pesan antar agen, orkestratur multi-agen (dekomposisi goal → agen spesialis → sintesis), checkpoin untuk pulihkan tugas setelah crash, dan self-correction (perbaiki input + coba ulang sekali), dan HabitLearner / chip kebiasaan untuk proaktif prediktif. ✅
12. **Setelah Phase 13.5**: self-improving (FeedbackLoop mencatat pelajaran ke AuditLog + MemoryService; PromptEvolver memilih & mempromosi sistem prompt terbaik). ✅
13. **Setelah Phase 13.7**: agen terdistribusi / remote worker (RemoteAgentBridge melalui stdio JSON-RPC + HTTP report) agar agen pusat bisa menjalankan tugas otonom di Mac tempat Coucou berjalan. ✅
14. **Setelah Phase 13.6**: human-in-the-loop gate (HumanInTheLoop: konfirmasi manusia untuk aksi beresiko tinggi meski autopilot ON) dan multimodal layar (ScreenAgent: baca konteks UI aktif via Accessibility + tangkapan layar untuk LLM). ✅

---

## Phase 12 — Node Engine + JavaScriptCore (8 node otomatisasi) ✅

- `NodeDefinitions.swift` — 8 tipe node: `http_request`, `file_system`, `cron_schedule`, `if_else`, `json_transform`, `desktop_notification`, `clipboard`, `run_sleep`. Setiap punya `displayName`, `description`, `inputSchema` (requiredKeys/outputKeys).
- `NodeInput` / `NodeOutput` / `NodeDefinition` / `AutomationNode` / `AutomationWorkflow` / `WorkflowEdge` — model alur kerja otomatisasi.
- `NodeEngine.swift` — JavaScriptCore sandbox: `evaluate`/`callFunction`, konversi JSValue ↔ JSONValue, JS tidak punya akses filesystem/jaringan langsung.
- `NodeRunner.swift` — eksekusi 8 tipe node (I/O lewat Swift; JS hanya kondisi/transformasi), timeout 30 s shell, output dibatasi 8 KB.
- `ToolExecutor.swift` — 8 alat `node_*` (total naik 16 → 24): setiap alat melalui `PolicyEngine` + `AuditLog`, kategori per tipe (network/fileWrite/shell/appControl).
- Tests: `tests/Phase12Tests.swift` + `scripts/test-phase12.sh` — 8 node type defs + 8 executor kasus.
- Verifikasi: `test-phase12.sh` ✅, semua `scripts/test-*.sh` (13/13) ✅, `swiftc -typecheck -strict-concurrency=complete` 0 error ✅, `xcodebuild` Debug **BUILD SUCCEEDED** ✅.

---

## Phase 13 — Super Autonomous AI Assistant (diterapkan sebagian) ✅

Tujuan: Coucou bukan lagi hanya "remote control" Claude Code, melainkan **asisten AI otonom penuh ala JARVIS** yang bisa merencanakan, mengeksekusi, dan memperbaiki diri tanpa sentuhan user.

### 13.1 Multi-Agent Orchestration (Swarm) ✅
- `MessageBus.swift` — bus pesan async berbasis actor: `subscribe(topic:handler:)`, `publish(topic:payload:)`, `unsubscribe(token:topic:)`, `subscriberCount(topic:)`. Topik: task.decomposed, task.assigned, task.completed, task.failed, correction.needed, synthesis.ready, user.input.
- `AgentOrchestrator.swift` — koordinasi sekelompok agen spesialis pada satu goal:
  - `AgentRole` (coder, researcher, operator, writer, analyst) dengan `systemPrompt` + `allowedTools` per peran.
  - `SubTask` / `SubTaskStatus` / `SpecialistResult` / `OrchestrationResult` / `OrchestratorEvent`.
  - `defaultDecompose(_:)` — pecah goal menjadi sub-tugas (heuristik kata kunci, deterministic, tanpa LLM).
  - `run(goal:model:onEvent:)` — dekomposi → jalankan setiap spesialis via `AgentController` + LLMProvider yang di-inject → sintesis hasil. Menerbitkan event ke `MessageBus` dan mencatat status ke `AppState.shared.autonomousTasks`.
- Tests: `tests/Phase13Tests.swift` + `scripts/test-phase13.sh` — MessageBus publish/subscribe/unsubscribe, dekomposisi deterministik, orchestrasi dengan provider palsu.

### 13.2 Long-Running Autonomous Projects ✅
- `CheckpointManager.swift` — simpan & muat `AutonomousTask` + `[AutonomousStep]` ke file JSON di `Application Support/NotchBuddy/checkpoints/` (via JSONSerialization, kompatibel dengan `JSONValue` yang bukan `Codable`). Operasi: `save(taskId:task:steps:)`, `load(taskId:)`, `delete(taskId:)`, `list()`, `has(taskId:)`, `clearAll()`. Directory bisa di-inject untuk tes.

### 13.3 Self-Correction ✅
- `SelfCorrection.swift` — `correct(step:error:provider:model:executor:)` — saat pemanggilan alat gagal, susun prompt perbaikan ke LLM yang menulis ulang input sebagai JSON, lalu coba eksekusi sekali lagi via `ToolExecutor`. Mengembalikan hasil retry, atau hasil asli jika perbaikan tidak valid.
- Polisi `shell` di `ToolExecutor` tetap diterapkan (hard floor + PolicyEngine) pada setiap percobaan.

### 13.4 Proaktif Prediktif (HabitLearner) ✅
- `HabitLearner.swift` — belajar dari tindakan berulang pengguna (waktu + hari + kategori) dan menghasilkan saran otomatisasi:
  - `record(action:category:)` — catat tindakan (dipanggil dari `AutonomousAgent.submit`).
  - `suggestions(minConfidence:)` — deteksi pola ≥3 kali pada hari + jam yang sama → `HabitSuggestion` (title, action, confidence).
  - `now` injectable untuk tes deterministik.
- `ProactiveEngine.swift` diperluas:
  - `learner = HabitLearner.shared`; `refresh()` menggabungkan chip memori + chip kebiasaan.
  - `habitChips(from:)` — konversi `HabitSuggestion` → `ProactiveChip`.
  - `recordHabit(action:category:)` — delegasi ke learner.
- `AutonomousAgent.submit` — mencatat `recordHabit(action:goal, category:source)` setiap tujuan baru.
- Tests: `tests/Phase14Tests.swift` + `scripts/test-phase14.sh` — HabitLearner record/count, ambang 3 kemunculan, pengurutan confidence, filter minConfidence, injeksi `now`, ProactiveEngine mencakup chip kebiasaan, recordHabit delegasi.

### 13.5 Self-Improving (Feedback Loop + Prompt Evolver) ✅
- `FeedbackLoop.swift` — mengumpulkan koreksi & penolakan pengguna sebagai pelajaran:
  - `record(kind:target:original:corrected:lesson:)` — mencatat ke `AuditLog` + `MemoryService` (sebagai fakta pelajaran) dan berkas terstruktur `feedback.json`.
  - `all()` / `lessons(limit:)` — daftar entri terbaru, diformat untuk disuntik ke sistem prompt.
- `PromptEvolver.swift` — memelihara versi sistem prompt dan memilih yang terbaik:
  - `register(prompt:)` — daftar versi prompt baru.
  - `recordOutcome(versionId:success:)` — catat hasil eksekusi per versi.
  - `currentBest()` — versi dengan tingkat sukses tertinggi.
  - `evolve(basePrompt:)` — jika tingkat kegagalan tinggi (≥50%, ≥3 uji coba), tambahkan instruksi perbaikan dan daftarkan versi baru. Tidak ada deadlock (kunci tidak re-entran).
- Tests: `tests/Phase15Tests.swift` + `scripts/test-phase15.sh` — FeedbackLoop record/lessons/clear, PromptEvolver register/best/evolve/no-evolve, RemoteAgentBridge run-task/report.

### 13.6 Human-in-the-loop Gate + Multimodal Screen Context ✅
- `HumanInTheLoop.swift` — gate konfirmasi manusia untuk aksi beresiko tinggi meski autopilot ON:
  - `evaluate(_:policy:)` — menurunkan verdict PolicyEngine `.allow` menjadi `.confirm` bila risiko high/critical; hard floor (sudo, rm -rf, pipe-to-shell, dst.) tetap deny absolut (tidak bisa di-override manusia).
  - `HumanRiskLevel` (low/medium/high/critical) berdasarkan kategori + perintah (rm -rf, sudo, chmod, /etc/, ~/.ssh/, kill, dll.).
  - `requestHumanConfirmation(_:riskLevel:ttl:)`, `approve(_:)`, `reject(_:)` — decision pending dengan TTL + otomatis expired.
  - `pendingDecisions()`, `pruneExpired()`, `history()` — riwayat keputusan untuk audit.
- `ScreenAgent.swift` — konteks layar aktif untuk LLM (multimodal):
  - `currentContext()` — membaca aplikasi frontmost + snapshot Accessibility (elemen teks yang difokuskan), opt-in hanya saat izin Accessibility diberikan.
  - `contextText()` — ringkasan teks siap disuntik ke sistem prompt LLM.
  - `currentScreenshot()` — tangkapan layar jendela aktif sebagai data PNG (untuk image block ke LLM), butuh izin Screen Recording.
  - AX client dan granted-status dapat di-inject untuk tes deterministik.
- Tests: `tests/Phase16Tests.swift` + `scripts/test-phase16.sh` — HumanInTheLoop risk levels, allow→confirm, deny-stays-deny, pending approve/reject/expire/prune, history; ScreenAgent mock granted/denied + contextText.

### 13.7 Agen Terdistribusi / Remote Worker ✅
- `RemoteAgentBridge.swift` — Coucou sebagai "worker" bagi agen pusat (cloud/lokal):
  - `run(goal:model:)` — menjalankan tugas otonom via `AgentOrchestrator`, mengembalikan `OrchestrationResult`.
  - `runAndReport(goal:model:to:)` — menjalankan lalu melaporkan hasil ke agen pusat via HTTP POST.
  - `report(result:to:)` — HTTP POST hasil ke URL.
  - `serveStdio()` — worker stdio (JSON-RPC per baris: `method: "runTask"`), menjawab di stdout.
  - Semua eksekusi melewati `ToolExecutor` → `PolicyEngine` → `AuditLog`; hard floor tidak bisa di-override bahkan dari agen eksternal.
- Tests: mencakup `runTask` dengan runner palsu dan `runAndReport` ke URL yang tidak tersedia.

### Kriteria Acceptance Phase 13
- User bisa memberikan satu perintah dalam bahasa alami → Coucou merencanakan, mengeksekusi beberapa alat, dan melaporkan hasil tanpa klik.
- Semua aksi melalui `PolicyEngine` + `AuditLog`; hard floor keamanan tetap tidak bisa di-override.
- 0 % CPU saat island hidden tetap terpelihara.
- Tidak ada dependensi pihak ketiga baru.
- Test: `tests/Phase13Tests.swift`, `tests/Phase14Tests.swift`, `tests/Phase15Tests.swift`, `tests/Phase16Tests.swift` + masing-masing `scripts/test-*.sh`, `swiftc -typecheck -strict-concurrency=complete` 0 error, `xcodebuild` BUILD SUCCEEDED.

### Milestone
1. Selesai Phase 12 → alur kerja node bisa dijalankan dari teks. ✅
2. Selesai Phase 13.1–13.3 → bus pesan, orkestratur multi-agen, checkpoin, self-correction. ✅
3. Selesai Phase 13.4 → proaktif prediktif (HabitLearner + chip kebiasaan). ✅
4. Selesai Phase 13.5 → self-improving (FeedbackLoop + PromptEvolver). ✅
5. Selesai Phase 13.6 → human-in-the-loop gate + multimodal screen context (HumanInTheLoop + ScreenAgent). ✅
6. Selesai Phase 13.7 → agen terdistribusi / remote worker (RemoteAgentBridge). ✅




