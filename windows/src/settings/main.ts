// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { Bridge, onEvent, type CrashReport, type HookStatus, type IntegrationHealth, type LauncherCatalog, type LauncherOption, type ProviderInfo, type ProviderModelOption, type UpdateProgress } from "../core/bridge";
import { DEFAULT_SETTINGS, type Settings } from "../core/state";
import { h, clear } from "../views/dom";

let settings: Settings = { ...DEFAULT_SETTINGS };
let version = "";
/** True only for `COUCOU_SMOKE_TEST=1` launches; the update check never runs. */
let smoke = false;

const root = document.getElementById("settings-root")!;

async function save() {
  await Bridge.saveSettings(settings);
}

// ── Reusable bits ─────────────────────────────────────────────────────────────

function toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement {
  const el = h("button", { class: on ? "switch on" : "switch", "aria-pressed": on });
  el.addEventListener("click", () => {
    const next = !el.classList.contains("on");
    el.classList.toggle("on", next);
    onChange(next);
  });
  return el;
}

function statusDot(ok: boolean): HTMLElement {
  return h("i", { class: "dot", style: `background:${ok ? "#22c55e" : "#f4505e"}` });
}

function renderDiff(text: string): HTMLElement {
  const box = h("div", { class: "diff" });
  for (const line of text.split("\n")) {
    const cls = line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx";
    box.append(h("div", { class: cls, text: line }));
  }
  return box;
}

// ── Claude Code section ───────────────────────────────────────────────────────

function claudeSection(status: HookStatus): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const section = h(
    "section",
    {},
    h("h2", {}, statusDot(status.installed), h("span", { text: "Claude Code" })),
    body,
  );

  const rebuild = async () => {
    const fresh = await Bridge.hooksStatus();
    if (fresh) Object.assign(status, fresh);
    clear(body);
    draw();
    const head = section.querySelector("h2")!;
    clear(head);
    head.append(statusDot(status.installed), h("span", { text: "Claude Code" }));
  };

  function draw() {
    body.append(
      h("div", {
        class: "hint",
        text: status.installed
          ? "Coucou is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there."
          : "Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing.",
      }),
      h("div", { class: "row" },
        h("label", { text: "settings.json" }),
        h("span", { class: "path", text: status.settingsPath }),
      ),
      h("div", { class: "row" },
        h("label", { text: "Relay" }),
        h("span", { class: "path", text: status.hookPath }),
        statusDot(status.hookReady),
      ),
    );

    if (!status.hookReady) {
      body.append(h("div", {
        class: "notice warn",
        text: "coucou-hook.exe is not in place yet. Restart Coucou; if it still fails, build it with `cargo build -p coucou-hook`.",
      }));
    }

    const actions = h("div", { class: "row" });
    const install = h("button", {
      class: "primary",
      text: status.installed ? "Reinstall hooks…" : "Install hooks…",
      onclick: () => showPreview(true),
    });
    // Writing hook commands that point at a relay which isn't there would give
    // every Claude Code session a broken hook and nothing to show for it.
    if (!status.hookReady) {
      install.disabled = true;
      install.title = "The relay isn't installed yet.";
    }
    actions.append(install);
    if (status.installed) {
      actions.append(h("button", {
        class: "danger",
        text: "Uninstall hooks…",
        onclick: () => showPreview(false),
      }));
    }
    body.append(actions);
  }

  async function showPreview(install: boolean) {
    let preview;
    try {
      preview = await Bridge.hooksPreview(install);
    } catch (err) {
      // An unreadable or invalid settings.json stops here rather than being
      // treated as empty and written over.
      clear(body);
      body.append(
        h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }),
        h("div", { class: "row" }, h("button", {
          text: "Back",
          onclick: () => { clear(body); draw(); },
        })),
      );
      return;
    }
    if (!preview) return;
    clear(body);
    body.append(
      h("div", {
        class: "hint",
        text: install
          ? "This is exactly what will change in your settings.json. Your own hooks are left untouched."
          : "This removes Coucou's entries only. Your own hooks are left untouched.",
      }),
      renderDiff(preview.diff),
      h("div", { class: "row" },
        h("span", { class: "path", text: `Backup → ${preview.backup}` }),
      ),
    );
    const confirm = h("button", {
      class: install ? "primary" : "danger",
      text: install ? "Back up and write" : "Back up and remove",
    });
    confirm.addEventListener("click", async () => {
      confirm.disabled = true;
      try {
        const backup = await Bridge.hooksApply(install, preview.fingerprint);
        clear(body);
        body.append(h("div", {
          class: "notice ok",
          text: `Done. Previous settings saved as ${backup}. Open a new Claude Code session to pick the hooks up.`,
        }));
        window.setTimeout(() => void rebuild(), 2600);
      } catch (err) {
        confirm.disabled = false;
        body.append(h("div", { class: "notice err", text: `Could not write: ${String(err)}` }));
      }
    });
    body.append(h("div", { class: "row" }, confirm, h("button", {
      text: "Cancel",
      onclick: () => { clear(body); draw(); },
    })));
  }

  draw();
  return section;
}

// ── Claude API section ────────────────────────────────────────────────────────

// ── AI provider section ───────────────────────────────────────────────────────

/** Used when the settings page runs in a plain browser (`npm run dev`). The
 *  Rust catalogue is the source of truth in the app. */
const FALLBACK_PROVIDERS: ProviderInfo[] = [
  {
    id: "anthropic", name: "Anthropic", defaultModel: "claude-opus-5",
    models: [
      { id: "claude-opus-5", label: "Claude Opus 5" },
      { id: "claude-sonnet-5", label: "Claude Sonnet 5" },
      { id: "claude-haiku-4-5", label: "Claude Haiku 4.5" },
      { id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6" },
    ],
    keyName: "anthropic-api-key", keyPlaceholder: "sk-ant-…", requiresKey: true, isLocal: false,
  },
  {
    id: "openai", name: "OpenAI", defaultModel: "gpt-6.1-sol",
    models: [
      { id: "gpt-6.1-sol", label: "GPT-6.1 Sol" },
      { id: "gpt-6-astra", label: "GPT-6 Astra" },
      { id: "gpt-6-sol", label: "GPT-6 Sol" },
      { id: "gpt-6-luna", label: "GPT-6 Luna" },
      { id: "gpt-5.6-terra", label: "GPT-5.6 Terra" },
    ],
    keyName: "openai-api-key", keyPlaceholder: "sk-…", requiresKey: true, isLocal: false,
  },
  {
    id: "gemini", name: "Google Gemini", defaultModel: "gemini-3.6-flash",
    models: [
      { id: "gemini-3.6-flash", label: "Gemini 3.6 Flash" },
      { id: "gemini-3.5-flash-lite", label: "Gemini 3.5 Flash Lite" },
      { id: "gemini-3.1-flash-lite", label: "Gemini 3.1 Flash Lite" },
      { id: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro (preview)" },
      { id: "gemini-2.5-flash", label: "Gemini 2.5 Flash" },
    ],
    keyName: "gemini-api-key", keyPlaceholder: "AIza…", requiresKey: true, isLocal: false,
  },
  {
    id: "groq", name: "Groq", defaultModel: "openai/gpt-oss-120b",
    models: [
      { id: "openai/gpt-oss-120b", label: "GPT-OSS 120B (Groq)" },
      { id: "qwen/qwen3.8-27b", label: "Qwen 3.8 27B (Groq)" },
      { id: "openai/gpt-oss-20b", label: "GPT-OSS 20B (Groq)" },
      { id: "allam-2-7b", label: "ALLaM 2 7B (Groq)" },
      { id: "llama-3.3-70b-versatile", label: "Llama 3.3 70B Versatile" },
      { id: "llama-3.1-8b-instant", label: "Llama 3.1 8B Instant" },
    ],
    keyName: "groq-api-key", keyPlaceholder: "gsk_…", requiresKey: true, isLocal: false,
  },
  {
    id: "local_mlx", name: "Local model", defaultModel: "qwen2.5:7b",
    models: [
      { id: "qwen2.5:7b", label: "Qwen 2.5 7B (Recommended)" },
      { id: "llama3.2:3b", label: "Llama 3.2 3B (Fast)" },
      { id: "deepseek-r1:7b", label: "DeepSeek R1 7B (Reasoning)" },
      { id: "mistral:7b", label: "Mistral 7B" },
    ],
    keyName: "local-api-key", keyPlaceholder: "optional", requiresKey: false, isLocal: true,
  },
];

function providerFor(catalog: ProviderInfo[], id: string): ProviderInfo {
  return catalog.find((provider) => provider.id === id) ?? catalog[0];
}

function fillModels(
  select: HTMLSelectElement,
  models: ProviderModelOption[],
  selected: string,
) {
  clear(select);
  const seen = new Set<string>();
  for (const model of models) {
    if (seen.has(model.id)) continue;
    seen.add(model.id);
    select.append(h("option", { value: model.id, text: model.label }));
  }
  // A live model that disappeared from the list must still be visible, or the
  // user would silently be switched to a different one.
  if (!seen.has(selected) && selected) {
    select.append(h("option", { value: selected, text: selected }));
  }
  select.value = selected;
}

function normalizeEndpoint(value: string): string | null {
  const trimmed = value.trim().replace(/\/+$/, "");
  try {
    const url = new URL(trimmed);
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname) return null;
    return trimmed;
  } catch {
    return null;
  }
}

function aiSection(catalog: ProviderInfo[]): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:10px" });
  const liveModels: Record<string, ProviderModelOption[]> = {};
  let modelSelect: HTMLSelectElement | null = null;
  let feedback: HTMLElement = h("div", {});

  async function loadModels(provider: ProviderInfo, announce: boolean) {
    const models = await Bridge.providerModels(provider.id);
    if (!models || models.length === 0) {
      if (announce) {
        clear(feedback);
        feedback.append(h("div", {
          class: "notice warn",
          text: `Could not reach ${provider.name}. Showing the built-in model list.`,
        }));
      }
      return;
    }
    liveModels[provider.id] = models;
    // Only touch the dropdown if this provider is still on screen.
    if (!modelSelect || providerFor(catalog, settings.provider).id !== provider.id) return;
    fillModels(modelSelect, models, settings.model);
    if (announce) {
      clear(feedback);
      feedback.append(h("div", { class: "notice ok", text: `${models.length} models available.` }));
    }
  }

  function draw() {
    clear(body);
    feedback = h("div", {});
    const provider = providerFor(catalog, settings.provider);
    if (settings.provider !== provider.id) {
      settings.provider = provider.id;
      void save();
    }

    const dot = statusDot(!provider.requiresKey);
    const head = h("h2", {}, dot, h("span", { text: "AI provider" }));

    const providerSelect = h("select", {}) as HTMLSelectElement;
    for (const option of catalog) {
      providerSelect.append(h("option", { value: option.id, text: option.name }));
    }
    providerSelect.value = provider.id;
    providerSelect.addEventListener("change", () => {
      const next = providerFor(catalog, providerSelect.value);
      settings.provider = next.id;
      settings.model = next.defaultModel;
      void save();
      draw();
      void loadModels(next, false);
    });

    const model = h("select", {}) as HTMLSelectElement;
    modelSelect = model;
    fillModels(model, liveModels[provider.id] ?? provider.models, settings.model);
    model.addEventListener("change", () => {
      settings.model = model.value;
      void save();
    });

    const refresh = h("button", { text: "Refresh" });
    refresh.title = "Ask the provider for its current model list.";
    refresh.addEventListener("click", async () => {
      refresh.disabled = true;
      await loadModels(provider, true);
      refresh.disabled = false;
    });

    const keyState = h("span", { class: "hint" });
    const field = h("input", {
      type: "password",
      placeholder: provider.keyPlaceholder,
      style: "flex:1 1 auto;min-width:0",
      autocomplete: "off",
      spellcheck: "false",
    }) as HTMLInputElement;
    const saveBtn = h("button", { class: "primary", text: "Save key" });
    const clearBtn = h("button", { class: "danger", text: "Remove" });

    async function refreshKey() {
      const present = (await Bridge.secretPresent(provider.keyName)) ?? false;
      const ok = present || !provider.requiresKey;
      dot.style.background = ok ? "#22c55e" : "#f4505e";
      keyState.textContent = present
        ? "Key saved in the Windows Credential Manager."
        : provider.requiresKey
          ? `No key yet — ${provider.name} needs one.`
          : "No key set. Local servers usually do not need one.";
      field.placeholder = present ? "••••••••••••  (stored)" : provider.keyPlaceholder;
      clearBtn.style.display = present ? "" : "none";
    }

    saveBtn.addEventListener("click", async () => {
      const value = field.value.trim();
      if (!value) return;
      clear(feedback);
      try {
        await Bridge.secretSet(provider.keyName, value);
        field.value = "";
        feedback.append(h("div", { class: "notice ok", text: "Saved. It never touches disk." }));
        await refreshKey();
      } catch (err) {
        feedback.append(h("div", { class: "notice err", text: `Could not save: ${String(err)}` }));
      }
    });

    clearBtn.addEventListener("click", async () => {
      clear(feedback);
      try {
        await Bridge.secretClear(provider.keyName);
        feedback.append(h("div", { class: "notice ok", text: "Key removed." }));
        await refreshKey();
      } catch (err) {
        feedback.append(h("div", { class: "notice err", text: `Could not remove: ${String(err)}` }));
      }
    });

    body.append(
      head,
      h("div", {
        class: "hint",
        text: "The chat uses the selected provider. Keys stay in the Windows Credential Manager; model lists fall back to the built-in catalogue when the provider cannot be reached.",
      }),
      h("div", { class: "row" }, h("label", { text: "Provider" }), providerSelect),
      h("div", { class: "row" }, h("label", { text: "Model" }), model, refresh),
      h("div", { class: "row" }, h("label", { text: "API key" }), field, saveBtn, clearBtn),
      keyState,
    );

    if (provider.isLocal) {
      const endpoint = h("input", {
        type: "text",
        value: settings.localEndpoint,
        style: "flex:1 1 auto;min-width:0",
        autocomplete: "off",
        spellcheck: "false",
      }) as HTMLInputElement;
      const endpointSave = h("button", { text: "Save" });
      endpointSave.addEventListener("click", async () => {
        const value = normalizeEndpoint(endpoint.value);
        clear(feedback);
        if (!value) {
          feedback.append(h("div", {
            class: "notice warn",
            text: "Use an absolute http:// or https:// URL, for example http://127.0.0.1:11434/v1.",
          }));
          return;
        }
        settings.localEndpoint = value;
        endpoint.value = value;
        await save();
        feedback.append(h("div", { class: "notice ok", text: "Local endpoint saved." }));
        await loadModels(provider, true);
      });
      body.append(
        h("div", { class: "row" }, h("label", { text: "Server" }), endpoint, endpointSave),
        h("div", {
          class: "hint",
          text: "Ollama works out of the box at http://127.0.0.1:11434/v1. LM Studio and MLX servers use their own OpenAI-compatible URL.",
        }),
      );
    }

    body.append(feedback);
    void refreshKey();
  }

  draw();
  return h("section", {}, body);
}

// ── Welcome (first run) ───────────────────────────────────────────────────────

function welcomeSection(
  providers: ProviderInfo[],
  hasKey: boolean,
  hooksInstalled: boolean,
  launchers: LauncherCatalog,
): HTMLElement | null {
  if (settings.onboarded) return null;

  const initial = providerFor(providers, settings.provider);
  const notice = h("div", {});
  const finish = h("button", { class: "primary", text: "Finish setup" });
  const skip = h("button", { text: "Skip for now" });

  const editorReady = launchers.editors.find((option) => option.id === "auto")?.installed ?? false;
  const terminalReady = launchers.terminals.find((option) => option.id === "auto")?.installed ?? false;
  const detection = editorReady
    ? terminalReady
      ? "Auto-detect found an editor and a terminal."
      : "Auto-detect found an editor; Command Prompt is the terminal fallback."
    : "No editor found, so the folder opens in Explorer; Command Prompt is the terminal fallback.";

  function step(done: boolean, title: string, detail: string): HTMLElement {
    return h(
      "div",
      { class: "row", style: "align-items:flex-start" },
      statusDot(done),
      h("div", { style: "display:flex;flex-direction:column;gap:2px" },
        h("b", { text: title }),
        h("span", { class: "hint", text: detail }),
      ),
    );
  }

  async function complete(force: boolean) {
    clear(notice);
    const provider = providerFor(providers, settings.provider);
    if (!force && provider.requiresKey) {
      const present = (await Bridge.secretPresent(provider.keyName)) ?? false;
      if (!present) {
        notice.append(h("div", {
          class: "notice warn",
          text: `Add a key for ${provider.name} under AI provider first, pick the local provider, or skip for now.`,
        }));
        return;
      }
    }
    settings.onboarded = true;
    await save();
    section.remove();
  }

  finish.addEventListener("click", () => void complete(false));
  skip.addEventListener("click", () => void complete(true));

  const section = h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Welcome to Coucou" })),
    h("div", {
      class: "hint",
      text: "Three short steps and Mochi is ready. Everything can be changed later in this window.",
    }),
    step(
      hasKey || !initial.requiresKey,
      `1. Connect ${initial.name}`,
      hasKey || !initial.requiresKey
        ? "A key is saved in the Windows Credential Manager."
        : "Save a key under AI provider below, or switch to the local provider.",
    ),
    step(
      hooksInstalled,
      "2. Install Claude Code hooks",
      hooksInstalled
        ? "Hooks are installed; permission cards appear in the island."
        : "Use Install hooks under Claude Code so permission requests show up in the island.",
    ),
    step(true, "3. Pick an editor and terminal", detection),
    h("div", { class: "row" }, finish, skip),
    notice,
  );
  return section;
}

// ── Editor and terminal section ───────────────────────────────────────────────

const FALLBACK_LAUNCHERS: LauncherCatalog = {
  editors: [
    { id: "auto", name: "Auto-detect", installed: true },
    { id: "vscode", name: "Visual Studio Code", installed: false },
    { id: "cursor", name: "Cursor", installed: false },
    { id: "windsurf", name: "Windsurf", installed: false },
    { id: "antigravity", name: "Antigravity", installed: false },
  ],
  terminals: [
    { id: "auto", name: "Auto-detect", installed: true },
    { id: "windows_terminal", name: "Windows Terminal", installed: false },
    { id: "powershell", name: "Windows PowerShell", installed: false },
    { id: "pwsh", name: "PowerShell 7", installed: false },
    { id: "git_bash", name: "Git Bash", installed: false },
    { id: "cmd", name: "Command Prompt", installed: true },
  ],
};

function launcherSection(initial: LauncherCatalog): HTMLElement {
  let catalog = initial;
  const body = h("div", { style: "display:flex;flex-direction:column;gap:10px" });

  function picker(
    label: string,
    options: LauncherOption[],
    value: string,
    kind: "editor" | "terminal",
  ): HTMLElement {
    const select = h("select", {}) as HTMLSelectElement;
    for (const option of options) {
      select.append(h("option", {
        value: option.id,
        text: option.installed ? option.name : `${option.name} (not found)`,
      }));
    }
    select.value = options.some((option) => option.id === value) ? value : "auto";

    const hint = h("span", { class: "hint" });
    function updateHint() {
      const chosen = options.find((option) => option.id === select.value);
      if (chosen?.installed) {
        hint.textContent = "";
      } else if (chosen?.id === "auto") {
        hint.textContent = kind === "editor"
          ? "No editor found; the folder opens in Explorer instead."
          : "No terminal found; Command Prompt is used.";
      } else {
        hint.textContent = "Not found on this PC. Auto-detect is used until it is installed.";
      }
    }

    select.addEventListener("change", () => {
      if (kind === "editor") settings.preferredEditor = select.value;
      else settings.preferredTerminal = select.value;
      updateHint();
      void save();
    });
    updateHint();

    return h("div", { class: "row" }, h("label", { text: label }), select, hint);
  }

  function draw() {
    clear(body);
    body.append(
      picker("Editor", catalog.editors, settings.preferredEditor, "editor"),
      picker("Terminal", catalog.terminals, settings.preferredTerminal, "terminal"),
    );
  }

  const refresh = h("button", { text: "Refresh" });
  refresh.title = "Detect editors and terminals again.";
  refresh.addEventListener("click", async () => {
    refresh.disabled = true;
    const fresh = await Bridge.launchersCatalog();
    if (fresh) {
      catalog = fresh;
      draw();
    }
    refresh.disabled = false;
  });

  draw();
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Editor & terminal" })),
    h("div", {
      class: "hint",
      text: "Used by Open in editor on a Claude Code task and by Open terminal when a session finishes. Only apps from this list are launched, and the session folder is passed as a validated path.",
    }),
    body,
    h("div", { class: "row" }, refresh),
  );
}

// ── Integrations section ──────────────────────────────────────────────────────

interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  /** Credential Manager keys, in the order they are shown. */
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
}

const INTEGRATIONS: IntegrationDef[] = [
  { id: "integration_stripe", name: "Stripe", color: "#0570DE",
    fields: [{ key: "stripe-api-key", label: "Secret key", placeholder: "sk_live_…", secret: true }] },
  { id: "integration_github", name: "GitHub", color: "#F4505E",
    fields: [{ key: "github-token", label: "Token", placeholder: "ghp_…", secret: true }] },
  { id: "integration_vercel", name: "Vercel", color: "#7C5CFF",
    fields: [{ key: "vercel-token", label: "Token", placeholder: "…", secret: true }] },
  { id: "integration_n8n", name: "n8n", color: "#F29B38",
    fields: [
      { key: "n8n-url", label: "Instance URL", placeholder: "https://n8n.example.com", secret: false },
      { key: "n8n-api-key", label: "API key", placeholder: "…", secret: true },
    ] },
  { id: "integration_resend", name: "Resend", color: "#22C55E",
    fields: [{ key: "resend-api-key", label: "API key", placeholder: "re_…", secret: true }] },
  { id: "integration_notion", name: "Notion", color: "#8C8C8C",
    fields: [{ key: "notion-api-key", label: "Integration token", placeholder: "ntn_…", secret: true }] },
  { id: "integration_calcom", name: "Cal.com", color: "#C9956A",
    fields: [{ key: "calcom-api-key", label: "API key", placeholder: "cal_…", secret: true }] },
];

const MAX_ACTIVE = 4;

function relativeTime(seconds: number | null): string {
  if (!seconds) return "";
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - seconds);
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)} min ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} h ago`;
  return `${Math.floor(diff / 86400)} d ago`;
}

function integrationsSection(
  present: Record<string, boolean>,
  healthList: IntegrationHealth[],
): HTMLElement {
  const note = h("div", { class: "hint" });
  const list = h("div", { style: "display:flex;flex-direction:column;gap:14px" });
  const statuses: Record<string, { dot: HTMLElement; text: HTMLElement }> = {};

  function updateNote() {
    const used = settings.activeIntegrations.length;
    note.textContent = `Pick up to ${MAX_ACTIVE} pills to show next to Mochi — ${used}/${MAX_ACTIVE} in use. Keys are stored in the Windows Credential Manager, never on disk.`;
  }

  function applyHealth(list: IntegrationHealth[]) {
    for (const def of INTEGRATIONS) {
      const row = statuses[def.id];
      if (!row) continue;
      const health = list.find((item) => item.id === def.id);
      if (!health) {
        row.dot.style.background = "#8c8c8c";
        row.text.textContent = "Status unavailable.";
        continue;
      }
      if (!health.enabled) {
        row.dot.style.background = "#8c8c8c";
        row.text.textContent = "Off — switch it on to poll.";
      } else if (!health.configured) {
        row.dot.style.background = "#f5a524";
        row.text.textContent = "Needs its key before it can poll.";
      } else if (health.ok === null) {
        row.dot.style.background = "#8c8c8c";
        row.text.textContent = "Waiting for the first poll.";
      } else if (health.ok) {
        row.dot.style.background = "#22c55e";
        row.text.textContent = `Healthy${health.lastSuccess ? ` — checked ${relativeTime(health.lastSuccess)}` : ""}.`;
      } else {
        row.dot.style.background = "#f4505e";
        row.text.textContent = health.error || "Last poll failed.";
      }
    }
  }

  for (const def of INTEGRATIONS) {
    const active = settings.activeIntegrations.includes(def.id);
    const sw = h("button", { class: active ? "switch on" : "switch" });
    sw.addEventListener("click", () => {
      const on = settings.activeIntegrations.includes(def.id);
      if (on) {
        settings.activeIntegrations = settings.activeIntegrations.filter((x) => x !== def.id);
      } else {
        if (settings.activeIntegrations.length >= MAX_ACTIVE) return;
        settings.activeIntegrations = [...settings.activeIntegrations, def.id];
      }
      sw.classList.toggle("on", !on);
      updateNote();
      void save();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
    for (const field of def.fields) {
      const input = h("input", {
        type: field.secret ? "password" : "text",
        placeholder: present[field.key] ? "••••••••  (stored)" : field.placeholder,
        autocomplete: "off",
        spellcheck: "false",
        style: "flex:1 1 auto;min-width:0",
      }) as HTMLInputElement;
      const saveBtn = h("button", { text: "Save" });
      const dotEl = statusDot(present[field.key] ?? false);
      saveBtn.addEventListener("click", async () => {
        const value = input.value.trim();
        try {
          await Bridge.secretSet(field.key, value);
          present[field.key] = value.length > 0;
          input.value = "";
          input.placeholder = value ? "••••••••  (stored)" : field.placeholder;
          dotEl.style.background = value ? "#22c55e" : "#f4505e";
        } catch {
          dotEl.style.background = "#f5a524";
        }
      });
      rows.append(
        h("div", { class: "row" },
          h("label", { style: "min-width:104px", text: field.label }),
          input, saveBtn, dotEl,
        ),
      );
    }

    const healthDot = statusDot(false);
    const healthText = h("span", { class: "hint" });
    statuses[def.id] = { dot: healthDot, text: healthText };
    rows.append(
      h("div", { class: "row" },
        h("label", { style: "min-width:104px", text: "Status" }),
        healthDot, healthText,
      ),
    );

    list.append(
      h("div", { style: "display:flex;gap:12px;align-items:flex-start" },
        h("div", { style: "display:flex;align-items:center;gap:8px;min-width:132px;padding-top:4px" },
          sw,
          h("i", { class: "dot", style: `background:${def.color}` }),
          h("span", { style: "font-size:12.5px", text: def.name }),
        ),
        rows,
      ),
    );
  }

  updateNote();
  applyHealth(healthList);

  const refreshStatus = h("button", { text: "Refresh status" });
  refreshStatus.title = "Show the latest poll result for each integration.";
  refreshStatus.addEventListener("click", async () => {
    refreshStatus.disabled = true;
    const fresh = await Bridge.integrationsHealth();
    if (fresh) applyHealth(fresh);
    refreshStatus.disabled = false;
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Integrations" })),
    note,
    list,
    h("div", { class: "row" }, refreshStatus),
  );
}

// ── General section ───────────────────────────────────────────────────────────

function generalSection(): HTMLElement {
  const volume = h("input", {
    type: "range", min: "0", max: "0.2", step: "0.005",
    value: String(settings.soundVolume),
  }) as HTMLInputElement;
  volume.addEventListener("input", () => {
    settings.soundVolume = Number(volume.value);
    void save();
  });

  const autoClose = h("input", {
    type: "number", min: "5", max: "120", step: "1",
    value: String(Math.round(settings.autoCloseInterval)),
    style: "width:72px",
  }) as HTMLInputElement;
  autoClose.addEventListener("change", () => {
    settings.autoCloseInterval = Math.max(5, Math.min(120, Number(autoClose.value) || 15));
    autoClose.value = String(settings.autoCloseInterval);
    void save();
  });

  const screen = h("select", {}) as HTMLSelectElement;
  screen.append(
    h("option", { value: "primary", text: "Main display" }),
    h("option", { value: "cursor", text: "Display under the cursor" }),
  );
  screen.value = settings.screen;
  screen.addEventListener("change", () => {
    settings.screen = screen.value as Settings["screen"];
    void save();
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "General" })),
    h("div", { class: "row" },
      h("label", { text: "Sound" }),
      toggle(settings.soundEnabled, (v) => { settings.soundEnabled = v; void save(); }),
      volume,
    ),
    h("div", { class: "row" },
      h("label", { text: "Auto-close" }),
      autoClose,
      h("span", { class: "hint", text: "seconds after you leave the island" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Island lives on" }),
      screen,
    ),
    h("div", { class: "row" },
      h("label", { text: "Launch at startup" }),
      toggle(settings.autostart, (v) => { settings.autostart = v; void save(); }),
    ),
  );
}

// ── Updates section ───────────────────────────────────────────────────────────

/** Set by `updateSection`; fires a quiet check when Settings is opened. */
let autoUpdateCheck: (() => void) | null = null;

function updateSection(): HTMLElement {
  const feedback = h("div", {});
  const progress = h("div", { class: "hint" });
  const checkBtn = h("button", { class: "primary", text: "Check for updates" });
  let installBtn: HTMLButtonElement | null = null;
  let busy = false;

  const message = (err: unknown) => String(err).replace(/^Error:\s*/, "");

  function setBusy(on: boolean, label: string) {
    busy = on;
    (checkBtn as HTMLButtonElement).disabled = on;
    if (installBtn) installBtn.disabled = on;
    checkBtn.textContent = on ? label : "Check for updates";
  }

  function notice(kind: "ok" | "err", text: string) {
    feedback.append(h("div", { class: `notice ${kind}`, text }));
  }

  function dropInstall() {
    installBtn?.remove();
    installBtn = null;
  }

  function drawProgress(p: UpdateProgress) {
    clear(progress);
    const mb = (bytes: number) => (bytes / 1024 / 1024).toFixed(1);
    const text = p.total && p.total > 0
      ? `Downloading update — ${Math.min(100, Math.round((p.downloaded / p.total) * 100))}% (${mb(p.downloaded)} of ${mb(p.total)} MB)`
      : `Downloading update — ${mb(p.downloaded)} MB`;
    progress.append(h("span", { text }));
  }

  async function install(target: string) {
    if (busy) return;
    clear(feedback);
    clear(progress);
    setBusy(true, "Installing…");
    progress.append(h("span", { text: `Preparing Coucou ${target}…` }));
    try {
      await Bridge.updatesInstall();
      // On Windows the app exits so the installer can replace the running
      // files, so this line is only reached if the install did not start.
      notice("ok", "The installer has started. Coucou restarts when it finishes.");
    } catch (err) {
      clear(progress);
      notice("err", `Could not install the update: ${message(err)}`);
      setBusy(false, "");
    }
  }

  async function check(silent: boolean) {
    if (busy) return;
    clear(feedback);
    clear(progress);
    dropInstall();
    setBusy(true, "Checking…");
    try {
      const info = await Bridge.updatesCheck();
      if (!info) {
        notice("ok", `Coucou ${version || "is"} is up to date.`);
        return;
      }
      feedback.append(
        h("div", { class: "notice ok" },
          h("strong", { text: `Coucou ${info.version} is available` }),
          info.date ? h("span", { text: ` — released ${info.date.slice(0, 10)}` }) : null,
          info.body ? h("div", { class: "hint", text: info.body }) : null,
        ),
      );
      installBtn = h("button", { class: "primary", text: `Install ${info.version}` }) as HTMLButtonElement;
      installBtn.addEventListener("click", () => void install(info.version));
      feedback.append(h("div", { class: "row" }, installBtn));
    } catch (err) {
      if (silent) {
        // Settings just opened; an offline laptop is not an error worth a red box.
        progress.append(h("span", { text: "Could not reach the update feed. Check again later." }));
      } else {
        notice("err", `Could not check for updates: ${message(err)}`);
      }
    } finally {
      setBusy(false, "");
    }
  }

  checkBtn.addEventListener("click", () => void check(false));

  // The Rust side emits this while the signed installer downloads.
  void onEvent<UpdateProgress>("update-progress", drawProgress);

  autoUpdateCheck = () => {
    if (settings.autoCheckUpdates) void check(true);
  };

  const section = h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Updates" })),
    h("div", {
      class: "hint",
      text: "Updates come from signed GitHub Releases. Coucou checks the manifest, verifies the installer against its update key, and only installs after you click. Nothing runs in the background.",
    }),
    h("div", { class: "row" },
      h("label", { text: "Check when Settings opens" }),
      toggle(settings.autoCheckUpdates, (v) => { settings.autoCheckUpdates = v; void save(); }),
    ),
    h("div", { class: "row" }, checkBtn),
    progress,
    feedback,
  );

  return section;
}

// ── Logs section ──────────────────────────────────────────────────────────────

function logSection(): HTMLElement {
  const feedback = h("div", {});
  const exportBtn = h("button", { class: "primary", text: "Export log" });
  const openBtn = h("button", { text: "Open log folder" });

  exportBtn.addEventListener("click", async () => {
    clear(feedback);
    exportBtn.disabled = true;
    try {
      const path = await Bridge.exportLog();
      feedback.append(h("div", {
        class: "notice ok",
        text: `Sanitised copy saved to ${path}`,
      }));
    } catch (err) {
      feedback.append(h("div", {
        class: "notice err",
        text: `Could not export the log: ${String(err).replace(/^Error:\s*/, "")}`,
      }));
    } finally {
      exportBtn.disabled = false;
    }
  });

  openBtn.addEventListener("click", () => {
    void Bridge.openLogFolder();
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Logs" })),
    h("div", {
      class: "hint",
      text: "The local log records hook events, permission decisions and poller problems. It stays on this machine. Export writes a sanitised copy (tokens redacted, size capped) next to the original.",
    }),
    h("div", { class: "row" }, exportBtn, openBtn),
    feedback,
  );
}

// ── Crash reports section ─────────────────────────────────────────────────────

function crashSection(initial: CrashReport[]): HTMLElement {
  let reports = initial;
  const list = h("div", { style: "display:flex;flex-direction:column;gap:6px" });
  const feedback = h("div", {});
  const clearBtn = h("button", { text: "Clear crash reports" });
  const openBtn = h("button", { text: "Open crash folder" });

  function draw() {
    clear(list);
    if (reports.length === 0) {
      list.append(h("div", { class: "hint", text: "No crash reports on this machine." }));
      return;
    }
    for (const report of reports.slice(0, 3)) {
      list.append(
        h("div", { style: "display:flex;flex-direction:column;gap:1px" },
          h("span", { class: "hint", text: `${report.timestamp} - ${report.location}` }),
          h("span", { style: "font-size:12px", text: report.message }),
        ),
      );
    }
    if (reports.length > 3) {
      list.append(h("div", { class: "hint", text: `and ${reports.length - 3} older report(s)` }));
    }
  }

  clearBtn.addEventListener("click", async () => {
    clear(feedback);
    clearBtn.disabled = true;
    try {
      await Bridge.clearCrashReports();
      reports = [];
      draw();
      feedback.append(h("div", { class: "notice ok", text: "Local crash reports cleared." }));
    } catch (err) {
      feedback.append(h("div", {
        class: "notice err",
        text: `Could not clear the reports: ${String(err).replace(/^Error:\s*/, "")}`,
      }));
    } finally {
      clearBtn.disabled = false;
    }
  });
  openBtn.addEventListener("click", () => void Bridge.openCrashFolder());

  draw();
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Crash reports" })),
    h("div", {
      class: "hint",
      text: "If the app panics, a report is written locally next to the log (at most 50, messages sanitised). Nothing is uploaded. Clearing them only removes the reports.",
    }),
    list,
    h("div", { class: "row" }, openBtn, clearBtn),
    feedback,
  );
}

// ── Security & Policy section (Phase 5.0) ─────────────────────────────────────

function securitySection(): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:14px" });
  const section = h("section", {}, h("h2", {}, h("span", { text: "Security & Policy" })), body);

  async function draw() {
    clear(body);
    const status = await Bridge.securityStatus();
    if (!status) {
      body.append(h("div", { class: "notice warn", text: "Security subsystem unavailable." }));
      return;
    }

    // Automation status and kill switch
    const statusRow = h("div", { class: "row", style: "justify-content:space-between" },
      h("div", { style: "display:flex;align-items:center;gap:8px" },
        statusDot(status.automationEnabled),
        h("span", { style: "font-weight:500", text: status.statusReason }),
      ),
      status.killSwitchEngaged
        ? h("button", {
            class: "primary",
            text: "Resume automation",
            onclick: async () => {
              await Bridge.securityResume();
              void draw();
            },
          })
        : h("button", {
            class: "danger",
            text: "Stop all automation",
            onclick: async () => {
              await Bridge.securityKill();
              void draw();
            },
          }),
    );

    // Capabilities table
    const table = h("table", { class: "security-table" });
    table.append(
      h("thead", {},
        h("tr", {},
          h("th", { text: "Capability" }),
          h("th", { text: "Status" }),
          h("th", { text: "Scope" }),
        ),
      ),
    );

    const tbody = h("tbody");
    for (const cap of status.capabilities) {
      const modeLabel =
        cap.mode === "always"
          ? "Always allowed"
          : cap.mode === "session"
            ? "Session only"
            : "Denied";
      const badgeCls = `badge ${cap.mode}`;
      const scopesText =
        cap.scopes.length === 0
          ? "Default"
          : cap.scopes
              .map((s) => (s.kind === "folder" ? s.path : s.kind === "window" ? s.process : s.id))
              .join(", ");

      tbody.append(
        h("tr", {},
          h("td", {},
            h("div", { style: "font-weight:500", text: cap.label }),
            h("code", { style: "font-size:10.5px;color:var(--dim-2)", text: cap.id }),
          ),
          h("td", {}, h("span", { class: badgeCls, text: modeLabel })),
          h("td", { class: "path", text: scopesText }),
        ),
      );
    }
    table.append(tbody);

    // Audit logs section
    const auditEvents = (await Bridge.auditRecent(50)) ?? [];
    const auditContainer = h("div", { style: "display:flex;flex-direction:column;gap:8px" });
    auditContainer.append(
      h("div", { style: "display:flex;justify-content:space-between;align-items:center" },
        h("h3", { style: "font-size:12.5px;font-weight:600", text: "Audit log (last 50 events)" }),
        h("span", {
          class: "hint",
          text: `${status.recentDenials24h} denied in last 24h`,
        }),
      ),
    );

    const auditList = h("div", { class: "audit-list" });
    if (auditEvents.length === 0) {
      auditList.append(h("div", { class: "hint", text: "No security audit events recorded yet." }));
    } else {
      for (const ev of auditEvents) {
        const isOk = ev.decision === "allow" || ev.decision === "kill" || ev.decision === "resume";
        auditList.append(
          h("div", { class: "audit-item" },
            statusDot(isOk),
            h("span", { style: "color:var(--dim-2);min-width:70px", text: ev.event }),
            h("span", { style: "font-weight:500;min-width:60px", text: ev.decision }),
            h("span", { style: "color:var(--dim);flex:1 1 auto", text: ev.target ?? ev.capability ?? "" }),
          ),
        );
      }
    }
    auditContainer.append(auditList);

    const auditActions = h("div", { class: "row" },
      h("button", {
        text: "Export audit log…",
        onclick: async () => {
          try {
            const data = await Bridge.auditExport();
            if (data) {
              const blob = new Blob([data], { type: "application/x-jsonlines" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url;
              a.download = `coucou-audit-${new Date().toISOString().slice(0, 10)}.jsonl`;
              a.click();
              URL.revokeObjectURL(url);
            }
          } catch (err) {
            console.error("Failed to export audit log", err);
          }
        },
      }),
      h("button", {
        text: "Open audit folder",
        onclick: () => void Bridge.auditOpenFolder(),
      }),
    );

    body.append(
      h("div", {
        class: "hint",
        text: "Phase 5.0 Policy Engine enforces default-deny permissions, tamper-evident local audit chaining, and an instant kill switch for all automated background tasks.",
      }),
      statusRow,
      table,
      auditContainer,
      auditActions,
    );
  }

  void draw();
  void onEvent<null>("security_state_changed", () => void draw());

  return section;
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function main() {
  const boot = await Bridge.boot();
  if (boot) {
    settings = { ...settings, ...boot.settings };
    version = boot.version;
    smoke = boot.smoke;
  }
  const status = (await Bridge.hooksStatus()) ?? {
    installed: false, settingsPath: "", hookPath: "", hookReady: false,
  };

  const catalog = (await Bridge.providersCatalog()) ?? FALLBACK_PROVIDERS;
  const providers = catalog.length > 0 ? catalog : FALLBACK_PROVIDERS;
  const initialProvider = providerFor(providers, settings.provider);
  const hasKey = initialProvider.requiresKey
    ? (await Bridge.secretPresent(initialProvider.keyName)) ?? false
    : true;

  const launchers = (await Bridge.launchersCatalog()) ?? FALLBACK_LAUNCHERS;

  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;

  const health = (await Bridge.integrationsHealth()) ?? [];
  const crashes = (await Bridge.crashReports()) ?? [];

  clear(root);
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
  );
  const welcome = welcomeSection(providers, hasKey, status.installed, launchers);
  if (welcome) root.append(welcome);
  root.append(
    claudeSection(status),
    aiSection(providers),
    launcherSection(launchers),
    integrationsSection(present, health),
    generalSection(),
    securitySection(),
    updateSection(),
    logSection(),
    crashSection(crashes),
    h("div", {
      class: "hint",
      text: "No telemetry. Network requests only go to the services you configure yourself.",
    }),
  );

  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
  });

  // Rust emits this every time the hidden Settings window is shown. A smoke run
  // never touches the network, so it skips the check entirely.
  if (smoke) {
    autoUpdateCheck = null;
  } else {
    void onEvent<null>("settings-opened", () => autoUpdateCheck?.());
  }

  // The smoke test uses this to prove the Settings webview actually rendered,
  // and that a fresh profile got the Welcome card rather than an empty page.
  void Bridge.settingsReady(welcome !== null);
}

void main();
