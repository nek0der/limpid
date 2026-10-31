//! What Claude Code's transcript lines say of the requests they record,
//! shared by the cache window (`cache`) and a turn's usage (`tokens`).
//!
//! Each API request appears as one or more assistant lines that share a
//! `requestId` (the message id in versions that write none), every one
//! carrying the request's `message.usage`. The input counters repeat on every
//! line and the output count grows as the response streams, so a request's
//! usage is the larger value of each counter over its lines
//! (`TurnUsage::fuller`).

use serde_json::{Map, Value};
use weir_agent_model::TurnUsage;

/// One line as an object; a line cut in half by the tail, or anything
/// malformed, reads as nothing.
pub(crate) fn parse(line: &[u8]) -> Option<Map<String, Value>> {
    match serde_json::from_slice::<Value>(line) {
        Ok(Value::Object(record)) => Some(record),
        _ => None,
    }
}

/// The request an assistant line belongs to and the usage it records;
/// `None` for a line that records none (an error the API returned, a line
/// of another shape).
pub(crate) fn request_usage(record: &Map<String, Value>) -> Option<(&str, TurnUsage)> {
    let message = record.get("message").and_then(Value::as_object)?;
    let usage = message.get("usage").and_then(Value::as_object)?;
    let request = string(record, "requestId").or_else(|| string(message, "id"))?;
    let count = |key: &str| usage.get(key).and_then(Value::as_u64).unwrap_or(0);
    Some((
        request,
        TurnUsage {
            input_tokens: count("input_tokens"),
            cache_write_tokens: count("cache_creation_input_tokens"),
            cache_read_tokens: count("cache_read_input_tokens"),
            output_tokens: count("output_tokens"),
            is_partial: false,
        },
    ))
}

/// The words of a user line: its content when that is text, else its first
/// text block's.
pub(crate) fn user_text(record: &Map<String, Value>) -> Option<&str> {
    let content = record.get("message")?.get("content")?;
    content.as_str().or_else(|| {
        content
            .as_array()?
            .iter()
            .find(|part| part.get("type").and_then(Value::as_str) == Some("text"))?
            .get("text")?
            .as_str()
    })
}

/// Whether the line is a subagent's, written into the main transcript by
/// some versions.
pub(crate) fn is_sidechain(record: &Map<String, Value>) -> bool {
    record.get("isSidechain").and_then(Value::as_bool) == Some(true)
}

pub(crate) fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

pub(crate) fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}
