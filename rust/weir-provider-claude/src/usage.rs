//! Reads the usage limit a failed turn hit from the transcript tail.
//!
//! `StopFailure` names the failure (`rate_limit`) but not whether it was the
//! plan's usage limit or a passing rate limit (an API key's, a cloud
//! provider's, which have no reset to wait for), nor when the limit resets.
//! Claude Code writes the API error it got as an assistant line marked
//! `isApiErrorMessage`, and from 2.1.273 that line carries the plan's quota:
//! `quotaLimits` with `status` (`rejected` at the limit), `resetsAt` in epoch
//! seconds, and `rateLimitType` (`five_hour`, `seven_day`, …); 2.1.293 also
//! writes `apiErrorParams.rate_limit_info` of the same shape. Neither key is
//! documented (<https://code.claude.com/docs/en/hooks>, the Agent SDK's
//! `SDKRateLimitInfo`), and whether the line is in the file by the time the
//! hook runs is not verified: the transcripts read show it written before the
//! turn's closing system lines. So a turn whose line is not found is not
//! taken as anything; the caller decides from the payload.

use serde_json::{Map, Value};
use std::time::{Duration, UNIX_EPOCH};
use weir_agent_model::{UsageLimit, format_utc_seconds};

/// What the transcript says of the turn's failure.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Finding {
    /// The plan's usage limit, with what the line says of it.
    Limit(UsageLimit),
    /// An API error that is not the plan's limit: another error, or a
    /// quota the line reports as still allowed.
    NotALimit,
    /// No API error of this turn is in the tail, or its rate-limit or
    /// usage-limit error says nothing of a quota (a Claude Code older than
    /// 2.1.273).
    NotFound,
}

/// The turn's last API error, read from the end back to the turn's last
/// answer or main-thread user line: an error further back belongs to an
/// earlier turn. Claude Code's own notices (`model: "<synthetic>"` lines that
/// are not errors, such as the line saying it will continue once the limit
/// resets) are passed over.
pub(crate) fn transcript_usage_limit(transcript: &[u8]) -> Finding {
    for line in transcript.split(|byte| *byte == b'\n').rev() {
        // Substring checks keep the JSON parse for the lines that can matter.
        if !contains(line, br#""assistant""#) && !contains(line, br#""user""#) {
            continue;
        }
        let Ok(Value::Object(record)) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if record.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        match record.get("type").and_then(Value::as_str) {
            Some("assistant") if is_api_error(&record) => return finding_of(&record),
            Some("assistant") if is_synthetic(&record) => {}
            Some("assistant" | "user") => return Finding::NotFound,
            _ => {}
        }
    }
    Finding::NotFound
}

/// What a failure's own words say, for a turn whose transcript line was not
/// found: only the forms Claude Code uses for a limit the person has to
/// wait out ("You've hit your session limit · resets 3pm", "usage limit
/// reached") count, never its server's own throttling ("Server is
/// temporarily limiting requests (not your usage limit)") or an API key's
/// "Request rejected (429)" (<https://code.claude.com/docs/en/errors>). A
/// spend limit ("You've hit your monthly spend limit") counts too on
/// purpose: it also holds the account's agents until the person acts.
pub(crate) fn message_names_a_limit(message: &str) -> bool {
    let message = message.to_lowercase();
    if message.contains("not your usage limit") {
        return false;
    }
    message.contains("hit your")
        || message.contains("usage limit reached")
        || message.contains("limit · resets")
}

fn is_api_error(record: &Map<String, Value>) -> bool {
    record.get("isApiErrorMessage").and_then(Value::as_bool) == Some(true)
}

fn is_synthetic(record: &Map<String, Value>) -> bool {
    record
        .get("message")
        .and_then(|message| message.get("model"))
        .and_then(Value::as_str)
        == Some("<synthetic>")
}

/// What an API error line says of the plan's quota.
fn finding_of(record: &Map<String, Value>) -> Finding {
    let quota = record
        .get("quotaLimits")
        .and_then(Value::as_object)
        .or_else(|| {
            record
                .get("apiErrorParams")
                .and_then(|params| params.get("rate_limit_info"))
                .and_then(Value::as_object)
        });
    let is_usage_limit_error =
        record.get("apiError").and_then(Value::as_str) == Some("usage_limit_reached");
    let Some(quota) = quota else {
        // No quota on the line: a rate limit or usage-limit error an older
        // Claude Code wrote is not told apart here, and any other error is
        // not one.
        return if is_usage_limit_error
            || record.get("error").and_then(Value::as_str) == Some("rate_limit")
        {
            Finding::NotFound
        } else {
            Finding::NotALimit
        };
    };
    if quota.get("status").and_then(Value::as_str) != Some("rejected") && !is_usage_limit_error {
        return Finding::NotALimit;
    }
    Finding::Limit(UsageLimit {
        resets_at: quota
            .get("resetsAt")
            .and_then(Value::as_u64)
            .and_then(|seconds| UNIX_EPOCH.checked_add(Duration::from_secs(seconds)))
            .map(format_utc_seconds),
        window: quota
            .get("rateLimitType")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shape Claude Code 2.1.29x writes, with the content cut down.
    const REJECTED: &str = r#"{"type":"assistant","isSidechain":false,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"You've hit your session limit"}]},"quotaLimits":{"status":"rejected","resetsAt":1791352800,"rateLimitType":"five_hour","overageStatus":"rejected"},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}"#;
    const PROMPT: &str =
        r#"{"type":"user","isSidechain":false,"message":{"role":"user","content":"go on"}}"#;
    const ANSWER: &str =
        r#"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[]}}"#;
    const TURN_DURATION: &str = r#"{"type":"system","subtype":"turn_duration"}"#;

    fn tail(lines: &[&str]) -> Vec<u8> {
        lines.join("\n").into_bytes()
    }

    #[test]
    fn a_rejected_request_names_the_reset_and_the_window() {
        let limit = transcript_usage_limit(&tail(&[PROMPT, REJECTED, TURN_DURATION]));
        assert_eq!(
            limit,
            Finding::Limit(UsageLimit {
                resets_at: Some("2026-10-07T06:00:00Z".to_owned()),
                window: Some("five_hour".to_owned()),
            })
        );
    }

    #[test]
    fn the_rate_limit_info_is_read_when_the_quota_is_not_there() {
        let line = r#"{"type":"assistant","isApiErrorMessage":true,"apiError":"usage_limit_reached","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1791352800,"rateLimitType":"seven_day"}}}"#;
        let Finding::Limit(limit) = transcript_usage_limit(&tail(&[PROMPT, line])) else {
            panic!("a limit");
        };
        assert_eq!(limit.resets_at.as_deref(), Some("2026-10-07T06:00:00Z"));
        assert_eq!(limit.window.as_deref(), Some("seven_day"));
        let allowed = r#"{"type":"assistant","isApiErrorMessage":true,"apiErrorParams":{"rate_limit_info":{"status":"allowed_warning","resetsAt":1791352800}}}"#;
        assert_eq!(
            transcript_usage_limit(&tail(&[PROMPT, allowed])),
            Finding::NotALimit
        );
    }

    #[test]
    fn an_error_from_an_earlier_turn_or_a_turn_that_answered_names_nothing() {
        assert_eq!(
            transcript_usage_limit(&tail(&[REJECTED, PROMPT])),
            Finding::NotFound
        );
        assert_eq!(
            transcript_usage_limit(&tail(&[REJECTED, PROMPT, ANSWER])),
            Finding::NotFound
        );
        assert_eq!(
            transcript_usage_limit(&tail(&[PROMPT, ANSWER])),
            Finding::NotFound
        );
        assert_eq!(transcript_usage_limit(b""), Finding::NotFound);
    }

    #[test]
    fn an_api_error_without_a_rejected_quota_names_nothing() {
        let overloaded = r#"{"type":"assistant","isApiErrorMessage":true,"error":"overloaded"}"#;
        assert_eq!(
            transcript_usage_limit(&tail(&[PROMPT, overloaded])),
            Finding::NotALimit
        );
        let allowed = REJECTED.replace(r#""status":"rejected""#, r#""status":"allowed""#);
        assert_eq!(
            transcript_usage_limit(&tail(&[PROMPT, &allowed])),
            Finding::NotALimit
        );
    }

    #[test]
    fn a_rate_limit_line_without_a_quota_is_not_told_apart() {
        let older = r#"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit"}"#;
        assert_eq!(
            transcript_usage_limit(&tail(&[PROMPT, older])),
            Finding::NotFound
        );
    }

    #[test]
    fn claude_codes_own_notice_after_the_error_is_passed_over() {
        let notice = r#"{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Usage limit reached · continuing automatically at 3:45pm"}]}}"#;
        assert!(matches!(
            transcript_usage_limit(&tail(&[PROMPT, REJECTED, notice])),
            Finding::Limit(_)
        ));
    }

    #[test]
    fn a_reset_past_any_date_is_left_out_rather_than_panicking() {
        let far = REJECTED.replace("1791352800", "18446744073709551615");
        assert_eq!(
            transcript_usage_limit(&tail(&[PROMPT, &far])),
            Finding::Limit(UsageLimit {
                resets_at: None,
                window: Some("five_hour".to_owned()),
            })
        );
    }

    #[test]
    fn the_failures_own_words_tell_the_plans_limit_from_another() {
        assert!(message_names_a_limit(
            "You've hit your session limit · resets 3pm (Asia/Tokyo)"
        ));
        assert!(message_names_a_limit("Claude usage limit reached"));
        assert!(!message_names_a_limit(
            "API Error: Server is temporarily limiting requests (not your usage limit)"
        ));
        assert!(!message_names_a_limit(
            "API Error: Request rejected (429) · rate limited"
        ));
    }

    #[test]
    fn a_subagent_line_is_passed_over() {
        let subagent = r#"{"type":"assistant","isSidechain":true,"message":{"content":[]}}"#;
        assert!(matches!(
            transcript_usage_limit(&tail(&[PROMPT, REJECTED, subagent])),
            Finding::Limit(_)
        ));
    }
}
