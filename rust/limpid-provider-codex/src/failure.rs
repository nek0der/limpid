//! Reads the failure a Codex turn ended in from its rollout.
//!
//! Codex runs no hook when a turn fails: `Stop` runs only on the path where
//! sampling succeeded (`codex-rs/core`, read on 2026-10-13; a turn that
//! failed in Codex CLI 0.165.0 still ran none). The rollout (`transcript_path` in every hook payload) does
//! record it, as the turn's `task_complete` event with an `error`: the
//! message the TUI shows, and the kind as `codex_error_info`, a name such as
//! `model_not_found` or `server_overloaded`, or an object named by its one
//! key (`http_connection_failed`). The helper's watcher sees that line and
//! reports `LimpidTurnFailed` through this adapter, which reads the rest
//! here. A turn that ended at the plan's usage limit
//! (`usage_limit_exceeded`, "… try again at 10:29 AM.") also names the
//! window it used up. Neither shape is documented, so what cannot be read
//! leaves a failure with less said rather than no failure, and a limit with
//! no time rather than no limit.

use crate::json::string;
use limpid_agent_model::{UsageLimit, format_utc_seconds};
use serde_json::{Map, Value};
use std::time::{Duration, UNIX_EPOCH};

/// The kind Codex gives a turn its plan's usage limit ended.
pub(crate) const USAGE_LIMIT_KIND: &str = "usage_limit_exceeded";

/// What a failed turn ended in, as the rollout says it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RolloutFailure {
    /// The failure as the run record holds it: the kind Codex gave it, a
    /// name as Claude's failures carry (`server_error`), or Codex's message
    /// for one with no kind. A usage limit keeps Codex's message, which names
    /// when it resets.
    pub error: String,
    /// The limit the turn ended at, when that is what ended it.
    pub usage_limit: Option<UsageLimit>,
}

/// The failure the rollout's last turn ended in; `None` when that turn did
/// not fail (it ended otherwise, or a later turn began).
pub(crate) fn rollout_failure(rollout: &[u8]) -> Option<RolloutFailure> {
    let mut lines = rollout
        .split(|byte| *byte == b'\n')
        .rev()
        .filter_map(event_payload);
    let (kind, message) = loop {
        let payload = lines.next()?;
        match string(&payload, "type") {
            Some("task_complete") => {
                let error = payload.get("error")?.as_object()?;
                break (
                    error_kind(error),
                    string(error, "message").map(str::to_owned),
                );
            }
            Some("task_started") => return None,
            _ => {}
        }
    };
    if kind.as_deref() != Some(USAGE_LIMIT_KIND) {
        return Some(RolloutFailure {
            error: kind.or(message).unwrap_or_else(|| "error".to_owned()),
            usage_limit: None,
        });
    }
    // The reset is in the rate limits Codex last reported in that turn: the
    // window it used up.
    let mut limit = UsageLimit::default();
    for payload in lines {
        match string(&payload, "type") {
            Some("task_started") => break,
            Some("token_count") => {
                if let Some(reached) = payload.get("rate_limits").and_then(reached_window) {
                    limit = reached;
                    break;
                }
            }
            _ => {}
        }
    }
    Some(RolloutFailure {
        error: message.unwrap_or_else(|| USAGE_LIMIT_KIND.to_owned()),
        usage_limit: Some(limit),
    })
}

/// The kind of a failure: `codex_error_info` as a name, or as the one key of
/// an object that carries details (`{"http_connection_failed": {...}}`).
fn error_kind(error: &Map<String, Value>) -> Option<String> {
    match error.get("codex_error_info")? {
        Value::String(kind) => Some(kind.clone()),
        Value::Object(details) if details.len() == 1 => details.keys().next().cloned(),
        _ => None,
    }
    .filter(|kind| !kind.is_empty())
}

/// The `payload` of an `event_msg` line.
fn event_payload(line: &[u8]) -> Option<Map<String, Value>> {
    // A substring check keeps the JSON parse for the event lines.
    if !line.windows(11).any(|window| window == b"\"event_msg\"") {
        return None;
    }
    let Ok(Value::Object(mut record)) = serde_json::from_slice::<Value>(line) else {
        return None;
    };
    if string(&record, "type") != Some("event_msg") {
        return None;
    }
    match record.remove("payload") {
        Some(Value::Object(payload)) => Some(payload),
        _ => None,
    }
}

/// Of `primary` and `secondary`, the window used up (`used_percent` 100),
/// the one that resets last when both are.
fn reached_window(rate_limits: &Value) -> Option<UsageLimit> {
    ["primary", "secondary"]
        .iter()
        .filter_map(|name| rate_limits.get(name)?.as_object())
        .filter(|window| {
            window
                .get("used_percent")
                .and_then(Value::as_f64)
                .is_some_and(|used| used >= 100.0)
        })
        .filter_map(|window| {
            let resets_at = window.get("resets_at").and_then(Value::as_u64)?;
            Some((resets_at, window))
        })
        .max_by_key(|(resets_at, _)| *resets_at)
        .map(|(resets_at, window)| UsageLimit {
            resets_at: UNIX_EPOCH
                .checked_add(Duration::from_secs(resets_at))
                .map(format_utc_seconds),
            window: window
                .get("window_minutes")
                .and_then(Value::as_u64)
                .and_then(window_name)
                .map(str::to_owned),
        })
}

/// Codex's windows by length, in the names Claude gives the same ones, so
/// the interface words them once.
fn window_name(minutes: u64) -> Option<&'static str> {
    match minutes {
        300 => Some("five_hour"),
        10_080 => Some("seven_day"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const STARTED: &str =
        r#"{"timestamp":"t","type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"#;
    const LIMITED: &str = r#"{"timestamp":"t","type":"event_msg","payload":{"type":"task_complete","turn_id":"a","last_agent_message":null,"error":{"message":"You've hit your usage limit. Try again at 10:29 AM.","codex_error_info":"usage_limit_exceeded"}}}"#;
    const DONE: &str = r#"{"timestamp":"t","type":"event_msg","payload":{"type":"task_complete","turn_id":"a","last_agent_message":"ok"}}"#;
    const TOKENS: &str = r#"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1791352800},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":1791900000}}}}"#;
    const EMPTY_TOKENS: &str = r#"{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}"#;
    const ITEM: &str = r#"{"timestamp":"t","type":"response_item","payload":{"type":"message"}}"#;

    fn rollout(lines: &[&str]) -> Vec<u8> {
        lines.join("\n").into_bytes()
    }

    #[test]
    fn a_turn_ended_at_the_limit_names_the_window_it_used_up() {
        let failure =
            rollout_failure(&rollout(&[STARTED, ITEM, TOKENS, EMPTY_TOKENS, LIMITED])).unwrap();
        assert_eq!(
            failure,
            RolloutFailure {
                error: "You've hit your usage limit. Try again at 10:29 AM.".to_owned(),
                usage_limit: Some(UsageLimit {
                    resets_at: Some("2026-10-07T06:00:00Z".to_owned()),
                    window: Some("five_hour".to_owned()),
                }),
            }
        );
    }

    #[test]
    fn a_turn_with_no_rate_limits_is_a_limit_with_no_time() {
        let failure = rollout_failure(&rollout(&[STARTED, ITEM, LIMITED])).unwrap();
        assert_eq!(failure.usage_limit, Some(UsageLimit::default()));
    }

    #[test]
    fn rate_limits_of_an_earlier_turn_are_not_read() {
        let failure = rollout_failure(&rollout(&[TOKENS, DONE, STARTED, LIMITED])).unwrap();
        assert_eq!(failure.usage_limit, Some(UsageLimit::default()));
    }

    #[test]
    fn any_other_failure_is_named_by_its_kind() {
        let failed = |error: &str| {
            format!(
                r#"{{"timestamp":"t","type":"event_msg","payload":{{"type":"task_complete","turn_id":"a","last_agent_message":null,"error":{error}}}}}"#
            )
        };
        let failure = |error: &str| rollout_failure(&rollout(&[STARTED, &failed(error)])).unwrap();
        // Taken from what Codex CLI 0.165.0 wrote for a model it does not have.
        let model = failure(
            r#"{"message":"The 'no-such-model' model is not supported when using Codex with a ChatGPT account.","codex_error_info":"model_not_found"}"#,
        );
        assert_eq!(
            model,
            RolloutFailure {
                error: "model_not_found".to_owned(),
                usage_limit: None,
            }
        );
        assert_eq!(
            failure(r#"{"message":"lost","codex_error_info":{"http_connection_failed":{"http_status_code":502}}}"#).error,
            "http_connection_failed"
        );
        assert_eq!(
            failure(r#"{"message":"Something broke."}"#).error,
            "Something broke."
        );
        assert_eq!(failure("{}").error, "error");
    }

    #[test]
    fn a_turn_that_ended_otherwise_or_a_later_one_names_nothing() {
        assert_eq!(rollout_failure(&rollout(&[STARTED, DONE])), None);
        assert_eq!(rollout_failure(&rollout(&[LIMITED, STARTED])), None);
        assert_eq!(rollout_failure(b""), None);
    }
}
