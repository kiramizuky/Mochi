#![allow(dead_code)]

use serde::Serialize;
use tokio::time::timeout;

use super::audit::{record, AuditEntry};
use super::consent::{self, Decision, CONSENT_TIMEOUT};
use super::killswitch;
use super::policy::{self, Capability, GrantMode, Scope};

/// Non-forgeable grant required by executors. Cannot be constructed outside this module.
#[derive(Debug)]
pub struct ActionGrant {
    _private: (),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConsentBasis {
    /// Explicit human click in Coucou's own UI.
    UserAction,
    /// Automated or background execution (watcher, MCP, tool loop, remote).
    Background,
}

#[derive(Debug, Clone)]
pub struct ActionRequest {
    pub capability: Capability,
    pub scope: Option<Scope>,
    pub target: String,
    pub basis: ConsentBasis,
    pub args_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SecurityError {
    Killed,
    AutomationDisabled,
    Denied(String),
    Timeout,
    ScopeError(String),
}

impl std::fmt::Display for SecurityError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SecurityError::Killed => write!(f, "Action blocked: kill switch is engaged"),
            SecurityError::AutomationDisabled => {
                write!(f, "Action blocked: automation is disabled in settings")
            }
            SecurityError::Denied(reason) => write!(f, "Action denied: {reason}"),
            SecurityError::Timeout => write!(f, "Action denied: consent request timed out"),
            SecurityError::ScopeError(err) => write!(f, "Invalid scope: {err}"),
        }
    }
}

impl std::error::Error for SecurityError {}

/// The single authorization gate. All risky actions must pass through here.
pub async fn authorize(request: ActionRequest) -> Result<ActionGrant, SecurityError> {
    // 1. Kill switch check (sub-millisecond latency path)
    if killswitch::is_killed() {
        record(&AuditEntry {
            event: "action_denied".into(),
            capability: Some(request.capability.as_str().to_string()),
            scope: request.scope.as_ref().map(|s| format!("{s:?}")),
            target: Some(request.target.clone()),
            decision: "deny".into(),
            rule: "kill_switch".into(),
            outcome: "not_run".into(),
        });
        return Err(SecurityError::Killed);
    }

    // 2. Normalize scope if provided
    let normalized_scope = if let Some(ref s) = request.scope {
        match policy::normalize_scope(s) {
            Ok(norm) => Some(norm),
            Err(e) => {
                record(&AuditEntry {
                    event: "action_denied".into(),
                    capability: Some(request.capability.as_str().to_string()),
                    scope: Some(format!("{s:?}")),
                    target: Some(request.target.clone()),
                    decision: "deny".into(),
                    rule: "invalid_scope".into(),
                    outcome: "rejected".into(),
                });
                return Err(SecurityError::ScopeError(e));
            }
        }
    } else {
        None
    };

    // 3. Explicit user clicks bypass consent cards but are audited
    if request.basis == ConsentBasis::UserAction {
        record(&AuditEntry {
            event: "action_allowed".into(),
            capability: Some(request.capability.as_str().to_string()),
            scope: normalized_scope.as_ref().map(|s| format!("{s:?}")),
            target: Some(request.target),
            decision: "allow".into(),
            rule: "user_action".into(),
            outcome: "granted".into(),
        });
        return Ok(ActionGrant { _private: () });
    }

    // 4. Background / autonomous actions require policy or consent
    let (pol, is_invalid) = policy::load();
    if is_invalid {
        record(&AuditEntry {
            event: "action_denied".into(),
            capability: Some(request.capability.as_str().to_string()),
            scope: normalized_scope.as_ref().map(|s| format!("{s:?}")),
            target: Some(request.target.clone()),
            decision: "deny".into(),
            rule: "policy_invalid".into(),
            outcome: "not_run".into(),
        });
        return Err(SecurityError::Denied("Security policy is invalid".into()));
    }

    if !pol.automation_enabled {
        record(&AuditEntry {
            event: "action_denied".into(),
            capability: Some(request.capability.as_str().to_string()),
            scope: normalized_scope.as_ref().map(|s| format!("{s:?}")),
            target: Some(request.target.clone()),
            decision: "deny".into(),
            rule: "automation_disabled".into(),
            outcome: "not_run".into(),
        });
        return Err(SecurityError::AutomationDisabled);
    }

    // Check static persistent grant
    if let Some(grant) = pol.capabilities.get(request.capability.as_str()) {
        if grant.mode == GrantMode::Always {
            let scope_ok = match (&normalized_scope, &grant.scopes) {
                (Some(target_scope), granted_scopes) => {
                    granted_scopes.iter().any(|g| policy::scope_matches(g, target_scope))
                }
                (None, _) => true,
            };

            if scope_ok {
                record(&AuditEntry {
                    event: "action_allowed".into(),
                    capability: Some(request.capability.as_str().to_string()),
                    scope: normalized_scope.as_ref().map(|s| format!("{s:?}")),
                    target: Some(request.target),
                    decision: "allow".into(),
                    rule: "policy_always".into(),
                    outcome: "granted".into(),
                });
                return Ok(ActionGrant { _private: () });
            }
        }
    }

    // Check in-memory session grants
    if consent::has_session_grant(request.capability, normalized_scope.as_ref()) {
        record(&AuditEntry {
            event: "action_allowed".into(),
            capability: Some(request.capability.as_str().to_string()),
            scope: normalized_scope.as_ref().map(|s| format!("{s:?}")),
            target: Some(request.target),
            decision: "allow".into(),
            rule: "session_grant".into(),
            outcome: "granted".into(),
        });
        return Ok(ActionGrant { _private: () });
    }

    // High risk capabilities cannot have "Always" grants and must raise a fresh card
    // Request human consent
    let (_id, rx) = consent::request_consent(
        request.capability,
        normalized_scope.clone(),
        request.target.clone(),
        request.args_hash,
    )
    .map_err(|e| SecurityError::Denied(e))?;

    // Wait for user decision with 30-second timeout
    match timeout(CONSENT_TIMEOUT, rx).await {
        Ok(Ok(decision)) => match decision {
            Decision::AllowOnce | Decision::AllowSession => {
                record(&AuditEntry {
                    event: "action_allowed".into(),
                    capability: Some(request.capability.as_str().to_string()),
                    scope: normalized_scope.as_ref().map(|s| format!("{s:?}")),
                    target: Some(request.target),
                    decision: "allow".into(),
                    rule: "consent_decision".into(),
                    outcome: "granted".into(),
                });
                Ok(ActionGrant { _private: () })
            }
            Decision::Deny => {
                record(&AuditEntry {
                    event: "action_denied".into(),
                    capability: Some(request.capability.as_str().to_string()),
                    scope: normalized_scope.as_ref().map(|s| format!("{s:?}")),
                    target: Some(request.target),
                    decision: "deny".into(),
                    rule: "user_declined".into(),
                    outcome: "rejected".into(),
                });
                Err(SecurityError::Denied("User declined request".into()))
            }
        },
        _ => {
            record(&AuditEntry {
                event: "action_denied".into(),
                capability: Some(request.capability.as_str().to_string()),
                scope: normalized_scope.as_ref().map(|s| format!("{s:?}")),
                target: Some(request.target),
                decision: "deny".into(),
                rule: "consent_timeout".into(),
                outcome: "timed_out".into(),
            });
            Err(SecurityError::Timeout)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn user_action_is_allowed_and_audited() {
        let _guard = killswitch::TEST_LOCK.lock().unwrap();
        let _ = killswitch::resume(None);
        let req = ActionRequest {
            capability: Capability::FsRead,
            scope: None,
            target: "C:\\Users\\USER\\file.txt".into(),
            basis: ConsentBasis::UserAction,
            args_hash: "hash".into(),
        };

        let grant = authorize(req).await;
        assert!(grant.is_ok());
    }

    #[tokio::test]
    async fn kill_switch_blocks_actions_immediately() {
        let _guard = killswitch::TEST_LOCK.lock().unwrap();
        killswitch::kill(None).unwrap();

        let req = ActionRequest {
            capability: Capability::FsRead,
            scope: None,
            target: "C:\\test".into(),
            basis: ConsentBasis::UserAction,
            args_hash: "hash".into(),
        };

        let err = authorize(req).await.unwrap_err();
        assert_eq!(err, SecurityError::Killed);

        killswitch::resume(None).unwrap();
    }
}
