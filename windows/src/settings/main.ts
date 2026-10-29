// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { Bridge, onEvent, type CrashReport, type HookStatus, type IntegrationHealth, type LauncherCatalog, type LauncherOption, type ProviderInfo, type ProviderModelOption, type UpdateProgress, type CameraDeviceInfo } from "../core/bridge";
import { DEFAULT_SETTINGS, type Settings } from "../core/state";
import { h, clear, svg } from "../views/dom";
import { ICONS } from "../views/icons";

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
          ? "Mochi is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there."
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
        text: "coucou-hook.exe is not in place yet. Restart Mochi; if it still fails, build it with `cargo build -p coucou-hook`.",
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
          : "This removes Mochi's entries only. Your own hooks are left untouched.",
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
    h("h2", {}, h("span", { text: "Welcome to Mochi" })),
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
      h("label", { text: "Keep island visible" }),
      toggle(settings.keepVisible ?? true, (v) => { settings.keepVisible = v; void save(); }),
      h("span", { class: "hint", text: "Stay docked at the top of the screen (never auto-hide)" }),
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
    progress.append(h("span", { text: `Preparing Mochi ${target}…` }));
    try {
      await Bridge.updatesInstall();
      // On Windows the app exits so the installer can replace the running
      // files, so this line is only reached if the install did not start.
      notice("ok", "The installer has started. Mochi restarts when it finishes.");
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
        notice("ok", `Mochi ${version || "is"} is up to date.`);
        return;
      }
      feedback.append(
        h("div", { class: "notice ok" },
          h("strong", { text: `Mochi ${info.version} is available` }),
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
      text: "Updates come from signed GitHub Releases. Mochi checks the manifest, verifies the installer against its update key, and only installs after you click. Nothing runs in the background.",
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
              a.download = `mochi-audit-${new Date().toISOString().slice(0, 10)}.jsonl`;
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

function sentinelSection(): HTMLElement {
  const section = h("section", {});
  section.append(h("h2", {}, h("span", { text: "Security Sentinel & Network" })));
  section.append(
    h("div", {
      class: "hint",
      text: "Audit keamanan Windows (Firewall, BitLocker, Antivirus, UAC, Port), pemindaian perangkat LAN, dan diagnostik latensi jaringan (Paket 5 Blueprint).",
    }),
  );

  const buttonRow = h("div", { class: "row", style: "gap: 8px; flex-wrap: wrap;" });
  const resultBox = h("div", { class: "sentinel-result-box", style: "margin-top: 12px;" });

  const btnAudit = h("button", {
    class: "primary",
    text: "Audit Keamanan PC",
    onclick: async () => {
      btnAudit.disabled = true;
      clear(resultBox);
      resultBox.append(h("div", { class: "hint", text: "Menjalankan audit keamanan Windows…" }));
      try {
        const report = await Bridge.sentinelAudit();
        clear(resultBox);
        const scoreBadge = h("div", {
          class: "notice ok",
          style: "font-weight: 600; font-size: 14px; margin-bottom: 8px;",
          text: `Skor Keamanan PC: ${report.healthScore}/100 (${report.openPortsCount} Port TCP Listening)`,
        });
        resultBox.append(scoreBadge);

        for (const c of report.checks) {
          resultBox.append(
            h("div", { class: "row", style: "justify-content: space-between; border-bottom: 1px solid rgba(255,255,255,0.06); padding: 4px 0;" },
              h("span", { style: "font-size: 13px;", text: `${c.isPassed ? "✅" : "⚠️"} ${c.title}` }),
              h("span", { class: "path", text: c.statusText }),
            ),
          );
        }
      } catch (err) {
        clear(resultBox);
        resultBox.append(h("div", { class: "notice err", text: `Audit gagal: ${String(err)}` }));
      } finally {
        btnAudit.disabled = false;
      }
    },
  }) as HTMLButtonElement;

  const btnScan = h("button", {
    text: "Pindai Perangkat LAN",
    onclick: async () => {
      btnScan.disabled = true;
      clear(resultBox);
      resultBox.append(h("div", { class: "hint", text: "Memindai perangkat di jaringan lokal…" }));
      try {
        const scan = await Bridge.sentinelScan();
        clear(resultBox);
        resultBox.append(h("div", { class: "hint", text: scan.summaryText }));
        if (scan.devices.length > 0) {
          for (const d of scan.devices) {
            resultBox.append(
              h("div", { class: "row", style: "justify-content: space-between; padding: 4px 0;" },
                h("span", { style: "font-weight: 500;", text: d.ipAddress }),
                h("span", { class: "path", text: `${d.deviceTypeGuess} (${d.macAddress})` }),
              ),
            );
          }
        }
      } catch (err) {
        clear(resultBox);
        resultBox.append(h("div", { class: "notice err", text: `Scan gagal: ${String(err)}` }));
      } finally {
        btnScan.disabled = false;
      }
    },
  }) as HTMLButtonElement;

  const btnDiag = h("button", {
    text: "Diagnostik Koneksi",
    onclick: async () => {
      btnDiag.disabled = true;
      clear(resultBox);
      resultBox.append(h("div", { class: "hint", text: "Menguji latensi ping & DNS…" }));
      try {
        const diag = await Bridge.sentinelDiagnostics();
        clear(resultBox);
        resultBox.append(h("div", { class: "notice ok", text: diag.summaryText }));
      } catch (err) {
        clear(resultBox);
        resultBox.append(h("div", { class: "notice err", text: `Diagnostik gagal: ${String(err)}` }));
      } finally {
        btnDiag.disabled = false;
      }
    },
  }) as HTMLButtonElement;

  buttonRow.append(btnAudit, btnScan, btnDiag);
  section.append(buttonRow, resultBox);
  return section;
}

function memorySection(): HTMLElement {
  const section = h("section", {});
  section.append(h("h2", {}, h("span", { text: "JARVIS Long-Term Memory" })));
  section.append(
    h("div", {
      class: "hint",
      text: "Fakta preferensi dan konteks jangka panjang tentang pengguna yang disuntikkan secara dinamis ke system prompt AI.",
    }),
  );

  const container = h("div", { style: "margin-top: 8px;" });

  const inputRow = h("div", { class: "row", style: "gap: 8px; margin-bottom: 8px;" });
  const inputFact = h("input", {
    type: "text",
    placeholder: "Tambahkan fakta baru (misal: 'Saya menyukai TypeScript dan Rust')",
    style: "flex: 1; min-width: 260px;",
  }) as HTMLInputElement;

  const btnAdd = h("button", {
    class: "primary",
    text: "Ingat Fakta",
    onclick: async () => {
      const val = inputFact.value.trim();
      if (!val) return;
      try {
        await Bridge.memoryRemember(val);
        inputFact.value = "";
        void renderList();
      } catch (err) {
        console.error("Gagal menyimpan memori", err);
      }
    },
  });

  inputRow.append(inputFact, btnAdd);
  section.append(inputRow);

  async function renderList() {
    clear(container);
    try {
      const items = (await Bridge.memoryAll()) ?? [];
      if (items.length === 0) {
        container.append(h("div", { class: "hint", text: "Belum ada fakta yang tersimpan di memori jangka panjang." }));
        return;
      }
      for (const item of items) {
        const row = h("div", { class: "row", style: "justify-content: space-between; padding: 4px 0; border-bottom: 1px solid rgba(255,255,255,0.06);" },
          h("span", { style: "font-size: 13px;", text: `• ${item.fact}` }),
          h("button", {
            class: "danger",
            style: "padding: 2px 8px; font-size: 11px;",
            text: "Lupakan",
            onclick: async () => {
              await Bridge.memoryForget(item.id);
              void renderList();
            },
          }),
        );
        container.append(row);
      }
    } catch (err) {
      container.append(h("div", { class: "notice err", text: `Gagal memuat memori: ${String(err)}` }));
    }
  }

  void renderList();
  section.append(container);
  return section;
}

// ── Desktop & Server App Integrations Section ───────────────────────────────

function appIntegrationsSection() {
  const section = h("section", { id: "app-integrations" });
  section.append(h("h2", {}, h("span", { text: "Desktop & Server App Integrations" })));
  section.append(
    h("div", {
      class: "hint",
      text: "Integrasi sistem komputer lokal: pemantauan aplikasi aktif, peluncur aplikasi, Git repository, dan Docker Desktop.",
    }),
  );

  // Quick Launcher Buttons
  const launcherRow = h("div", { class: "row", style: "gap: 6px; flex-wrap: wrap; margin-top: 8px;" });
  const appList = [
    { label: "VS Code", id: "vscode" },
    { label: "Cursor", id: "cursor" },
    { label: "Terminal", id: "terminal" },
    { label: "PowerShell", id: "powershell" },
    { label: "Notepad", id: "notepad" },
    { label: "Explorer", id: "explorer" },
    { label: "Task Manager", id: "taskmgr" },
  ];
  for (const item of appList) {
    const btn = h("button", {
      class: "primary",
      style: "font-size: 11px; padding: 4px 8px;",
      text: item.label,
      onclick: async () => {
        try {
          const res = await Bridge.appsLaunch(item.id);
          alertContainer.innerText = res;
          alertContainer.style.display = "block";
        } catch (e) {
          alertContainer.innerText = String(e);
          alertContainer.style.display = "block";
        }
      },
    });
    launcherRow.append(btn);
  }
  section.append(launcherRow);

  const alertContainer = h("div", {
    class: "notice ok",
    style: "display: none; margin-top: 8px; font-size: 12px;",
  });
  section.append(alertContainer);

  // Running Apps Box
  const runningBox = h("div", { style: "margin-top: 14px; background: rgba(0,0,0,0.2); padding: 8px; border-radius: 6px;" });
  const runningHeader = h("div", { class: "row", style: "justify-content: space-between; margin-bottom: 6px;" },
    h("strong", { style: "font-size: 12px;", text: "Aplikasi Desktop yang Sedang Terbuka" }),
    h("button", {
      style: "font-size: 11px; padding: 2px 6px;",
      text: "Refresh Apps",
      onclick: () => void loadRunningApps(),
    }),
  );
  const runningList = h("div", { style: "font-size: 12px; max-height: 140px; overflow-y: auto;" });
  runningBox.append(runningHeader, runningList);
  section.append(runningBox);

  async function loadRunningApps() {
    clear(runningList);
    runningList.append(h("span", { class: "hint", text: "Memuat aplikasi aktif..." }));
    const apps = (await Bridge.appsListRunning()) ?? [];
    clear(runningList);
    if (apps.length === 0) {
      runningList.append(h("span", { class: "hint", text: "Tidak ada aplikasi desktop dengan jendela aktif." }));
      return;
    }
    for (const a of apps) {
      const row = h("div", { class: "row", style: "justify-content: space-between; padding: 2px 0; border-bottom: 1px solid rgba(255,255,255,0.03);" },
        h("span", { text: `• ${a.processName} (PID: ${a.pid})` }),
        h("span", { class: "dim", style: "font-size: 11px; max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;", text: a.windowTitle }),
      );
      runningList.append(row);
    }
  }

  // Docker & Git Row
  const opsRow = h("div", { class: "row", style: "gap: 8px; margin-top: 10px;" },
    h("button", {
      style: "font-size: 11px;",
      text: "Cek Docker Containers",
      onclick: async () => {
        opsOutput.innerText = "Memeriksa status Docker Desktop...";
        opsOutput.style.display = "block";
        const res = await Bridge.appsDockerStatus();
        opsOutput.innerText = res ? res.summaryMarkdown : "Docker tidak tersedia.";
      },
    }),
    h("button", {
      style: "font-size: 11px;",
      text: "Cek Git Status Proyek",
      onclick: async () => {
        opsOutput.innerText = "Memeriksa status Git repository...";
        opsOutput.style.display = "block";
        const res = await Bridge.appsGitStatus();
        opsOutput.innerText = res ? res.summaryMarkdown : "Bukan repositori Git.";
      },
    }),
  );
  section.append(opsRow);

  const opsOutput = h("pre", {
    style: "display: none; margin-top: 8px; font-size: 11px; background: rgba(0,0,0,0.4); padding: 8px; border-radius: 6px; white-space: pre-wrap;",
  });
  section.append(opsOutput);

  void loadRunningApps();
  return section;
}

function webcamSection(): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const section = h(
    "section",
    {},
    h("h2", {}, h("span", { text: "📷 Kamera & Webcam" })),
    body,
  );

  const deviceList = h("div", { style: "display:flex;flex-direction:column;gap:6px" });
  const previewBox = h("div", {
    style: "display:none;margin-top:10px;padding:10px;background:rgba(0,0,0,0.4);border-radius:10px;border:1px solid var(--hairline);",
  });
  const previewImg = h("img", {
    style: "max-width:100%;max-height:220px;border-radius:8px;object-fit:contain;display:block;margin:0 auto;",
  });
  const previewInfo = h("div", { class: "hint", style: "margin-top:6px;text-align:center;" });
  previewBox.append(previewImg, previewInfo);

  const statusText = h("div", { class: "hint" });
  const captureBtn = h("button", {
    class: "primary",
    text: "Ambil Foto Uji Coba",
    onclick: async () => {
      captureBtn.setAttribute("disabled", "true");
      statusText.textContent = "Mengakses sensor kamera...";
      try {
        const snap = await Bridge.cameraCapture();
        if (snap) {
          previewImg.setAttribute("src", `data:image/jpeg;base64,${snap.base64Image}`);
          previewInfo.textContent = `Tersimpan: ${snap.filePath} (${Math.round(snap.sizeBytes / 1024)} KB) • ${snap.timestamp}`;
          previewBox.style.display = "block";
          statusText.textContent = "Foto berhasil diambil. Sensor kamera telah dinonaktifkan kembali.";
        }
      } catch (err) {
        statusText.textContent = `❌ ${err}`;
      } finally {
        captureBtn.removeAttribute("disabled");
      }
    },
  });

  const refreshBtn = h("button", {
    text: "Pindai Kamera",
    onclick: () => void loadCameras(),
  });

  async function loadCameras() {
    clear(deviceList);
    deviceList.append(h("div", { class: "hint", text: "Memeriksa perangkat kamera terhubung..." }));
    const cameras = await Bridge.cameraList();
    clear(deviceList);
    if (!cameras || cameras.length === 0) {
      deviceList.append(h("div", { class: "hint", text: "Tidak ditemukan kamera atau webcam pada komputer ini." }));
      return;
    }
    const webcams = cameras.filter((c: CameraDeviceInfo) => c.isWebcam);
    const displayList = webcams.length > 0 ? webcams : cameras;
    for (const cam of displayList) {
      deviceList.append(
        h(
          "div",
          { class: "row", style: "gap:8px" },
          statusDot(cam.status.toLowerCase() === "ok"),
          h("b", { text: cam.name, style: "font-size:12px;" }),
          h("span", { class: "hint", text: cam.isWebcam ? "Webcam Siap" : "Image Device" }),
        ),
      );
    }
  }

  body.append(
    h("div", {
      class: "hint",
      text: "Integrasi sensor visual untuk analisis multimodal AI (Vision VLM). Sensor kamera hanya menyala sesaat ketika memotret dan langsung dimatikan (0% CPU idle, privacy protected).",
    }),
    deviceList,
    h("div", { class: "row", style: "gap:8px;margin-top:6px;" }, captureBtn, refreshBtn),
    statusText,
    previewBox,
  );

  void loadCameras();
  return section;
}

interface SettingsTab {
  id: string;
  label: string;
  iconSvg: SVGSVGElement;
  sections: HTMLElement[];
}

function buildTabs(tabs: SettingsTab[]): HTMLElement {
  const container = h("div", { class: "tabs-container" });
  const nav = h("div", { class: "tabs-nav", role: "tablist", "aria-label": "Settings Tabs" });
  const panesWrapper = h("div", { class: "tab-panes" });

  let savedTab = "general";
  try {
    savedTab = localStorage.getItem("mochi-settings-active-tab") || "general";
  } catch {
    // ignore
  }
  if (!tabs.some((t) => t.id === savedTab)) {
    savedTab = tabs[0]?.id || "general";
  }

  const buttons: HTMLButtonElement[] = [];
  const panes: HTMLElement[] = [];

  function switchTab(id: string) {
    for (let i = 0; i < tabs.length; i++) {
      const tab = tabs[i];
      const btn = buttons[i];
      const pane = panes[i];
      const isActive = tab.id === id;
      btn.classList.toggle("active", isActive);
      btn.setAttribute("aria-selected", String(isActive));
      btn.tabIndex = isActive ? 0 : -1;
      pane.classList.toggle("hidden", !isActive);
      pane.setAttribute("aria-hidden", String(!isActive));
    }
    try {
      localStorage.setItem("mochi-settings-active-tab", id);
    } catch {
      // ignore
    }
  }

  tabs.forEach((tab, index) => {
    const isActive = tab.id === savedTab;
    const btn = h(
      "button",
      {
        class: isActive ? "tab-btn active" : "tab-btn",
        role: "tab",
        id: `tab-btn-${tab.id}`,
        "aria-selected": String(isActive),
        "aria-controls": `tab-pane-${tab.id}`,
        tabIndex: isActive ? 0 : -1,
        onclick: () => switchTab(tab.id),
      },
      tab.iconSvg,
      h("span", { text: tab.label }),
    );

    btn.addEventListener("keydown", (e: KeyboardEvent) => {
      if (e.key === "ArrowRight") {
        const next = (index + 1) % tabs.length;
        buttons[next].focus();
        switchTab(tabs[next].id);
      } else if (e.key === "ArrowLeft") {
        const prev = (index - 1 + tabs.length) % tabs.length;
        buttons[prev].focus();
        switchTab(tabs[prev].id);
      }
    });

    buttons.push(btn);
    nav.append(btn);

    const pane = h(
      "div",
      {
        class: isActive ? "tab-pane" : "tab-pane hidden",
        role: "tabpanel",
        id: `tab-pane-${tab.id}`,
        "aria-labelledby": `tab-btn-${tab.id}`,
        "aria-hidden": String(!isActive),
      },
      ...tab.sections,
    );
    panes.push(pane);
    panesWrapper.append(pane);
  });

  container.append(nav, panesWrapper);
  return container;
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
    h("h1", {}, h("span", { text: "Mochi" }), h("span", { class: "version", text: version })),
  );
  const welcome = welcomeSection(providers, hasKey, status.installed, launchers);
  if (welcome) root.append(welcome);
  const tabs: SettingsTab[] = [
    {
      id: "general",
      label: "General",
      iconSvg: svg(ICONS.gear, 13),
      sections: [
        generalSection(),
        claudeSection(status),
        launcherSection(launchers),
      ],
    },
    {
      id: "ai",
      label: "AI & Models",
      iconSvg: svg(
        "M12 2a2 2 0 0 1 2 2c0 .74-.4 1.39-1 1.73V7h1a7 7 0 0 1 7 7h1a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1h-1v1a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-1H2a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1h1a7 7 0 0 1 7-7h1V5.73c-.6-.34-1-.99-1-1.73a2 2 0 0 1 2-2zM7.5 13A1.5 1.5 0 1 0 9 14.5 1.5 1.5 0 0 0 7.5 13zm9 0a1.5 1.5 0 1 0 1.5 1.5 1.5 1.5 0 0 0-1.5-1.5z",
        13,
      ),
      sections: [aiSection(providers)],
    },
    {
      id: "integrations",
      label: "Integrations",
      iconSvg: svg("M4 4h7v7H4V4zm9 0h7v7h-7V4zm-9 9h7v7H4v-7zm9 0h7v7h-7v-7z", 13),
      sections: [
        appIntegrationsSection(),
        integrationsSection(present, health),
      ],
    },
    {
      id: "security",
      label: "Security & Sentinel",
      iconSvg: svg(
        "M12 2L4 5v6.09c0 5.05 3.41 9.76 8 10.91 4.59-1.15 8-5.86 8-10.91V5l-8-3zm0 2.18l6 2.25v4.66c0 4.14-2.73 8.01-6 9.07-3.27-1.06-6-4.93-6-9.07V6.43l6-2.25z",
        13,
      ),
      sections: [
        securitySection(),
        sentinelSection(),
        webcamSection(),
      ],
    },
    {
      id: "memory",
      label: "Memory",
      iconSvg: svg(
        "M12 3c-4.97 0-9 4.03-9 9 0 2.12.74 4.07 1.97 5.61L4.35 21l3.39-.62C9.17 20.73 10.54 21 12 21c4.97 0 9-4.03 9-9s-4.03-9-9-9zm0 2c3.87 0 7 3.13 7 7s-3.13 7-7 7c-1.28 0-2.48-.35-3.52-.96l-.25-.15-2.02.37.37-2.02-.15-.25C5.83 14.95 5.5 13.52 5.5 12c0-3.87 3.13-7 6.5-7z",
        13,
      ),
      sections: [memorySection()],
    },
    {
      id: "system",
      label: "System & Logs",
      iconSvg: svg(
        "M22.7 19l-9.1-9.1c.9-2.3.4-5-1.5-6.9-2-2-5-2.4-7.4-1.3L9 6 6 9 1.6 4.7C.5 7.1.9 10.1 2.9 12.1c1.9 1.9 4.6 2.4 6.9 1.5l9.1 9.1c.4.4 1 .4 1.4 0l2.3-2.3c.5-.4.5-1.1.1-1.4z",
        13,
      ),
      sections: [
        updateSection(),
        logSection(),
        crashSection(crashes),
      ],
    },
  ];

  root.append(
    buildTabs(tabs),
    h("div", {
      class: "hint",
      style: "text-align: center; margin-top: 12px;",
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
