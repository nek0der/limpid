//! Reading the objects Codex's payloads and rollout lines are.

use serde_json::{Map, Value};

/// One rollout line as an object; a line cut in half by the tail, or
/// anything malformed, reads as nothing.
pub(crate) fn parse(line: &[u8]) -> Option<Map<String, Value>> {
    match serde_json::from_slice::<Value>(line) {
        Ok(Value::Object(record)) => Some(record),
        _ => None,
    }
}

pub(crate) fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

pub(crate) fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}
