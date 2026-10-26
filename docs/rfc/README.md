# Requests for Comments

Every Windows feature that can read user data, write outside Coucou's own
folders, spend money, control another application, or act without a click needs
an RFC **and** a threat model before implementation. The two documents are
reviewed together; an approved RFC without a threat model is not approval to
build.

This process exists because Phase 5 adds capabilities that the current app does
not have: MCP servers, filesystem and clipboard watchers, voice, memory/RAG,
Telegram, autonomous tools, and screen automation. A bug in any of them is no
longer a visual glitch — it can leak a file, send a message, or run a command.

## Process

1. Copy `0000-template.md` and `../threat-models/0000-template.md` to the next
   free number. Use the same number for both documents.
2. Fill in the RFC first: what is built, how it is gated, and how it fails.
3. Fill in the threat model: assets, trust boundaries, abuse cases, and
   residual risk.
4. Open a pull request that contains **only** the documents. Reviewers look for
   a denied-by-default design, a visible consent path, an audit trail, and a
   kill switch before discussing implementation details.
5. Implementation starts only after the RFC status is `Accepted`. Changes to
   the security model during implementation require an RFC update in the same
   pull request.

## Status values

| Status | Meaning |
|---|---|
| `Draft` | Being written; do not implement. |
| `Review` | Ready for security/privacy review. |
| `Accepted` | Approved for implementation as written. |
| `Implemented` | Code and tests match the accepted design. |
| `Superseded` | Replaced by a later RFC; link it. |
| `Rejected` | Not being built; record why. |

## Non-negotiable requirements

These apply to every RFC in this folder. An RFC that cannot meet them is
rejected rather than weakened:

- **Deny by default.** A new capability is off until the user grants it, and a
  missing/corrupt policy file means "deny", not "allow everything".
- **One gate.** Risky actions go through a single Rust policy/consent gateway.
  Front-end code cannot call the underlying Windows API directly.
- **Explicit consent.** The user sees the capability, the concrete target, and
  the data involved before it is used. Silent background actions are limited to
  the capabilities the user explicitly enabled for that scope.
- **Audit without content.** Local audit events name the capability, decision,
  rule, and outcome. They never contain secret values, full file contents, full
  URLs with query strings, or message bodies.
- **A working kill switch.** Pause stops new actions immediately, cancels
  pending consent, and does not silently re-enable after a restart or crash.
- **Secrets stay in the Credential Manager.** Policy files, logs, bundles,
  crash reports, and test fixtures contain no credentials.
- **Fail closed.** If the policy engine, consent UI, or audit sink is
  unavailable, the risky action is refused.
- **Tests include abuse.** Unit tests cover the policy matrix and timeouts;
  integration tests cover a denied action, an expired consent, and a kill
  switch pressed while an action is queued.

## Index

| RFC | Title | Status | Threat model |
|---|---|---|---|
| [0001](0001-phase5-foundation-policy-audit-consent-killswitch.md) | Phase 5 foundation: policy, audit, consent, kill switch | Review | [0001](../threat-models/0001-phase5-foundation-policy-audit-consent-killswitch.md) |
