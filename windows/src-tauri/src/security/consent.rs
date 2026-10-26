#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::sync::oneshot;

use super::audit::{record, AuditEntry};
use super::policy::{self, Capability, Scope};

pub const CONSENT_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_QUEUE_SIZE: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Decision {
    AllowOnce,
    AllowSession,
    Deny,
}

pub struct PendingConsent {
    pub id: String,
    pub capability: Capability,
    pub scope: Option<Scope>,
    pub target: String,
    pub args_hash: String,
    pub created_at: Instant,
    pub expires_at: Instant,
    pub sender: Option<oneshot::Sender<Decision>>,
}

#[derive(Default)]
struct ConsentState {
    pending: Vec<PendingConsent>,
    session_grants: HashMap<String, Vec<Scope>>,
}

static STATE: Mutex<Option<ConsentState>> = Mutex::new(None);

fn with_state<F, R>(f: F) -> R
where
    F: FnOnce(&mut ConsentState) -> R,
{
    let mut lock = STATE.lock().unwrap();
    if lock.is_none() {
        *lock = Some(ConsentState::default());
    }
    f(lock.as_mut().unwrap())
}

/// Checks whether an in-memory session grant covers the requested capability and scope.
pub fn has_session_grant(capability: Capability, scope: Option<&Scope>) -> bool {
    with_state(|state| {
        if let Some(granted_scopes) = state.session_grants.get(capability.as_str()) {
            match scope {
                Some(target_scope) => {
                    for granted in granted_scopes {
                        if policy::scope_matches(granted, target_scope) {
                            return true;
                        }
                    }
                    false
                }
                None => {
                    // Wildcard or scope-less capability session grant
                    true
                }
            }
        } else {
            false
        }
    })
}

/// Enqueues a consent request for the user.
/// Returns a receiver for the decision, or Err if the queue is full.
pub fn request_consent(
    capability: Capability,
    scope: Option<Scope>,
    target: String,
    args_hash: String,
) -> Result<(String, oneshot::Receiver<Decision>), String> {
    with_state(|state| {
        // Prune any already expired requests
        let now = Instant::now();
        state.pending.retain(|p| p.expires_at > now);

        if state.pending.len() >= MAX_QUEUE_SIZE {
            record(&AuditEntry {
                event: "action_denied".into(),
                capability: Some(capability.as_str().to_string()),
                scope: scope.as_ref().map(|s| format!("{s:?}")),
                target: Some(target.clone()),
                decision: "deny".into(),
                rule: "queue_overflow".into(),
                outcome: "rejected".into(),
            });
            return Err("Consent queue is full (max 8 pending requests)".into());
        }

        let id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();

        record(&AuditEntry {
            event: "consent_shown".into(),
            capability: Some(capability.as_str().to_string()),
            scope: scope.as_ref().map(|s| format!("{s:?}")),
            target: Some(target.clone()),
            decision: "pending".into(),
            rule: "user_consent".into(),
            outcome: "waiting".into(),
        });

        state.pending.push(PendingConsent {
            id: id.clone(),
            capability,
            scope,
            target,
            args_hash,
            created_at: now,
            expires_at: now + CONSENT_TIMEOUT,
            sender: Some(tx),
        });

        Ok((id, rx))
    })
}

/// Decides a pending consent request by ID and argument hash.
pub fn decide(id: &str, args_hash: &str, decision: Decision) -> Result<(), String> {
    with_state(|state| {
        let now = Instant::now();
        let idx = state
            .pending
            .iter()
            .position(|p| p.id == id)
            .ok_or_else(|| "Consent request not found".to_string())?;

        let item = &state.pending[idx];
        if item.expires_at <= now {
            let expired = state.pending.remove(idx);
            record(&AuditEntry {
                event: "consent_expired".into(),
                capability: Some(expired.capability.as_str().to_string()),
                scope: expired.scope.as_ref().map(|s| format!("{s:?}")),
                target: Some(expired.target),
                decision: "deny".into(),
                rule: "timeout_30s".into(),
                outcome: "expired".into(),
            });
            return Err("Consent request has expired".into());
        }

        if item.args_hash != args_hash {
            record(&AuditEntry {
                event: "action_denied".into(),
                capability: Some(item.capability.as_str().to_string()),
                scope: item.scope.as_ref().map(|s| format!("{s:?}")),
                target: Some(item.target.clone()),
                decision: "deny".into(),
                rule: "args_hash_mismatch".into(),
                outcome: "rejected".into(),
            });
            return Err("Argument hash mismatch on consent decision".into());
        }

        let mut item = state.pending.remove(idx);

        if decision == Decision::AllowSession {
            if let Some(scope) = item.scope.clone() {
                state
                    .session_grants
                    .entry(item.capability.as_str().to_string())
                    .or_default()
                    .push(scope);
            }
        }

        record(&AuditEntry {
            event: "consent_decided".into(),
            capability: Some(item.capability.as_str().to_string()),
            scope: item.scope.as_ref().map(|s| format!("{s:?}")),
            target: Some(item.target),
            decision: format!("{decision:?}").to_ascii_lowercase(),
            rule: "user_consent".into(),
            outcome: "decided".into(),
        });

        if let Some(sender) = item.sender.take() {
            let _ = sender.send(decision);
        }

        Ok(())
    })
}

/// Cancels all pending consent cards (e.g. on kill switch or shutdown).
pub fn cancel_all() {
    with_state(|state| {
        for mut item in state.pending.drain(..) {
            record(&AuditEntry {
                event: "action_cancelled".into(),
                capability: Some(item.capability.as_str().to_string()),
                scope: item.scope.as_ref().map(|s| format!("{s:?}")),
                target: Some(item.target),
                decision: "deny".into(),
                rule: "kill_switch_or_shutdown".into(),
                outcome: "cancelled".into(),
            });
            if let Some(sender) = item.sender.take() {
                let _ = sender.send(Decision::Deny);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_use_consent_decision() {
        let cap = Capability::FsRead;
        let (id, rx) = request_consent(cap, None, "test_target".into(), "hash123".into()).unwrap();

        assert!(decide(&id, "hash123", Decision::AllowOnce).is_ok());

        // Second decision on same id must fail
        assert!(decide(&id, "hash123", Decision::AllowOnce).is_err());

        // Check channel receiver
        let res = rx.blocking_recv().unwrap();
        assert_eq!(res, Decision::AllowOnce);
    }

    #[test]
    fn args_hash_mismatch_is_rejected() {
        let cap = Capability::NetRequest;
        let (id, _rx) = request_consent(cap, None, "test".into(), "hash_correct".into()).unwrap();

        let err = decide(&id, "hash_wrong", Decision::AllowOnce).unwrap_err();
        assert!(err.contains("mismatch"));
    }
}
