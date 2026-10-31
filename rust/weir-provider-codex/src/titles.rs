//! The name Codex gives a session. Codex names a thread from its first
//! prompt, and `/rename` names it again; either way it appends
//! `{"id","thread_name","updated_at"}` to `session_index.jsonl` under its
//! home, where the latest line for an id is its name
//! (`codex-rs/rollout/src/session_index.rs`, Codex CLI 0.164.0). The rollout
//! never holds the name, so the runtime reads this file beside it.
//!
//! Codex writes the name its model makes a few seconds after the first
//! prompt, so the first prompt's hook finds none, and the turn's `Stop`
//! does. A resumed session has its name from its `SessionStart`. The file
//! does not say whether the person or Codex chose the name, so it is read as
//! the session's title, the one a provider keeps for the session.

use crate::json::{contains, parse, string};
use std::path::PathBuf;
use weir_agent_model::{
    HookContext, MAX_HOOK_INPUT_BYTES, NormalizeError, RawHookInput, Titles, parse_object,
};

/// Codex's index of thread names, under its home.
const SESSION_INDEX_FILE: &str = "session_index.jsonl";

/// The index, for the events whose normalization carries titles.
pub(crate) fn title_index_path(
    input: RawHookInput<'_>,
    context: &HookContext,
) -> Result<Option<PathBuf>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let carries_titles = matches!(
        string(&object, "hook_event_name"),
        Some("SessionStart" | "UserPromptSubmit" | "Stop")
    );
    Ok(carries_titles
        .then_some(context.provider_home.as_ref())
        .flatten()
        .map(|home| home.join(SESSION_INDEX_FILE)))
}

/// The latest name the index gives the payload's session. A blank name is
/// passed over for an earlier one, as Codex's own reader does
/// (`find_thread_names_by_ids`).
pub(crate) fn indexed_titles(input: RawHookInput<'_>, index: &[u8]) -> Option<Titles> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
    let session = string(&object, "session_id").filter(|id| !id.is_empty())?;
    let name = index
        .split(|byte| *byte == b'\n')
        .rev()
        // Most lines name other sessions; the id check keeps the JSON parse
        // for this one's.
        .filter(|line| contains(line, session.as_bytes()))
        .filter_map(parse)
        .filter(|entry| string(entry, "id") == Some(session))
        .find_map(|entry| {
            string(&entry, "thread_name")
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(str::to_owned)
        })?;
    Some(Titles {
        session_title: Some(name),
        generated_title: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use uuid::Uuid;

    const SESSION: &str = "01a17d88-d294-7bf3-9afa-01908d0365ef";

    fn titles(payload: &str, index: &str) -> Option<Titles> {
        indexed_titles(
            RawHookInput {
                bytes: payload.as_bytes(),
                transcript: None,
            },
            index.as_bytes(),
        )
    }

    fn stop() -> String {
        format!(r#"{{"hook_event_name":"Stop","session_id":"{SESSION}"}}"#)
    }

    #[test]
    fn the_latest_name_of_the_session_is_its_title() {
        let index = format!(
            concat!(
                "me\",\"updated_at\":\"cut by the tail\"}}\n",
                "{{\"id\":\"{0}\",\"thread_name\":\"Choose a license\",\"updated_at\":\"t1\"}}\n",
                "{{\"id\":\"other\",\"thread_name\":\"Another\",\"updated_at\":\"t2\"}}\n",
                "{{\"id\":\"{0}\",\"thread_name\":\"Choose project license\",\"updated_at\":\"t3\"}}\n",
                "{{\"id\":\"{0}\",\"thread_name\":\"  \",\"updated_at\":\"t4\"}}\n",
            ),
            SESSION
        );
        assert_eq!(
            titles(&stop(), &index),
            Some(Titles {
                session_title: Some("Choose project license".into()),
                generated_title: None,
            })
        );
    }

    #[test]
    fn a_session_the_index_does_not_name_has_no_title() {
        let index = "{\"id\":\"other\",\"thread_name\":\"Another\",\"updated_at\":\"t\"}\n";
        assert_eq!(titles(&stop(), index), None);
        assert_eq!(titles(&stop(), ""), None);
        assert_eq!(
            titles(r#"{"hook_event_name":"Stop"}"#, index),
            None,
            "a payload without a session id"
        );
    }

    #[test]
    fn only_the_events_that_carry_titles_read_the_index() {
        let context = HookContext {
            run_id: Uuid::nil(),
            pane_id: Uuid::nil(),
            tmux: None,
            pid: None,
            invocation_id: None,
            provider_home: Some(Path::new("/Users/example/.codex").to_path_buf()),
            hook_directory: None,
        };
        let path = |event: &str| {
            title_index_path(
                RawHookInput {
                    bytes: format!(r#"{{"hook_event_name":"{event}"}}"#).as_bytes(),
                    transcript: None,
                },
                &context,
            )
            .expect("an object")
        };
        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            assert_eq!(
                path(event),
                Some(Path::new("/Users/example/.codex/session_index.jsonl").to_path_buf()),
                "{event}"
            );
        }
        assert_eq!(path("PreToolUse"), None);
        let homeless = HookContext {
            provider_home: None,
            ..context
        };
        assert_eq!(
            title_index_path(
                RawHookInput {
                    bytes: br#"{"hook_event_name":"Stop"}"#,
                    transcript: None,
                },
                &homeless,
            )
            .expect("an object"),
            None
        );
    }
}
