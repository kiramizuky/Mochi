// Named-pipe server for coucou-hook.
//
// `\\.\pipe\coucou-<sid>` — one instance per connection. Every hook event is
// forwarded to the island as a `hook` event. `PermissionRequest` is the only one
// that keeps its connection open: it waits for the island's decision and writes
// it back on the same pipe, which is how approving from the island works.
//
// Claude Code is never blocked by us. Three things guarantee it:
//   * coucou-hook gives the connection 300 ms and exits cleanly if we are closed;
//   * we only wait for a human once the island has *confirmed* the card is on
//     screen, so a paused island or a webview that is not listening costs a few
//     hundred milliseconds, not two minutes;
//   * whatever happens we drop the connection after the decision timeout, and
//     the terminal takes over.
//
// What we write back is the bare word `allow` or `deny`. Turning that into the
// documented hookSpecificOutput JSON is coucou-hook's job, so the wire format
// Claude Code expects lives in exactly one place.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
use tokio::sync::mpsc;

use crate::island::WINDOW_LABEL;
use crate::log;

/// Slightly under coucou-hook's own 110 s wait, so we always answer first.
const DECISION_TIMEOUT: Duration = Duration::from_secs(108);
/// How long the island gets to say "the card is up". This is the whole of B4:
/// without it, an island that is paused, hidden behind a crashed webview or
/// simply not listening would leave Claude Code staring at a prompt nobody can
/// see for nearly two minutes.
const ACK_TIMEOUT: Duration = Duration::from_millis(800);
const MAX_PAYLOAD: usize = 1 << 20;

/// What the island can say about a permission request.
pub enum Reply {
    /// The card is on screen and a human can act on it.
    Ack,
    /// A human clicked: `allow` or `deny`.
    Decision(String),
    /// Nobody can act on it — paused, or another request already holds the card.
    Decline,
}

/// Permission requests the island has been told about.
#[derive(Default)]
pub struct Pending(pub Mutex<HashMap<String, mpsc::Sender<Reply>>>);

static COUNTER: AtomicU64 = AtomicU64::new(1);

/// `\\.\pipe\coucou-<sid>` — must match coucou-hook's `pipe_path()` exactly.
pub fn pipe_name() -> String {
    let key = crate::win_user::current_user_sid()
        .unwrap_or_else(|| std::env::var("USERNAME").unwrap_or_else(|_| "user".into()));
    format!(r"\\.\pipe\coucou-{key}")
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let name = pipe_name();
        // first_pipe_instance also means we refuse to join a pipe somebody else
        // already owns under our name, rather than serving on top of it.
        let mut server = match ServerOptions::new().first_pipe_instance(true).create(&name) {
            Ok(s) => s,
            Err(err) => {
                log::line(format!("cannot open the relay pipe: {err}"));
                return;
            }
        };
        loop {
            if server.connect().await.is_err() {
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
            // Hand the connected instance to a task and listen on a fresh one.
            let next = match ServerOptions::new().create(&name) {
                Ok(s) => s,
                Err(err) => {
                    log::line(format!("cannot reopen the relay pipe: {err}"));
                    return;
                }
            };
            let connected = std::mem::replace(&mut server, next);
            let app = app.clone();
            tauri::async_runtime::spawn(async move { handle(app, connected).await });
        }
    });
}

async fn handle(app: AppHandle, mut pipe: NamedPipeServer) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match pipe.read(&mut chunk).await {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.contains(&b'\n') || buf.len() > MAX_PAYLOAD {
                    break;
                }
            }
            Err(_) => return,
        }
    }
    let line = match buf.iter().position(|b| *b == b'\n') {
        Some(i) => &buf[..i],
        None => &buf[..],
    };
    let Ok(mut payload) = serde_json::from_slice::<Value>(line) else {
        return;
    };
    if !payload.is_object() {
        return;
    }

    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    if event != "PermissionRequest" {
        log::line(format!("hook {event}"));
        let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
        let _ = pipe.disconnect();
        return;
    }

    let id = format!(
        "{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    let (tx, mut rx) = mpsc::channel::<Reply>(4);
    {
        let pending = app.state::<Pending>();
        pending.0.lock().unwrap().insert(id.clone(), tx);
    }
    payload["request_id"] = json!(id);
    log::line(format!("hook PermissionRequest id={id}"));
    let _ = app.emit_to(WINDOW_LABEL, "hook", payload);

    let waiting = std::time::Instant::now();
    let decision = wait_for_decision(&id, &mut rx).await;
    if crate::smoke::requested() {
        log::line(format!(
            "hook id={id} wait returned after {} ms",
            waiting.elapsed().as_millis()
        ));
    }
    app.state::<Pending>().0.lock().unwrap().remove(&id);

    // No decision: say nothing at all. coucou-hook then writes nothing to stdout
    // and Claude Code asks in the terminal, exactly as if Coucou were closed.
    if let Some(d) = decision {
        let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
        let _ = pipe.flush().await;
    }
    let _ = pipe.disconnect();
}

/// Two waits: a short one for "the card is up", then the long one for a human.
async fn wait_for_decision(id: &str, rx: &mut mpsc::Receiver<Reply>) -> Option<String> {
    wait_for_decision_with(id, rx, ACK_TIMEOUT, DECISION_TIMEOUT).await
}

/// The timeouts are parameters so the tests can exercise every branch without
/// waiting 108 seconds. Production always goes through `wait_for_decision`.
async fn wait_for_decision_with(
    id: &str,
    rx: &mut mpsc::Receiver<Reply>,
    ack_timeout: Duration,
    decision_timeout: Duration,
) -> Option<String> {
    let started = std::time::Instant::now();
    let verbose = crate::smoke::requested();
    match tokio::time::timeout(ack_timeout, rx.recv()).await {
        Ok(Some(Reply::Ack)) => {
            if verbose {
                log::line(format!(
                    "wait id={id} ack after {} ms",
                    started.elapsed().as_millis()
                ));
            }
        }
        // A click that beats the ack is still a click.
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {d}"));
            return Some(d);
        }
        Ok(Some(Reply::Decline)) => {
            log::line(format!("hook id={id} not shown — terminal takes over"));
            return None;
        }
        Ok(None) => {
            if verbose {
                log::line(format!(
                    "wait id={id} channel closed in the ack wait after {} ms",
                    started.elapsed().as_millis()
                ));
            }
            return None;
        }
        Err(_) => {
            log::line(format!(
                "hook id={id} island never acknowledged — terminal takes over"
            ));
            return None;
        }
    }

    // The island may acknowledge more than once (the card is re-rendered, or a
    // second listener acks too). An Ack in this phase must never be mistaken for
    // the decision timeout: keep waiting until the deadline.
    let deadline = started + decision_timeout;
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            log::line(format!("hook id={id} timed out — terminal takes over"));
            return None;
        }
        match tokio::time::timeout(remaining, rx.recv()).await {
            Ok(Some(Reply::Decision(d))) => {
                log::line(format!("hook id={id} answered {d}"));
                return Some(d);
            }
            Ok(Some(Reply::Decline)) => {
                log::line(format!("hook id={id} released without a decision"));
                return None;
            }
            Ok(Some(Reply::Ack)) => {
                if verbose {
                    log::line(format!(
                        "wait id={id} duplicate ack after {} ms",
                        started.elapsed().as_millis()
                    ));
                }
                continue;
            }
            Ok(None) => {
                if verbose {
                    log::line(format!(
                        "wait id={id} channel closed in the decision wait after {} ms",
                        started.elapsed().as_millis()
                    ));
                }
                return None;
            }
            Err(_) => {
                log::line(format!("hook id={id} timed out — terminal takes over"));
                return None;
            }
        }
    }
}

fn send(app: &AppHandle, request_id: &str, reply: Reply, keep: bool) {
    let sender = {
        let pending = app.state::<Pending>();
        let mut map = pending.0.lock().unwrap();
        if keep {
            map.get(request_id).cloned()
        } else {
            map.remove(request_id)
        }
    };
    match sender {
        Some(tx) => {
            let result = tx.try_send(reply);
            if crate::smoke::requested() {
                match &result {
                    Ok(()) => log::line(format!("reply id={request_id} queued (keep={keep})")),
                    Err(err) => log::line(format!("reply id={request_id} failed: {err}")),
                }
            }
        }
        None => log::line(format!("reply for id={request_id} — no pending request")),
    }
}

/// The island has the card on screen; the long wait may begin.
pub fn acknowledge(app: &AppHandle, request_id: &str) {
    send(app, request_id, Reply::Ack, true);
}

/// Nobody can act on this one — paused, or another card already holds the view.
pub fn decline(app: &AppHandle, request_id: &str) {
    log::line(format!("decline id={request_id}"));
    send(app, request_id, Reply::Decline, false);
}

/// Called by the island's Allow / Deny buttons. Only ever a bare word: turning
/// it into Claude Code's JSON is coucou-hook's job.
pub fn answer(app: &AppHandle, request_id: &str, decision: &str) {
    let word = decision_word(decision);
    log::line(format!("decision id={request_id} {word}"));
    send(app, request_id, Reply::Decision(word.to_string()), false);
}

/// Anything that is not an explicit allow becomes a deny. An IPC message typo
/// must never turn into a permission grant.
fn decision_word(decision: &str) -> &'static str {
    match decision {
        "allow" | "always" => "allow",
        _ => "deny",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    const ACK: Duration = Duration::from_millis(20);
    const DECISION: Duration = Duration::from_millis(40);

    fn channel() -> (mpsc::Sender<Reply>, mpsc::Receiver<Reply>) {
        mpsc::channel(4)
    }

    #[tokio::test]
    async fn a_confirmed_card_waits_for_the_human_and_returns_the_click() {
        let (tx, mut rx) = channel();
        tx.send(Reply::Ack).await.unwrap();
        tx.send(Reply::Decision("allow".into())).await.unwrap();
        let answer = wait_for_decision_with("test", &mut rx, ACK, DECISION).await;
        assert_eq!(answer.as_deref(), Some("allow"));
    }

    #[tokio::test]
    async fn a_click_that_beats_the_ack_is_still_a_click() {
        let (tx, mut rx) = channel();
        tx.send(Reply::Decision("deny".into())).await.unwrap();
        let answer = wait_for_decision_with("test", &mut rx, ACK, DECISION).await;
        assert_eq!(answer.as_deref(), Some("deny"));
    }

    #[tokio::test]
    async fn a_duplicate_ack_does_not_end_the_wait() {
        let (tx, mut rx) = channel();
        tx.send(Reply::Ack).await.unwrap();
        tx.send(Reply::Ack).await.unwrap();
        tx.send(Reply::Decision("allow".into())).await.unwrap();
        let answer = wait_for_decision_with("test", &mut rx, ACK, DECISION).await;
        assert_eq!(answer.as_deref(), Some("allow"));
    }

    #[tokio::test]
    async fn a_declined_card_never_waits_for_a_human() {
        let (tx, mut rx) = channel();
        tx.send(Reply::Decline).await.unwrap();
        let started = std::time::Instant::now();
        let answer = wait_for_decision_with("test", &mut rx, ACK, DECISION).await;
        assert_eq!(answer, None);
        assert!(started.elapsed() < ACK, "decline must release immediately");
    }

    #[tokio::test]
    async fn an_unacknowledged_card_gives_up_after_the_ack_timeout() {
        let (_tx, mut rx) = channel();
        let started = std::time::Instant::now();
        let answer = wait_for_decision_with("test", &mut rx, ACK, DECISION).await;
        assert_eq!(answer, None);
        assert!(started.elapsed() >= ACK);
        assert!(started.elapsed() < DECISION + ACK);
    }

    #[tokio::test]
    async fn an_acknowledged_card_times_out_instead_of_blocking_forever() {
        let (tx, mut rx) = channel();
        tx.send(Reply::Ack).await.unwrap();
        let started = std::time::Instant::now();
        let answer = wait_for_decision_with("test", &mut rx, ACK, DECISION).await;
        assert_eq!(answer, None);
        assert!(started.elapsed() >= DECISION);
    }

    #[tokio::test]
    async fn a_dropped_island_releases_the_hook() {
        let (tx, mut rx) = channel();
        tx.send(Reply::Ack).await.unwrap();
        drop(tx);
        let answer = wait_for_decision_with("test", &mut rx, ACK, DECISION).await;
        assert_eq!(answer, None);
    }

    #[test]
    fn only_an_explicit_allow_is_a_grant() {
        assert_eq!(decision_word("allow"), "allow");
        assert_eq!(decision_word("always"), "allow");
        assert_eq!(decision_word("deny"), "deny");
        assert_eq!(decision_word("ALLOW"), "deny");
        assert_eq!(decision_word(""), "deny");
        assert_eq!(decision_word("yes please"), "deny");
    }

    #[test]
    fn the_pipe_name_is_per_user_and_well_formed() {
        let name = pipe_name();
        assert!(name.starts_with(r"\\.\pipe\coucou-"), "got {name}");
        assert!(!name.contains(char::is_whitespace), "got {name}");
        assert!(name.len() > r"\\.\pipe\coucou-".len());
    }
}
