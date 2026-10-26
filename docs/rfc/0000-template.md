# RFC 0000 — Title

- **Status:** Draft
- **Author:** @your-handle
- **Reviewers:** @security, @windows
- **Created:** YYYY-MM-DD
- **Last updated:** YYYY-MM-DD
- **Threat model:** `../threat-models/0000-title.md`
- **Issue / pull request:** #
- **Target phase:** 5.x

## Summary

One paragraph. What capability is added, for whom, and why it cannot be done by
the existing features? If this is a port from macOS, say what changes on
Windows instead of assuming parity.

## Motivation

The user problem, with a concrete example. What does the user do today, and
what does the new feature remove or shorten?

## Goals

- A short, testable list.

## Non-goals

- What this RFC deliberately does **not** do. This section prevents scope creep
  from turning a read-only feature into an automation platform.

## Risk classification

Pick every capability the feature touches. Each one needs a policy entry and an
audit event.

| Capability | Touches | Default | Reversible? |
|---|---|---|---|
| Read local state | filesystem, registry, process list | denied until granted | n/a |
| Write local state | filesystem, settings, app data | denied until granted | usually |
| Network egress | HTTP/S, WebSocket, SMTP, Telegram | denied until granted | no |
| Spend money | purchase/refund APIs | denied | no |
| Control another app | UI Automation, SendInput, window messages | denied | usually |
| Screen capture | desktop/window capture | denied | no (data leaves the screen) |
| Run a process | shell, scripts, binaries | denied | no |
| Autonomy | multi-step actions without a click | denied | no |

If an action can be both read-only and destructive depending on arguments, the
RFC must classify it by the **worst** case or require an explicit sub-policy.

## User experience and consent

Show the exact flow: what opens, what text the user reads, what is preselected,
and what happens on timeout.

- Entry point and whether the action is user-initiated or background.
- Preview: capability, target (path/window/recipient), data read and sent, and
  the number of steps.
- Choices: **Allow once**, **Allow for this session**, **Always allow**, **Deny**.
  Justify any option that is remembered across restarts.
- Timeout: default deny after N seconds; no auto-allow.
- High-risk actions (irreversible write, money, process launch, screen input)
  must not offer "Always allow" unless the RFC explains why that is safe.
- Revocation path: where the user turns it off, and whether it takes effect
  immediately for queued actions.

## Design

### Architecture

Describe the modules and the data flow. Name the single gateway every risky
action passes through and how the front end reaches it (Tauri command/event).
State explicitly which code is allowed to call the raw Windows API.

```
front end → Tauri command → policy check → consent (if required) → audit start
         → action executor → audit result → front end
```

### Data model

Policy entry, consent token, audit event, and any on-disk files. Include a
schema version and the forward-compatibility rule. No secret belongs in any of
these.

### Windows APIs

List each API, the minimum Windows version, and the failure mode when it is
unavailable. Prefer documented, least-privilege APIs over shelling out.

### Policy semantics

- Who can change policy (Settings UI, tray, enterprise config)?
- What happens when policy JSON is missing, corrupt, or from a newer schema?
- Precedence between a global kill switch, a capability grant, and a one-off
  consent.
- Scope keys (per app, per folder, per recipient) and how they are normalised
  to prevent path/prefix tricks.

### Audit

- Event fields and their allowlisted values.
- Where the file lives, rotation/retention, and export behaviour.
- How content and secrets are excluded; redaction happens before writing.
- Tamper evidence (hash chain, keyed MAC) and its honest limitations.
- What happens when the disk is full or the audit file is unwritable.

### Kill switch

- UI and keyboard/tray entry points.
- Latency target for stopping new work and cancelling queued work.
- Behaviour of in-flight processes, long downloads, and pending consent.
- Restart/crash behaviour: fail closed, with the exact state the user sees.

## Failure modes

| Failure | User sees | System does |
|---|---|---|
| policy file unreadable | | |
| consent window never answers | | |
| audit sink unavailable | | |
| action partially completed | | |
| app crashes mid-action | | |
| network drops mid-request | | |

## Observability and logs

What is logged, at what level, and what is deliberately not logged. Link the
audit events. Never log tokens, full paths of user documents, message bodies,
or clipboard contents.

## Rollout

- Feature flag / setting name and default.
- Migration of existing settings.
- Can it be disabled remotely or by policy? (Coucou has no remote kill service;
  say so if that remains true.)
- Rollback plan if the feature misbehaves in a release.

## Testing

- Unit tests: policy matrix, scope normalisation, timeout, sanitisation.
- Integration tests: allow path, deny path, expired consent, kill switch during
  a queued action, crash/restart.
- Manual UAT: Windows 10/11, standard user, high DPI, no developer tools.
- Abuse tests: forged target, path traversal, replayed consent, policy downgrade.

## Alternatives considered

What else was possible, and why this design wins. Include "do nothing" when it
is a real option.

## Open questions

- [ ] Question with an owner and a date.

## References

- Related RFCs, threat models, Windows documentation, and upstream issues.
