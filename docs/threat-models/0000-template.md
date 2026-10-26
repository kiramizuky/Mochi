# Threat model 0000 — Title

- **Status:** Draft
- **RFC:** `../rfc/0000-title.md`
- **Author:** @your-handle
- **Reviewers:** @security, @windows
- **Created:** YYYY-MM-DD
- **Last updated:** YYYY-MM-DD
- **Review scope:** the code paths the RFC adds, plus how they change existing ones

## System in scope

One paragraph: what is being added and which process owns it. Name the trust
boundary explicitly. If the feature is not yet implemented, describe the planned
boundary and mark this document as a design review.

```
untrusted input (remote payload, file, clipboard, model output)
        │
        ▼
  validation / policy / consent
        │
        ▼
  Windows API or local resource
```

## Assets

What an attacker wants, ranked by impact.

| Asset | Why it matters | Where it lives |
|---|---|---|
| Credential Manager entries | provider/API keys, bot tokens | `Credential Manager`, process memory |
| User documents | private content | user profile |
| Claude Code session | commands, repository content | local process, named pipe |
| Audit trail | accountability, incident response | local app data |
| Update key / release feed | supply chain | CI secrets, GitHub Release |
| User attention | social engineering, silent actions | the UI |

## Adversaries

| Adversary | Capability | In scope? |
|---|---|---|
| Remote unauthenticated attacker | sends payloads to a webhook/MCP server | yes |
| Malicious local process | same-user process, can read app data | yes, limited |
| Malicious model output | prompt injection through files/clipboard/web | yes |
| Shoulder-surfer / physical access | unlocked desktop | partial |
| Supply-chain attacker | release assets, dependency | covered by signing RFCs |
| Administrator / kernel attacker | full control | out of scope; say why |

State the honest limit: code running as the same user can usually read
`%APPDATA%`, the audit file, and policy. The goal is to prevent *silent,
unauthorised action*, not to defend against a same-user attacker with full
debugging rights.

## Trust boundaries and data flow

List each crossing and what validates it.

1. Webview (untrusted content) → Rust command: schema validation, no raw paths.
2. Rust → external service: allowlisted host, TLS, scoped credential.
3. Model output → tool executor: policy gate, consent, no implicit shell.
4. Local file/clipboard → prompt: size/type caps, secret detection, redaction.
5. CI → release: Authenticode + updater signature, pinned actions.

For each boundary, state what happens on malformed input, oversized input, and
replayed input.

## Abuse cases

Use STRIDE or an equivalent checklist; write concrete steps, not categories.

| # | Abuse case | Preconditions | Impact | Mitigation | Residual risk |
|---|---|---|---|---|---|
| 1 | Prompt injection asks the agent to read `%USERPROFILE%\.ssh\id_rsa` | file watcher + model | key exfiltration | path deny-list, consent, audit | user grants broad folder access |
| 2 | Telegram message replays an old "run" command | paired bot | unauthorised action | message id/nonce cache, allowlisted commands, kill switch | token theft |
| 3 | Forged update manifest points at a malicious installer | endpoint override | code execution | pinned HTTPS endpoint, minisign, `requireSignedVersion` | compromised release key |
| 4 | Consent dialog is spoofed by a fullscreen window | clickjacking | user approves silently | topmost owned window, show target details | determined UI spoofing |
| 5 | Audit file edited to hide an action | same-user access | no accountability | hash chain + keyed MAC | attacker with key access |
| 6 | Kill switch pressed but queued actions still run | race | unwanted action | single gate, cancellation tokens, latency test | in-flight OS call cannot be undone |

Add rows until every capability in the RFC has at least one abuse case.

## Mitigations

Group by layer:

- **Input validation:** schemas, size caps, path canonicalisation, URL allowlist.
- **Authorisation:** default-deny policy, scoped grants, no inherited "always
  allow" for irreversible actions.
- **Isolation:** least-privilege process, no shell interpolation, bounded
  sandbox for dynamic tools.
- **Secrets:** Credential Manager only; never in settings, logs, bundles,
  fixtures, or crash reports.
- **Auditability:** append-only local events, redaction before write, export.
- **Kill switch:** immediate, persistent across restart, cancels queued work.
- **Supply chain:** pinned dependencies/actions, signed release, checksum.

## Privacy

- What user data is read, where it goes, and whether it leaves the machine.
- Retention and deletion path.
- Consent text must match the actual data flow.
- If the feature sends data to a third party, name the host and the fields.

## Residual risks

Be explicit. "None" is almost never true.

| Risk | Why it remains | Accepted by |
|---|---|---|
| | | |

## Verification

- [ ] Policy matrix tests cover every capability and default.
- [ ] Consent timeout and "deny on close" tests.
- [ ] Kill switch stops a queued action within the stated latency.
- [ ] Audit sanitisation test uses a fake token/secret and asserts absence.
- [ ] Path traversal / prefix-collision tests for scoped grants.
- [ ] Crash/restart leaves the feature disabled (fail closed).
- [ ] Manual UAT on Windows 10 and 11 as a standard user.
- [ ] Threat model updated in the same PR as any security-relevant design change.

## References

- RFC, related threat models, Windows security documentation, incident notes.
