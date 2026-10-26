# Threat model 0001 — Phase 5 foundation: policy, audit, consent, kill switch

- **Status:** Review
- **RFC:** [`../rfc/0001-phase5-foundation-policy-audit-consent-killswitch.md`](../rfc/0001-phase5-foundation-policy-audit-consent-killswitch.md)
- **Author:** Coucou Windows
- **Reviewers:** security, Windows maintainers
- **Created:** 2026-10-26
- **Last updated:** 2026-10-26
- **Review scope:** the gate, policy file, consent flow, audit sink, and kill
  switch added in 5.0, plus the existing commands that start writing audit
  events

## System in scope

The foundation runs inside the Coucou Tauri process (Rust) and is rendered by
the island and Settings webviews. It owns permission decisions and the audit
file. It does not yet execute a Phase 5 capability; the first consumer arrives
in 5.1.

The trust boundary is between untrusted input (model output, remote payloads,
files, clipboard, web content) and the Windows APIs a future feature will call.
Every crossing must pass `security::gate::authorize`. The webview is treated as
untrusted for *authorisation decisions* even though it is our code: a bug or a
future injection must not be able to mark a background action as user-initiated.

```
model / remote / file / clipboard
        │  untrusted data (never an authorisation decision)
        ▼
feature input validation + capability mapping (static enum)
        │
        ▼
policy check → consent card → kill switch
        │
        ▼
ActionGrant (Rust-only, opaque) → executor → Windows API
        │
        ▼
audit JSONL (content redacted, HMAC chain)
```

## Assets

| Asset | Why it matters | Where it lives |
|---|---|---|
| Credential Manager entries | provider keys, bot tokens, audit HMAC key | Windows Credential Manager |
| User documents | private content that a future watcher/agent can read | user profile, OneDrive, network shares |
| Claude Code sessions and repository content | commands, source code, prompts | local processes, named pipe, editor |
| Audit trail | accountability and incident reconstruction | `%LOCALAPPDATA%\Coucou\audit` |
| Policy file | the only thing standing between a model and a risky action | `%APPDATA%\Coucou\security.json` |
| User attention | consent is worthless if it can be bypassed or spoofed | island UI |
| Release/update chain | protects the binary that runs the gate | GitHub Release, minisign key |

## Adversaries

| Adversary | Capability | In scope? |
|---|---|---|
| Remote unauthenticated attacker | sends a malicious Telegram message, webhook payload, or MCP response | yes |
| Malicious or compromised content | prompt injection in a file, clipboard, web page, or model output | yes |
| Malicious local process (same user) | reads/writes `%APPDATA%`, injects input, races the kill switch | partially; see residual risk |
| Shoulder-surfer / unattended desktop | sees or clicks a consent card | partial |
| Supply-chain attacker | modifies a dependency, CI action, installer, or update feed | covered by signing RFCs; out of scope here |
| Administrator / kernel attacker | full control, can read Credential Manager and patch the binary | out of scope |

The honest boundary: a same-user process with debugging rights can read the
policy, replace the binary, and read the HMAC key from the Credential Manager.
The foundation prevents *silent, unauthorised action by Coucou's own features*;
it does not turn Windows into a multi-tenant sandbox.

## Trust boundaries and data flow

1. **Webview → Rust command.** Validate the command schema; never accept a
   capability string, scope object, or `user_initiated` flag from JavaScript.
   The Rust command knows its own capability and consent basis.
2. **Untrusted input → feature → gate.** A model can propose an action, but the
   feature maps it to the static `Capability` enum and a structured scope.
   Unknown tool names and free-form capability strings are refused.
3. **Gate → consent card.** The card receives a sanitised preview. It does not
   receive secret values or file contents; an executor that needs to show a
   content snippet must do so through a dedicated, size-capped path reviewed in
   its own RFC.
4. **Gate → executor.** `ActionGrant` is opaque and single-use. An executor
   cannot be called without one, and a grant for `fs.read` cannot be used for
   `fs.write`.
5. **Executor → audit sink.** Audit records are built from allowlisted fields,
   sanitised, and written before/after the action. An audit failure denies the
   risky action.
6. **CI → installed app.** Authenticode and the updater key protect the binary
   and updates; this threat model assumes those controls hold.

Malformed, oversized, and replayed input at each boundary is refused and
audited; it never degrades into "allow".

## Abuse cases

| # | Abuse case | Preconditions | Impact | Mitigation | Residual risk |
|---|---|---|---|---|---|
| 1 | Prompt injection tells an MCP tool to mark a background read as a user click | MCP client, model-controlled tool args | unauthorised file read | consent basis is chosen in Rust, never passed from JS; static capability mapping | a bug in a future feature could mislabel its own basis |
| 2 | A remote Telegram message replays an old `/run` command | paired bot token leaked | unauthorised action | message id/nonce cache, remote commands are capabilities, kill switch | token theft remains possible |
| 3 | Policy file is edited to `"mode":"always"` for `process.run` | same-user or malware | silent command execution | default deny, policy change audit, PID-owned file ACL, UI shows active grants | same-user attacker can edit the file; HMAC is not used for policy |
| 4 | Policy file is replaced with a valid older file | backup/rollback | re-enables a revoked grant | schema migration is explicit; downgrade never auto-grants; audit `policy_changed` | user-initiated restore is indistinguishable from an attack |
| 5 | Consent card is spoofed by a fullscreen window | unattended desktop | user approves a malicious target | card in the always-on-top island, shows target and data, no auto-focus steal, deny on close | determined UI spoofing / accessibility abuse |
| 6 | Consent id or argument hash is swapped after approval | compromised webview or local process | action runs on a different target | single-use token bound to capability + scope + args hash; decision must include the id | a compromised webview can still answer its own card |
| 7 | A second request queues behind the card and runs after the user denies the first | queue logic bug | unauthorised action | one card at a time, queue cap 8, deny cancels only its request, kill cancels all | user may misread which request they denied |
| 8 | Kill switch is pressed while an executor is about to call `CreateProcess` | race | process still starts | cancellation check immediately before the OS call; job object kills child; audit `in_flight` | a narrow race remains between the check and the syscall |
| 9 | Audit file is edited to remove a denied action | same-user access | no accountability | HMAC chain with key in Credential Manager; failed verification is shown | attacker who can read the key can re-forge the chain |
| 10 | Audit export includes a full path or token | exporter bug | privacy leak to a shared file | allowlisted fields, `~` home replacement, sanitiser, export test with fake secret | labels supplied by future features may be too verbose; review required |
| 11 | Disk full / audit folder unwritable | low disk, antivirus lock | risky action proceeds without a record | audit failure denies risky actions; UI explains | read-only actions still run |
| 12 | App crashes after writing `action_started` but before the result | crash, power loss | ambiguous audit | next launch marks the last started action `outcome: interrupted`; kill switch stays engaged | OS call may have completed |
| 13 | Malicious `security.json` with a huge scope list or deep JSON | local file | memory/CPU exhaustion at boot | size cap (64 KB), depth/schema limits, parse failure → deny | very low |
| 14 | Scope prefix collision (`C:\Data` matches `C:\DataBackup`) | future fs feature | reads/writes outside the granted folder | component-boundary matching, canonicalisation, traversal tests | reparse-point race on a live filesystem |
| 15 | User grants `fs.read` to a folder, then a symlink is swapped to `C:\Windows` | local attacker or sync client | reads system files | canonicalise and re-check immediately before the read; refuse if the final path leaves the scope | TOCTOU window between check and open |
| 16 | Kill switch state is lost on restart | crash during write | automation resumes silently | flush `killSwitchEngaged` before returning from the click; startup reads policy before starting background modules | disk corruption; UI shows the parsed state |
| 17 | Clock change extends a consent countdown | user/attacker changes system time | stale consent remains valid | expiry uses monotonic time; wall clock only for display | process suspend/resume may extend wall time, not the monotonic check |
| 18 | Audit HMAC key is deleted and the app treats old events as valid | Credential Manager reset | forged history accepted | mark events as unkeyed, show "integrity unavailable", do not claim verified | old events cannot be re-verified without the key |

## Mitigations

### Input validation and capability mapping

- Static `Capability` enum, compiled into the binary. No string-to-capability
  lookup from model or remote input.
- Structured scopes; no free-form shell strings.
- Schema, size, and depth limits for policy, consent previews, and audit fields.
- Path canonicalisation and component-boundary matching (see RFC).

### Authorisation

- Deny by default for every capability, every boot.
- `ActionGrant` is opaque, single-use, and scoped to one capability + scope.
- Consent basis is chosen by Rust code, not by the webview.
- High-risk classes cannot be "always allowed".
- Policy changes are explicit and audited; revoking a grant cancels queued work.

### Isolation

- Future executors run with a job object so child processes die with the app.
- No shell interpolation; arguments are separate.
- Dynamic tools get a separate RFC and a stronger sandbox; this foundation only
  provides the gate.

### Secrets and privacy

- Credential Manager only. Policy and audit files contain no secrets.
- Audit fields are allowlisted; redaction happens before the write.
- `~` replaces the home directory in target labels.
- No upload, no telemetry, no remote policy.

### Auditability

- Append-only JSONL with a hash chain and keyed MAC.
- Monthly rotation, size cap, retention, explicit export.
- Failed audit writes block risky actions.
- The Settings UI shows recent events and a denied-action count.

### Kill switch

- Persisted before the command returns.
- Startup reads the state before any background module starts.
- Cancels queued requests, closes consent cards, signals cancellable work.
- Resume is explicit and does not restore grants or autonomy.

### Supply chain

- Authenticode for binaries/installer; minisign for updates; signed release
  workflow. This threat model assumes those controls are not bypassed.

## Privacy

- Data read: local policy, local audit, capability metadata. No personal
  content beyond the short target label.
- Data sent: none. The foundation makes no network requests.
- Retention: 30 days / 20 files / 10 MB per file. The user can export or delete;
  deletion is audited as a local event.
- Consent text must match the actual data flow of the future feature; the
  foundation only renders the preview it is given, so each feature RFC must
  review that text.

## Residual risks

| Risk | Why it remains | Accepted by |
|---|---|---|
| Same-user attacker can read the HMAC key and re-forge the audit chain | Credential Manager is per-user, not per-process | Security review; documented in RFC |
| Same-user attacker can edit `security.json` to grant capabilities | file ACL is the same user; policy is local | Product decision: Coucou is a single-user app |
| TOCTOU between scope check and file open | Windows has no atomic "open only if still inside scope" primitive for all cases | Future fs RFC must use handle-based checks where possible |
| Kill switch cannot undo an OS call already in flight | Windows APIs are not all cancellable | Audit records `in_flight`; UI explains |
| Determined UI spoofing / accessibility abuse | the island is a normal top-level window | Partial; high-risk actions require a fresh card |
| Consent fatigue leads to blanket approval | user behaviour, not code | Keep high-risk classes non-persistent; scope previews explicit |
| A compromised webview can answer its own consent card | the card lives in the same process | CSP/hardening and code review; same-user attacker already wins |

## Verification

- [ ] Policy tests: missing/corrupt/future schema → deny; session grants expire;
      downgrade does not grant.
- [ ] Scope tests: `..`, case, trailing dots/spaces, prefix collision, reparse
      point, reserved names, UNC.
- [ ] Consent tests: single use, id mismatch, args hash mismatch, timeout on a
      monotonic clock, queue overflow, wrong window.
- [ ] Audit tests: fake `sk-` token and newline injection absent from the file;
      HMAC chain survives rotation; unkeyed fallback is labelled; export
      redacts.
- [ ] Kill switch tests: persisted before return, queued action cancelled,
      restart stays off, in-flight reported.
- [ ] Crash test: kill the process after `action_started`; next launch marks it
      interrupted and keeps automation off.
- [ ] UAT on Windows 10 and 11 as a standard user: kill → restart → verify off;
      corrupt policy → verify deny and warning; resume → grants still off.
- [ ] Threat model updated in the same PR as any security-relevant change.

## References

- RFC 0001.
- OWASP ASVS v4 (access control, logging).
- Microsoft: `GetFinalPathNameByHandle`, job objects, UI Automation security.
- Tauri v2 command/capability documentation.
- `docs/PLAN-windows.md`, Phase 5.
