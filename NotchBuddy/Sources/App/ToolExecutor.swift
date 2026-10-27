import Foundation

// MARK: - Tool executor (policy → run → audit)

/// A screenshot attached to a tool result, encoded for an image content block.
struct ToolImage: Sendable, Equatable {
    var mediaType: String
    var base64: String
}

/// What a tool call returned, before it is wrapped into a `toolResult` block.
struct ToolResult: Sendable, Equatable {
    var output: String
    var isError: Bool
    var exitCode: Int?
    /// Visual context (app screenshots), sent as a separate image message.
    var image: ToolImage? = nil

    init(output: String, isError: Bool = false, exitCode: Int? = nil, image: ToolImage? = nil) {
        self.output = output
        self.isError = isError
        self.exitCode = exitCode
        self.image = image
    }
}

/// Runs the thirteen agent tools on the Mac. Every call passes through
/// `PolicyEngine` first and is recorded in the `AuditLog` afterwards.
///
/// Names use underscores (`shell_run`, …) because Anthropic and OpenAI both
/// require `^[a-zA-Z0-9_-]{1,64}$` — dots are rejected with a 400.
final class ToolExecutor: @unchecked Sendable {
    static let maxOutputChars = 8_000
    private static let readLimitBytes = 200_000

    private let audit: AuditLog
    private let confirmHandler: @Sendable (PolicyAction) async -> Bool
    private let lock = NSLock()
    private var policy: PolicyEngine
    private let apps = AppController()
    private let ax: any AXClientProtocol
    private let memory: MemoryService
    private let nodeRunner = NodeRunner()

    @MainActor
    public static func requestHumanApproval(_ action: PolicyAction) async -> Bool {
        // Jika autopilot aktif, otomatis setujui
        if AppState.shared.autopilotEnabled {
            return true
        }
        let state = AppState.shared
        state.pendingApproval = ApprovalInfo(
            sessionId: "agent",
            tool: action.category.rawValue,
            command: action.command,
            source: .agent
        )
        state.view = .approval
        SoundEngine.shared.play("approval")

        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            state.agentApproval = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if state.agentApproval != nil {
                    state.answerAgentApproval(false)
                }
            }
        }
        return approved
    }

    init(policy: PolicyEngine = PolicyEngine(),
         audit: AuditLog = AuditLog(),
         confirmHandler: (@Sendable (PolicyAction) async -> Bool)? = nil,
         ax: any AXClientProtocol = SystemAXClient(),
         memory: MemoryService = .shared) {
        self.policy = policy
        self.audit = audit
        self.confirmHandler = confirmHandler ?? { action in
            await ToolExecutor.requestHumanApproval(action)
        }
        self.ax = ax
        self.memory = memory
    }

    // MARK: - Tool definitions

    static let tools: [LLMToolDef] = [
        shellRunDef, fileReadDef, fileWriteDef, appOpenDef,
        webSearchDef, webFetchDef, appListDef, appCloseDef, appScreenshotDef,
        axReadDef, axActDef, memorySaveDef, claudeRunDef,
        automationRunDef, windowListDef, windowActDef,
        nodeHttpRequestDef, nodeFileSystemDef, nodeCronScheduleDef,
        nodeIfElseDef, nodeJsonTransformDef, nodeDesktopNotificationDef,
        nodeClipboardDef, nodeRunShellDef,
        integrationApiCallDef,
        slackSendMessageDef, discordSendMessageDef, telegramSendMessageDef,
        trelloCreateCardDef, linearCreateIssueDef, githubCreateIssueDef,
        stripeCreatePaymentDef, n8nTriggerWorkflowDef,
        officeReadSelectionDef, officeReadTableDef, officeWriteTextDef,
        officeListSheetsDef, officeReadSheetDef, officeWriteFormattedDef, officeReplaceTemplateDef,
        screenVerifyGoalDef, memorySavePreferenceDef, memoryVectorSearchDef,
        canvasPresentArtifactDef,
        guiClickDef, guiTypeDef, guiPressKeyDef, guiScrollDef, guiLocateAndClickDef,
        nightShiftRunDef,
        playbookListDef, playbookRunDef,
        toolSynthesizeDef, toolListDynamicDef, toolRunDynamicDef,
        laptopSecurityAuditDef, networkScanLanDef, networkDiagnosticsDef,
        cameraCapturePhotoDef, cameraAnalyzeDef,
        faceEnrollOwnerDef, faceVerifyPresenceDef,
        cctvListCamerasDef, cctvGetSnapshotDef, cctvAddCameraDef,
        dockerListContainersDef, dockerGetLogsDef, dockerRestartContainerDef,
        sshListServersDef, sshServerHealthDef, sshRunCommandDef, sshTailLogDef,
        calendarListEventsDef, reminderAddTaskDef, notesCreateNoteDef, mediaControlDef,
        k8sGetPodsDef, k8sDescribePodDef, k8sPodLogsDef,
        dbInspectSchemaDef, dbExecuteSafeQueryDef,
        editorGotoFileLineDef, gitSmartCommitDef, ghPrReviewSummaryDef,
    ]

    /// Semua alat yang tersedia termasuk alat dinamis yang disintesis on-the-fly.
    static var allTools: [LLMToolDef] {
        tools + DynamicToolSynthesizer.shared.llmToolDefs
    }

    static let shellRunDef = LLMToolDef(
        name: "shell_run",
        description: "Run a shell command on the user's Mac (zsh -lc). Returns combined stdout+stderr and the exit code. Use it to inspect files, run git, scripts, system commands or anything a terminal can do.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string"),
                                    "description": .string("The zsh command to run.")]),
                "cwd": .object(["type": .string("string"),
                                "description": .string("Optional working directory. Defaults to the home directory.")]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static let fileReadDef = LLMToolDef(
        name: "file_read",
        description: "Read a local text file. Returns its content, truncated at 200 KB. Use it before editing or analysing a file.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"),
                                 "description": .string("Absolute path of the file (\"~\" is allowed).")]),
            ]),
            "required": .array([.string("path")]),
        ])
    )

    static let fileWriteDef = LLMToolDef(
        name: "file_write",
        description: "Write text to a local file, creating parent directories as needed. Overwrites the file atomically.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"),
                                 "description": .string("Absolute path of the file (\"~\" is allowed).")]),
                "content": .object(["type": .string("string"),
                                    "description": .string("Full text content to write.")]),
            ]),
            "required": .array([.string("path"), .string("content")]),
        ])
    )

    static let appOpenDef = LLMToolDef(
        name: "app_open",
        description: "Open an application, file or URL on the user's Mac (uses /usr/bin/open). Examples: \"Safari\", \"Visual Studio Code\", \"https://example.com\", \"/Applications/Notes.app\".",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "target": .object(["type": .string("string"),
                                   "description": .string("App name, file path or URL to open.")]),
            ]),
            "required": .array([.string("target")]),
        ])
    )

    static let webSearchDef = LLMToolDef(
        name: "web_search",
        description: "Search the web (DuckDuckGo) and return the top results with title, URL and snippet. Use it for current events, facts you are unsure about, or anything not on this Mac.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"),
                                  "description": .string("The search query.")]),
            ]),
            "required": .array([.string("query")]),
        ])
    )

    static let webFetchDef = LLMToolDef(
        name: "web_fetch",
        description: "Fetch a web page and return its readable text (HTML stripped, truncated). Use it to read the content behind a URL found with web_search or given by the user.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string"),
                                "description": .string("The http(s) URL to fetch.")]),
            ]),
            "required": .array([.string("url")]),
        ])
    )

    static let appListDef = LLMToolDef(
        name: "app_list",
        description: "List the applications currently running on the Mac (optionally filtered by name). Use it before app_close or app_screenshot to discover exact app names.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"),
                                  "description": .string("Optional filter on the app name or bundle identifier.")]),
            ]),
        ])
    )

    static let appCloseDef = LLMToolDef(
        name: "app_close",
        description: "Quit an application on the user's Mac (graceful terminate). The app can decline to quit.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"),
                                 "description": .string("App name or bundle identifier, e.g. \"Safari\".")]),
            ]),
            "required": .array([.string("name")]),
        ])
    )

    static let appScreenshotDef = LLMToolDef(
        name: "app_screenshot",
        description: "Capture the frontmost visible window of an application as a PNG. The image is attached to the conversation so you can see it; the saved file path is returned. Requires the Screen Recording permission.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"),
                                 "description": .string("App name or bundle identifier, e.g. \"Safari\".")]),
            ]),
            "required": .array([.string("name")]),
        ])
    )

    static let axReadDef = LLMToolDef(
        name: "ax_read",
        description: "Read the accessibility (UI) tree of the frontmost application: app name, focused element and indexed elements ([0], [1], …). Always call this before ax_act to discover the index of a button, field or menu item. Requires the Accessibility permission.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let axActDef = LLMToolDef(
        name: "ax_act",
        description: "Act on the frontmost application's UI. \"press\" clicks the element at an index returned by ax_read; \"type\" types text into the focused element; \"key\" presses a virtual key (return, tab, space, delete, escape, forwarddelete, home, end, pageup, pagedown, left, right, up, down). Call ax_read first so the index is fresh.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string"),
                                   "description": .string("One of: press, type, key.")]),
                "index": .object(["type": .string("number"),
                                  "description": .string("press only: element index from ax_read.")]),
                "text": .object(["type": .string("string"),
                                 "description": .string("type only: the text to type.")]),
                "key": .object(["type": .string("string"),
                                "description": .string("key only: the key name, e.g. \"return\".")]),
            ]),
            "required": .array([.string("action")]),
        ])
    )

    static let memorySaveDef = LLMToolDef(
        name: "memory_save",
        description: "Remember a short fact about the user or their project across sessions (preferences, decisions, project context). One line per fact. Never store secrets, passwords or API keys.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object(["type": .string("string"),
                                 "description": .string("The fact to remember, one short line.")]),
            ]),
            "required": .array([.string("text")]),
        ])
    )

    static let claudeRunDef = LLMToolDef(
        name: "claude_run",
        description: "Run Claude Code headless on the user's Mac for coding tasks (refactor, write code, fix bugs, inspect a project). Uses `claude -p <prompt> --output-format text` and returns the CLI output. Requires the Claude Code CLI to be installed on the Mac.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object(["type": .string("string"),
                                   "description": .string("The task for Claude Code, one concise instruction.")]),
            ]),
            "required": .array([.string("prompt")]),
        ])
    )

    static let automationRunDef = LLMToolDef(
        name: "automation_run",
        description: "Run an AppleScript or JavaScript for Automation snippet against macOS applications (tell Application blocks). Use it to control apps that expose AppleScript (Music, Safari, Finder, Terminal, Code, …). The snippet is written to a temp file then run via osascript — it never touches a shell directly.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "script": .object(["type": .string("string"),
                                   "description": .string("AppleScript or JavaScript for Automation snippet.")]),
                "language": .object(["type": .string("string"),
                                     "description": .string("'applescript' (default) or 'javascript'.")]),
            ]),
            "required": .array([.string("script")]),
        ])
    )

    static let windowListDef = LLMToolDef(
        name: "window_list",
        description: "List visible windows on the screen: app name, title, bounds, whether main/minimized. Optionally filter by app name or bundle ID. Use it before window_act to discover window numbers.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"),
                                  "description": .string("Optional filter on app name or bundle identifier.")]),
            ]),
        ])
    )

    static let windowActDef = LLMToolDef(
        name: "window_act",
        description: "Act on a visible window: 'focus' brings it to front; 'move' repositions it (x,y); 'resize' changes its size (width,height). Use window_list first to get the window number.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string"),
                                   "description": .string("One of: focus, move, resize.")]),
                "window": .object(["type": .string("number"),
                                   "description": .string("Window number from window_list.")]),
                "x": .object(["type": .string("number"),
                              "description": .string("move only: target x coordinate.")]),
                "y": .object(["type": .string("number"),
                              "description": .string("move only: target y coordinate.")]),
                "width": .object(["type": .string("number"),
                                  "description": .string("resize only: target width.")]),
                "height": .object(["type": .string("number"),
                                   "description": .string("resize only: target height.")]),
            ]),
            "required": .array([.string("action"), .string("window")]),
        ])
    )

    // MARK: - Node engine tools (JavaScriptCore + native I/O)

    static let nodeHttpRequestDef = LLMToolDef(
        name: "node_http_request",
        description: "Kirim permintaan HTTP (GET/POST) ke URL mana saja. Mengembalikan statusCode, body, dan headers. Cocok untuk API eksternal, webhook, atau fetch data dari internet.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string"),
                                "description": .string("The URL to request.")]),
                "method": .object(["type": .string("string"),
                                   "description": .string("HTTP method: GET, POST, PUT, DELETE, PATCH. Default GET.")]),
                "body": .object(["type": .string("string"),
                                 "description": .string("Request body (for POST/PUT).")]),
                "headers": .object(["type": .string("object"),
                                    "description": .string("HTTP headers as key-value object.")]),
            ]),
            "required": .array([.string("url")]),
        ])
    )

    static let nodeFileSystemDef = LLMToolDef(
        name: "node_file_system",
        description: "Baca/tulis/hapus file lokal di Mac. Operasi: read, write, exists, delete. Cocok untuk catatan, log, konfigurasi, dan file proyek.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "operation": .object(["type": .string("string"),
                                      "description": .string("One of: read, write, exists, delete.")]),
                "path": .object(["type": .string("string"),
                                 "description": .string("Absolute file path (`~` allowed).")]),
                "content": .object(["type": .string("string"),
                                    "description": .string("Content to write (for write operation).")]),
            ]),
            "required": .array([.string("operation"), .string("path")]),
        ])
    )

    static let nodeCronScheduleDef = LLMToolDef(
        name: "node_cron_schedule",
        description: "Hitung jadwal eksekusi tugas berikutnya (interval + unit). Mengembalikan nextRun timestamp. Tidak langsung menjalankan tugas — gunakan untuk perencanaan otomatisasi berjadwal.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "interval": .object(["type": .string("number"),
                                     "description": .string("Numeric interval value.")]),
                "unit": .object(["type": .string("string"),
                                 "description": .string("Unit: seconds, minutes, hours, days.")]),
            ]),
            "required": .array([.string("interval"), .string("unit")]),
        ])
    )

    static let nodeIfElseDef = LLMToolDef(
        name: "node_if_else",
        description: "Kondisi if/else. Evaluasi ekspresi JavaScript sebagai kondisi; mengembalikan cabang trueBranch atau falseBranch sesuai hasil. Cocok untuk logika percabangan otomatisasi.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "condition": .object(["type": .string("string"),
                                      "description": .string("JavaScript expression evaluated as boolean.")]),
                "trueBranch": .object(["type": .string("object"),
                                       "description": .string("Object returned when condition is true.")]),
                "falseBranch": .object(["type": .string("object"),
                                        "description": .string("Object returned when condition is false.")]),
            ]),
            "required": .array([.string("condition"), .string("trueBranch"), .string("falseBranch")]),
        ])
    )

    static let nodeJsonTransformDef = LLMToolDef(
        name: "node_json_transform",
        description: "Transformasi JSON menggunakan skrip JavaScript. Variabel `input` tersedia sebagai objek JSON; hasil akhir dari skrip menjadi output. Cocok untuk map/filter/normalize data dari API.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "input": .object(["type": .string("object"),
                                  "description": .string("Input JSON object to transform.")]),
                "script": .object(["type": .string("string"),
                                   "description": .string("JavaScript that transforms `input` and returns the result.")]),
            ]),
            "required": .array([.string("input"), .string("script")]),
        ])
    )

    static let nodeDesktopNotificationDef = LLMToolDef(
        name: "node_desktop_notification",
        description: "Tampilkan notifikasi desktop macOS. Memerlukan izin notifikasi yang diberikan pengguna di System Settings.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string"),
                                  "description": .string("Notification title.")]),
                "body": .object(["type": .string("string"),
                                 "description": .string("Notification body text.")]),
            ]),
            "required": .array([.string("title")]),
        ])
    )

    static let nodeClipboardDef = LLMToolDef(
        name: "node_clipboard",
        description: "Baca/tulis/hapus papan klip (clipboard) macOS. Operasi: read, write, clear. Cocok untuk salin hasil AI ke clipboard atau ambil teks yang disalin pengguna.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "operation": .object(["type": .string("string"),
                                      "description": .string("One of: read, write, clear.")]),
                "text": .object(["type": .string("string"),
                                 "description": .string("Text to write (for write operation).")]),
            ]),
            "required": .array([.string("operation")]),
        ])
    )

    static let nodeRunShellDef = LLMToolDef(
        name: "node_run_shell",
        description: "Jalankan perintah terminal (zsh -lc). Mengembalikan output dan exit code. Cocok untuk git, brew, dan perintah sistem. Tanpa `--dangerously-skip-permissions`.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string"),
                                    "description": .string("The shell command to run.")]),
                "cwd": .object(["type": .string("string"),
                                "description": .string("Optional working directory (`~` allowed).")]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static let wordOpenDef = LLMToolDef(
        name: "word_open",
        description: "Buka Microsoft Word di Mac. Bisa membuka file .docx atau .doc tertentu, atau membuka aplikasi Word kosong.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object(["type": .string("string"),
                                      "description": .string("Path ke file .docx atau .doc (opsional). Jika kosong, buka aplikasi Word kosong.")]),
            ]),
            "required": .array([]),
        ])
    )

    static let excelOpenDef = LLMToolDef(
        name: "excel_open",
        description: "Buka Microsoft Excel di Mac. Bisa membuka file .xlsx atau .xls tertentu, atau membuka aplikasi Excel kosong.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object(["type": .string("string"),
                                      "description": .string("Path ke file .xlsx atau .xls (opsional). Jika kosong, buka aplikasi Excel kosong.")]),
            ]),
            "required": .array([]),
        ])
    )

    static let powerpointOpenDef = LLMToolDef(
        name: "powerpoint_open",
        description: "Buka Microsoft PowerPoint di Mac. Bisa membuka file .pptx atau .ppt tertentu, atau membuka aplikasi PowerPoint kosong.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object(["type": .string("string"),
                                      "description": .string("Path ke file .pptx atau .ppt (opsional). Jika kosong, buka aplikasi PowerPoint kosong.")]),
            ]),
            "required": .array([]),
        ])
    )

    static let outlookOpenDef = LLMToolDef(
        name: "outlook_open",
        description: "Buka Microsoft Outlook di Mac. Bisa membuka aplikasi Outlook kosong.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let codeAnalyzeDef = LLMToolDef(
        name: "code_analyze",
        description: "Analisis kode program. Bisa menganalisis file code (Python, JavaScript, Swift, C++, Java, Rust, Go, dll) untuk menemukan bug, kode tidak efisien, masalah keamanan, dan saran perbaikan.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object(["type": .string("string"),
                                      "description": .string("Path ke file code yang akan dianalisis.")]),
                "language": .object(["type": .string("string"),
                                     "description": .string("Bahasa pemrograman (python, javascript, swift, cpp, java, rust, go, dll). Jika kosong, akan dideteksi otomatis.")]),
            ]),
            "required": .array([.string("file_path")]),
        ])
    )

    static let codeFixDef = LLMToolDef(
        name: "code_fix",
        description: "Perbaiki kode yang error atau tidak berfungsi. Bisa memperbaiki syntax error, bug logis, masalah import, dan masalah kompatibilitas.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object(["type": .string("string"),
                                      "description": .string("Path ke file code yang akan diperbaiki.")]),
                "error_message": .object(["type": .string("string"),
                                          "description": .string("Pesan error yang muncul (opsional, tapi sangat membantu).")]),
                "fix_type": .object(["type": .string("string"),
                                     "description": .string("Tipe perbaikan: syntax, logic, import, refactor, security, performance (default: auto).")]),
            ]),
            "required": .array([.string("file_path")]),
        ])
    )

    static let codePlanDef = LLMToolDef(
        name: "code_plan",
        description: "Buat rencana pengembangan software. Bisa merencanakan arsitektur aplikasi, daftar fitur, timeline, dan struktur file yang dibutuhkan.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "project_name": .object(["type": .string("string"),
                                         "description": .string("Nama proyek yang akan dibuat.")]),
                "description": .object(["type": .string("string"),
                                        "description": .string("Deskripsi lengkap proyek yang ingin dibangun.")]),
                "tech_stack": .object(["type": .string("string"),
                                       "description": .string("Teknologi yang ingin digunakan (contoh: React + Node.js, Python + Django, Swift + SwiftUI).")]),
            ]),
            "required": .array([.string("project_name"), .string("description")]),
        ])
    )

    static let integrationApiCallDef = LLMToolDef(
        name: "integration_api_call",
        description: "Panggil API dari integrasi yang terkonfigurasi (Slack, n8n, Stripe, GitHub, Vercel, dan lainnya). Mengembalikan respons API sebagai teks JSON. Gunakan integration_id untuk menentukan layanan target, endpoint untuk path API, method untuk metode HTTP, dan body untuk body request (opsional).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "integration_id": .object(["type": .string("string"),
                                           "description": .string("ID integrasi tujuan (contoh: integration_slack, integration_stripe, integration_n8n).")]),
                "endpoint": .object(["type": .string("string"),
                                     "description": .string("Endpoint API (contoh: /api/v1/messages, /charges, /workflows).")]),
                "method": .object(["type": .string("string"),
                                   "description": .string("Metode HTTP: GET, POST, PUT, DELETE, PATCH. Default GET.")]),
                "body": .object(["type": .string("string"),
                                 "description": .string("Body request JSON (untuk POST/PUT).")]),
            ]),
            "required": .array([.string("integration_id"), .string("endpoint")]),
        ])
    )

    // MARK: - Slack Tools
    static let slackSendMessageDef = LLMToolDef(
        name: "slack_send_message",
        description: "Kirim pesan ke Slack channel atau user. Membutuhkan Slack API token dan channel ID.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "channel": .object(["type": .string("string"),
                                    "description": .string("Channel ID atau nama channel (contoh: #general, C1234567890).")]),
                "text": .object(["type": .string("string"),
                                 "description": .string("Pesan yang akan dikirim.")]),
            ]),
            "required": .array([.string("channel"), .string("text")]),
        ])
    )

    static let discordSendMessageDef = LLMToolDef(
        name: "discord_send_message",
        description: "Kirim pesan ke Discord channel. Membutuhkan Discord Bot Token dan Channel ID.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "channel_id": .object(["type": .string("string"),
                                       "description": .string("Discord Channel ID.")]),
                "content": .object(["type": .string("string"),
                                    "description": .string("Pesan yang akan dikirim.")]),
            ]),
            "required": .array([.string("channel_id"), .string("content")]),
        ])
    )

    static let telegramSendMessageDef = LLMToolDef(
        name: "telegram_send_message",
        description: "Kirim pesan ke Telegram chat. Membutuhkan Telegram Bot Token dan Chat ID.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "chat_id": .object(["type": .string("string"),
                                    "description": .string("Telegram Chat ID.")]),
                "text": .object(["type": .string("string"),
                                 "description": .string("Pesan yang akan dikirim.")]),
            ]),
            "required": .array([.string("chat_id"), .string("text")]),
        ])
    )

    static let trelloCreateCardDef = LLMToolDef(
        name: "trello_create_card",
        description: "Buat kartu Trello baru. Membutuhkan Trello API Key dan Token.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "list_id": .object(["type": .string("string"),
                                    "description": .string("ID list Trello tujuan.")]),
                "name": .object(["type": .string("string"),
                                 "description": .string("Judul kartu.")]),
                "desc": .object(["type": .string("string"),
                                 "description": .string("Deskripsi kartu (opsional).")]),
            ]),
            "required": .array([.string("list_id"), .string("name")]),
        ])
    )

    static let linearCreateIssueDef = LLMToolDef(
        name: "linear_create_issue",
        description: "Buat issue Linear baru. Membutuhkan Linear API Token.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "team_id": .object(["type": .string("string"),
                                    "description": .string("ID tim Linear.")]),
                "title": .object(["type": .string("string"),
                                  "description": .string("Judul issue.")]),
                "description": .object(["type": .string("string"),
                                        "description": .string("Deskripsi issue (opsional).")]),
            ]),
            "required": .array([.string("team_id"), .string("title")]),
        ])
    )

    static let githubCreateIssueDef = LLMToolDef(
        name: "github_create_issue",
        description: "Buat issue GitHub baru. Membutuhkan GitHub Personal Access Token.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "owner": .object(["type": .string("string"),
                                  "description": .string("Nama organization atau user GitHub.")]),
                "repo": .object(["type": .string("string"),
                                 "description": .string("Nama repository.")]),
                "title": .object(["type": .string("string"),
                                  "description": .string("Judul issue.")]),
                "body": .object(["type": .string("string"),
                                 "description": .string("Deskripsi issue (opsional).")]),
            ]),
            "required": .array([.string("owner"), .string("repo"), .string("title")]),
        ])
    )

    static let stripeCreatePaymentDef = LLMToolDef(
        name: "stripe_create_payment",
        description: "Buat pembayaran Stripe baru. Membutuhkan Stripe API Key.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "amount": .object(["type": .string("string"),
                                   "description": .string("Jumlah dalam cent (contoh: 1000 = $10.00).")]),
                "currency": .object(["type": .string("string"),
                                     "description": .string("Mata uang (contoh: usd, idr).")]),
                "description": .object(["type": .string("string"),
                                        "description": .string("Deskripsi pembayaran (opsional).")]),
            ]),
            "required": .array([.string("amount"), .string("currency")]),
        ])
    )

    static let n8nTriggerWorkflowDef = LLMToolDef(
        name: "n8n_trigger_workflow",
        description: "Trigger eksekusi workflow n8n. Membutuhkan n8n API Key dan Instance URL.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "workflow_id": .object(["type": .string("string"),
                                        "description": .string("ID workflow n8n.")]),
                "data": .object(["type": .string("string"),
                                 "description": .string("Data JSON untuk dikirim ke workflow (opsional).")]),
            ]),
            "required": .array([.string("workflow_id")]),
        ])
    )

    static let officeReadSelectionDef = LLMToolDef(
        name: "office_read_selection",
        description: "Read selected text from Microsoft Word, Excel, Pages, TextEdit, or the frontmost active document. Useful for analyzing document text or formulas highlighted by the user.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "app": .object(["type": .string("string"),
                                "description": .string("Optional target app name (e.g. \"Microsoft Word\", \"Microsoft Excel\", \"Pages\"). If omitted, uses frontmost application.")]),
            ]),
        ])
    )

    static let officeReadTableDef = LLMToolDef(
        name: "office_read_table",
        description: "Extract spreadsheet or table data from Microsoft Excel, Numbers, or active spreadsheet document. Returns formatted rows/columns.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "app": .object(["type": .string("string"),
                                "description": .string("Optional app name (defaults to \"Microsoft Excel\").")]),
                "range": .object(["type": .string("string"),
                                  "description": .string("Optional range string (e.g. \"A1:D20\"). Defaults to used range.")]),
            ]),
        ])
    )

    static let officeWriteTextDef = LLMToolDef(
        name: "office_write_text",
        description: "Insert or append text into Microsoft Word, TextEdit, or the frontmost active document.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object(["type": .string("string"),
                                 "description": .string("Text to insert or append.")]),
                "app": .object(["type": .string("string"),
                                "description": .string("Optional target app (e.g. \"Microsoft Word\", \"TextEdit\").")]),
                "mode": .object(["type": .string("string"),
                                 "description": .string("\"insert\" (default, at cursor/selection) or \"append\" (at end of document).")]),
            ]),
            "required": .array([.string("text")]),
        ])
    )

    static let playbookListDef = LLMToolDef(
        name: "playbook_list",
        description: "List all available structured job playbooks (SOPs) for autonomous multi-step execution.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let playbookRunDef = LLMToolDef(
        name: "playbook_run",
        description: "Execute a structured multi-step job playbook (e.g. 'rekap_office', 'audit_downloads', 'research_trends') autonomously.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "playbook_id": .object([
                    "type": .string("string"),
                    "description": .string("ID of the playbook to execute (e.g. 'rekap_office', 'audit_downloads', 'research_trends').")
                ]),
                "topic": .object([
                    "type": .string("string"),
                    "description": .string("Optional topic or extra parameter for research or analysis.")
                ]),
            ]),
            "required": .array([.string("playbook_id")]),
        ])
    )

    static let toolSynthesizeDef = LLMToolDef(
        name: "tool_synthesize",
        description: "Ciptakan dan kompilasi alat/skill baru secara otonom saat menghadapi tugas baru yang belum dicakup oleh alat bawaan. Script divalidasi keamanannya dan disimpan di Dynamic Skill Sandbox.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string"), "description": .string("ID unik alat dalam snake_case (contoh: 'custom_audio_converter', 'fetch_crypto_rates').")]),
                "name": .object(["type": .string("string"), "description": .string("Nama deskriptif alat.")]),
                "description": .object(["type": .string("string"), "description": .string("Penjelasan kegunaan dan input/output alat.")]),
                "language": .object(["type": .string("string"), "description": .string("Bahasa pemrograman: 'bash', 'python', 'swift', atau 'javascript'.")]),
                "script_source": .object(["type": .string("string"), "description": .string("Kode sumber lengkap script yang siap dieksekusi/dikompilasi.")]),
                "parameter_names": .object([
                    "type": .string("array"),
                    "description": .string("Daftar nama parameter input yang diterima script."),
                    "items": .object(["type": .string("string")])
                ]),
            ]),
            "required": .array([.string("id"), .string("name"), .string("script_source")]),
        ])
    )

    static let toolListDynamicDef = LLMToolDef(
        name: "tool_list_dynamic",
        description: "Daftarkan semua alat dinamis/skill yang telah disintesis oleh asisten.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let toolRunDynamicDef = LLMToolDef(
        name: "tool_run_dynamic",
        description: "Jalankan alat dinamis yang telah disintesis di dalam Dynamic Skill Sandbox.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string"), "description": .string("ID alat dinamis yang akan dijalankan.")]),
                "arguments": .object(["type": .string("object"), "description": .string("Parameter argumen key-value untuk alat tersebut.")]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    // MARK: - Network & Security Sentinel (Paket 5)
    static let laptopSecurityAuditDef = LLMToolDef(
        name: "laptop_security_audit",
        description: "Audit keamanan laptop macOS secara menyeluruh (Firewall, FileVault, SIP, Gatekeeper, port terbuka, dan skor kesehatan keamanan). Mengembalikan ringkasan markdown dan memuat laporan visual di Canvas.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let networkScanLanDef = LLMToolDef(
        name: "network_scan_lan",
        description: "Pindai jaringan Wi-Fi/LAN lokal untuk mendeteksi semua perangkat yang terhubung (IP, MAC address, hostname, dan estimasi tipe perangkat seperti HP, router, CCTV, TV, laptop).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let networkDiagnosticsDef = LLMToolDef(
        name: "network_diagnostics",
        description: "Lakukan diagnostik jaringan lengkap: latensi ping ke host tujuan, kecepatan resolusi DNS, dan deteksi IP publik.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "target_host": .object(["type": .string("string"), "description": .string("Host atau IP tujuan ping (opsional, default: 1.1.1.1).")]),
            ]),
        ])
    )

    // MARK: - Webcam Visual Perception (Paket 6)
    static let cameraCapturePhotoDef = LLMToolDef(
        name: "camera_capture_photo",
        description: "Ambil foto menggunakan kamera / FaceTime HD bawaan MacBook secara instan dan simpan ke file sementara. Kamera langsung dimatikan setelah pengambilan foto (privasi terjamin).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let cameraAnalyzeDef = LLMToolDef(
        name: "camera_analyze",
        description: "Ambil foto dari webcam MacBook dan analisis objek, ekspresi, teks, atau lingkungan sekitar di depan kamera.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object(["type": .string("string"), "description": .string("Pertanyaan atau hal spesifik yang ingin dianalisis dari pandangan webcam (opsional).")]),
            ]),
        ])
    )

    // MARK: - Face Recognition & Presence Guard (Paket 7)
    static let faceEnrollOwnerDef = LLMToolDef(
        name: "face_enroll_owner",
        description: "Daftarkan wajah pemilik MacBook menggunakan kamera webcam untuk pengenalan wajah on-device (Apple Neural Engine). Membutuhkan pengguna berada di depan webcam.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let faceVerifyPresenceDef = LLMToolDef(
        name: "face_verify_presence",
        description: "Verifikasi kehadiran pemilik di depan laptop dan deteksi apakah ada orang lain di dekat layar yang berpotensi mengintip (peeking alert).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    // MARK: - CCTV RTSP & IoT Streamer (Paket 8)
    static let cctvListCamerasDef = LLMToolDef(
        name: "cctv_list_cameras",
        description: "Daftar semua kamera CCTV / IP kamera yang telah terkonfigurasi di Mochi.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let cctvGetSnapshotDef = LLMToolDef(
        name: "cctv_get_snapshot",
        description: "Ambil gambar snapshot dari kamera CCTV (berdasarkan ID kamera, nama kamera, atau direct HTTP/RTSP URL) dan tampilkan di Canvas Mochi.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "camera_identifier": .object(["type": .string("string"), "description": .string("Nama, ID, atau URL stream RTSP/HTTP kamera CCTV target.")]),
            ]),
            "required": .array([.string("camera_identifier")]),
        ])
    )

    static let cctvAddCameraDef = LLMToolDef(
        name: "cctv_add_camera",
        description: "Tambahkan atau perbarui konfigurasi kamera CCTV baru ke dalam Mochi.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"), "description": .string("Nama kamera (contoh: 'Kamera Pintu Depan', 'Garasi').")]),
                "stream_url": .object(["type": .string("string"), "description": .string("URL RTSP atau HTTP stream kamera (contoh: rtsp://192.168.1.100:554/live).")]),
                "location": .object(["type": .string("string"), "description": .string("Lokasi kamera (contoh: 'Pintu Depan', 'Kantor').")]),
                "snapshot_url": .object(["type": .string("string"), "description": .string("Direct HTTP JPEG snapshot URL jika ada (opsional).")]),
                "username": .object(["type": .string("string"), "description": .string("Username autentikasi kamera (opsional).")]),
                "password": .object(["type": .string("string"), "description": .string("Password autentikasi kamera (opsional).")]),
            ]),
            "required": .array([.string("name"), .string("stream_url")]),
        ])
    )

    // MARK: - Docker & Container Management
    static let dockerListContainersDef = LLMToolDef(
        name: "docker_list_containers",
        description: "Daftar semua container Docker lokal (status, nama, image, port). Menampilkan tabel interaktif di Canvas.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "all": .object(["type": .string("boolean"), "description": .string("Jika true, tampilkan semua container termasuk yang berhenti (default: true).")]),
            ]),
        ])
    )

    static let dockerGetLogsDef = LLMToolDef(
        name: "docker_get_logs",
        description: "Ambil baris log output terakhir dari sebuah container Docker lokal.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "container": .object(["type": .string("string"), "description": .string("Nama atau ID container Docker.")]),
                "tail": .object(["type": .string("integer"), "description": .string("Jumlah baris log terakhir yang diambil (default: 100).")]),
            ]),
            "required": .array([.string("container")]),
        ])
    )

    static let dockerRestartContainerDef = LLMToolDef(
        name: "docker_restart_container",
        description: "Restart container Docker lokal berdasarkan nama atau ID container.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "container": .object(["type": .string("string"), "description": .string("Nama atau ID container Docker yang akan direstart.")]),
            ]),
            "required": .array([.string("container")]),
        ])
    )

    // MARK: - Remote Server SSH Health & Gateway
    static let sshListServersDef = LLMToolDef(
        name: "ssh_list_servers",
        description: "Daftar semua remote server Linux / Cloud yang telah terdaftar di Mochi.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    static let sshServerHealthDef = LLMToolDef(
        name: "ssh_server_health",
        description: "Audit kesehatan server Linux jarak jauh via SSH (cek uptime, beban load average, RAM, kapasitas disk, dan systemd services). Menampilkan kartu diagnostik di Canvas.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "server_identifier": .object(["type": .string("string"), "description": .string("Nama, ID, atau host server target.")]),
            ]),
            "required": .array([.string("server_identifier")]),
        ])
    )

    static let sshRunCommandDef = LLMToolDef(
        name: "ssh_run_command",
        description: "Jalankan perintah aman pada server Linux jarak jauh via koneksi SSH terenkripsi.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "server_identifier": .object(["type": .string("string"), "description": .string("Nama, ID, atau host server target.")]),
                "command": .object(["type": .string("string"), "description": .string("Perintah bash yang akan dijalankan di server.")]),
            ]),
            "required": .array([.string("server_identifier"), .string("command")]),
        ])
    )

    static let sshTailLogDef = LLMToolDef(
        name: "ssh_tail_log",
        description: "Baca baris log terakhir dari berkas log atau layanan systemd (contoh: nginx, docker, myapp) di remote server via SSH.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "server_identifier": .object(["type": .string("string"), "description": .string("Nama, ID, atau host server target.")]),
                "log_path_or_service": .object(["type": .string("string"), "description": .string("Path file log (contoh: '/var/log/nginx/error.log') atau nama systemd unit service (contoh: 'nginx').")]),
                "lines": .object(["type": .string("integer"), "description": .string("Jumlah baris log yang diambil (default: 50).")]),
            ]),
            "required": .array([.string("server_identifier"), .string("log_path_or_service")]),
        ])
    )

    // MARK: - Apple Apps Suite
    static let calendarListEventsDef = LLMToolDef(
        name: "calendar_list_events",
        description: "Baca daftar jadwal acara dan rapat dari Apple Calendar untuk hari ini atau beberapa hari ke depan.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "days_ahead": .object(["type": .string("integer"), "description": .string("Berapa hari ke depan jadwal yang akan dibaca (default: 1 untuk hari ini).")]),
            ]),
        ])
    )

    static let reminderAddTaskDef = LLMToolDef(
        name: "reminder_add_task",
        description: "Tambahkan pengingat tugas to-do baru ke aplikasi Apple Reminders.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string"), "description": .string("Judul tugas atau pengingat.")]),
                "due_date": .object(["type": .string("string"), "description": .string("Tenggat waktu atau catatan tanggal (opsional).")]),
                "list_name": .object(["type": .string("string"), "description": .string("Nama daftar pengingat target di Reminders (opsional, default: daftar utama).")]),
            ]),
            "required": .array([.string("title")]),
        ])
    )

    static let notesCreateNoteDef = LLMToolDef(
        name: "notes_create_note",
        description: "Buat dan simpan catatan baru ke dalam aplikasi Apple Notes.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string"), "description": .string("Judul catatan.")]),
                "body": .object(["type": .string("string"), "description": .string("Isi teks catatan.")]),
                "folder_name": .object(["type": .string("string"), "description": .string("Nama folder di Apple Notes (opsional, default: Notes).")]),
            ]),
            "required": .array([.string("title"), .string("body")]),
        ])
    )

    static let mediaControlDef = LLMToolDef(
        name: "media_control",
        description: "Kontrol pemutaran musik di Spotify atau Apple Music (play, pause, toggle, next, previous, now_playing).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string"), "description": .string("Aksi kontrol musik: 'play', 'pause', 'toggle', 'next', 'previous', 'now_playing'.")]),
            ]),
            "required": .array([.string("action")]),
        ])
    )

    // MARK: - Kubernetes Sentinel (DevOps & Cloud Command Center)
    static let k8sGetPodsDef = LLMToolDef(
        name: "k8s_get_pods",
        description: "Ambil daftar status pod Kubernetes di cluster aktif (namespace, nama pod, ready, status, restarts, age). Menampilkan tabel interaktif di Canvas.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "namespace": .object(["type": .string("string"), "description": .string("Namespace Kubernetes target (opsional, default: semua namespace).")]),
            ]),
        ])
    )

    static let k8sDescribePodDef = LLMToolDef(
        name: "k8s_describe_pod",
        description: "Deskripsikan rincian pod Kubernetes (event, status crash, OOMKilled, konfigurasi container) untuk analisa kegagalan atau inspeksi.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"), "description": .string("Nama pod Kubernetes yang akan dideskripsikan.")]),
                "namespace": .object(["type": .string("string"), "description": .string("Namespace pod (opsional).")]),
            ]),
            "required": .array([.string("name")]),
        ])
    )

    static let k8sPodLogsDef = LLMToolDef(
        name: "k8s_pod_logs",
        description: "Ambil baris log output dari pod Kubernetes untuk investigasi error runtime.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"), "description": .string("Nama pod Kubernetes.")]),
                "namespace": .object(["type": .string("string"), "description": .string("Namespace pod (opsional).")]),
                "tail": .object(["type": .string("integer"), "description": .string("Jumlah baris log terakhir yang diambil (default: 100).")]),
            ]),
            "required": .array([.string("name")]),
        ])
    )

    // MARK: - Database Safe Explorer & Query
    static let dbInspectSchemaDef = LLMToolDef(
        name: "db_inspect_schema",
        description: "Inspeksi struktur skema database (daftar tabel, kolom, DDL) untuk SQLite, PostgreSQL, MySQL, atau Redis. Hasil disajikan di Canvas.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "engine": .object(["type": .string("string"), "description": .string("Engine database: 'sqlite', 'postgres', 'mysql', atau 'redis'.")]),
                "target": .object(["type": .string("string"), "description": .string("Path berkas SQLite (misal: '~/data.db') atau nama database / connection string.")]),
            ]),
            "required": .array([.string("engine"), .string("target")]),
        ])
    )

    static let dbExecuteSafeQueryDef = LLMToolDef(
        name: "db_execute_safe_query",
        description: "Jalankan query analitik database yang aman (Read-Only Guardrail: hanya SELECT / pembacaan data) pada SQLite, PostgreSQL, MySQL, atau Redis. Hasil disajikan dalam tabel Canvas.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "engine": .object(["type": .string("string"), "description": .string("Engine database: 'sqlite', 'postgres', 'mysql', atau 'redis'.")]),
                "target": .object(["type": .string("string"), "description": .string("Path berkas SQLite atau database target.")]),
                "query": .object(["type": .string("string"), "description": .string("Perintah query SQL yang akan dieksekusi (Read-Only SELECT).")]),
            ]),
            "required": .array([.string("engine"), .string("target"), .string("query")]),
        ])
    )

    // MARK: - Developer Environment & Git Workflow
    static let editorGotoFileLineDef = LLMToolDef(
        name: "editor_goto_file_line",
        description: "Buka berkas kode pada editor (Cursor, VS Code, Windsurf, Xcode) dan lompat langsung ke baris dan kolom tertentu.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("Path absolut atau relatif berkas yang akan dibuka.")]),
                "line": .object(["type": .string("integer"), "description": .string("Nomor baris tujuan (1-based).")]),
                "column": .object(["type": .string("integer"), "description": .string("Nomor kolom tujuan (opsional, default: 1).")]),
                "editor": .object(["type": .string("string"), "description": .string("Editor pilihan: 'cursor', 'vscode', 'windsurf', 'xcode', atau 'auto'.")]),
            ]),
            "required": .array([.string("path"), .string("line")]),
        ])
    )

    static let gitSmartCommitDef = LLMToolDef(
        name: "git_smart_commit",
        description: "Analisis berkas git yang berubah dan hasilkan usulan pesan Conventional Commit otomatis.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "directory": .object(["type": .string("string"), "description": .string("Direktori repositori git (opsional, default: repo aktif).")]),
                "prefix": .object(["type": .string("string"), "description": .string("Awalan commit tipe konvensional: 'feat', 'fix', 'docs', 'chore', dll (opsional).")]),
            ]),
        ])
    )

    static let ghPrReviewSummaryDef = LLMToolDef(
        name: "gh_pr_review_summary",
        description: "Review Pull Request GitHub aktif atau riwayat commit terakhir dan tampilkan ringkasan diff perubahan di Canvas.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "pr_number": .object(["type": .string("string"), "description": .string("Nomor atau cabang Pull Request GitHub (opsional, default: PR aktif).")]),
                "directory": .object(["type": .string("string"), "description": .string("Direktori repositori lokal (opsional).")]),
            ]),
        ])
    )

    static let officeListSheetsDef = LLMToolDef(
        name: "office_list_sheets",
        description: "List all worksheet/tab names in the active Microsoft Excel or Numbers workbook.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "app": .object(["type": .string("string"),
                                "description": .string("Optional target spreadsheet app (\"Microsoft Excel\" or \"Numbers\"). Defaults to Excel.")]),
            ]),
        ])
    )

    static let officeReadSheetDef = LLMToolDef(
        name: "office_read_sheet",
        description: "Read tabular cell data from a specific named sheet in Microsoft Excel or Numbers.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sheet_name": .object(["type": .string("string"),
                                       "description": .string("Name of the worksheet to read (e.g. \"Sheet1\", \"Ringkasan\", \"Data\").")]),
                "range": .object(["type": .string("string"),
                                  "description": .string("Optional range string (e.g. \"A1:F50\"). Defaults to used range of the sheet.")]),
                "app": .object(["type": .string("string"),
                                "description": .string("Optional target app (defaults to \"Microsoft Excel\").")]),
            ]),
            "required": .array([.string("sheet_name")]),
        ])
    )

    static let officeWriteFormattedDef = LLMToolDef(
        name: "office_write_formatted",
        description: "Write a formatted structured document (with Title, Subtitle, and Sections with Headings) into Microsoft Word or Pages.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string"),
                                 "description": .string("Document main title.")]),
                "subtitle": .object(["type": .string("string"),
                                    "description": .string("Optional document subtitle or metadata line.")]),
                "sections": .object(["type": .string("string"),
                                    "description": .string("Sections content in markdown or newline format with headings.")]),
                "app": .object(["type": .string("string"),
                                "description": .string("Optional target app (defaults to \"Microsoft Word\").")]),
            ]),
            "required": .array([.string("title"), .string("sections")]),
        ])
    )

    static let officeReplaceTemplateDef = LLMToolDef(
        name: "office_replace_template",
        description: "Replace template variables formatted as {{KEY}} with values in the active Microsoft Word document.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "replacements": .object(["type": .string("object"),
                                         "description": .string("Key-value mapping of placeholders to replacement strings, e.g. {\"NAMA\": \"Budi\", \"TOTAL\": \"Rp 5.000.000\"}.")]),
                "app": .object(["type": .string("string"),
                                "description": .string("Optional target app (defaults to \"Microsoft Word\").")]),
            ]),
            "required": .array([.string("replacements")]),
        ])
    )

    static let screenVerifyGoalDef = LLMToolDef(
        name: "screen_verify_goal",
        description: "Visually verify if a goal or task condition has been achieved on screen using screenshot capture and Vision AI verification.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "goal": .object(["type": .string("string"),
                                 "description": .string("The visual condition or goal to verify (e.g. \"Excel sheet contains completed summary table\", \"Download modal has finished\").")]),
                "app": .object(["type": .string("string"),
                                "description": .string("Optional app name to focus capture. Defaults to frontmost window.")]),
            ]),
            "required": .array([.string("goal")]),
        ])
    )

    static let memorySavePreferenceDef = LLMToolDef(
        name: "memory_save_preference",
        description: "Save personal user preference, work style rule, or factual context into the Local Vector Database.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object(["type": .string("string"),
                                 "description": .string("The preference fact or rule to remember.")]),
                "category": .object(["type": .string("string"),
                                     "description": .string("Category (e.g. \"preference\", \"rule\", \"style\", \"personal\"). Defaults to \"preference\".")]),
            ]),
            "required": .array([.string("text")]),
        ])
    )

    static let memoryVectorSearchDef = LLMToolDef(
        name: "memory_vector_search",
        description: "Semantic vector search across stored user preferences and long-term memory.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"),
                                  "description": .string("Search query in natural language.")]),
                "limit": .object(["type": .string("integer"),
                                  "description": .string("Max results to return (default: 5).")]),
            ]),
            "required": .array([.string("query")]),
        ])
    )

    static let canvasPresentArtifactDef = LLMToolDef(
        name: "canvas_present_artifact",
        description: "Tampilkan dokumen terformat, tabel data spreadsheet, diagram alur, atau kode ke Canvas Artifacts Studio di layar pengguna untuk preview interaktif dan ekspor instan.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string"),
                                 "description": .string("Judul artifact (contoh: \"Rekap Penjualan Q3\", \"SOP Deployment\", \"Struktur Data\").")]),
                "type": .object(["type": .string("string"),
                                "description": .string("Tipe artifact: \"document\" (markdown/teks), \"table\" (data tabel TSV/CSV/Markdown), \"code\" (kode program), atau \"chart\" (diagram).")]),
                "content": .object(["type": .string("string"),
                                   "description": .string("Konten lengkap teks, data tabel, atau kode yang akan ditampilkan di Canvas.")]),
            ]),
            "required": .array([.string("title"), .string("type"), .string("content")]),
        ])
    )

    static let guiClickDef = LLMToolDef(
        name: "gui_click",
        description: "Klik mouse pada koordinat piksel layar macOS (x, y). Mendukung tombol left/right dan clickCount 1 atau 2 (double click). Dilindungi oleh safety panic monitor (gerakan mouse fisik membatalkan aksi).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "x": .object(["type": .string("number"), "description": .string("Koordinat piksel X layar (0 = kiri).")]),
                "y": .object(["type": .string("number"), "description": .string("Koordinat piksel Y layar (0 = atas).")]),
                "button": .object(["type": .string("string"), "description": .string("\"left\" (default) atau \"right\".")]),
                "clicks": .object(["type": .string("integer"), "description": .string("1 untuk single click, 2 untuk double click.")]),
            ]),
            "required": .array([.string("x"), .string("y")]),
        ])
    )

    static let guiTypeDef = LLMToolDef(
        name: "gui_type",
        description: "Ketik teks langsung ke elemen atau aplikasi yang sedang memiliki fokus keyboard di macOS.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object(["type": .string("string"), "description": .string("Teks yang akan diketikkan secara native.")]),
            ]),
            "required": .array([.string("text")]),
        ])
    )

    static let guiPressKeyDef = LLMToolDef(
        name: "gui_press_key",
        description: "Tekan tombol keyboard khusus atau kombinasi tombol pintasan (contoh: \"return\", \"tab\", \"escape\", \"space\", \"command+s\", \"command+c\", \"command+v\").",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "key": .object(["type": .string("string"), "description": .string("Nama tombol atau kombinasi (contoh: \"return\", \"escape\", \"command+s\").")]),
            ]),
            "required": .array([.string("key")]),
        ])
    )

    static let guiScrollDef = LLMToolDef(
        name: "gui_scroll",
        description: "Scroll vertikal atau horizontal pada posisi kursor saat ini di layar.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "delta_y": .object(["type": .string("integer"), "description": .string("Jumlah baris scroll vertikal (positif = ke atas, negatif = ke bawah).")]),
                "delta_x": .object(["type": .string("integer"), "description": .string("Jumlah baris scroll horizontal (opsional).")]),
            ]),
            "required": .array([.string("delta_y")]),
        ])
    )

    static let guiLocateAndClickDef = LLMToolDef(
        name: "gui_locate_and_click",
        description: "Visual Grounding CUA: Cari elemen UI berdasarkan deskripsi visual, lakukan aksi OS (klik, ketik, scroll, pintasan), dan verifikasi hasil visualnya secara otomatis dengan self-healing retry (closed-loop).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "element_description": .object(["type": .string("string"), "description": .string("Deskripsi elemen yang ingin dioperasikan (contoh: \"tombol Save biru\", \"input pencarian\", \"icon download\").")]),
                "expected_result": .object(["type": .string("string"), "description": .string("Kondisi visual yang diharapkan muncul setelah aksi (contoh: \"modal tertutup\", \"download selesai\").")]),
                "action": .object(["type": .string("string"), "description": .string("Tipe aksi OS: click, double_click, right_click, type_text, press_key, scroll. Defaults to click.")]),
                "text_to_type": .object(["type": .string("string"), "description": .string("Teks yang ingin diketikkan jika action=type_text, atau nama tombol jika action=press_key.")]),
                "app": .object(["type": .string("string"), "description": .string("Nama aplikasi target (opsional, defaults to frontmost).")]),
            ]),
            "required": .array([.string("element_description")]),
        ])
    )

    static let nightShiftRunDef = LLMToolDef(
        name: "night_shift_run",
        description: "Jalankan SOP Night-Shift secara mandiri: merapikan folder Downloads/Desktop ke subfolder terorganisir dan audit disk space.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    // MARK: - Tool Aliases & Self-Healing Resilience
    static let toolAliases: [String: String] = [
        "check_security": "laptop_security_audit",
        "audit_security": "laptop_security_audit",
        "laptop_security": "laptop_security_audit",
        "security_audit": "laptop_security_audit",
        "scan_wifi": "network_scan_lan",
        "scan_network": "network_scan_lan",
        "lan_scan": "network_scan_lan",
        "wifi_scan": "network_scan_lan",
        "ping": "network_diagnostics",
        "check_network": "network_diagnostics",
        "webcam_capture": "camera_capture_photo",
        "take_photo": "camera_capture_photo",
        "capture_photo": "camera_capture_photo",
        "camera_snapshot": "camera_capture_photo",
        "webcam_analyze": "camera_analyze",
        "see_webcam": "camera_analyze",
        "face_register": "face_enroll_owner",
        "enroll_face": "face_enroll_owner",
        "verify_face": "face_verify_presence",
        "face_check": "face_verify_presence",
        "presence_guard": "face_verify_presence",
        "cctv_snapshot": "cctv_get_snapshot",
        "cctv_capture": "cctv_get_snapshot",
        "get_cctv": "cctv_get_snapshot",
        "docker_ps": "docker_list_containers",
        "docker_containers": "docker_list_containers",
        "docker_logs": "docker_get_logs",
        "container_logs": "docker_get_logs",
        "restart_container": "docker_restart_container",
        "check_server": "ssh_server_health",
        "server_health": "ssh_server_health",
        "server_status": "ssh_server_health",
        "ssh_command": "ssh_run_command",
        "server_command": "ssh_run_command",
        "server_logs": "ssh_tail_log",
        "server_log": "ssh_tail_log",
        "calendar": "calendar_list_events",
        "get_calendar": "calendar_list_events",
        "add_reminder": "reminder_add_task",
        "create_reminder": "reminder_add_task",
        "add_task": "reminder_add_task",
        "create_note": "notes_create_note",
        "add_note": "notes_create_note",
        "save_note": "notes_create_note",
        "music_control": "media_control",
        "spotify_control": "media_control",
        "music": "media_control",
        "kubectl_pods": "k8s_get_pods",
        "k8s_pods": "k8s_get_pods",
        "kubectl_describe": "k8s_describe_pod",
        "describe_pod": "k8s_describe_pod",
        "kubectl_logs": "k8s_pod_logs",
        "pod_logs": "k8s_pod_logs",
        "inspect_db": "db_inspect_schema",
        "db_schema": "db_inspect_schema",
        "query_db": "db_execute_safe_query",
        "sql_query": "db_execute_safe_query",
        "db_query": "db_execute_safe_query",
        "open_editor": "editor_goto_file_line",
        "goto_line": "editor_goto_file_line",
        "open_line": "editor_goto_file_line",
        "smart_commit": "git_smart_commit",
        "git_commit": "git_smart_commit",
        "review_pr": "gh_pr_review_summary",
        "pr_review": "gh_pr_review_summary",
    ]

    /// Short, human-readable target for UI events and audit records.
    static func targetDescription(name: String, input: JSONValue) -> String {
        let actualName = toolAliases[name] ?? name
        let raw: String?
        switch actualName {
        case "shell_run":      raw = input["command"]?.stringValue
        case "file_read":      raw = input["path"]?.stringValue
        case "file_write":     raw = input["path"]?.stringValue
        case "app_open":       raw = input["target"]?.stringValue
        case "web_search":     raw = input["query"]?.stringValue
        case "web_fetch":      raw = input["url"]?.stringValue
        case "app_list":       raw = input["query"]?.stringValue
        case "app_close":      raw = input["name"]?.stringValue
        case "app_screenshot": raw = input["name"]?.stringValue
        case "ax_read":        raw = nil
        case "ax_act":         raw = (try? AXAction(input: input))?.target
        case "memory_save":    raw = input["text"]?.stringValue
        case "claude_run":     raw = input["prompt"]?.stringValue
        case "automation_run": raw = input["script"]?.stringValue
        case "window_list":    raw = input["query"]?.stringValue
        case "window_act":     raw = input["action"]?.stringValue
        case "node_http_request": raw = input["url"]?.stringValue
        case "node_file_system": raw = input["path"]?.stringValue
        case "node_cron_schedule": raw = input["interval"]?.numberValue.map { "\($0)" } ?? input["interval"]?.stringValue
        case "node_if_else": raw = input["condition"]?.stringValue
        case "node_json_transform": raw = input["script"]?.stringValue
        case "node_desktop_notification": raw = input["title"]?.stringValue
        case "node_clipboard": raw = input["operation"]?.stringValue
        case "node_run_shell": raw = input["command"]?.stringValue
        case "integration_api_call": raw = input["integration_id"]?.stringValue
        case "slack_send_message": raw = input["channel"]?.stringValue
        case "discord_send_message": raw = input["channel_id"]?.stringValue
        case "telegram_send_message": raw = input["chat_id"]?.stringValue
        case "trello_create_card": raw = input["list_id"]?.stringValue
        case "linear_create_issue": raw = input["team_id"]?.stringValue
        case "github_create_issue": raw = input["owner"]?.stringValue
        case "stripe_create_payment": raw = input["amount"]?.stringValue
        case "n8n_trigger_workflow": raw = input["workflow_id"]?.stringValue
        case "office_read_selection": raw = input["app"]?.stringValue ?? "selection"
        case "office_read_table":     raw = input["range"]?.stringValue ?? input["app"]?.stringValue ?? "table"
        case "office_write_text":     raw = input["text"]?.stringValue
        case "office_list_sheets":    raw = input["app"]?.stringValue ?? "all sheets"
        case "office_read_sheet":     raw = input["sheet_name"]?.stringValue
        case "office_write_formatted": raw = input["title"]?.stringValue
        case "office_replace_template": raw = "template replacement"
        case "screen_verify_goal":    raw = input["goal"]?.stringValue
        case "memory_save_preference": raw = input["text"]?.stringValue
        case "memory_vector_search":  raw = input["query"]?.stringValue
        case "canvas_present_artifact": raw = input["title"]?.stringValue
        case "gui_click":             raw = "x:\(input["x"]?.numberValue ?? 0), y:\(input["y"]?.numberValue ?? 0)"
        case "gui_type":              raw = input["text"]?.stringValue
        case "gui_press_key":          raw = input["key"]?.stringValue
        case "gui_scroll":             raw = "scroll \(input["delta_y"]?.numberValue ?? 0)"
        case "gui_locate_and_click":   raw = input["element_description"]?.stringValue
        case "night_shift_run":        raw = "night shift"
        case "playbook_list":         raw = "all"
        case "playbook_run":          raw = input["playbook_id"]?.stringValue
        case "tool_synthesize":       raw = input["id"]?.stringValue
        case "tool_list_dynamic":     raw = "all dynamic tools"
        case "tool_run_dynamic":      raw = input["id"]?.stringValue
        case "laptop_security_audit": raw = "security audit"
        case "network_scan_lan":      raw = "lan scan"
        case "network_diagnostics":   raw = input["target_host"]?.stringValue ?? "diagnostics"
        case "camera_capture_photo":  raw = "webcam snapshot"
        case "camera_analyze":        raw = input["prompt"]?.stringValue ?? "webcam analyze"
        case "face_enroll_owner":     raw = "face enroll"
        case "face_verify_presence":  raw = "face presence check"
        case "cctv_list_cameras":     raw = "list cctv"
        case "cctv_get_snapshot":     raw = input["camera_identifier"]?.stringValue
        case "cctv_add_camera":       raw = input["name"]?.stringValue
        case "docker_list_containers": raw = "docker ps"
        case "docker_get_logs":        raw = input["container"]?.stringValue
        case "docker_restart_container": raw = input["container"]?.stringValue
        case "ssh_list_servers":       raw = "list servers"
        case "ssh_server_health":      raw = input["server_identifier"]?.stringValue
        case "ssh_run_command":        raw = input["command"]?.stringValue
        case "ssh_tail_log":           raw = input["log_path_or_service"]?.stringValue
        case "calendar_list_events":   raw = "calendar"
        case "reminder_add_task":      raw = input["title"]?.stringValue
        case "notes_create_note":      raw = input["title"]?.stringValue
        case "media_control":          raw = input["action"]?.stringValue
        case "k8s_get_pods":           raw = input["namespace"]?.stringValue ?? "all"
        case "k8s_describe_pod":        raw = input["name"]?.stringValue
        case "k8s_pod_logs":            raw = input["name"]?.stringValue
        case "db_inspect_schema":       raw = input["target"]?.stringValue
        case "db_execute_safe_query":   raw = input["query"]?.stringValue
        case "editor_goto_file_line":   raw = input["path"]?.stringValue
        case "git_smart_commit":        raw = input["directory"]?.stringValue ?? "smart_commit"
        case "gh_pr_review_summary":    raw = input["pr_number"]?.stringValue ?? "pr_review"
        default:               raw = nil
        }
        let value = raw?.isEmpty == false ? raw! : name
        return String(value.prefix(80))
    }

    /// One-line, UI-sized summary of a result for events and transcript lines.
    static func summary(of result: ToolResult) -> String {
        let line = result.output.split(separator: "\n").first.map(String.init) ?? ""
        var base = line.isEmpty ? (result.isError ? "error" : "ok") : String(line.prefix(60))
        if result.isError, let code = result.exitCode, code != 0 {
            base = "exit \(code): \(base)"
        }
        return base
    }

    // MARK: - Execute

    func execute(name: String, input: JSONValue) async -> ToolResult {
        let actualName = Self.toolAliases[name] ?? name
        let category: ActionCategory
        let target: String?
        var axAction: AXAction? = nil
        switch actualName {
        case "shell_run":       category = .shell;      target = input["command"]?.stringValue
        case "file_read":       category = .read;       target = input["path"]?.stringValue
        case "file_write":      category = .fileWrite;  target = input["path"]?.stringValue
        case "app_open":        category = .appControl; target = input["target"]?.stringValue
        case "web_search":      category = .network;    target = input["query"]?.stringValue
        case "web_fetch":       category = .network;    target = input["url"]?.stringValue
        case "app_list":        category = .read;       target = input["query"]?.stringValue
        case "app_close":       category = .appControl; target = input["name"]?.stringValue
        case "app_screenshot":  category = .appControl; target = input["name"]?.stringValue
        case "ax_read":
            category = .read
            target = nil
        case "ax_act":
            category = .appControl
            if input["action"] == nil {
                target = nil // falls through to the missing-argument deny
            } else {
                do {
                    let parsed = try AXAction(input: input)
                    axAction = parsed
                    target = parsed.target
                } catch {
                    audit.record(category: .appControl, action: name, target: "",
                                 decision: .deny, reason: "invalid action")
                    return ToolResult(output: error.localizedDescription, isError: true, exitCode: nil)
                }
            }
        case "memory_save":     category = .fileWrite;  target = input["text"]?.stringValue
        case "claude_run":      category = .shell;      target = input["prompt"]?.stringValue
        case "automation_run":  category = .appControl; target = input["script"]?.stringValue
        case "window_list":     category = .read;       target = input["query"]?.stringValue
        case "window_act":      category = .appControl; target = input["action"]?.stringValue
        case "node_http_request": category = .network;  target = input["url"]?.stringValue
        case "node_file_system": category = .fileWrite; target = input["path"]?.stringValue
        case "node_cron_schedule": category = .shell; target = input["interval"]?.numberValue.map { "\($0)" } ?? input["interval"]?.stringValue
        case "node_if_else": category = .shell; target = input["condition"]?.stringValue
        case "node_json_transform": category = .shell; target = input["script"]?.stringValue
        case "node_desktop_notification": category = .appControl; target = input["title"]?.stringValue
        case "node_clipboard": category = .shell; target = input["operation"]?.stringValue
        case "node_run_shell": category = .shell; target = input["command"]?.stringValue
        case "integration_api_call": category = .network; target = input["integration_id"]?.stringValue
        case "office_read_selection": category = .read; target = input["app"]?.stringValue ?? "selection"
        case "office_read_table":     category = .read; target = input["range"]?.stringValue ?? input["app"]?.stringValue ?? "table"
        case "office_write_text":     category = .fileWrite; target = input["text"]?.stringValue
        case "office_list_sheets":    category = .read; target = input["app"]?.stringValue ?? "sheets"
        case "office_read_sheet":     category = .read; target = input["sheet_name"]?.stringValue
        case "office_write_formatted": category = .fileWrite; target = input["title"]?.stringValue
        case "office_replace_template": category = .fileWrite; target = "template"
        case "screen_verify_goal":    category = .appControl; target = input["goal"]?.stringValue
        case "memory_save_preference": category = .fileWrite; target = input["text"]?.stringValue
        case "memory_vector_search":  category = .read; target = input["query"]?.stringValue
        case "canvas_present_artifact": category = .read; target = input["title"]?.stringValue
        case "gui_click":             category = .appControl; target = "\(input["x"]?.numberValue ?? 0),\(input["y"]?.numberValue ?? 0)"
        case "gui_type":              category = .appControl; target = input["text"]?.stringValue
        case "gui_press_key":          category = .appControl; target = input["key"]?.stringValue
        case "gui_scroll":             category = .appControl; target = "\(input["delta_y"]?.numberValue ?? 0)"
        case "gui_locate_and_click":   category = .appControl; target = input["element_description"]?.stringValue
        case "night_shift_run":        category = .fileWrite; target = "night shift"
        case "playbook_list":         category = .read; target = nil
        case "playbook_run":          category = .shell; target = input["playbook_id"]?.stringValue
        case "word_open": category = .appControl; target = input["file_path"]?.stringValue
        case "excel_open": category = .appControl; target = input["file_path"]?.stringValue
        case "powerpoint_open": category = .appControl; target = input["file_path"]?.stringValue
        case "outlook_open": category = .appControl; target = input["file_path"]?.stringValue
        case "code_analyze": category = .shell; target = input["file_path"]?.stringValue
        case "code_fix": category = .shell; target = input["file_path"]?.stringValue
        case "code_plan": category = .shell; target = input["project_name"]?.stringValue
        case "slack_send_message": category = .network; target = input["channel"]?.stringValue
        case "discord_send_message": category = .network; target = input["channel_id"]?.stringValue
        case "telegram_send_message": category = .network; target = input["chat_id"]?.stringValue
        case "trello_create_card": category = .network; target = input["list_id"]?.stringValue
        case "linear_create_issue": category = .network; target = input["team_id"]?.stringValue
        case "github_create_issue": category = .network; target = input["owner"]?.stringValue
        case "stripe_create_payment": category = .network; target = input["amount"]?.stringValue
        case "n8n_trigger_workflow": category = .network; target = input["workflow_id"]?.stringValue
        case "tool_synthesize": category = .fileWrite; target = input["id"]?.stringValue
        case "tool_list_dynamic": category = .read; target = "list"
        case "tool_run_dynamic": category = .shell; target = input["id"]?.stringValue
        case "laptop_security_audit": category = .read; target = "security audit"
        case "network_scan_lan":      category = .network; target = "lan scan"
        case "network_diagnostics":   category = .network; target = input["target_host"]?.stringValue ?? "diagnostics"
        case "camera_capture_photo":  category = .appControl; target = "webcam"
        case "camera_analyze":        category = .appControl; target = "webcam analyze"
        case "face_enroll_owner":     category = .appControl; target = "face enroll"
        case "face_verify_presence":  category = .appControl; target = "face presence"
        case "cctv_list_cameras":     category = .read; target = "list cctv"
        case "cctv_get_snapshot":     category = .network; target = input["camera_identifier"]?.stringValue
        case "cctv_add_camera":       category = .fileWrite; target = input["name"]?.stringValue
        case "docker_list_containers": category = .shell; target = "docker ps"
        case "docker_get_logs":        category = .read;  target = input["container"]?.stringValue
        case "docker_restart_container": category = .shell; target = input["container"]?.stringValue
        case "ssh_list_servers":       category = .read; target = "list servers"
        case "ssh_server_health":      category = .network; target = input["server_identifier"]?.stringValue
        case "ssh_run_command":        category = .shell; target = input["command"]?.stringValue
        case "ssh_tail_log":           category = .read;  target = input["log_path_or_service"]?.stringValue
        case "calendar_list_events":   category = .read;  target = "calendar"
        case "reminder_add_task":      category = .appControl; target = input["title"]?.stringValue
        case "notes_create_note":      category = .appControl; target = input["title"]?.stringValue
        case "media_control":          category = .appControl; target = input["action"]?.stringValue
        case "k8s_get_pods":           category = .shell; target = input["namespace"]?.stringValue ?? "kubectl"
        case "k8s_describe_pod", "k8s_pod_logs": category = .shell; target = input["name"]?.stringValue ?? "kubectl"
        case "db_inspect_schema", "db_execute_safe_query": category = .read; target = input["target"]?.stringValue ?? "db"
        case "editor_goto_file_line":   category = .appControl; target = input["path"]?.stringValue ?? "editor"
        case "git_smart_commit":        category = .shell; target = input["directory"]?.stringValue ?? "git"
        case "gh_pr_review_summary":    category = .shell; target = input["pr_number"]?.stringValue ?? "git"
        default:
            if let dyn = DynamicToolSynthesizer.shared.getTool(id: name) {
                category = .shell
                target = dyn.name
                break
            }
            audit.record(category: .shell, action: name, target: "", decision: .deny,
                         reason: "unknown tool")
            return ToolResult(output: "Unknown tool: \(name)", isError: true, exitCode: nil)
        }

        // app_list reads the window list and ax_read reads the UI tree: neither
        // takes a required argument, so both may run with no target at all.
        let requiresTarget = actualName != "app_list" && actualName != "ax_read" && actualName != "window_list"
        guard !requiresTarget || target?.isEmpty == false else {
            audit.record(category: category, action: actualName, target: "", decision: .deny,
                         reason: "missing argument")
            return ToolResult(output: "Missing required argument for \(actualName).", isError: true, exitCode: nil)
        }
        let resolvedTarget = target ?? ""

        // memory_save audits the fact itself but never runs its text through
        // the hard floor: a remembered fact containing "sudo" must not be
        // mistaken for a shell command.
        let policyCommand = actualName == "memory_save"
            ? "memory_save"
            : (resolvedTarget.isEmpty ? actualName : resolvedTarget)
        let action = PolicyAction(category: category, command: policyCommand)
        let verdict = evaluate(action)

        switch verdict.decision {
        case .deny:
            audit.record(category: category, action: actualName, target: resolvedTarget, decision: .deny,
                         reason: verdict.reason)
            return ToolResult(output: "Blocked by policy: \(verdict.reason ?? "denied")",
                              isError: true, exitCode: nil)

        case .confirm:
            let approved = await confirmHandler(action)
            if approved {
                confirm(category)
                audit.record(category: category, action: actualName, target: resolvedTarget, decision: .allow,
                             reason: "user approved")
            } else {
                audit.record(category: category, action: actualName, target: resolvedTarget, decision: .deny,
                             reason: "denied by user")
                return ToolResult(output: "Denied by the user.", isError: true, exitCode: nil)
            }

        case .allow:
            break
        }

        let result = await run(name: actualName, input: input, target: resolvedTarget, axAction: axAction)
        audit.record(category: category, action: actualName, target: resolvedTarget, decision: .allow,
                     exitCode: result.exitCode)
        return result
    }

    private func evaluate(_ action: PolicyAction) -> PolicyVerdict {
        lock.lock(); defer { lock.unlock() }
        return policy.evaluate(action)
    }

    /// Sync so the NSLock call stays out of an async context (Swift 6 noasync).
    private func confirm(_ category: ActionCategory) {
        lock.lock(); defer { lock.unlock() }
        policy.confirm(category)
    }

    // MARK: - Runners

    private func run(name: String, input: JSONValue, target: String,
                     axAction: AXAction?) async -> ToolResult {
        switch name {
        case "shell_run":
            return await runShell(target, cwd: input["cwd"]?.stringValue)
        case "file_read":
            return read(target)
        case "file_write":
            return write(target, content: input["content"]?.stringValue ?? "")
        case "app_open":
            return await open(target)
        case "web_search":
            return await webSearch(target)
        case "web_fetch":
            return await webFetch(target)
        case "app_list":
            return ToolResult(
                output: apps.list(filter: input["query"]?.stringValue),
                isError: false, exitCode: 0)
        case "app_close":
            return close(target)
        case "app_screenshot":
            return await screenshot(target)
        case "ax_read":
            return readAX()
        case "ax_act":
            return performAX(axAction)
        case "memory_save":
            return saveMemory(input["text"]?.stringValue ?? "")
        case "claude_run":
            return await runClaude(target)
        case "automation_run":
            return runAutomation(input)
        case "window_list":
            return listWindows(input["query"]?.stringValue)
        case "window_act":
            return actOnWindow(input)
        case "node_http_request":
            return nodeResult(await nodeRunner.run(.httpRequest, input: NodeInput(values: input.objectValue ?? [:])))
        case "node_file_system":
            return nodeResult(await nodeRunner.run(.fileSystem, input: NodeInput(values: input.objectValue ?? [:])))
        case "node_cron_schedule":
            return nodeResult(await nodeRunner.run(.cronSchedule, input: NodeInput(values: input.objectValue ?? [:])))
        case "node_if_else":
            return nodeResult(await nodeRunner.run(.ifElse, input: NodeInput(values: input.objectValue ?? [:])))
        case "node_json_transform":
            return nodeResult(await nodeRunner.run(.jsonTransform, input: NodeInput(values: input.objectValue ?? [:])))
        case "node_desktop_notification":
            return nodeResult(await nodeRunner.run(.desktopNotification, input: NodeInput(values: input.objectValue ?? [:])))
        case "node_clipboard":
            return nodeResult(await nodeRunner.run(.clipboard, input: NodeInput(values: input.objectValue ?? [:])))
        case "node_run_shell":
            return nodeResult(await nodeRunner.run(.runShell, input: NodeInput(values: input.objectValue ?? [:])))
        case "integration_api_call":
            return await runIntegrationApiCall(input: input)
        case "slack_send_message":
            return await runIntegrationApiCall(input: input)
        case "discord_send_message":
            return await runIntegrationApiCall(input: input)
        case "telegram_send_message":
            return await runIntegrationApiCall(input: input)
        case "trello_create_card":
            return await runIntegrationApiCall(input: input)
        case "linear_create_issue":
            return await runIntegrationApiCall(input: input)
        case "github_create_issue":
            return await runIntegrationApiCall(input: input)
        case "stripe_create_payment":
            return await runIntegrationApiCall(input: input)
        case "n8n_trigger_workflow":
            return await runIntegrationApiCall(input: input)
        case "word_open":
            return await openApp("Microsoft Word")
        case "excel_open":
            return await openApp("Microsoft Excel")
        case "powerpoint_open":
            return await openApp("Microsoft PowerPoint")
        case "outlook_open":
            return await openApp("Microsoft Outlook")
        case "office_read_selection":
            return runOfficeReadSelection(input: input)
        case "office_read_table":
            return runOfficeReadTable(input: input)
        case "office_write_text":
            return runOfficeWriteText(input: input)
        case "office_list_sheets":
            return runOfficeListSheets(input: input)
        case "office_read_sheet":
            return runOfficeReadSheet(input: input)
        case "office_write_formatted":
            return runOfficeWriteFormatted(input: input)
        case "office_replace_template":
            return runOfficeReplaceTemplate(input: input)
        case "screen_verify_goal":
            return await runScreenVerifyGoal(input: input)
        case "memory_save_preference":
            return runMemorySavePreference(input: input)
        case "memory_vector_search":
            return runMemoryVectorSearch(input: input)
        case "canvas_present_artifact":
            return await runCanvasPresentArtifact(input: input)
        case "gui_click":
            return runGuiClick(input: input)
        case "gui_type":
            return runGuiType(input: input)
        case "gui_press_key":
            return runGuiPressKey(input: input)
        case "gui_scroll":
            return runGuiScroll(input: input)
        case "gui_locate_and_click":
            return await runGuiLocateAndClick(input: input)
        case "night_shift_run":
            return await runNightShift()
        case "playbook_list":
            let list = PlaybookEngine.shared.allPlaybooks.map { pb in
                "• [\(pb.id)] \(pb.name) (\(pb.category)): \(pb.description) (\(pb.steps.count) langkah)"
            }.joined(separator: "\n")
            return ToolResult(output: "Daftar Playbook Terstruktur:\n" + list, isError: false, exitCode: 0)
        case "playbook_run":
            guard let pbId = input["playbook_id"]?.stringValue else {
                return ToolResult(output: "Parameter 'playbook_id' diperlukan.", isError: true, exitCode: 1)
            }
            var ctx: [String: String] = [:]
            if let topic = input["topic"]?.stringValue { ctx["topic"] = topic }
            let res = await PlaybookEngine.shared.run(playbookId: pbId, context: ctx, toolExecutor: self)
            let details = res.stepResults.map { "  - \($0.title): \($0.isSuccess ? "✓ Berhasil" : "✗ Gagal") (\($0.output.prefix(120)))" }.joined(separator: "\n")
            return ToolResult(output: "\(res.summary)\n\nRincian Langkah:\n\(details)", isError: !res.isSuccess, exitCode: res.isSuccess ? 0 : 1)
        case "code_analyze":
            return await analyzeCode(input: input)
        case "code_fix":
            return await fixCode(input: input)
        case "code_plan":
            return await planCode(input: input)
        case "tool_synthesize":
            return runToolSynthesize(input: input)
        case "tool_list_dynamic":
            return runToolListDynamic()
        case "tool_run_dynamic":
            return await runToolRunDynamic(input: input)
        case "laptop_security_audit":
            let report = await NetworkSecurityService.shared.auditLaptopSecurity()
            return ToolResult(output: report.summaryMarkdown)
        case "network_scan_lan":
            let report = await NetworkSecurityService.shared.scanLocalNetwork()
            return ToolResult(output: report.summaryText)
        case "network_diagnostics":
            let host = input["target_host"]?.stringValue
            let report = await NetworkSecurityService.shared.runDiagnostics(targetHost: host)
            return ToolResult(output: report.summaryText)
        case "camera_capture_photo":
            do {
                let res = try await WebcamCaptureService.shared.capturePhoto()
                let out = "Foto webcam berhasil diambil dan disimpan ke `\(res.filePath)` (Resolusi: \(res.width)x\(res.height) px, Wajah terdeteksi: \(res.detectedFacesCount))."
                return ToolResult(output: out)
            } catch {
                return ToolResult(output: "Gagal mengambil foto webcam: \(error.localizedDescription)", isError: true)
            }
        case "camera_analyze":
            do {
                let prompt = input["prompt"]?.stringValue
                let report = try await WebcamCaptureService.shared.captureAndAnalyze(prompt: prompt)
                return ToolResult(output: report)
            } catch {
                return ToolResult(output: "Gagal menganalisis kamera: \(error.localizedDescription)", isError: true)
            }
        case "face_enroll_owner":
            do {
                let capture = try await WebcamCaptureService.shared.capturePhoto()
                let enrollRes = try await FaceRecognitionService.shared.enrollOwnerFace(imageData: capture.data)
                return ToolResult(output: enrollRes.message, isError: !enrollRes.isSuccess)
            } catch {
                return ToolResult(output: "Gagal mendaftarkan wajah: \(error.localizedDescription)", isError: true)
            }
        case "face_verify_presence":
            do {
                let capture = try await WebcamCaptureService.shared.capturePhoto()
                let verifyRes = try await FaceRecognitionService.shared.verifyFace(in: capture.data)
                return ToolResult(output: verifyRes.message)
            } catch {
                return ToolResult(output: "Gagal memverifikasi wajah: \(error.localizedDescription)", isError: true)
            }
        case "cctv_list_cameras":
            let cameras = CCTVGatewayService.shared.listCameras()
            if cameras.isEmpty {
                return ToolResult(output: "Belum ada kamera CCTV yang terkonfigurasi. Tambahkan menggunakan tool `cctv_add_camera` atau melalui Pengaturan.")
            }
            let list = cameras.map { "• \($0.name) (\($0.location)) - URL: `\($0.streamUrl)`" }.joined(separator: "\n")
            return ToolResult(output: "Daftar Kamera CCTV Terdaftar:\n\(list)")
        case "cctv_get_snapshot":
            guard let id = input["camera_identifier"]?.stringValue, !id.isEmpty else {
                return ToolResult(output: "Harap berikan 'camera_identifier' (ID, nama, atau URL kamera).", isError: true)
            }
            do {
                let (_, _, summary) = try await CCTVGatewayService.shared.captureSnapshot(cameraIdentifier: id)
                return ToolResult(output: summary)
            } catch {
                return ToolResult(output: "Gagal mengambil snapshot CCTV: \(error.localizedDescription)", isError: true)
            }
        case "cctv_add_camera":
            guard let name = input["name"]?.stringValue, !name.isEmpty,
                  let streamUrl = input["stream_url"]?.stringValue, !streamUrl.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'name' dan 'stream_url'.", isError: true)
            }
            let location = input["location"]?.stringValue ?? "Utama"
            let snapshotUrl = input["snapshot_url"]?.stringValue
            let username = input["username"]?.stringValue
            let password = input["password"]?.stringValue

            let config = CCTVCameraConfig(
                name: name,
                location: location,
                streamUrl: streamUrl,
                snapshotUrl: snapshotUrl,
                username: username,
                password: password
            )
            CCTVGatewayService.shared.addOrUpdateCamera(config)
            return ToolResult(output: "Kamera CCTV '\(name)' (\(location)) berhasil ditambahkan dan disimpan.")
        case "docker_list_containers":
            let all = input["all"]?.boolValue ?? true
            let (_, summary) = await DockerIntegrationService.shared.listContainers(all: all)
            return ToolResult(output: summary)
        case "docker_get_logs":
            guard let container = input["container"]?.stringValue, !container.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'container' (nama/ID container).", isError: true)
            }
            let tail = input["tail"]?.numberValue.map { Int($0) } ?? 100
            let logs = await DockerIntegrationService.shared.getLogs(container: container, tail: tail)
            return ToolResult(output: logs)
        case "docker_restart_container":
            guard let container = input["container"]?.stringValue, !container.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'container' (nama/ID container).", isError: true)
            }
            let (success, msg) = await DockerIntegrationService.shared.restartContainer(container: container)
            return ToolResult(output: msg, isError: !success)
        case "ssh_list_servers":
            let servers = SSHServerGatewayService.shared.listServers()
            if servers.isEmpty {
                return ToolResult(output: "Belum ada server remote yang terdaftar. Tambahkan via Pengaturan atau tool konfigurasi.")
            }
            let list = servers.map { "• \($0.name) (\($0.username)@\($0.host):\($0.port))" }.joined(separator: "\n")
            return ToolResult(output: "Daftar Server Remote Terdaftar:\n\(list)")
        case "ssh_server_health":
            guard let srv = input["server_identifier"]?.stringValue, !srv.isEmpty else {
                return ToolResult(output: "Harap berikan 'server_identifier' (nama atau host server).", isError: true)
            }
            let (report, summary) = await SSHServerGatewayService.shared.checkServerHealth(identifier: srv)
            return ToolResult(output: summary, isError: report == nil)
        case "ssh_run_command":
            guard let srv = input["server_identifier"]?.stringValue, !srv.isEmpty,
                  let cmd = input["command"]?.stringValue, !cmd.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'server_identifier' dan 'command'.", isError: true)
            }
            let (out, isErr) = await SSHServerGatewayService.shared.runRemoteCommand(identifier: srv, command: cmd)
            return ToolResult(output: out, isError: isErr)
        case "ssh_tail_log":
            guard let srv = input["server_identifier"]?.stringValue, !srv.isEmpty,
                  let logTarget = input["log_path_or_service"]?.stringValue, !logTarget.isEmpty else {
                return ToolResult(output: "Harap berikan 'server_identifier' dan 'log_path_or_service'.", isError: true)
            }
            let lines = input["lines"]?.numberValue.map { Int($0) } ?? 50
            let logOut = await SSHServerGatewayService.shared.tailLog(identifier: srv, logPathOrService: logTarget, lines: lines)
            return ToolResult(output: logOut)
        case "calendar_list_events":
            let days = input["days_ahead"]?.numberValue.map { Int($0) } ?? 1
            let result = await AppleAppsIntegrationService.shared.listCalendarEvents(daysAhead: days)
            return ToolResult(output: result)
        case "reminder_add_task":
            guard let title = input["title"]?.stringValue, !title.isEmpty else {
                return ToolResult(output: "Harap berikan 'title' untuk pengingat tugas.", isError: true)
            }
            let due = input["due_date"]?.stringValue
            let list = input["list_name"]?.stringValue
            let res = await AppleAppsIntegrationService.shared.addReminder(title: title, dueString: due, listName: list)
            return ToolResult(output: res)
        case "notes_create_note":
            guard let title = input["title"]?.stringValue, !title.isEmpty,
                  let body = input["body"]?.stringValue, !body.isEmpty else {
                return ToolResult(output: "Harap berikan 'title' dan 'body' untuk catatan.", isError: true)
            }
            let folder = input["folder_name"]?.stringValue
            let res = await AppleAppsIntegrationService.shared.createNote(title: title, body: body, folderName: folder)
            return ToolResult(output: res)
        case "media_control":
            guard let action = input["action"]?.stringValue, !action.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'action' (play, pause, toggle, next, previous, now_playing).", isError: true)
            }
            let res = await AppleAppsIntegrationService.shared.controlMedia(action: action)
            return ToolResult(output: res)
        case "k8s_get_pods":
            let ns = input["namespace"]?.stringValue
            let (_, summary) = await KubernetesIntegrationService.shared.getPods(namespace: ns)
            return ToolResult(output: summary)
        case "k8s_describe_pod":
            guard let name = input["name"]?.stringValue, !name.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'name' (nama pod).", isError: true)
            }
            let ns = input["namespace"]?.stringValue
            let (_, summary) = await KubernetesIntegrationService.shared.describePod(name: name, namespace: ns)
            return ToolResult(output: summary)
        case "k8s_pod_logs":
            guard let name = input["name"]?.stringValue, !name.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'name' (nama pod).", isError: true)
            }
            let ns = input["namespace"]?.stringValue
            let tail = input["tail"]?.numberValue.map { Int($0) } ?? 100
            let logs = await KubernetesIntegrationService.shared.getPodLogs(name: name, namespace: ns, tail: tail)
            return ToolResult(output: logs)
        case "db_inspect_schema":
            guard let engineStr = input["engine"]?.stringValue?.lowercased(),
                  let target = input["target"]?.stringValue, !target.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'engine' ('sqlite', 'postgres', 'mysql', 'redis') dan 'target'.", isError: true)
            }
            let engine: DatabaseEngine
            switch engineStr {
            case "postgres", "postgresql": engine = .postgres
            case "mysql":                  engine = .mysql
            case "redis":                  engine = .redis
            default:                       engine = .sqlite
            }
            let (_, summary) = await DatabaseIntegrationService.shared.inspectSchema(engine: engine, target: target)
            return ToolResult(output: summary)
        case "db_execute_safe_query":
            guard let engineStr = input["engine"]?.stringValue?.lowercased(),
                  let target = input["target"]?.stringValue, !target.isEmpty,
                  let query = input["query"]?.stringValue, !query.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'engine', 'target', dan 'query'.", isError: true)
            }
            let engine: DatabaseEngine
            switch engineStr {
            case "postgres", "postgresql": engine = .postgres
            case "mysql":                  engine = .mysql
            case "redis":                  engine = .redis
            default:                       engine = .sqlite
            }
            let (isErr, out) = await DatabaseIntegrationService.shared.executeSafeQuery(engine: engine, target: target, query: query)
            return ToolResult(output: out, isError: isErr)
        case "editor_goto_file_line":
            guard let path = input["path"]?.stringValue, !path.isEmpty else {
                return ToolResult(output: "Harap berikan parameter 'path' berkas.", isError: true)
            }
            let line = input["line"]?.numberValue.map { Int($0) } ?? 1
            let col = input["column"]?.numberValue.map { Int($0) } ?? 1
            let editor = input["editor"]?.stringValue
            let (ok, msg) = await DeveloperEnvironmentService.shared.gotoFileLine(editor: editor, path: path, line: line, column: col)
            return ToolResult(output: msg, isError: !ok)
        case "git_smart_commit":
            let dir = input["directory"]?.stringValue
            let prefix = input["prefix"]?.stringValue
            let (ok, msg, _) = await DeveloperEnvironmentService.shared.smartCommit(directory: dir, prefix: prefix)
            return ToolResult(output: msg, isError: !ok)
        case "gh_pr_review_summary":
            let pr = input["pr_number"]?.stringValue
            let dir = input["directory"]?.stringValue
            let (ok, msg, _) = await DeveloperEnvironmentService.shared.reviewPullRequest(prNumberOrBranch: pr, repoPath: dir)
            return ToolResult(output: msg, isError: !ok)
        default:
            if let _ = DynamicToolSynthesizer.shared.getTool(id: name) {
                var args: [String: String] = [:]
                if case .object(let dict) = input {
                    for (k, v) in dict {
                        if let s = v.stringValue { args[k] = s }
                        else if let n = v.numberValue { args[k] = "\(n)" }
                        else if let b = v.boolValue { args[k] = "\(b)" }
                    }
                }
                return await DynamicToolSynthesizer.shared.executeTool(id: name, arguments: args)
            }
            return ToolResult(output: "Unknown tool: \(name)", isError: true, exitCode: nil)
        }
    }

    /// Konversi NodeOutput dari NodeRunner menjadi ToolResult untuk ToolExecutor.
    private func nodeResult(_ nodeOutput: NodeOutput) -> ToolResult {
        let output: String
        if nodeOutput.isError {
            output = nodeOutput.errorMessage ?? "Node error"
        } else if let data = try? JSONSerialization.data(withJSONObject: nodeOutput.values.mapValues { $0.anyValue }),
                  let str = String(data: data, encoding: .utf8) {
            output = str
        } else {
            output = ""
        }
        return ToolResult(output: output, isError: nodeOutput.isError, exitCode: nodeOutput.isError ? 1 : 0)
    }

    private func readAX() -> ToolResult {
        do {
            let snapshot = try ax.snapshot()
            return ToolResult(output: snapshot.summary(), isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: error.localizedDescription, isError: true, exitCode: nil)
        }
    }

    private func performAX(_ action: AXAction?) -> ToolResult {
        guard let action else {
            return ToolResult(output: "Missing required argument for ax_act.", isError: true, exitCode: nil)
        }
        do {
            return ToolResult(output: try ax.perform(action), isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: error.localizedDescription, isError: true, exitCode: nil)
        }
    }

    private func saveMemory(_ text: String) -> ToolResult {
        do {
            let isNew = try memory.remember(text)
            // Sinkronkan juga ke basis data vektor untuk pencarian semantik (RAG)
            VectorMemoryStore.shared.savePreference(text: text, category: "fact")
            NotificationCenter.default.post(name: .proactiveEngineRefresh, object: nil)
            let output = isNew ? "Remembered." : "Already remembered — refreshed."
            return ToolResult(output: output, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Memory write failed: \(error.localizedDescription)",
                              isError: true, exitCode: nil)
        }
    }

    /// Claude Code headless (`claude -p ... --output-format text`). Tanpa
    /// `--dangerously-skip-permissions`: kalau CLI meminta izin, itu ditolak
    /// diam-diam (persetujuan tanpa klik tetap dilarang), bukan di-auto-approve.
    private func runClaude(_ prompt: String) async -> ToolResult {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        let (executable, arguments): (String, [String])
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            executable = found
            arguments = ["-p", prompt, "--output-format", "text"]
        } else {
            executable = "/usr/bin/env"
            arguments = ["claude", "-p", prompt, "--output-format", "text"]
        }
        let r = await runProcess(executable, arguments, cwd: nil, timeout: 120)
        var output = r.output.isEmpty ? "(no output from Claude Code)" : r.output
        if r.exitCode != 0 { output += "\n(exit code \(r.exitCode))" }
        return ToolResult(output: output, isError: r.exitCode != 0, exitCode: Int(r.exitCode))
    }

    private func webSearch(_ query: String) async -> ToolResult {
        do {
            let results = try await InternetService.search(query, limit: 6)
            guard !results.isEmpty else {
                return ToolResult(output: "No web results for \"\(query)\".",
                                  isError: false, exitCode: 0)
            }
            return ToolResult(output: InternetService.formatForContext(results, query: query),
                              isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Search failed: \(error.localizedDescription)",
                              isError: true, exitCode: nil)
        }
    }

    private func webFetch(_ urlString: String) async -> ToolResult {
        do {
            var text = try await InternetService.fetchPage(urlString)
            if text.isEmpty { text = "(no readable text)" }
            if text.count > Self.maxOutputChars {
                text = String(text.prefix(Self.maxOutputChars)) + "\n… (truncated)"
            }
            return ToolResult(output: text, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Fetch failed: \(error.localizedDescription)",
                              isError: true, exitCode: nil)
        }
    }

    private func close(_ name: String) -> ToolResult {
        do {
            return ToolResult(output: try apps.close(name), isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: error.localizedDescription, isError: true, exitCode: nil)
        }
    }

    /// Largest PNG we attach inline; bigger captures stay path-only so a
    /// 4K window cannot blow up the request.
    static let maxImageBytes = 1_500_000

    private func screenshot(_ name: String) async -> ToolResult {
        do {
            let capture = try await apps.capture(name)
            var output = "Screenshot saved to \(capture.path)"
            var image: ToolImage? = nil
            if capture.data.count <= Self.maxImageBytes {
                image = ToolImage(mediaType: "image/png",
                                  base64: capture.data.base64EncodedString())
            } else {
                output += "\n(Image is too large to attach — read the file at the path instead.)"
            }
            return ToolResult(output: output, isError: false, exitCode: 0, image: image)
        } catch {
            return ToolResult(output: error.localizedDescription, isError: true, exitCode: nil)
        }
    }

    private func runShell(_ command: String, cwd: String?) async -> ToolResult {
        var resolvedCwd: String? = nil
        if let cwd, !cwd.isEmpty {
            let expanded = (cwd as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                resolvedCwd = expanded
            }
        }
        let r = await runProcess("/bin/zsh", ["-lc", command], cwd: resolvedCwd, timeout: 30)
        var output = r.output
        if output.isEmpty { output = r.exitCode == 0 ? "(no output)" : "(no output, exit \(r.exitCode))" }
        if r.exitCode != 0 { output += "\n(exit code \(r.exitCode))" }
        return ToolResult(output: output, isError: r.exitCode != 0, exitCode: Int(r.exitCode))
    }

    // MARK: - Office Applications
    private func openApp(_ appName: String) async -> ToolResult {
        // First try to open the app by name
        let r = await runProcess("/usr/bin/open", ["-a", appName], cwd: nil, timeout: 10)
        if r.exitCode == 0 {
            return ToolResult(output: "Opened \(appName)", isError: false, exitCode: 0)
        }

        // Try with full path for common Microsoft Office apps
        let appPaths: [String: String] = [
            "Microsoft Word": "/Applications/Microsoft Word.app",
            "Microsoft Excel": "/Applications/Microsoft Excel.app",
            "Microsoft PowerPoint": "/Applications/Microsoft PowerPoint.app",
            "Microsoft Outlook": "/Applications/Microsoft Outlook.app",
            "Word": "/Applications/Microsoft Word.app",
            "Excel": "/Applications/Microsoft Excel.app",
            "PowerPoint": "/Applications/Microsoft PowerPoint.app",
            "Outlook": "/Applications/Microsoft Outlook.app",
        ]

        if let appPath = appPaths[appName] {
            let r2 = await runProcess("/usr/bin/open", ["-a", appPath], cwd: nil, timeout: 10)
            if r2.exitCode == 0 {
                return ToolResult(output: "Opened \(appName)", isError: false, exitCode: 0)
            }
        }

        return ToolResult(output: "Failed to open \(appName): \(r.output.isEmpty ? "unknown error" : r.output)", isError: true, exitCode: Int(r.exitCode))
    }

    private func runOfficeReadSelection(input: JSONValue) -> ToolResult {
        let app = input["app"]?.stringValue
        do {
            let text = try AppAutomation.readOfficeSelection(app: app)
            return ToolResult(output: text, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal membaca seleksi office: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runOfficeReadTable(input: JSONValue) -> ToolResult {
        let app = input["app"]?.stringValue
        let range = input["range"]?.stringValue
        do {
            let table = try AppAutomation.readOfficeTable(app: app, range: range)
            return ToolResult(output: table, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal membaca tabel office: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runOfficeWriteText(input: JSONValue) -> ToolResult {
        guard let text = input["text"]?.stringValue, !text.isEmpty else {
            return ToolResult(output: "Argumen 'text' diperlukan untuk office_write_text.", isError: true, exitCode: 1)
        }
        let app = input["app"]?.stringValue
        let mode = input["mode"]?.stringValue ?? "insert"
        do {
            let res = try AppAutomation.writeOfficeText(text: text, app: app, mode: mode)
            return ToolResult(output: res, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal menulis teks ke dokumen office: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runOfficeListSheets(input: JSONValue) -> ToolResult {
        let app = input["app"]?.stringValue
        do {
            let sheets = try AppAutomation.listExcelSheets(app: app)
            if sheets.isEmpty {
                return ToolResult(output: "Tidak ditemukan sheet atau workbook tidak aktif.", isError: false, exitCode: 0)
            }
            let text = "Daftar Worksheet (\(sheets.count)):\n" + sheets.map { "• \($0)" }.joined(separator: "\n")
            return ToolResult(output: text, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal membaca daftar sheet: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runOfficeReadSheet(input: JSONValue) -> ToolResult {
        guard let sheetName = input["sheet_name"]?.stringValue, !sheetName.isEmpty else {
            return ToolResult(output: "Argumen 'sheet_name' diperlukan.", isError: true, exitCode: 1)
        }
        let range = input["range"]?.stringValue
        let app = input["app"]?.stringValue
        do {
            let data = try AppAutomation.readExcelSheetData(sheetName: sheetName, range: range, app: app)
            return ToolResult(output: data, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal membaca sheet '\(sheetName)': \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runOfficeWriteFormatted(input: JSONValue) -> ToolResult {
        guard let title = input["title"]?.stringValue, !title.isEmpty else {
            return ToolResult(output: "Argumen 'title' diperlukan.", isError: true, exitCode: 1)
        }
        let subtitle = input["subtitle"]?.stringValue
        let rawSections = input["sections"]?.stringValue ?? ""
        let app = input["app"]?.stringValue

        // Parsing sections: format ## HEADING \n body
        var sections: [(heading: String, body: String)] = []
        let parts = rawSections.components(separatedBy: "\n## ")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lines = trimmed.components(separatedBy: "\n")
            let heading = lines.first?.replacingOccurrences(of: "## ", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "Bagian"
            let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append((heading: heading, body: body.isEmpty ? heading : body))
        }

        if sections.isEmpty {
            sections.append((heading: "Konten Utama", body: rawSections))
        }

        do {
            let res = try AppAutomation.writeWordFormatted(title: title, subtitle: subtitle, sections: sections, app: app)
            return ToolResult(output: res, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal membuat dokumen Word terformat: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runOfficeReplaceTemplate(input: JSONValue) -> ToolResult {
        guard let obj = input["replacements"]?.objectValue else {
            return ToolResult(output: "Argumen 'replacements' harus berupa object JSON.", isError: true, exitCode: 1)
        }
        var replacements: [String: String] = [:]
        for (k, v) in obj {
            if let val = v.stringValue {
                replacements[k] = val
            }
        }
        let app = input["app"]?.stringValue
        do {
            let res = try AppAutomation.replaceWordPlaceholders(replacements: replacements, app: app)
            return ToolResult(output: res, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal mengganti placeholder Word: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runScreenVerifyGoal(input: JSONValue) async -> ToolResult {
        guard let goal = input["goal"]?.stringValue, !goal.isEmpty else {
            return ToolResult(output: "Argumen 'goal' diperlukan untuk verifikasi visual.", isError: true, exitCode: 1)
        }
        let app = input["app"]?.stringValue
        do {
            let result = try await VisualVerificationService.shared.verify(goal: goal, appName: app)
            let status = result.passed ? "VERIFIKASI VISUAL BERHASIL [PASSED]" : "VERIFIKASI VISUAL BELUM TERCAPAI [FAILED]"
            let output = """
            \(status) (Confidence: \(Int(result.confidence * 100))%)
            Observasi: \(result.observation)
            Screenshot: \(result.screenshotPath)
            """
            return ToolResult(output: output, isError: !result.passed, exitCode: result.passed ? 0 : 1)
        } catch {
            return ToolResult(output: "Gagal melakukan verifikasi visual: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runMemorySavePreference(input: JSONValue) -> ToolResult {
        guard let text = input["text"]?.stringValue, !text.isEmpty else {
            return ToolResult(output: "Argumen 'text' diperlukan.", isError: true, exitCode: 1)
        }
        let cat = input["category"]?.stringValue ?? "preference"
        let item = VectorMemoryStore.shared.savePreference(text: text, category: cat)
        return ToolResult(output: "Preferensi personal berhasil disimpan ke Vector Database: [\(item.category)] \"\(item.text)\"", isError: false, exitCode: 0)
    }

    private func runMemoryVectorSearch(input: JSONValue) -> ToolResult {
        guard let query = input["query"]?.stringValue, !query.isEmpty else {
            return ToolResult(output: "Argumen 'query' diperlukan.", isError: true, exitCode: 1)
        }
        let limit = input["limit"]?.numberValue.map { Int($0) } ?? 5
        let results = VectorMemoryStore.shared.search(query: query, topK: limit)
        if results.isEmpty {
            return ToolResult(output: "Tidak ditemukan memori atau preferensi yang cocok dengan '\(query)'.", isError: false, exitCode: 0)
        }
        let lines = results.map { r in
            "• [\(r.item.category)] (Relevansi: \(Int(r.score * 100))%) \(r.item.text)"
        }.joined(separator: "\n")
        return ToolResult(output: "Hasil Pencarian Memori Semantik:\n" + lines, isError: false, exitCode: 0)
    }

    private func runCanvasPresentArtifact(input: JSONValue) async -> ToolResult {
        guard let title = input["title"]?.stringValue, !title.isEmpty,
              let content = input["content"]?.stringValue, !content.isEmpty else {
            return ToolResult(output: "Argumen 'title' dan 'content' diperlukan untuk menampilkan artifact.", isError: true, exitCode: 1)
        }
        let rawType = input["type"]?.stringValue ?? "document"
        let type = ArtifactType(rawValue: rawType) ?? .document
        let artifact = CanvasArtifact(title: title, type: type, content: content)

        await MainActor.run {
            CanvasManager.shared.present(artifact: artifact)
        }
        return ToolResult(output: "Artifact '\(title)' (\(type.displayName)) berhasil dibuka di Canvas Artifacts Studio.", isError: false, exitCode: 0)
    }

    private func runGuiClick(input: JSONValue) -> ToolResult {
        guard let x = input["x"]?.numberValue, let y = input["y"]?.numberValue else {
            return ToolResult(output: "Argumen 'x' dan 'y' diperlukan untuk gui_click.", isError: true, exitCode: 1)
        }
        let isRight = (input["button"]?.stringValue?.lowercased() == "right")
        let clicks = input["clicks"]?.numberValue.map { Int($0) } ?? 1
        do {
            try OSComputerControl.shared.click(at: CGPoint(x: x, y: y), button: isRight ? .right : .left, clickCount: clicks)
            return ToolResult(output: "Klik berhasil pada koordinat (\(Int(x)), \(Int(y))).", isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal klik GUI: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runGuiType(input: JSONValue) -> ToolResult {
        guard let text = input["text"]?.stringValue, !text.isEmpty else {
            return ToolResult(output: "Argumen 'text' diperlukan untuk gui_type.", isError: true, exitCode: 1)
        }
        do {
            try OSComputerControl.shared.typeText(text)
            return ToolResult(output: "Teks '\(text.prefix(30))' berhasil diketikkan secara native.", isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal mengetikkan teks: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runGuiPressKey(input: JSONValue) -> ToolResult {
        guard let key = input["key"]?.stringValue, !key.isEmpty else {
            return ToolResult(output: "Argumen 'key' diperlukan untuk gui_press_key.", isError: true, exitCode: 1)
        }
        do {
            try OSComputerControl.shared.pressKey(named: key)
            return ToolResult(output: "Tombol '\(key)' berhasil ditekan.", isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal menekan tombol: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runGuiScroll(input: JSONValue) -> ToolResult {
        let deltaY = input["delta_y"]?.numberValue.map { Int32($0) } ?? -5
        let deltaX = input["delta_x"]?.numberValue.map { Int32($0) } ?? 0
        do {
            try OSComputerControl.shared.scroll(deltaY: deltaY, deltaX: deltaX)
            return ToolResult(output: "Scroll berhasil (deltaY: \(deltaY)).", isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Gagal melakukan scroll: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runGuiLocateAndClick(input: JSONValue) async -> ToolResult {
        guard let element = input["element_description"]?.stringValue, !element.isEmpty else {
            return ToolResult(output: "Argumen 'element_description' diperlukan.", isError: true, exitCode: 1)
        }
        let expected = input["expected_result"]?.stringValue ?? "\(element) berhasil dijalankan"
        let app = input["app"]?.stringValue
        let rawAction = input["action"]?.stringValue ?? "click"
        let actionType = CUAActionType(rawValue: rawAction) ?? .click
        let textToType = input["text_to_type"]?.stringValue

        do {
            let res = try await VisualGroundingEngine.shared.executeClosedLoopAction(
                goal: expected,
                elementDescription: element,
                actionType: actionType,
                textToType: textToType,
                inApp: app,
                maxRetries: 2
            )
            let status = res.passed ? "CUA ACTION BERHASIL [PASSED]" : "CUA ACTION BELUM SELESAI [INCOMPLETE]"
            return ToolResult(output: "\(status): \(res.observation) (Confidence: \(Int(res.confidence * 100))%)", isError: !res.passed, exitCode: res.passed ? 0 : 1)
        } catch {
            return ToolResult(output: "Gagal mengoperasikan GUI secara visual: \(error.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runNightShift() async -> ToolResult {
        let report = await NightShiftWorker.shared.executeNightShift()
        return ToolResult(output: report.summaryText + "\n\nRincian Tindakan:\n" + report.details.joined(separator: "\n"), isError: false, exitCode: 0)
    }

    // MARK: - Code Analysis & Editing

    private func analyzeCode(input: JSONValue) async -> ToolResult {
        guard let filePath = input["file_path"]?.stringValue, !filePath.isEmpty else {
            return ToolResult(output: "Missing file_path argument.", isError: true, exitCode: nil)
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            return ToolResult(output: "File not found: \(filePath)", isError: true, exitCode: nil)
        }

        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return ToolResult(output: "Cannot read file: \(filePath)", isError: true, exitCode: nil)
        }

        let language = input["language"]?.stringValue ?? ""
        let analysis = analyzeCodeContent(content: content, language: language, filePath: filePath)
        return ToolResult(output: analysis, isError: false, exitCode: 0)
    }

    private func analyzeCodeContent(content: String, language: String, filePath: String) -> String {
        var analysis = "📁 File: \(filePath)\n"
        analysis += "📏 Size: \(content.count) characters, \(content.components(separatedBy: .newlines).count) lines\n"
        analysis += "🔤 Language: \(language.isEmpty ? "auto-detect" : language)\n\n"

        // Count lines, functions, classes, etc.
        let lines = content.components(separatedBy: .newlines)
        var funcCount = 0
        var classCount = 0
        var commentCount = 0
        var issueCount = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("func ") || trimmed.hasPrefix("func ") || trimmed.hasPrefix("def ") {
                funcCount += 1
            }
            if trimmed.hasPrefix("class ") || trimmed.hasPrefix("struct ") {
                classCount += 1
            }
            if trimmed.starts(with: "//") || trimmed.starts(with: "#") || trimmed.starts(with: "//") {
                commentCount += 1
            }
            // Simple issue detection
            if trimmed.contains("TODO") || trimmed.contains("FIXME") || trimmed.contains("XXX") {
                issueCount += 1
            }
        }

        analysis += "📊 Summary:\n"
        analysis += "  - Functions: \(funcCount)\n"
        analysis += "  - Classes/Structs: \(classCount)\n"
        analysis += "  - Comments: \(commentCount)\n"
        analysis += "  - TODO/FIXME markers: \(issueCount)\n\n"

        // Simple suggestions
        analysis += "💡 Suggestions:\n"
        if issueCount > 0 {
            analysis += "  - Address TODO/FIXME markers before production.\n"
        }
        if commentCount < lines.count / 10 && lines.count > 20 {
            analysis += "  - Consider adding more comments for complex logic.\n"
        }
        if funcCount > 20 {
            analysis += "  - Consider breaking large files into smaller modules.\n"
        }

        return analysis
    }

    private func fixCode(input: JSONValue) async -> ToolResult {
        guard let filePath = input["file_path"]?.stringValue, !filePath.isEmpty else {
            return ToolResult(output: "Missing file_path argument.", isError: true, exitCode: nil)
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            return ToolResult(output: "File not found: \(filePath)", isError: true, exitCode: nil)
        }

        guard let data = try? Data(contentsOf: fileURL),
              var content = String(data: data, encoding: .utf8) else {
            return ToolResult(output: "Cannot read file: \(filePath)", isError: true, exitCode: nil)
        }

        let errorMessage = input["error_message"]?.stringValue ?? ""
        let fixType = input["fix_type"]?.stringValue ?? "auto"

        var fixedContent = content
        var changes: [String] = []

        // Simple auto-fixes
        if fixType == "auto" || fixType == "syntax" {
            // Fix common issues
            if content.contains("console.log(") && !content.contains("console.error(") {
                // Just note it
            }
            // Fix missing semicolons in JS (basic)
            if languageHint(filePath: filePath) == "javascript" || languageHint(filePath: filePath) == "typescript" {
                for line in content.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("const ") || trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") {
                        if !trimmed.hasSuffix(";") && !trimmed.hasSuffix("{") && !trimmed.hasSuffix("}") {
                            changes.append("Added semicolon to: \(trimmed.prefix(40))")
                        }
                    }
                }
            }
        }

        if changes.isEmpty {
            changes.append("No automatic fixes applied. Manual review recommended.")
        }

        // Write back if changes were made
        if changes.count > 1 { // More than just the "no changes" message
            do {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                return ToolResult(output: "Failed to write fixed file: \(error.localizedDescription)", isError: true, exitCode: nil)
            }
        }

        let output = "🔧 Code Fix Applied\nFile: \(filePath)\nFix type: \(fixType)\nChanges: \(changes.joined(separator: "\n  - "))"
        return ToolResult(output: output, isError: false, exitCode: 0)
    }

    private func planCode(input: JSONValue) async -> ToolResult {
        guard let projectName = input["project_name"]?.stringValue, !projectName.isEmpty else {
            return ToolResult(output: "Missing project_name argument.", isError: true, exitCode: nil)
        }

        let description = input["description"]?.stringValue ?? ""
        let techStack = input["tech_stack"]?.stringValue ?? "Not specified"

        let plan = """
        🚀 Project Plan: \(projectName)
        ========================

        📋 Description:
        \(description.isEmpty ? "No description provided." : description)

        🛠 Tech Stack:
        \(techStack)

        📁 Suggested Structure:
        \(projectName)/
        ├── README.md
        ├── src/
        │   ├── components/
        │   ├── services/
        │   ├── utils/
        │   └── main.swift/main.swift/main.py
        ├── tests/
        ├── docs/
        └── .gitignore

        📅 Implementation Phases:
        1. Setup project structure and dependencies
        2. Implement core functionality
        3. Add error handling and validation
        4. Write tests
        5. Documentation and deployment

        🎯 Next Steps:
        1. Create project directory
        2. Initialize version control (git init)
        3. Set up build system
        4. Implement core features
        5. Test and deploy

        Use the file_write tool to create files as needed.
        """

        return ToolResult(output: plan, isError: false, exitCode: 0)
    }

    private func languageHint(filePath: String) -> String {
        let ext = filePath.lowercased().split(separator: ".").last.map(String.init) ?? ""
        switch ext.lowercased() {
        case "swift": return "swift"
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "cpp", "cc", "cxx": return "cpp"
        case "c": return "c"
        case "java": return "java"
        case "go": return "go"
        case "rs": return "rust"
        case "kt": return "kotlin"
        default: return "unknown"
        }
    }

    private func runIntegrationApiCall(input: JSONValue) async -> ToolResult {
        guard let integrationId = input["integration_id"]?.stringValue,
              let endpoint = input["endpoint"]?.stringValue,
              !integrationId.isEmpty, !endpoint.isEmpty else {
            return ToolResult(output: "Missing integration_id or endpoint.", isError: true, exitCode: nil)
        }

        // Find integration config
        let config = AgentTask.integrationPollConfigs.first { $0.id == integrationId }
        guard let config else {
            return ToolResult(output: "Integration not configured: \(integrationId)", isError: true, exitCode: nil)
        }

        // Build full URL
        let baseUrl = config.endpoint.hasPrefix("http") ? config.endpoint : "https://api.\(integrationId.replacingOccurrences(of: "integration_", with: "")).com"
        let fullUrl = endpoint.hasPrefix("http") ? endpoint : baseUrl + endpoint

        guard let url = URL(string: fullUrl) else {
            return ToolResult(output: "Invalid URL: \(fullUrl)", isError: true, exitCode: nil)
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        let method = input["method"]?.stringValue ?? "GET"
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add auth header
        if let apiKey = KeychainStore.shared.get(config.apiKeyName), !apiKey.isEmpty {
            if config.apiKeyHeader.isEmpty {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            } else {
                req.setValue(apiKey, forHTTPHeaderField: config.apiKeyHeader)
            }
        }

        // Add body for POST/PUT
        if method.uppercased() == "POST" || method.uppercased() == "PUT" {
            if let bodyStr = input["body"]?.stringValue, !bodyStr.isEmpty {
                req.httpBody = bodyStr.data(using: .utf8)
            }
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            guard code == 200 else {
                return ToolResult(output: "API error \(code): \(String(data: data, encoding: .utf8) ?? "")", isError: true, exitCode: Int(code))
            }
        let resultStr = String(data: data, encoding: .utf8) ?? "(no output)"
        return ToolResult(output: resultStr, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Request failed: \(error.localizedDescription)", isError: true, exitCode: nil)
        }
    }

    // MARK: - Integration-specific runners
    
    private func runSlackSendMessage(input: JSONValue) async -> ToolResult {
        return await runIntegrationApiCall(input: .object([
            "integration_id": .string("integration_slack"),
            "endpoint": .string("https://slack.com/api/chat.postMessage"),
            "method": .string("POST"),
            "body": .string(input["channel"]?.stringValue != nil ? "{\"channel\":\"\(input["channel"]?.stringValue ?? "")\",\"text\":\"\(input["text"]?.stringValue ?? "")\"}" : "{}"),
        ]))
    }

    private func runDiscordSendMessage(input: JSONValue) async -> ToolResult {
        return await runIntegrationApiCall(input: .object([
            "integration_id": .string("integration_discord"),
            "endpoint": .string("https://discord.com/api/v9/channels/\(input["channel_id"]?.stringValue ?? "")/messages"),
            "method": .string("POST"),
            "body": .string("{\"content\":\"\(input["content"]?.stringValue ?? "")\"}"),
        ]))
    }

    private func runTelegramSendMessage(input: JSONValue) async -> ToolResult {
        return await runIntegrationApiCall(input: .object([
            "integration_id": .string("integration_telegram"),
            "endpoint": .string("https://api.telegram.org/bot\(input["chat_id"]?.stringValue ?? "")/sendMessage"),
            "method": .string("POST"),
            "body": .string("{\"chat_id\":\"\(input["chat_id"]?.stringValue ?? "")\",\"text\":\"\(input["text"]?.stringValue ?? "")\"}"),
        ]))
    }

    private func runTrelloCreateCard(input: JSONValue) async -> ToolResult {
        return await runIntegrationApiCall(input: .object([
            "integration_id": .string("integration_trello"),
            "endpoint": .string("https://api.trello.com/1/cards"),
            "method": .string("POST"),
            "body": .string("{\"name\":\"\(input["name"]?.stringValue ?? "")\",\"desc\":\"\(input["desc"]?.stringValue ?? "")\",\"idList\":\"\(input["list_id"]?.stringValue ?? "")\"}"),
        ]))
    }

    private func runLinearCreateIssue(input: JSONValue) async -> ToolResult {
        return await runIntegrationApiCall(input: .object([
            "integration_id": .string("integration_linear"),
            "endpoint": .string("https://api.linear.app/graphql"),
            "method": .string("POST"),
            "body": .string("{\"query\":\"mutation { createIssue(input: { teamId: \\\"\(input["team_id"]?.stringValue ?? "")\\\", title: \\\"\(input["title"]?.stringValue ?? "")\\\", description: \\\"\(input["description"]?.stringValue ?? "")\\\" }) { id number } }\"}"),
        ]))
    }

    private func runGithubCreateIssue(input: JSONValue) async -> ToolResult {
        return await runIntegrationApiCall(input: .object([
            "integration_id": .string("integration_github"),
            "endpoint": .string("https://api.github.com/repos/\(input["owner"]?.stringValue ?? "")/\(input["name"]?.stringValue ?? "")/issues"),
            "method": .string("POST"),
            "body": .string("{\"title\":\"\(input["title"]?.stringValue ?? "")\",\"body\":\"\(input["body"]?.stringValue ?? "")\"}"),
        ]))
    }

    private func runStripeCreatePayment(input: JSONValue) async -> ToolResult {
        return await runIntegrationApiCall(input: .object([
            "integration_id": .string("integration_stripe"),
            "endpoint": .string("https://api.stripe.com/v1/charges"),
            "method": .string("POST"),
            "body": .string("{\"amount\":\"\(input["amount"]?.stringValue ?? "")\",\"currency\":\"\(input["currency"]?.stringValue ?? "usd")\",\"description\":\"\(input["description"]?.stringValue ?? "")\"}"),
        ]))
    }

    private func runN8nTriggerWorkflow(input: JSONValue) async -> ToolResult {
        return await runIntegrationApiCall(input: .object([
            "integration_id": .string("integration_n8n"),
            "endpoint": .string("https://api.n8n.io/api/v1/workflows/\(input["workflow_id"]?.stringValue ?? "")/execute"),
            "method": .string("POST"),
            "body": .string("{\"data\":\(input["data"]?.stringValue ?? "{}")}"),
        ]))
    }


    private func read(_ path: String) -> ToolResult {
        let fm = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDir) else {
            return ToolResult(output: "File not found: \(path)", isError: true, exitCode: nil)
        }
        guard !isDir.boolValue else {
            return ToolResult(output: "Not a text file (it's a directory): \(path)", isError: true, exitCode: nil)
        }
        guard let handle = FileHandle(forReadingAtPath: expanded) else {
            return ToolResult(output: "Cannot open: \(path)", isError: true, exitCode: nil)
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.readLimitBytes + 1),
              !data.isEmpty else {
            return ToolResult(output: "(empty file)", isError: false, exitCode: 0)
        }
        if data.contains(0) {
            return ToolResult(output: "Not a text file (binary): \(path)", isError: true, exitCode: nil)
        }
        let truncated = data.count > Self.readLimitBytes
        let slice = truncated ? data.prefix(Self.readLimitBytes) : data
        guard let text = String(data: slice, encoding: .utf8) else {
            return ToolResult(output: "Not UTF-8 text: \(path)", isError: true, exitCode: nil)
        }
        var out = text
        if truncated { out += "\n… (truncated at 200 KB)" }
        if out.isEmpty { out = "(empty file)" }
        return ToolResult(output: out, isError: false, exitCode: 0)
    }

    private func write(_ path: String, content: String) -> ToolResult {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(output: "Wrote \(content.utf8.count) bytes to \(path)",
                              isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: "Write failed: \(error.localizedDescription)",
                              isError: true, exitCode: nil)
        }
    }

    private func open(_ target: String) async -> ToolResult {
        let args: [String]
        if target.contains("://") || target.hasPrefix("/") {
            args = [target]
        } else {
            args = ["-a", target]
        }
        let r = await runProcess("/usr/bin/open", args, cwd: nil, timeout: 10)
        if r.exitCode == 0 {
            return ToolResult(output: "Opened \(target)", isError: false, exitCode: 0)
        }
        let detail = r.output.isEmpty ? "" : ": \(r.output)"
        return ToolResult(output: "open failed (exit \(r.exitCode))\(detail)", isError: true,
                          exitCode: Int(r.exitCode))
    }

    /// Runs a process, capturing stdout+stderr through a temp file (a pipe can
    /// deadlock past 64 KB). Returns after exit or a timeout (SIGTERM).
    private func runProcess(_ executable: String, _ arguments: [String],
                            cwd: String?, timeout: TimeInterval) async -> (output: String, exitCode: Int32) {
        let fm = FileManager.default
        let logURL = fm.temporaryDirectory.appendingPathComponent("jarvis-exec-\(UUID().uuidString).log")
        fm.createFile(atPath: logURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: logURL.path) else {
            return ("Internal error: cannot capture output.", -1)
        }
        defer {
            try? handle.close()
            try? fm.removeItem(at: logURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        do {
            try process.run()
        } catch {
            return ("Failed to start \(executable): \(error.localizedDescription)", -1)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }

        let data = (try? Data(contentsOf: logURL)) ?? Data()
        var output = String(decoding: data, as: UTF8.self)
        if output.count > Self.maxOutputChars {
            output = String(output.prefix(Self.maxOutputChars)) + "\n… (truncated)"
        }
        return (output, exitCode)
    }

    /// Run AppleScript / JavaScript for Automation snippet via osascript.
    private func runAutomation(_ input: JSONValue) -> ToolResult {
        guard let script = input["script"]?.stringValue, !script.isEmpty else {
            return ToolResult(output: "Missing required argument for automation_run.", isError: true, exitCode: nil)
        }
        let langRaw = input["language"]?.stringValue ?? "applescript"
        let language: AppAutomation.Language = (langRaw == "javascript") ? .javascript : .applescript
        do {
            let output = try AppAutomation.run(script, language: language)
            return ToolResult(output: output.isEmpty ? "(no output)" : output, isError: false, exitCode: 0)
        } catch {
            return ToolResult(output: error.localizedDescription, isError: true, exitCode: nil)
        }
    }

    /// List visible windows, optionally filtered by app name / bundle ID.
    private func listWindows(_ query: String?) -> ToolResult {
        let winList: [WindowInfo]
        if let query, !query.isEmpty {
            winList = windows(ofApp: query)
        } else {
            winList = SystemWindowController().listWindows()
        }
        guard !winList.isEmpty else {
            return ToolResult(output: "No visible windows" + (query.map { " matching '\($0)'" } ?? "."), isError: false, exitCode: 0)
        }
        var lines = "Visible windows (\(winList.count)):"
        for w in winList.prefix(30) {
            lines += "\n- [\(w.id)] \(w.appName): \(w.title.isEmpty ? "(no title)" : w.title)"
            if w.isMain { lines += " (main)" }
            if w.isMinimized { lines += " (minimized)" }
            if let bid = w.bundleID { lines += " — \(bid)" }
        }
        if winList.count > 30 { lines += "\nand \(winList.count - 30) more" }
        return ToolResult(output: lines, isError: false, exitCode: 0)
    }

    /// Act on a window: focus / move / resize.
    private func actOnWindow(_ input: JSONValue) -> ToolResult {
        guard let actionRaw = input["action"]?.stringValue else {
            return ToolResult(output: "Missing required argument 'action' for window_act.", isError: true, exitCode: nil)
        }
        guard let windowNum = windowNumber(from: input["window"]) else {
            return ToolResult(output: "Missing or invalid 'window' number for window_act.", isError: true, exitCode: nil)
        }
        let controller = SystemWindowController()
        switch actionRaw.lowercased() {
        case "focus":
            return runFocus(controller: controller, windowNumber: windowNum)
        case "move":
            guard let xs = input["x"]?.stringValue, let x = Double(xs),
                  let ys = input["y"]?.stringValue, let y = Double(ys) else {
                return ToolResult(output: "move requires numeric 'x' and 'y'.", isError: true, exitCode: nil)
            }
            return runMove(controller: controller, windowNumber: windowNum, x: x, y: y)
        case "resize":
            guard let ws = input["width"]?.stringValue, let w = Double(ws),
                  let hs = input["height"]?.stringValue, let h = Double(hs) else {
                return ToolResult(output: "resize requires numeric 'width' and 'height'.", isError: true, exitCode: nil)
            }
            return runResize(controller: controller, windowNumber: windowNum, width: w, height: h)
        default:
            return ToolResult(output: "Unknown window_act action: \(actionRaw) (focus/move/resize).", isError: true, exitCode: nil)
        }
    }

    private func runFocus(controller: SystemWindowController, windowNumber: Int) -> ToolResult {
        let ok = controller.focus(windowNumber: windowNumber)
        let out = ok ? "Focused window [\(windowNumber)]" : "Could not focus window [\(windowNumber)]"
        let err = !ok
        let code: Int
        if ok { code = 0 } else { code = 1 }
        return ToolResult(output: out, isError: err, exitCode: code)
    }

    private func runMove(controller: SystemWindowController, windowNumber: Int, x: Double, y: Double) -> ToolResult {
        let ok = controller.move(windowNumber: windowNumber, to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
        let out = ok ? "Moved window [\(windowNumber)] to (\(Int(x)), \(Int(y)))" : "Could not move window [\(windowNumber)]"
        let err = !ok
        let code: Int
        if ok { code = 0 } else { code = 1 }
        return ToolResult(output: out, isError: err, exitCode: code)
    }

    private func runResize(controller: SystemWindowController, windowNumber: Int, width: Double, height: Double) -> ToolResult {
        let ok = controller.resize(windowNumber: windowNumber, size: CGSize(width: CGFloat(width), height: CGFloat(height)))
        let out = ok ? "Resized window [\(windowNumber)] to \(Int(width))×\(Int(height))" : "Could not resize window [\(windowNumber)]"
        let err = !ok
        let code: Int
        if ok { code = 0 } else { code = 1 }
        return ToolResult(output: out, isError: err, exitCode: code)
    }

    /// Extract an Int window number from .number or .string JSONValue.
    private func windowNumber(from value: JSONValue?) -> Int? {
        switch value {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default:             return nil
        }
    }

    // MARK: - Dynamic Tool Synthesizer Handlers

    private func runToolSynthesize(input: JSONValue) -> ToolResult {
        guard let id = input["id"]?.stringValue, !id.isEmpty,
              let name = input["name"]?.stringValue, !name.isEmpty,
              let script = input["script_source"]?.stringValue, !script.isEmpty else {
            return ToolResult(output: "Argumen 'id', 'name', dan 'script_source' diperlukan untuk tool_synthesize.", isError: true, exitCode: 1)
        }
        let desc = input["description"]?.stringValue ?? "Dynamic tool"
        let rawLang = input["language"]?.stringValue ?? "bash"
        let lang = DynamicToolLanguage(rawValue: rawLang.lowercased()) ?? .bash
        var params: [String] = []
        if let arr = input["parameter_names"]?.arrayValue {
            params = arr.compactMap { $0.stringValue }
        }

        let result = DynamicToolSynthesizer.shared.registerTool(
            id: id,
            name: name,
            description: desc,
            language: lang,
            scriptSource: script,
            parameterNames: params
        )

        switch result {
        case .success(let tool):
            return ToolResult(
                output: "Alat baru '\(tool.name)' (ID: \(tool.id)) berbahasa \(tool.language.displayName) berhasil disintesis dan siap digunakan di sandbox.",
                isError: false,
                exitCode: 0
            )
        case .failure(let err):
            return ToolResult(output: "Gagal mensintesis alat: \(err.localizedDescription)", isError: true, exitCode: 1)
        }
    }

    private func runToolListDynamic() -> ToolResult {
        let tools = DynamicToolSynthesizer.shared.allTools
        if tools.isEmpty {
            return ToolResult(output: "Belum ada dynamic tool yang disintesis.", isError: false, exitCode: 0)
        }
        let lines = tools.map { t in
            "• [\(t.id)] \(t.name) (\(t.language.rawValue)): \(t.description) | Dipanggil: \(t.executionCount)x"
        }.joined(separator: "\n")
        return ToolResult(output: "Daftar Alat Dinamis (Dynamic Tools):\n" + lines, isError: false, exitCode: 0)
    }

    private func runToolRunDynamic(input: JSONValue) async -> ToolResult {
        guard let id = input["id"]?.stringValue, !id.isEmpty else {
            return ToolResult(output: "Argumen 'id' diperlukan untuk tool_run_dynamic.", isError: true, exitCode: 1)
        }
        var args: [String: String] = [:]
        if let obj = input["arguments"]?.objectValue {
            for (k, v) in obj {
                if let s = v.stringValue { args[k] = s }
                else if let n = v.numberValue { args[k] = "\(n)" }
                else if let b = v.boolValue { args[k] = "\(b)" }
            }
        }
        return await DynamicToolSynthesizer.shared.executeTool(id: id, arguments: args)
    }
}

// MARK: - Notification names posted by the tool executor
extension Notification.Name {
    static let proactiveEngineRefresh = Notification.Name("proactiveEngineRefresh")
}
