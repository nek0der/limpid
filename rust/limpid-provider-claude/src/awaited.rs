//! Reads from the transcript tail whether the tool call Claude made last has
//! ended, for the idle prompt.
//!
//! A question (`AskUserQuestion`) or a permission prompt that the person
//! declines with Esc sends no hook: the call was refused before it ran, so
//! there is no `PostToolUse` or `PostToolUseFailure`, and Claude does not run
//! `Stop` for a stop the user interrupted. The transcript is the only place
//! that says so. It gains a `tool_result` for the call (`is_error`, "User
//! rejected tool use") and then a user line that reads
//! "[Request interrupted by user for tool use]". The idle prompt a minute
//! later is the first hook after that, so it carries what the transcript
//! shows and the record rules decide what it ends.
//!
//! A call still waiting on the person has neither line after it. One that is
//! answered or approved has its result; its `PostToolUse` (or the next tool's
//! `PreToolUse`) moves the run on before any idle prompt does.

use serde_json::{Map, Value};

/// This is the text Claude writes as a user line when the person interrupts it.
/// Claude adds " for tool use" when the interrupt refused a tool call, and
/// writes the bare form for an interrupt while the model was writing.
pub(crate) const INTERRUPT_PREFIX: &str = "[Request interrupted by user";

/// This says how the tool call Claude made last stands in the transcript tail.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AwaitedCall {
    /// There is no tool call in the tail, or one of the latest message's
    /// calls has neither a result nor an interrupt after it.
    Open,
    /// Every call of the latest message has a result: answered, approved,
    /// or refused with words the turn goes on from.
    Returned,
    /// An interrupt line follows the latest call: the person stopped the
    /// turn there, as Esc at a question or permission prompt does.
    Interrupted,
}

/// Returns whether every tool call of the latest assistant message that made
/// one has a result, or an interrupt line follows that message. It is `false`
/// when the tail shows no tool call, or one of them has neither: an unknown
/// is read as a wait still open, because ending a live question would hide it
/// from the person.
///
/// The calls of one message are read together because Claude can make
/// several at once and ask permission for one while another has already
/// returned. Claude writes each content block as its own line with the
/// message's id, so the message is the run of tool lines with that id.
pub(crate) fn transcript_awaited_call_ended(transcript: &[u8]) -> bool {
    awaited_call(transcript) != AwaitedCall::Open
}

/// Returns whether the person stopped the turn at the call Claude made last:
/// an interrupt line follows it. It is stricter than
/// `transcript_awaited_call_ended` because the app reads it while the run
/// still waits, with no idle minute behind it: a result alone is also an
/// answered question or an approved command, whose own hook moves the run on
/// a moment later, and a refusal with words lets the turn go on.
pub(crate) fn transcript_awaited_call_interrupted(transcript: &[u8]) -> bool {
    awaited_call(transcript) == AwaitedCall::Interrupted
}

/// Returns how the latest tool call stands (`AwaitedCall`), read from the end.
fn awaited_call(transcript: &[u8]) -> AwaitedCall {
    let mut ended: Vec<String> = Vec::new();
    let mut is_interrupted = false;
    // This holds the message id of the latest tool call once it is found; the
    // inner `None` is a message without an id, which matches only another
    // one.
    let mut latest: Option<Option<String>> = None;
    for line in transcript.split(|byte| *byte == b'\n').rev() {
        // Substring checks keep the JSON parse for the lines that can matter:
        // a tool call, a tool result (`tool_use_id`), or an interrupt.
        if !contains(line, b"tool_use") && !contains(line, INTERRUPT_PREFIX.as_bytes()) {
            continue;
        }
        let Ok(Value::Object(record)) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        // A subagent's lines are its own conversation's, not the call the
        // main thread waits on.
        if record.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(message) = record.get("message").and_then(Value::as_object) else {
            continue;
        };
        match record.get("type").and_then(Value::as_str) {
            Some("user") => {
                // A result read here is newer than every call still ahead of
                // us, so it can be an earlier sibling's, written between two
                // calls of one message. An interrupt counts only after the
                // latest call: one before it ended something else.
                let counts_interrupt = latest.is_none();
                for block in blocks(message) {
                    match block.get("type").and_then(Value::as_str) {
                        Some("tool_result") => {
                            if let Some(id) = block.get("tool_use_id").and_then(Value::as_str) {
                                ended.push(id.to_owned());
                            }
                        }
                        Some("text") if counts_interrupt => {
                            is_interrupted |= is_interrupt(block.get("text"));
                        }
                        _ => {}
                    }
                }
                if counts_interrupt {
                    is_interrupted |= is_interrupt(message.get("content"));
                }
            }
            Some("assistant") => {
                let calls: Vec<&Map<String, Value>> = blocks(message)
                    .filter(|block| block.get("type").and_then(Value::as_str) == Some("tool_use"))
                    .collect();
                if calls.is_empty() {
                    continue;
                }
                let id = message.get("id").and_then(Value::as_str).map(str::to_owned);
                match &latest {
                    None if is_interrupted => return AwaitedCall::Interrupted,
                    None => latest = Some(id),
                    // An earlier message: every call of the latest one ended.
                    Some(latest_id) if *latest_id != id => return AwaitedCall::Returned,
                    Some(_) => {}
                }
                let has_open_call = calls.iter().any(|call| {
                    call.get("id")
                        .and_then(Value::as_str)
                        .is_none_or(|id| !ended.iter().any(|ended| ended == id))
                });
                if has_open_call {
                    return AwaitedCall::Open;
                }
            }
            _ => {}
        }
    }
    if latest.is_some() {
        AwaitedCall::Returned
    } else {
        AwaitedCall::Open
    }
}

/// Returns the content blocks of a message; content that is a string has none.
fn blocks(message: &Map<String, Value>) -> impl Iterator<Item = &Map<String, Value>> {
    message
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_object)
}

fn is_interrupt(text: Option<&Value>) -> bool {
    text.and_then(Value::as_str)
        .is_some_and(|text| text.starts_with(INTERRUPT_PREFIX))
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(message: &str, id: &str) -> String {
        format!(
            r#"{{"type":"assistant","message":{{"id":"{message}","role":"assistant","content":[{{"type":"tool_use","id":"{id}","name":"AskUserQuestion","input":{{}}}}]}}}}"#
        )
    }

    fn result(id: &str) -> String {
        format!(
            r#"{{"type":"user","message":{{"role":"user","content":[{{"type":"tool_result","tool_use_id":"{id}","is_error":true,"content":"User rejected tool use"}}]}},"toolUseResult":"User rejected tool use","toolDenialKind":"user-rejected"}}"#
        )
    }

    const INTERRUPT: &str = r#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#;

    fn ended(lines: &[String]) -> bool {
        transcript_awaited_call_ended(lines.join("\n").as_bytes())
    }

    #[test]
    fn a_declined_call_has_ended() {
        assert!(ended(&[
            call("m1", "t1"),
            result("t1"),
            INTERRUPT.to_owned()
        ]));
        // Either line alone says so.
        assert!(ended(&[call("m1", "t1"), result("t1")]));
        assert!(ended(&[call("m1", "t1"), INTERRUPT.to_owned()]));
    }

    #[test]
    fn a_call_with_nothing_after_it_is_still_open() {
        assert!(!ended(&[call("m1", "t1")]));
        // A result for an earlier call, or an interrupt before this call,
        // says nothing about it.
        assert!(!ended(&[
            call("m0", "t0"),
            result("t0"),
            INTERRUPT.to_owned(),
            call("m1", "t1"),
        ]));
        assert!(!ended(&[]));
        assert!(!ended(&[INTERRUPT.to_owned()]));
    }

    #[test]
    fn every_call_of_the_latest_message_must_have_ended() {
        // The permission prompt waits on `t2` while `t1` has returned.
        assert!(!ended(&[call("m1", "t1"), call("m1", "t2"), result("t1")]));
        assert!(!ended(&[call("m1", "t1"), call("m1", "t2"), result("t2")]));
        assert!(ended(&[
            call("m1", "t1"),
            call("m1", "t2"),
            result("t1"),
            result("t2"),
        ]));
        // A sibling's result written between the two calls counts too.
        assert!(ended(&[
            call("m1", "t1"),
            result("t1"),
            call("m1", "t2"),
            result("t2"),
        ]));
        assert!(!ended(&[call("m1", "t1"), result("t1"), call("m1", "t2")]));
        // An earlier message's open call is not the one waited on.
        assert!(ended(&[call("m0", "t0"), call("m1", "t1"), result("t1")]));
    }

    #[test]
    fn a_subagents_lines_are_not_the_main_threads() {
        let sidechain = call("m2", "t2").replacen(
            r#""type":"assistant""#,
            r#""type":"assistant","isSidechain":true"#,
            1,
        );
        assert!(ended(&[call("m1", "t1"), result("t1"), sidechain]));
        assert!(!ended(&[
            call("m1", "t1"),
            result("t1").replacen(r#""type":"user""#, r#""type":"user","isSidechain":true"#, 1,)
        ]));
    }

    fn interrupted(lines: &[String]) -> bool {
        transcript_awaited_call_interrupted(lines.join("\n").as_bytes())
    }

    #[test]
    fn only_an_interrupt_after_the_call_says_the_person_declined_it() {
        assert!(interrupted(&[
            call("m1", "t1"),
            result("t1"),
            INTERRUPT.to_owned()
        ]));
        assert!(interrupted(&[call("m1", "t1"), INTERRUPT.to_owned()]));
        // A result alone is also an answer or an approval, which its own
        // hook follows.
        assert!(!interrupted(&[call("m1", "t1"), result("t1")]));
        assert!(!interrupted(&[call("m1", "t1")]));
        // An interrupt before the call ended something else.
        assert!(!interrupted(&[
            call("m0", "t0"),
            INTERRUPT.to_owned(),
            call("m1", "t1"),
        ]));
        assert!(!interrupted(&[INTERRUPT.to_owned()]));
    }

    /// This is the tail of a real Claude Code 2.1.309 transcript, scrubbed of
    /// the person's paths, prompt, and system prompt: the question, then the
    /// Esc that declined it, and the lines Claude writes after.
    const DECLINED: &[u8] =
        include_bytes!("../../fixtures/transcripts/claude-2.1.309-question-declined.jsonl");
    /// This is the same transcript while the question is still up.
    const OPEN: &[u8] =
        include_bytes!("../../fixtures/transcripts/claude-2.1.309-question-open.jsonl");

    #[test]
    fn a_real_declined_question_reads_as_interrupted_and_an_open_one_as_open() {
        assert_eq!(awaited_call(DECLINED), AwaitedCall::Interrupted);
        assert!(transcript_awaited_call_ended(DECLINED));
        assert_eq!(awaited_call(OPEN), AwaitedCall::Open);
        assert!(!transcript_awaited_call_ended(OPEN));
    }
}
