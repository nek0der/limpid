//! Reads a usage limit Codex stopped at from its rollout.
//!
//! Codex runs no hook when its plan's usage limit ends a turn: `Stop` runs
//! only on the path where sampling succeeded (`codex-rs/core`, read on
//! 2026-10-13). The rollout (`transcript_path` in every hook payload) does
//! record it, as the turn's `task_complete` event with
//! `error.codex_error_info: "usage_limit_exceeded"` and the message the TUI
//! shows ("… try again at 10:29 AM."). The helper's watcher sees that line
//! and reports `LimpidUsageLimitReached` through this adapter, which reads
//! the rest here. Neither shape is documented, so what cannot be read leaves
//! a limit with no time rather than no limit.

use limpid_agent_model::{UsageLimit, format_utc_seconds};
use serde_json::{Map, Value};
use std::time::{Duration, UNIX_EPOCH};

/// The usage limit the rollout's last turn ended at, and the message Codex
/// gave for it; `None` when that turn did not end at one (it ended
/// otherwise, or a later turn began).
pub(crate) fn rollout_usage_limit(rollout: &[u8]) -> Option<(UsageLimit, Option<String>)> {
    let mut lines = rollout
        .split(|byte| *byte == b'\n')
        .rev()
        .filter_map(event_payload);
    let message = loop {
        let payload = lines.next()?;
        match string(&payload, "type") {
            Some("task_complete") => {
                let error = payload.get("error")?.as_object()?;
                if string(error, "codex_error_info") != Some("usage_limit_exceeded") {
                    return None;
                }
                break string(error, "message").map(str::to_owned);
            }
            Some("task_started") => return None,
            _ => {}
        }
    };
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
    Some((limit, message))
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

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
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
        let (limit, message) =
            rollout_usage_limit(&rollout(&[STARTED, ITEM, TOKENS, EMPTY_TOKENS, LIMITED])).unwrap();
        assert_eq!(
            limit,
            UsageLimit {
                resets_at: Some("2026-10-07T06:00:00Z".to_owned()),
                window: Some("five_hour".to_owned()),
            }
        );
        assert_eq!(
            message.as_deref(),
            Some("You've hit your usage limit. Try again at 10:29 AM.")
        );
    }

    #[test]
    fn a_turn_with_no_rate_limits_is_a_limit_with_no_time() {
        let (limit, message) = rollout_usage_limit(&rollout(&[STARTED, ITEM, LIMITED])).unwrap();
        assert_eq!(limit, UsageLimit::default());
        assert!(message.is_some());
    }

    #[test]
    fn rate_limits_of_an_earlier_turn_are_not_read() {
        let (limit, _) = rollout_usage_limit(&rollout(&[TOKENS, DONE, STARTED, LIMITED])).unwrap();
        assert_eq!(limit, UsageLimit::default());
    }

    #[test]
    fn a_turn_that_ended_otherwise_or_a_later_one_names_nothing() {
        assert_eq!(rollout_usage_limit(&rollout(&[STARTED, DONE])), None);
        assert_eq!(rollout_usage_limit(&rollout(&[LIMITED, STARTED])), None);
        assert_eq!(rollout_usage_limit(b""), None);
        let other = LIMITED.replace("usage_limit_exceeded", "server_error");
        assert_eq!(rollout_usage_limit(&rollout(&[STARTED, &other])), None);
    }
}
