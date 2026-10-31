//! The session's model, effort, and permission mode, as Claude Code says them.
//!
//! `permission_mode` comes on most events, `UserPromptSubmit`, `PreToolUse`,
//! and `Stop` among those we subscribe to, though not on `SessionStart` or
//! `PostModelSwitch`, so a mode shows from the first prompt. The model comes
//! only on `SessionStart` (`model`) and on `PostModelSwitch` (`to_model`,
//! since 2.1.251), which Claude sends after `/model`, the model picker, or a
//! switch it makes itself. Both name the resolved id (`claude-opus-5-5`, with
//! `[1m]` for the 1M context window), which we shorten to the name Claude
//! shows a person. A resumed session's `SessionStart` names no model, so a
//! `Stop` also reads the one its answer used from the transcript. The effort
//! comes as `effort.level` on `PreToolUse` and `Stop` among others, not on
//! `SessionStart` or `UserPromptSubmit`, so it shows from the turn's first tool
//! or its end.

use limpid_agent_model::{PermissionMode, SessionSettings};
use serde_json::{Map, Value};

use crate::transcript::{contains, is_sidechain};

pub(crate) fn session_settings(
    object: &Map<String, Value>,
    transcript: Option<&[u8]>,
) -> SessionSettings {
    // A subagent's calls carry `agent_id`, and its model and mode are its
    // own, not the session's.
    if string(object, "agent_id").is_some_and(|id| !id.is_empty()) {
        return SessionSettings::default();
    }
    let answer = transcript
        .filter(|_| string(object, "hook_event_name") == Some("Stop"))
        .map_or(TurnsAnswer::Unread, turns_answer);
    let model = match string(object, "hook_event_name") {
        Some("SessionStart") => string(object, "model"),
        Some("PostModelSwitch") => string(object, "to_model"),
        _ => None,
    };
    SessionSettings {
        model: model.map(display_name),
        is_awaiting_answer: matches!(answer, TurnsAnswer::Awaited),
        answered_model: match answer {
            TurnsAnswer::Model(id) => Some(display_name(&id)),
            TurnsAnswer::Awaited | TurnsAnswer::Unread => None,
        },
        effort: object
            .get("effort")
            .and_then(Value::as_object)
            .and_then(|effort| string(effort, "level"))
            .filter(|level| !level.is_empty())
            .map(str::to_owned),
        permission_mode: string(object, "permission_mode").and_then(PermissionMode::parse),
    }
}

/// What the transcript says of the model that answered the turn.
enum TurnsAnswer {
    /// The model of the turn's last answer on the main thread.
    Model(String),
    /// The turn's user line comes last: Claude writes an answer a moment
    /// after it calls `Stop`, so the answer may be on its way.
    Awaited,
    /// No transcript was read, or it holds neither line.
    Unread,
}

/// Reads from the end back to the turn's last user line, as an answer before
/// it may have come from a model since switched away from. Claude Code's own
/// notices name `<synthetic>`, no model, and are passed over.
fn turns_answer(transcript: &[u8]) -> TurnsAnswer {
    for line in transcript.split(|byte| *byte == b'\n').rev() {
        if !contains(line, br#""assistant""#) && !contains(line, br#""user""#) {
            continue;
        }
        let Ok(Value::Object(record)) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if is_sidechain(&record) {
            continue;
        }
        match string(&record, "type") {
            Some("assistant") => {
                let model = record
                    .get("message")
                    .and_then(Value::as_object)
                    .and_then(|message| string(message, "model"))
                    .filter(|model| !model.is_empty() && *model != "<synthetic>");
                if let Some(model) = model {
                    return TurnsAnswer::Model(model.to_owned());
                }
            }
            // Claude Code's own lines, such as a stop hook's feedback, come
            // after the answer and say nothing of the turn's user line.
            Some("user") if record.get("isMeta").and_then(Value::as_bool) == Some(true) => {}
            Some("user") => return TurnsAnswer::Awaited,
            _ => {}
        }
    }
    TurnsAnswer::Unread
}

/// `claude-opus-5-5` as `Opus 5.5`, `claude-fable-5-1[1m]` as
/// `Fable 5.1 1M`, and the older order, `claude-3-5-sonnet-20241022`, as
/// `Sonnet 3.5`. An id of any other shape (a provider's own, a custom
/// deployment) is shown as it is, since a guess at its name could name the
/// wrong model.
fn display_name(id: &str) -> String {
    let (base, long_context) = match id.strip_suffix("[1m]") {
        Some(base) => (base, true),
        None => (id, false),
    };
    let Some(name) = base.strip_prefix("claude-").and_then(family_and_version) else {
        return id.to_owned();
    };
    if long_context {
        format!("{name} 1M")
    } else {
        name
    }
}

/// `opus-5-5` or `3-5-sonnet`, with or without a trailing date, as
/// `Opus 5.5`; `None` for any other shape.
fn family_and_version(rest: &str) -> Option<String> {
    let mut parts: Vec<&str> = rest.split('-').collect();
    if parts
        .last()
        .is_some_and(|part| part.len() == 8 && is_number(part))
    {
        parts.pop();
    }
    let family_index = parts.iter().position(|part| !is_number(part))?;
    let family = parts[family_index];
    let version: Vec<&str> = parts
        .iter()
        .enumerate()
        .filter(|(index, _)| *index != family_index)
        .map(|(_, part)| *part)
        .collect();
    if version.is_empty()
        || version.len() > 2
        || !version.iter().all(|part| is_number(part))
        || !family
            .chars()
            .all(|character| character.is_ascii_lowercase())
    {
        return None;
    }
    let mut characters = family.chars();
    let first = characters.next()?.to_ascii_uppercase();
    Some(format!(
        "{first}{} {}",
        characters.as_str(),
        version.join(".")
    ))
}

fn is_number(part: &str) -> bool {
    !part.is_empty() && part.chars().all(|character| character.is_ascii_digit())
}

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;
    use limpid_agent_model::parse_object;

    #[test]
    fn a_stop_reads_the_model_of_the_turns_answer() {
        let stop = br#"{"hook_event_name":"Stop"}"#;
        let answered = |transcript: &str| {
            let object = parse_object(stop, 1 << 20).expect("object");
            session_settings(&object, Some(transcript.as_bytes())).answered_model
        };
        let answer = |model: &str, sidechain: bool| {
            format!(
                r#"{{"type":"assistant","isSidechain":{sidechain},"message":{{"model":"{model}"}}}}"#
            )
        };
        let user = r#"{"type":"user","isSidechain":false,"message":{}}"#;
        assert_eq!(
            answered(&format!(
                "{}\n{}\n{}\n{}\n",
                user,
                answer("claude-opus-5-5", false),
                answer("claude-haiku-5-5", true),
                answer("<synthetic>", false)
            ))
            .as_deref(),
            Some("Opus 5.5")
        );
        // A tool's result before the answer and Claude Code's own line after
        // it do not hide the answer.
        let meta = r#"{"type":"user","isSidechain":false,"isMeta":true,"message":{}}"#;
        assert_eq!(
            answered(&format!(
                "{}\n{}\n{}\n",
                user,
                answer("claude-opus-5-5", false),
                meta
            ))
            .as_deref(),
            Some("Opus 5.5")
        );
        // An answer not yet written says nothing of the model an earlier
        // one used, and the runtime may read again for it.
        let waiting = format!(
            "{}\n{}\n{}\n",
            answer("claude-opus-5-5", false),
            user,
            answer("<synthetic>", false)
        );
        assert_eq!(answered(&waiting), None);
        let object = parse_object(stop, 1 << 20).expect("object");
        assert!(session_settings(&object, Some(waiting.as_bytes())).is_awaiting_answer);

        let prompt =
            parse_object(br#"{"hook_event_name":"UserPromptSubmit"}"#, 1 << 20).expect("object");
        let transcript = answer("claude-opus-5-5", false);
        assert_eq!(
            session_settings(&prompt, Some(transcript.as_bytes())).answered_model,
            None
        );
    }

    #[test]
    fn the_effort_comes_from_the_sessions_own_calls() {
        assert_eq!(
            settings(r#"{"hook_event_name":"Stop","effort":{"level":"xhigh"}}"#)
                .effort
                .as_deref(),
            Some("xhigh")
        );
        assert_eq!(
            settings(r#"{"hook_event_name":"UserPromptSubmit"}"#).effort,
            None
        );
        assert!(
            settings(r#"{"hook_event_name":"PreToolUse","agent_id":"a","effort":{"level":"low"}}"#)
                .is_empty()
        );
    }

    fn settings(payload: &str) -> SessionSettings {
        session_settings(
            &parse_object(payload.as_bytes(), 1 << 20).expect("object"),
            None,
        )
    }

    #[test]
    fn model_ids_read_as_the_names_claude_shows() {
        for (id, name) in [
            ("claude-opus-5-5", "Opus 5.5"),
            ("claude-fable-5-1[1m]", "Fable 5.1 1M"),
            ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
            ("claude-opus-4-20250514", "Opus 4"),
            ("claude-3-5-haiku-20241022", "Haiku 3.5"),
            (
                "us.anthropic.claude-opus-5-5-v1:0",
                "us.anthropic.claude-opus-5-5-v1:0",
            ),
            ("claude-opus", "claude-opus"),
            ("my-model", "my-model"),
        ] {
            assert_eq!(display_name(id), name, "{id}");
        }
    }

    /// The recording of a session switched with `/model haiku` and then
    /// prompted once (`fixtures/claude/2026-10/model-switch`): the start and
    /// the switch name the model and no mode, and the prompt and the stop
    /// name the mode and no model.
    #[test]
    fn the_model_comes_from_the_start_and_the_switch_and_the_mode_from_the_turn() {
        let case = |name: &str| {
            let path = format!(
                "{}/../fixtures/claude/2026-10/model-switch/{name}",
                env!("CARGO_MANIFEST_DIR")
            );
            settings(&std::fs::read_to_string(&path).expect("a recorded payload"))
        };
        let said = |model: Option<&str>, mode: Option<PermissionMode>| SessionSettings {
            model: model.map(str::to_owned),
            answered_model: None,
            is_awaiting_answer: false,
            effort: None,
            permission_mode: mode,
        };
        assert_eq!(case("0000-SessionStart.json"), said(Some("Opus 5.5"), None));
        assert_eq!(
            case("0001-PostModelSwitch.json"),
            said(Some("Haiku 5.5"), None)
        );
        let default = Some(PermissionMode::Default);
        assert_eq!(case("0002-UserPromptSubmit.json"), said(None, default));
        assert_eq!(
            case("0003-Stop.json"),
            SessionSettings {
                effort: Some("medium".to_owned()),
                ..said(None, default)
            }
        );
        // Only the start and the switch name the session's model.
        assert_eq!(
            settings(r#"{"hook_event_name":"PreToolUse","model":"claude-haiku-5-5"}"#),
            said(None, None)
        );
    }

    #[test]
    fn a_subagents_call_says_nothing_of_the_session() {
        assert!(
            settings(
                r#"{"hook_event_name":"PreToolUse","agent_id":"a1","agent_type":"Explore","permission_mode":"acceptEdits"}"#
            )
            .is_empty()
        );
    }

    #[test]
    fn a_mode_this_build_does_not_know_is_not_said() {
        assert_eq!(
            settings(r#"{"hook_event_name":"Stop","permission_mode":"yolo"}"#).permission_mode,
            None
        );
    }
}
