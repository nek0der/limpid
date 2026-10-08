//! Estimates Claude Code's prompt cache window from the transcript tail.
//!
//! Claude Code exposes the expiry only to a status line command, through
//! `prompt_cache.expires_at` on its standard input. We do not install a status
//! line to read it: `--settings` outranks the user's settings files, so ours
//! would replace the one the user configured, and managed settings can own the
//! key outright. No hook payload, plugin API, or telemetry attribute carries
//! the value, so we reconstruct it from what the transcript does record.
//!
//! Each API request appears as one or more assistant lines that share a
//! `requestId` and carry `message.usage`. The usage names the cache bucket the
//! request wrote (`cache_creation.ephemeral_1h_input_tokens` or
//! `ephemeral_5m_input_tokens`), and the cache lives for that bucket's TTL
//! counted from when the request started. The lines are logged as the response
//! streams, so the earliest timestamp of the last request is the closest
//! anchor we can read. It is late by however long the response took to write
//! its first line, usually seconds but minutes for one that thinks at length,
//! which makes the estimate expire after the real cache rather than before.
//!
//! The estimate needs the turn's final response to be in the file when Stop
//! runs. If a main-thread user line is newer than the last usage, that
//! response is missing: the line is a tool result the model has yet to
//! answer, or the prompt of a turn whose only answer has not been flushed.
//! Anchoring on the request before it would show the cache expiring early,
//! so we report nothing rather than that.

use limpid_agent_model::{CachePrecision, CacheWindow, format_utc_seconds, parse_utc_seconds};
use serde_json::{Map, Value};
use std::time::{Duration, UNIX_EPOCH};

/// The one-hour bucket, used by the main conversation on a subscription.
const ONE_HOUR_SECONDS: u64 = 3600;
/// The five-minute bucket, used with API keys and usage credits.
const FIVE_MINUTES_SECONDS: u64 = 300;

/// What one transcript line says about one main-thread request.
struct Observation {
    request: String,
    started_at: u64,
    input: u64,
    cache_read: u64,
    cache_creation: u64,
    output: u64,
    ttl: Option<u64>,
}

/// The window the last main-thread request left, or `None` when the tail does
/// not say enough to name one.
///
/// Unknown is never rounded to the five-minute bucket. A window shown as
/// expired when the cache is in fact warm would talk the user into a
/// `/compact` they did not need, which costs more than saying nothing.
pub(crate) fn transcript_cache_window(transcript: &[u8]) -> Option<CacheWindow> {
    let mut lines = transcript.split(|byte| *byte == b'\n').rev();
    // Substring checks keep the JSON parse for the lines that can matter; most
    // of a long transcript is tool output.
    let first = loop {
        let line = lines.next()?;
        if contains(line, br#""usage""#)
            && let Some(observation) = observe(line)
        {
            break observation;
        }
        // Checked even on a line that mentions usage: a subagent's result
        // comes back to the main conversation with the subagent's own usage
        // inside it.
        if contains(line, br#""user""#) && is_main_user_line(line) {
            return None;
        }
    };
    let observations = lines
        .filter(|line| contains(line, br#""usage""#))
        .filter_map(observe);

    let mut last = first;
    let mut earlier_ttl = None;
    for observation in observations {
        if observation.request == last.request {
            last = merge(last, &observation);
            continue;
        }
        // Requests on the main thread run one after another, so the first
        // line of a different request means every line of the last one has
        // been seen. Keep walking only while its bucket is still unknown
        // and an earlier write could still name it.
        if last.ttl.is_some() || last.cache_read == 0 {
            break;
        }
        if let Some(ttl) = observation.ttl {
            earlier_ttl = Some(ttl);
            break;
        }
    }

    if last.cache_read == 0 && last.cache_creation == 0 {
        // Nothing was cached, so there is no window to lose.
        return None;
    }
    // A request that only read the cache refreshed it without naming a
    // bucket; it inherits the bucket of the request that wrote it.
    let ttl = last.ttl.or(if last.cache_read > 0 {
        earlier_ttl
    } else {
        None
    })?;
    let rewrite = last
        .input
        .saturating_add(last.cache_read)
        .saturating_add(last.cache_creation)
        .saturating_add(last.output);
    Some(CacheWindow {
        observed_at: format_utc_seconds(UNIX_EPOCH + Duration::from_secs(last.started_at)),
        ttl_seconds: ttl,
        rewrite_tokens: Some(rewrite),
        precision: CachePrecision::Estimated,
    })
}

/// One line's contribution. Lines that are not main-thread assistant usage,
/// including a first line cut in half by the tail and anything malformed,
/// are skipped rather than ending the scan.
fn observe(line: &[u8]) -> Option<Observation> {
    let Ok(Value::Object(record)) = serde_json::from_slice::<Value>(line) else {
        return None;
    };
    if string(&record, "type") != Some("assistant") {
        return None;
    }
    // Subagent work shares the transcript in some versions; its requests
    // carry their own prefix and do not refresh the main conversation's.
    if record.get("isSidechain").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let message = record.get("message").and_then(Value::as_object)?;
    let usage = message.get("usage").and_then(Value::as_object)?;
    let request = string(&record, "requestId")
        .or_else(|| string(message, "id"))?
        .to_owned();
    let started_at = string(&record, "timestamp").and_then(transcript_seconds)?;
    let count = |object: &Map<String, Value>, key: &str| {
        object.get(key).and_then(Value::as_u64).unwrap_or(0)
    };
    let creation = usage.get("cache_creation").and_then(Value::as_object);
    let one_hour = creation.map_or(0, |it| count(it, "ephemeral_1h_input_tokens"));
    let five_minutes = creation.map_or(0, |it| count(it, "ephemeral_5m_input_tokens"));
    let ttl = if one_hour > 0 {
        Some(ONE_HOUR_SECONDS)
    } else if five_minutes > 0 {
        Some(FIVE_MINUTES_SECONDS)
    } else {
        None
    };
    Some(Observation {
        request,
        started_at,
        input: count(usage, "input_tokens"),
        cache_read: count(usage, "cache_read_input_tokens"),
        cache_creation: count(usage, "cache_creation_input_tokens"),
        output: count(usage, "output_tokens"),
        ttl,
    })
}

/// Whether the line is a user line of the main conversation: a prompt, or a
/// tool result handed back. Either one newer than the last usage is input the
/// model has yet to answer in this file. Any main user line counts, not only
/// tool results and typed prompts, because an unknown estimate costs a
/// missing clock while a wrong anchor shows an expiry that has not happened.
fn is_main_user_line(line: &[u8]) -> bool {
    let Ok(Value::Object(record)) = serde_json::from_slice::<Value>(line) else {
        return false;
    };
    string(&record, "type") == Some("user")
        && record.get("isSidechain").and_then(Value::as_bool) != Some(true)
}

/// Folds two lines of one streamed request. The input-side counters repeat on
/// every line, and the output count only grows, so the larger value of each
/// is the request's; the earliest timestamp is when it started.
fn merge(later: Observation, earlier: &Observation) -> Observation {
    Observation {
        request: later.request,
        started_at: later.started_at.min(earlier.started_at),
        input: later.input.max(earlier.input),
        cache_read: later.cache_read.max(earlier.cache_read),
        cache_creation: later.cache_creation.max(earlier.cache_creation),
        output: later.output.max(earlier.output),
        ttl: later.ttl.or(earlier.ttl),
    }
}

/// Whole seconds for a transcript timestamp such as
/// `2026-10-07T12:34:56.789Z`. The fraction is dropped, which moves the
/// anchor earlier by under a second; any other shape, including an offset,
/// is not something Claude Code writes and is ignored rather than guessed at.
fn transcript_seconds(value: &str) -> Option<u64> {
    let whole = value.get(..19)?;
    let rest = value.get(19..)?;
    let is_utc = rest == "Z"
        || rest
            .strip_prefix('.')
            .and_then(|fraction| fraction.strip_suffix('Z'))
            .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()));
    if !is_utc {
        return None;
    }
    parse_utc_seconds(&format!("{whole}Z"))
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One assistant line in the shape Claude Code writes, reduced to the
    /// fields the estimate reads.
    fn line(request: &str, timestamp: &str, usage: &str) -> String {
        format!(
            r#"{{"type":"assistant","isSidechain":false,"requestId":"{request}","timestamp":"{timestamp}","message":{{"id":"msg_{request}","role":"assistant","usage":{usage}}}}}"#
        )
    }

    fn usage(read: u64, creation: u64, one_hour: u64, five_minutes: u64) -> String {
        format!(
            r#"{{"input_tokens":3,"cache_read_input_tokens":{read},"cache_creation_input_tokens":{creation},"output_tokens":120,"cache_creation":{{"ephemeral_1h_input_tokens":{one_hour},"ephemeral_5m_input_tokens":{five_minutes}}}}}"#
        )
    }

    fn transcript(lines: &[String]) -> Vec<u8> {
        let mut bytes = lines.join("\n").into_bytes();
        bytes.push(b'\n');
        bytes
    }

    #[test]
    fn a_one_hour_write_names_the_one_hour_bucket() {
        let bytes = transcript(&[
            r#"{"type":"user","message":{"content":"hi"}}"#.to_owned(),
            line(
                "req_1",
                "2026-10-07T12:00:05.120Z",
                &usage(500_000, 2_000, 2_000, 0),
            ),
        ]);
        let window = transcript_cache_window(&bytes).expect("window");
        assert_eq!(window.observed_at, "2026-10-07T12:00:05Z");
        assert_eq!(window.ttl_seconds, 3600);
        assert_eq!(window.rewrite_tokens, Some(3 + 500_000 + 2_000 + 120));
        assert_eq!(window.precision, CachePrecision::Estimated);
    }

    #[test]
    fn a_five_minute_write_names_the_five_minute_bucket() {
        let bytes = transcript(&[line(
            "req_1",
            "2026-10-07T12:00:05Z",
            &usage(0, 9_000, 0, 9_000),
        )]);
        let window = transcript_cache_window(&bytes).expect("window");
        assert_eq!(window.ttl_seconds, 300);
        assert_eq!(window.rewrite_tokens, Some(3 + 9_000 + 120));
    }

    #[test]
    fn a_read_only_request_inherits_the_bucket_of_an_earlier_write() {
        let bytes = transcript(&[
            line(
                "req_1",
                "2026-10-07T11:00:00Z",
                &usage(0, 40_000, 40_000, 0),
            ),
            line("req_2", "2026-10-07T11:30:00Z", &usage(40_000, 0, 0, 0)),
            line("req_3", "2026-10-07T12:00:00Z", &usage(40_000, 0, 0, 0)),
        ]);
        let window = transcript_cache_window(&bytes).expect("window");
        assert_eq!(window.observed_at, "2026-10-07T12:00:00Z");
        assert_eq!(window.ttl_seconds, 3600);
        assert_eq!(window.rewrite_tokens, Some(3 + 40_000 + 120));
    }

    #[test]
    fn a_read_only_request_with_no_known_bucket_is_unknown() {
        let bytes = transcript(&[
            line("req_1", "2026-10-07T11:30:00Z", &usage(40_000, 0, 0, 0)),
            line("req_2", "2026-10-07T12:00:00Z", &usage(40_000, 0, 0, 0)),
        ]);
        assert_eq!(transcript_cache_window(&bytes), None);
        // A usage block from before Claude Code split the buckets says nothing
        // about the TTL either, and is not assumed to be five minutes.
        let legacy = r#"{"input_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":800,"output_tokens":5}"#;
        let bytes = transcript(&[line("req_1", "2026-10-07T12:00:00Z", legacy)]);
        assert_eq!(transcript_cache_window(&bytes), None);
    }

    #[test]
    fn a_request_that_cached_nothing_has_no_window() {
        let bytes = transcript(&[
            line(
                "req_1",
                "2026-10-07T11:00:00Z",
                &usage(0, 40_000, 40_000, 0),
            ),
            line("req_2", "2026-10-07T12:00:00Z", &usage(0, 0, 0, 0)),
        ]);
        assert_eq!(transcript_cache_window(&bytes), None);
        assert_eq!(transcript_cache_window(b""), None);
        assert_eq!(transcript_cache_window(b"{\"type\":\"user\"}\n"), None);
    }

    #[test]
    fn subagent_lines_never_stand_for_the_main_conversation() {
        let sidechain = line("req_9", "2026-10-07T12:30:00Z", &usage(0, 7_000, 0, 7_000))
            .replace(r#""isSidechain":false"#, r#""isSidechain":true"#);
        let bytes = transcript(&[
            line(
                "req_1",
                "2026-10-07T12:00:00Z",
                &usage(90_000, 1_000, 1_000, 0),
            ),
            sidechain,
        ]);
        let window = transcript_cache_window(&bytes).expect("window");
        assert_eq!(window.observed_at, "2026-10-07T12:00:00Z");
        assert_eq!(window.ttl_seconds, 3600);
    }

    #[test]
    fn a_streamed_request_is_anchored_at_its_earliest_line() {
        let bytes = transcript(&[
            line(
                "req_1",
                "2026-10-07T11:00:00Z",
                &usage(0, 50_000, 50_000, 0),
            ),
            line(
                "req_2",
                "2026-10-07T12:00:01.900Z",
                &usage(50_000, 400, 400, 0),
            ),
            line(
                "req_2",
                "2026-10-07T12:00:09.000Z",
                &usage(50_000, 400, 400, 0),
            )
            .replace(r#""output_tokens":120"#, r#""output_tokens":900"#),
            line(
                "req_2",
                "2026-10-07T12:00:04.000Z",
                &usage(50_000, 400, 400, 0),
            ),
        ]);
        let window = transcript_cache_window(&bytes).expect("window");
        assert_eq!(window.observed_at, "2026-10-07T12:00:01Z");
        assert_eq!(window.rewrite_tokens, Some(3 + 50_000 + 400 + 900));
    }

    #[test]
    fn a_subagent_line_inside_a_streamed_request_does_not_split_it() {
        let sidechain = line("req_9", "2026-10-07T12:00:03Z", &usage(0, 7_000, 0, 7_000))
            .replace(r#""isSidechain":false"#, r#""isSidechain":true"#);
        let bytes = transcript(&[
            line("req_1", "2026-10-07T12:00:01Z", &usage(0, 800, 800, 0)),
            sidechain,
            line("req_1", "2026-10-07T12:00:05Z", &usage(0, 800, 800, 0)),
        ]);
        let window = transcript_cache_window(&bytes).expect("window");
        assert_eq!(window.observed_at, "2026-10-07T12:00:01Z");
        assert_eq!(window.ttl_seconds, 3600);
    }

    #[test]
    fn a_trailing_tool_result_means_the_final_response_is_missing() {
        let tool_result = r#"{"type":"user","isSidechain":false,"timestamp":"2026-10-07T12:00:20Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done"}]}}"#;
        let bytes = transcript(&[
            line("req_1", "2026-10-07T12:00:01Z", &usage(0, 800, 800, 0)),
            tool_result.to_owned(),
        ]);
        assert_eq!(transcript_cache_window(&bytes), None);

        // One that the model already answered changes nothing, and neither
        // does a subagent's.
        let answered = transcript(&[
            tool_result.to_owned(),
            line("req_2", "2026-10-07T12:00:30Z", &usage(800, 50, 50, 0)),
        ]);
        assert!(transcript_cache_window(&answered).is_some());
        let subagent = transcript(&[
            line("req_1", "2026-10-07T12:00:01Z", &usage(0, 800, 800, 0)),
            tool_result.replace(r#""isSidechain":false"#, r#""isSidechain":true"#),
        ]);
        assert!(transcript_cache_window(&subagent).is_some());
    }

    #[test]
    fn a_trailing_prompt_means_the_final_response_is_missing() {
        // A turn with no tools: Stop can run before its one response is
        // flushed, which leaves the previous turn's request as the newest.
        let prompt = r#"{"type":"user","isSidechain":false,"timestamp":"2026-10-07T12:10:00Z","message":{"role":"user","content":"and now the tests"}}"#;
        let bytes = transcript(&[
            line("req_1", "2026-10-07T12:00:01Z", &usage(0, 800, 800, 0)),
            prompt.to_owned(),
        ]);
        assert_eq!(transcript_cache_window(&bytes), None);

        // Once the response is written the estimate is back, anchored on it.
        let answered = transcript(&[
            line("req_1", "2026-10-07T12:00:01Z", &usage(0, 800, 800, 0)),
            prompt.to_owned(),
            line("req_2", "2026-10-07T12:10:02Z", &usage(800, 40, 40, 0)),
        ]);
        let window = transcript_cache_window(&answered).expect("window");
        assert_eq!(window.observed_at, "2026-10-07T12:10:02Z");

        // A subagent's prompt is not the main conversation's.
        let subagent = transcript(&[
            line("req_1", "2026-10-07T12:00:01Z", &usage(0, 800, 800, 0)),
            prompt.replace(r#""isSidechain":false"#, r#""isSidechain":true"#),
        ]);
        assert!(transcript_cache_window(&subagent).is_some());
    }

    #[test]
    fn a_trailing_subagent_result_carrying_usage_still_means_the_response_is_missing() {
        let task_result = r#"{"type":"user","isSidechain":false,"timestamp":"2026-10-07T12:03:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"done"}]}]},"toolUseResult":{"status":"completed","totalTokens":5000,"usage":{"input_tokens":4,"cache_read_input_tokens":3000,"output_tokens":900}}}"#;
        let bytes = transcript(&[
            line("req_1", "2026-10-07T12:00:01Z", &usage(0, 800, 800, 0)),
            task_result.to_owned(),
        ]);
        assert_eq!(transcript_cache_window(&bytes), None);
    }

    #[test]
    fn a_trailing_line_with_all_zero_usage_has_no_window() {
        // Claude Code writes synthetic assistant lines, such as an API error,
        // with every counter at zero; they cached nothing.
        let bytes = transcript(&[
            line("req_1", "2026-10-07T12:00:01Z", &usage(0, 800, 800, 0)),
            line("req_2", "2026-10-07T12:00:09Z", &usage(0, 0, 0, 0))
                .replace(r#""input_tokens":3"#, r#""input_tokens":0"#)
                .replace(r#""output_tokens":120"#, r#""output_tokens":0"#),
        ]);
        assert_eq!(transcript_cache_window(&bytes), None);
    }

    #[test]
    fn the_message_id_stands_in_for_a_missing_request_id() {
        let first = line("a", "2026-10-07T12:00:00Z", &usage(0, 500, 0, 500))
            .replace(r#""requestId":"a","#, "");
        let second = line("a", "2026-10-07T12:00:03Z", &usage(0, 500, 0, 500))
            .replace(r#""requestId":"a","#, "");
        let window = transcript_cache_window(&transcript(&[first, second])).expect("window");
        assert_eq!(window.observed_at, "2026-10-07T12:00:00Z");
        assert_eq!(window.ttl_seconds, 300);
    }

    #[test]
    fn truncated_and_malformed_lines_are_skipped() {
        let full = line("req_1", "2026-10-07T12:00:00Z", &usage(0, 2_000, 2_000, 0));
        // The tail can start in the middle of a line.
        let cut = full[40..].to_owned();
        let bytes = transcript(&[
            cut,
            "not json at all \"usage\"".to_owned(),
            r#"{"type":"assistant","message":{"usage":"none"}}"#.to_owned(),
            line("req_x", "yesterday", &usage(0, 9, 9, 0)),
            line("req_y", "2026-10-07T12:00:00+09:00", &usage(0, 9, 9, 0)),
            full,
            r#"{"type":"assistant","message":{"usage":{"#.to_owned(),
        ]);
        let window = transcript_cache_window(&bytes).expect("window");
        assert_eq!(window.observed_at, "2026-10-07T12:00:00Z");
        assert_eq!(window.ttl_seconds, 3600);
    }

    #[test]
    fn transcript_timestamps_parse_with_and_without_a_fraction() {
        assert_eq!(
            transcript_seconds("1970-01-01T00:01:00.5Z"),
            Some(60),
            "the fraction is dropped"
        );
        assert_eq!(transcript_seconds("1970-01-01T00:01:00Z"), Some(60));
        assert_eq!(transcript_seconds("1970-01-01T00:01:00.Z"), None);
        assert_eq!(transcript_seconds("1970-01-01T00:01:00"), None);
    }
}
