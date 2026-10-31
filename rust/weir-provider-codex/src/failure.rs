//! Reads the failure a Codex turn ended in from its rollout.
//!
//! Codex runs no hook when a turn fails: `Stop` runs only on the path where
//! sampling succeeded (`codex-rs/core`, read on 2026-10-13; a turn that
//! failed in Codex CLI 0.165.0 still ran none). The rollout (`transcript_path` in every hook payload) does
//! record it, as the turn's `task_complete` event with an `error`: the
//! message the TUI shows, and the kind as `codex_error_info`, a name such as
//! `model_not_found` or `server_overloaded`, or an object named by its one
//! key (`http_connection_failed`). The helper's watcher sees that line and
//! reports `WeirTurnFailed` through this adapter, which reads the rest
//! here. A turn that ended at the plan's usage limit
//! (`usage_limit_exceeded`, "… try again at 10:29 AM.") also names the
//! window it used up. Neither shape is documented, so what cannot be read
//! leaves a failure with less said rather than no failure, and a limit with
//! no time rather than no limit.

use crate::json::string;
use crate::normalize::{
    ERROR_KIND_KEY, FAILED_AT_KEY, MESSAGE_RESET_KEY, WATCHED_SESSION_KEY, WEIR_TURN_FAILED_EVENT,
};
use serde_json::{Map, Value, json};
use std::time::{Duration, UNIX_EPOCH};
use weir_agent_model::{
    FailureReport, FailureWatch, PlanUsageWindow, UsageLimit, format_utc_seconds, parse_utc_seconds,
};

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

/// The event a turn ends with. The helper's watcher looks for this text before
/// it asks about a line (`rust/fixtures/contract/shared-values.json`).
const TURN_END_EVENT: &str = "task_complete";

/// The report for `line` when it is a turn that failed: an `event_msg` whose
/// `task_complete` carries an `error`. Read as JSON, so the words in an agent's
/// own answer are not taken for it.
pub(crate) fn turn_failure_report(line: &[u8], watch: &FailureWatch<'_>) -> Option<FailureReport> {
    if !line
        .windows(TURN_END_EVENT.len())
        .any(|window| window == TURN_END_EVENT.as_bytes())
    {
        return None;
    }
    let Ok(Value::Object(record)) = serde_json::from_slice::<Value>(line) else {
        return None;
    };
    if string(&record, "type") != Some("event_msg") {
        return None;
    }
    let payload = record.get("payload")?.as_object()?;
    if string(payload, "type") != Some(TURN_END_EVENT) {
        return None;
    }
    let error = payload.get("error")?.as_object()?;
    let kind = error_kind(error);
    let written_at = string(&record, "timestamp").and_then(line_seconds);
    let mut report = json!({
        "hook_event_name": WEIR_TURN_FAILED_EVENT,
        "transcript_path": watch.transcript_path,
        WATCHED_SESSION_KEY: watch.session_id,
        FAILED_AT_KEY: written_at.unwrap_or(watch.read_at),
    });
    if let Some(kind) = &kind {
        report[ERROR_KIND_KEY] = json!(kind);
    }
    Some(FailureReport {
        payload: report,
        written_at,
        usage_limit_message: (kind.as_deref() == Some(USAGE_LIMIT_KIND))
            .then(|| string(error, "message").map(str::to_owned))
            .flatten(),
        message_reset_key: MESSAGE_RESET_KEY,
    })
}

/// A line's time in whole Unix seconds. Codex writes UTC with fractions of a
/// second; the shape is undocumented, so an offset is read too.
fn line_seconds(timestamp: &str) -> Option<u64> {
    let (seconds, zone) = timestamp.split_at_checked(19)?;
    let zone = match zone.split_once('.') {
        None => zone,
        Some(("", fraction)) => fraction.trim_start_matches(|digit: char| digit.is_ascii_digit()),
        Some(_) => return None,
    };
    let utc = parse_utc_seconds(&format!("{seconds}Z"))?;
    if zone == "Z" {
        return Some(utc);
    }
    let (sign, offset) = zone.split_at_checked(1)?;
    let (hours, minutes) = offset.split_once(':')?;
    let number = |text: &str, limit: u64| {
        let is_two_digits = text.len() == 2 && text.bytes().all(|byte| byte.is_ascii_digit());
        text.parse::<u64>()
            .ok()
            .filter(|value| is_two_digits && *value < limit)
    };
    let offset = number(hours, 24)? * 3600 + number(minutes, 60)? * 60;
    match sign {
        "+" => utc.checked_sub(offset),
        "-" => utc.checked_add(offset),
        _ => None,
    }
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
                .and_then(PlanUsageWindow::kind_for_minutes)
                .map(str::to_owned),
        })
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

    const WATCH: FailureWatch<'static> = FailureWatch {
        transcript_path: "/tmp/rollout.jsonl",
        session_id: "session-a",
        read_at: 1_791_853_260,
    };

    fn failed_line(timestamp: &str, error: &str) -> String {
        format!(
            r#"{{{timestamp}"type":"event_msg","payload":{{"type":"task_complete","error":{error}}}}}"#
        )
    }

    #[test]
    fn a_report_names_the_session_the_kind_and_when_the_turn_failed() {
        let line = failed_line(
            r#""timestamp":"2026-10-13T01:00:00.500Z","#,
            r#"{"message":"Try again at 10:29 AM.","codex_error_info":"usage_limit_exceeded"}"#,
        );
        let report = turn_failure_report(line.as_bytes(), &WATCH).unwrap();
        assert_eq!(
            report.written_at,
            Some(1_791_853_200),
            "the line's own time"
        );
        assert_eq!(report.payload["hook_event_name"], "WeirTurnFailed");
        assert_eq!(report.payload["transcript_path"], "/tmp/rollout.jsonl");
        assert_eq!(report.payload["session_id"], "session-a");
        assert_eq!(report.payload["weir_failed_at"], 1_791_853_200);
        assert_eq!(report.payload["weir_error_kind"], "usage_limit_exceeded");
        assert_eq!(
            report.usage_limit_message.as_deref(),
            Some("Try again at 10:29 AM.")
        );
        assert_eq!(report.message_reset_key, "weir_message_resets_at");
    }

    #[test]
    fn a_line_with_no_time_or_kind_is_reported_at_the_time_it_was_read() {
        let report = turn_failure_report(failed_line("", "{}").as_bytes(), &WATCH).unwrap();
        assert_eq!(report.written_at, None);
        assert_eq!(report.payload["weir_failed_at"], WATCH.read_at);
        assert!(report.payload.get("weir_error_kind").is_none());
        assert_eq!(report.usage_limit_message, None);
    }

    #[test]
    fn only_a_usage_limit_hands_its_message_to_the_host() {
        let line = failed_line(
            "",
            r#"{"message":"Overloaded","codex_error_info":{"http_connection_failed":{}}}"#,
        );
        let report = turn_failure_report(line.as_bytes(), &WATCH).unwrap();
        assert_eq!(report.payload["weir_error_kind"], "http_connection_failed");
        assert_eq!(report.usage_limit_message, None);
    }

    #[test]
    fn a_time_is_read_with_or_without_a_fraction_or_an_offset() {
        let utc = Some(1_791_853_200);
        assert_eq!(line_seconds("2026-10-13T01:00:00Z"), utc);
        assert_eq!(line_seconds("2026-10-13T01:00:00.500Z"), utc);
        assert_eq!(line_seconds("2026-10-13T10:00:00+09:00"), utc);
        assert_eq!(line_seconds("2026-10-13T10:00:00.500+09:00"), utc);
        assert_eq!(line_seconds("2026-10-12T21:00:00-04:00"), utc);
        assert_eq!(line_seconds("t"), None);
        assert_eq!(line_seconds("2026-10-13T10:00:00+99:99"), None);
        assert_eq!(line_seconds("2026-10-13T10:00:00++9:00"), None);
        assert_eq!(line_seconds("2026-10-13T01:00:00"), None);
    }

    #[test]
    fn a_usage_limit_with_no_message_is_still_named() {
        let line = failed_line("", r#"{"codex_error_info":"usage_limit_exceeded"}"#);
        let report = turn_failure_report(line.as_bytes(), &WATCH).unwrap();
        assert_eq!(report.payload["weir_error_kind"], "usage_limit_exceeded");
        assert_eq!(report.usage_limit_message, None);
    }

    /// Taken from what Codex CLI 0.165.0 wrote for a model it does not have.
    #[test]
    fn a_model_codex_does_not_have_is_named_by_its_kind() {
        let line = r#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":null,"error":{"message":"The 'no-such-model' model is not supported.","codex_error_info":"model_not_found"}}}"#;
        let report = turn_failure_report(line.as_bytes(), &WATCH).unwrap();
        assert_eq!(report.payload["weir_error_kind"], "model_not_found");
        assert_eq!(report.usage_limit_message, None);
    }

    #[test]
    fn anything_but_a_failed_turn_end_has_no_report() {
        for line in [
            DONE,
            r#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"usage_limit_exceeded"}}"#,
            "not json task_complete",
            r#"{"type":"response_item","payload":{"type":"task_complete","error":{}}}"#,
            r#"{"type":"event_msg","payload":{"type":"agent_message","message":"task_complete"}}"#,
        ] {
            assert_eq!(turn_failure_report(line.as_bytes(), &WATCH), None, "{line}");
        }
    }

    #[test]
    fn the_text_the_watcher_looks_for_is_the_event_a_turn_ends_with() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../fixtures/contract/shared-values.json"
        );
        let shared: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        assert_eq!(shared["codexTurnEndEvent"], TURN_END_EVENT);
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
