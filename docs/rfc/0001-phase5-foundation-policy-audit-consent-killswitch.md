# RFC 0001 — Phase 5 foundation: policy, audit, consent, and kill switch

- **Status:** Review
- **Author:** Coucou Windows
- **Reviewers:** security, Windows maintainers
- **Created:** 2026-10-26
- **Last updated:** 2026-10-26
- **Threat model:** [`../threat-models/0001-phase5-foundation-policy-audit-consent-killswitch.md`](../threat-models/0001-phase5-foundation-policy-audit-consent-killswitch.md)
- **Target phase:** 5.0

## Summary

Build the safety foundation every later Phase 5 capability must use: a
default-deny policy engine, a single authorisation gate, a local audit trail, a
consent flow, and a kill switch that survives a crash or restart.

This RFC deliberately ships **no new user-facing capability**. MCP, clipboard
and filesystem watchers, voice, memory/RAG, Telegram, autonomous tools, and
screen automation are separate RFCs. They cannot be implemented until this
foundation is accepted and merged, because each one needs the gate described
here.

## Motivation

The Windows app currently performs a small, auditable set of actions: open a
URL, open an editor or terminal at a validated folder, write Claude Code hooks
after a preview, and store secrets in the Credential Manager. Every one is
triggered by an explicit click.

Phase 5 changes that. A watcher reacts to files, a model decides which tool to
call, a remote Telegram message can start work, and an automation loop can act
without a click. Without a central gate, each feature would invent its own
permission checks, log format, and pause behaviour. The predictable result is a
feature that forgets one of them.

The foundation is intentionally built first and kept boring: a static
capability list, deny by default, one path to execute a risky action, and an
audit file that never contains the sensitive content itself.

## Goals

- One Rust gateway that every risky action must pass through; no front-end or
  feature module may call the underlying Windows API directly.
- Deny by default, including when policy is missing, corrupt, or written by a
  newer schema.
- Explicit, scoped consent for background and autonomous actions, with a
  default-deny timeout.
- A local, append-only, tamper-evident audit trail with content redacted before
  it is written.
- A kill switch that stops new work immediately, cancels queued work, and stays
  engaged across a crash or restart until the user deliberately re-enables it.
- Tests that prove deny-by-default, expiry, scope normalisation, kill-switch
  latency, and audit redaction.

## Non-goals

- No MCP client, watcher, voice pipeline, memory store, Telegram gateway,
  autonomous planner, or screen control. Later RFCs consume this foundation.
- No remote policy service, enterprise MDM integration, or account-level
  enforcement. Policy is local to this Windows user.
- No defence against a same-user attacker who can debug the process, replace
  the binary, or read the Credential Manager. The audit chain is tamper-evident,
  not tamper-proof; the threat model says so explicitly.
- No "remember this forever" for irreversible actions.
- No change to the existing tray **Pause** (integration pollers). The new hard
  stop is a separate control with a separate, persisted state.

## Risk classification

The foundation itself executes no risky action. It defines the following
capability classes; every future feature maps to exactly one class (or several,
if it performs several kinds of work).

| Capability class | Examples | Default | Reversible |
|---|---|---|---|
| `fs.read` | read a user file, list a folder | denied | n/a |
| `fs.write` | create, modify, delete, move | denied | depends on operation |
| `net.request` | HTTP/S, WebSocket, webhook | denied | no |
| `process.run` | launch a program or script | denied | no |
| `app.control` | UI Automation, `SendInput`, window messages | denied | usually |
| `screen.capture` | desktop or window capture | denied | no |
| `remote.command` | Telegram or another remote trigger | denied | no |
| `autonomy` | multi-step work without a click | denied | no |
| `money.spend` | purchase, refund, paid API action | denied | no |

The static registry lives in Rust as an enum. Names are compiled in; a model or
remote payload cannot introduce a new capability string.

## User experience and consent

The user meets the foundation in three places.

### Settings → Security

A read-only summary by default:

- **Automation:** Off / On, with the reason (killed, never enabled, or enabled).
- **Capabilities:** one row per registered capability, showing **Off**,
  **Allowed once**, **Allowed for this session**, or **Always allowed**, plus
  the scopes. In 5.0 every row is **Off** because no capability is registered
  yet; the section explains that advanced features will appear here.
- **Audit:** last 50 events, export button, folder button, retention note.
- **Kill switch:** **Stop all automation** with a confirmation. Re-enabling is a
  separate, explicit action.

### Consent card

Background or autonomous actions raise a card in the island, reusing the
existing approval-card pattern (always-on-top, non-activating until the user
chooses). The card shows:

- the capability in plain language ("Read a file", "Run a command");
- the concrete target (`C:\Users\…\Downloads\invoice.pdf`, window title,
  recipient);
- what data will be read and what will leave the machine;
- **Allow once**, **Allow for this session**, **Deny**;
- a countdown (30 seconds by default) and "Deny" as the default on timeout.

**Always allow** is not offered for `process.run`, `money.spend`,
`remote.command`, `autonomy`, or any `fs.write` operation classified as
irreversible. Those always require a fresh decision, though the user may grant
a session allowance for a narrow scope.

If the island cannot render the card (app shutting down, webview crashed, UI
not ready), the action is denied. There is no fallback that runs it silently.
User-initiated actions from Coucou's own UI (clicking a button that opens the
editor, sending a chat message) use the explicit-user-action basis and do not
show a second dialog; they are still audited.

### Tray

The existing menu keeps **Pause** (integration pollers). A new **Stop all
automation** item runs the hard stop described below. It is visible even when
no capability is registered, so the control is familiar before it matters.

## Design

### Architecture

```
front end (island / settings)
   │  user click only
   ▼
Tauri command ──────────────┐
                            │  ConsentBasis::UserAction
background module ──────────┤
(MCP, watcher, Telegram)    │  ConsentBasis::Background
                            ▼
                 security::gate::authorize(request)
                            │
              ┌─────────────┼──────────────┐
              ▼             ▼              ▼
         policy check   consent card   kill switch
              │             │              │
              └─────────────┴──────────────┘
                            ▼
                     ActionGrant (opaque)
                            ▼
                    feature executor
                            ▼
                 Windows API / network / file
                            ▼
                 audit start + audit result
```

`ActionGrant` has private fields and no public constructor outside
`security::gate`. An executor function takes `ActionGrant` by value, so "did I
check policy?" becomes a compile-time question for Rust callers rather than a
review checklist. The front end never receives a grant; it only receives the
result of a command.

The gate is called from Rust action executors, not from JavaScript. A new
capability must be registered in the static `Capability` enum and mapped to an
executor; unknown strings are refused before any policy lookup.

### Modules

```
src-tauri/src/security/
  mod.rs        public API: authorize(), decide(), kill(), status()
  policy.rs     schema, load/save, normalisation, precedence
  gate.rs       ActionRequest, ActionGrant, queue, cancellation
  consent.rs    pending requests, single-use tokens, expiry
  audit.rs      append-only JSONL, hash chain, redaction, rotation
  killswitch.rs persisted hard-stop state and latency path
```

Settings and tray call a small set of commands:

| Command | Purpose |
|---|---|
| `security_status` | policy summary + kill-switch state + capabilities |
| `security_set_capability` | change a grant; requires an explicit click and confirmation for high-risk classes |
| `security_consent_decide` | answer a pending card (`allow_once`, `allow_session`, `deny`) |
| `security_kill` | engage the hard stop and persist it |
| `security_resume` | clear the hard stop after an explicit confirmation; does not restore capability grants |
| `audit_recent` / `audit_export` | read/export sanitised local events |
| `audit_open_folder` | open `%LOCALAPPDATA%\Coucou\audit` |

### Policy file

`%APPDATA%\Coucou\security.json`, separate from `settings.json` so a preference
reset cannot silently reset permissions.

```json
{
  "schemaVersion": 1,
  "automationEnabled": false,
  "killSwitchEngaged": false,
  "capabilities": {
    "fs.read": {
      "mode": "denied",
      "scopes": []
    }
  }
}
```

- `mode` is `denied`, `session`, or `always`. `session` grants live in memory
  only and disappear when the process exits.
- Scopes are structured, not free-form paths: `{ "kind": "folder", "path":
  "C:\\Users\\Me\\Downloads" }`, `{ "kind": "window", "process":
  "notepad.exe" }`, `{ "kind": "recipient", "id": "telegram:123456" }`.
- Missing file → deny everything, `automationEnabled: false`.
- Corrupt JSON or an unknown `schemaVersion` > 1 → deny everything, keep the
  file untouched, surface a Settings warning, and write an audit event.
- A schema downgrade (`schemaVersion` lower than the running build expects) is
  accepted only through an explicit migration; it never re-enables a grant.
- File permissions: current user only (inherited ACL from `%APPDATA%`), no
  secrets, written atomically (temp file + replace).
- Changes take effect immediately. Revoking a grant cancels queued requests for
  that capability; it cannot undo an OS call already in flight, which is
  audited as `outcome: in_flight`.

### Scope normalisation

Windows path rules are part of the security boundary, so they are explicit:

- canonicalise with `GetFinalPathNameByHandle`-equivalent behaviour where the
  target exists; otherwise normalise lexically and refuse `..` segments;
- compare case-insensitively, strip trailing dots/spaces, reject reserved device
  names and alternate data streams for write scopes;
- expand no environment variables in stored scopes;
- match folders by component boundary, not string prefix (`C:\Data` must not
  match `C:\DataBackup`);
- resolve symlinks/reparse points and refuse a scope that changes after
  canonicalisation;
- a scope applies to one capability class only. `fs.read` on a folder does not
  imply `fs.write` there.

A scope that fails normalisation is a deny, not a best-effort match.

### Consent state machine

```
Idle ──request──► Pending ──allow_once──► Granted ──used──► Consumed
                    │  └────allow_session──► SessionGrant
                    ├────deny──────────────► Denied
                    ├────timeout (30 s)────► Denied
                    └────kill switch───────► Cancelled
```

- Each request has a random 128-bit id, a hash of the exact capability + scope +
  action arguments, and an expiry. The decision must include the id; a decision
  for a different argument hash is refused.
- Tokens are single-use. `allow_session` creates a session grant with the same
  scope and capability, not a wildcard.
- Only one card is shown at a time. A second background request queues; if the
  queue is full (8), new requests are denied and audited.
- The card is owned by the island webview. Closing it, killing the app, or
  losing the webview denies the request.
- The consent decision command is only accepted from the consent window's
  label; the front end cannot answer for a request it was not shown.

### Audit trail

`%LOCALAPPDATA%\Coucou\audit\audit-YYYY-MM.jsonl`, one JSON object per line.

```json
{"v":1,"ts":"2026-10-26T14:02:11.482Z","id":"…","event":"action_denied",
 "capability":"fs.read","scope":"folder","target":"~/Downloads",
 "decision":"deny","rule":"default_deny","outcome":"not_run","app":"0.1.1",
 "prev":"…","mac":"…"}
```

- **Allowlisted fields only.** No file contents, clipboard text, chat messages,
  full URLs with query strings, tokens, or email bodies.
- `target` is a short human label supplied by the executor (home directory
  replaced with `~`), capped at 160 characters and sanitised through the
  existing log sanitiser. Executors may omit it and log only `scope`.
- Events: `action_requested`, `action_allowed`, `action_denied`,
  `consent_shown`, `consent_decided`, `consent_expired`, `action_started`,
  `action_succeeded`, `action_failed`, `action_cancelled`, `kill_engaged`,
  `kill_released`, `policy_changed`, `policy_invalid`.
- Retention: monthly files, 10 MB per file hard cap, 30 days or 20 files,
  whichever comes first. The export button writes a sanitised copy of the
  selected range; it never uploads.
- Integrity: each line carries `prev` (previous line's `mac`) and `mac`
  (HMAC-SHA-256 over the canonical JSON without `mac`, keyed by a random key in
  the Credential Manager under `coucou-audit-hmac`). The first line of each file
  chains from the previous file's last `mac`. If the key or the file cannot be
  written, risky actions are denied until the user fixes the audit folder; the
  UI says why.
- The HMAC key is generated on first use and never leaves the Credential
  Manager. Losing it breaks chain verification for new events; the UI shows
  "integrity unavailable" rather than deleting old lines.

### Kill switch

Two levels, deliberately distinct:

| Control | Scope | Persistence |
|---|---|---|
| Tray **Pause** (existing) | integration pollers only | session |
| Tray/Settings **Stop all automation** | gate + autonomy + pollers | persists across restart |

Hard stop semantics:

1. Set `killSwitchEngaged = true` and `automationEnabled = false` in
   `security.json`, flushing before returning from the click.
2. Stop accepting new gate requests; existing queued requests are cancelled and
   audited as `action_cancelled`; pending consent cards are closed and denied.
3. Signal cancellation tokens for in-flight cancellable work (HTTP requests,
   child processes) and call `integrations::set_paused(true)`.
4. New actions are refused within 100 ms of the click. Cancellable work stops
   within 2 seconds; an OS call already in flight is reported as `in_flight`.
5. On restart, the persisted state is read before any background module starts,
   so automation is still off. `security_resume` is the only way to clear it and
   does not restore capability grants or `automationEnabled`.
6. Manual, user-initiated actions (chat, opening Settings, clicking a link) stay
   available; the kill switch stops background and autonomous work, not the
   whole app. Quit remains a separate tray action.

The latency target is tested with a queued action and a fake executor, not by
timing a real OS call.

### Interaction with existing features

- The existing `set_paused` command and tray item keep their current meaning.
  The hard stop also pauses pollers, but resuming automation does not resume
  them automatically; the tray state stays user-controlled.
- Hook installation, secret writes, and editor/terminal launches keep their
  current explicit-click flow. They are not routed through consent, but the
  security-relevant ones (`hooks_apply`, `secret_set`, `secret_clear`) emit an
  audit event (`action_succeeded` with `basis: user_action`). This proves the
  audit sink works without changing their UX.
- No Phase 5 module is registered in 5.0. The Settings section shows the
  foundation as ready and empty; the first consumer arrives in 5.1.

## Failure modes

| Failure | User sees | System does |
|---|---|---|
| `security.json` missing | "Permissions not set up" in Settings | deny all risky actions; create a default deny file on first explicit change |
| `security.json` corrupt | warning + **Reset permissions** | deny all; keep the corrupt file as `.corrupt-<date>` for diagnosis; audit `policy_invalid` |
| schema newer than build | "This file was written by a newer Coucou" | deny all; do not rewrite it |
| audit folder unwritable | "Audit log unavailable — actions are blocked" | deny risky actions; read-only UI still works |
| audit HMAC key unavailable | "Integrity check unavailable" | append unkeyed events only if the user explicitly continues; high-risk capabilities stay denied |
| consent card not rendered | card never appears; 30 s later | deny, audit `consent_expired` |
| consent decision raced with kill | card closes | deny, audit `action_cancelled` |
| app crashes mid-action | next launch shows "Automation stopped after an unexpected exit" | `killSwitchEngaged` persists; in-flight work is gone with the process; child processes are job-object bound and killed |
| policy revoked while action queued | queued request disappears | deny, audit `action_cancelled` |
| user changes system clock | countdown looks wrong | expiry uses monotonic time; wall clock only for display |

## Observability and logs

- Security events go to the audit file, not the general log. The general log
  gets a single line per hard stop and per policy parse failure.
- Audit export is explicit and local. Nothing is uploaded.
- Settings shows the last 50 events and a count of denied actions in the last
  24 hours, so a silent deny loop is visible.
- Debug builds may print capability names and decisions to the console; release
  builds do not print scopes or targets.

## Privacy

- All policy and audit data stay in the user's profile.
- Audit targets use short labels and `~` for the home directory; no file
  contents, message bodies, clipboard text, or secret values.
- The HMAC key lives in the Credential Manager only.
- No telemetry, no remote policy, no analytics.

## Rollout

- 5.0 adds the modules, commands, Settings section, tray item, and tests. Every
  capability is unregistered and every grant is denied.
- No migration of `settings.json` is needed. `security.json` is created lazily
  on the first explicit policy change.
- If the foundation misbehaves in a release, the fallback is to deny all risky
  actions (the app keeps working for chat, hooks, files, and integrations). The
  kill switch and audit remain available.
- Later RFCs must add their capability to the static registry and provide
  executor-level tests; the gate API is not bypassed.

## Testing

Unit (Rust):

- policy: missing, corrupt, future schema, downgrade, unknown capability,
  default deny, session grant expiry, atomic write;
- scope: `..`, case differences, trailing dot/space, `C:\Data` vs
  `C:\DataBackup`, symlink/reparse change, reserved device names, UNC paths;
- consent: single use, 30 s expiry with monotonic clock, id mismatch, argument
  hash mismatch, queue overflow, decision from the wrong window;
- audit: field allowlist, sanitisation of a fake token and newline injection,
  HMAC chain continues across rotation, unkeyed fallback is marked, export
  redaction;
- kill switch: persisted before return, restart stays off, queued request
  cancelled, in-flight result reported.

Integration / runtime:

- a test-only executor behind `cfg(test)` (or a debug-only command) proves
  allow-once, deny, expire, and kill-switch cancellation without touching the
  real filesystem or network;
- a smoke check asserts Settings renders the Security section and the tray item
  exists;
- manual UAT on Windows 10 and 11 as a standard user: kill, restart, verify
  automation stays off; re-enable; corrupt the policy file and verify deny.

## Alternatives considered

- **Per-feature permission checks.** Rejected: the failure mode is a feature
  that forgets a check, and the audit format drifts.
- **A prompt-only policy with no persisted state.** Rejected: a restart would
  silently return to the previous behaviour, and there is no way to revoke a
  capability while the app is closed.
- **Remote policy / account-level enforcement.** Rejected for now: Coucou has no
  account system or backend, and adding one expands the privacy surface for no
  immediate benefit.
- **Reuse the general log as the audit trail.** Rejected: the log rotates at
  1 MB, has no integrity chain, and mixes UI noise with security events.
- **A separate consent webview.** Rejected: WebView2 in this app has one browser
  environment, and a third window created later comes up blank (see
  `create_settings_window`). The island card is the reliable surface.
- **Allow-by-default with a warning.** Rejected: incompatible with the threat
  model and with the product promise that nothing runs without a click.

## Open questions

- [ ] Should `security.resume` require typing a phrase, or is a confirmation
  dialog with the capability list enough? Owner: UX, before implementation.
- [ ] Should the audit HMAC key be rotated yearly? Rotating breaks the chain
  across the rotation boundary unless the new key signs the old tail. Owner:
  security, before 5.1.
- [ ] Does the Settings audit list need a per-capability filter in 5.0, or can
  it wait until there is more than one capability? Owner: Windows, before
  implementation.
- [ ] The 100 ms/2 s latency targets need to be measured on a low-end Windows 10
  machine. Owner: QA, during 5.0 UAT.

## References

- OWASP ASVS v4: authentication, access control, logging.
- Microsoft: `GetFinalPathNameByHandle`, job objects, UI Automation security
  considerations.
- Tauri v2 command/capability documentation.
- Coucou `docs/PLAN-windows.md`, Phase 5.
- Related threat model: `../threat-models/0001-phase5-foundation-policy-audit-consent-killswitch.md`.
