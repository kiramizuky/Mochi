# Changelog

## Unreleased

- **Chat Mode Auto-Close Guard**: Island/notch will no longer prematurely collapse or hide while the AI is generating, streaming responses, executing tools, or speaking via TTS. Added FSM protection (`canCollapseHome`) and activity state tracking (`isGenerating`).
- **Visual Step-by-Step AI Responses**: Assistant chat responses now automatically parse and render procedural steps (`1. ...`, `Langkah X: ...`, `Step X: ...`) into a sleek timeline card with glowing numbered circle badges and connected vertical tracks.
- **Agent Tool Execution Badges**: Shell executions and tool operations are now displayed with live running indicators and status pills instead of raw text.
- **Enhanced Code Blocks**: Added syntax containers with language tags and 1-click clipboard copy buttons.
- **Extended Chat Island Height**: Chat prompt mode now expands up to 420px height to comfortably read multi-step answers.
- **Multi-Editor & Terminal Coding Support**: Removed hardcoded VS Code restriction in `HookServer`. Added support for Antigravity, Cursor, Windsurf, Codex, Claude Desktop, iTerm2, Warp, Ghostty, and Terminal.app with configurable preferred editor and toggle in Settings.
- **Settings UI Enhancement**: Added dedicated "Editor & Coding Agents" card and renamed "Active pills" to "Slot Integrasi Aplikasi Aktif (Active Slots)" with clear descriptions.
- **Groq AI Provider & Multi-Key Pool**: Added full support for Groq AI (`openai/gpt-oss-120b`, `qwen/qwen3.8-27b`, etc.) with streaming SSE and automatic multi-key rotation on HTTP 429 rate limits.
- **Groq Orpheus TTS with Auto-Rotation**: Added ultra-fast text-to-speech using Canopy Labs Orpheus models (`canopylabs/orpheus-v1-english`, `canopylabs/orpheus-arabic-saudi`) with multi-key failover and selectable voice personas (`troy`, `orla`, `autumn`, `austin`, `shelby`).
- Compact island on screens without a notch (#22) — thanks @Kamasoutra
- Only web links (http/https) open from the notch; other kinds of links from Claude or integrations are ignored (#16) — thanks @Cris1670
- Hook socket limited to your own user account, with size and time limits; logs no longer keep commands, n8n data or full URLs, and stay under 1 MB (#16) — thanks @Cris1670 and @Vignesh-Thangamariappan
- The island always reopens after folding, and Settings opens below it, resizable — thanks @rouderz
- Choose the Claude model for the chat in Settings; the list comes from your Anthropic account, and Claude Sonnet 4.6 stays the default — thanks @rouderz
- Windows build artifacts are now downloadable from a manual CI run — thanks @MysJofR
