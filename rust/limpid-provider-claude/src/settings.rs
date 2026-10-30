//! The session's model and permission mode, as Claude Code's hooks say them.
//!
//! `permission_mode` comes on most events, `UserPromptSubmit`, `PreToolUse`,
//! and `Stop` among those we subscribe to, though not on `SessionStart` or
//! `PostModelSwitch`, so a mode shows from the first prompt. The model comes
//! only on `SessionStart` (`model`) and on `PostModelSwitch` (`to_model`,
//! since 2.1.251), which Claude sends after `/model`, the model picker, or a
//! switch it makes itself. Both name the resolved id (`claude-opus-5-5`, with
//! `[1m]` for the 1M context window), which we shorten to the name Claude
//! shows a person.

use limpid_agent_model::{PermissionMode, SessionSettings};
use serde_json::{Map, Value};

pub(crate) fn session_settings(object: &Map<String, Value>) -> SessionSettings {
    // A subagent's calls carry `agent_id`, and its model and mode are its
    // own, not the session's.
    if string(object, "agent_id").is_some_and(|id| !id.is_empty()) {
        return SessionSettings::default();
    }
    let model = match string(object, "hook_event_name") {
        Some("SessionStart") => string(object, "model"),
        Some("PostModelSwitch") => string(object, "to_model"),
        _ => None,
    };
    SessionSettings {
        model: model.map(display_name),
        permission_mode: string(object, "permission_mode").and_then(PermissionMode::parse),
    }
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

    fn settings(payload: &str) -> SessionSettings {
        session_settings(&parse_object(payload.as_bytes(), 1 << 20).expect("object"))
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
            permission_mode: mode,
        };
        assert_eq!(case("0000-SessionStart.json"), said(Some("Opus 5.5"), None));
        assert_eq!(
            case("0001-PostModelSwitch.json"),
            said(Some("Haiku 5.5"), None)
        );
        let default = Some(PermissionMode::Default);
        assert_eq!(case("0002-UserPromptSubmit.json"), said(None, default));
        assert_eq!(case("0003-Stop.json"), said(None, default));
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
