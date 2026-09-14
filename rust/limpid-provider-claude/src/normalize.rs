//! Maps Claude Code hook payloads to neutral events.
//!
//! The mapping mirrors what `claude-shim/limpid-hook` did and is checked
//! against the recorded fixtures under `rust/fixtures/claude`. Titles come
//! from two places: `SessionStart` carries `session_title`, and the
//! transcript's latest `ai-title` line carries the observed titles that this
//! adapter reads on prompt submit and stop, because Claude has no live title
//! event.

use limpid_agent_model::{
    AgentEvent, MAX_HOOK_INPUT_BYTES, NormalizeError, RawHookInput, Titles, parse_object,
};
use serde_json::{Map, Value};

pub(crate) fn normalize(input: RawHookInput<'_>) -> Result<Vec<AgentEvent>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let event_name = string(&object, "hook_event_name")
        .unwrap_or("unknown")
        .to_owned();
    let cwd = string(&object, "cwd").map(str::to_owned);
    let event = match event_name.as_str() {
        "SessionStart" => AgentEvent::SessionStarted {
            compact: string(&object, "source") == Some("compact"),
            session_id: string(&object, "session_id").map(str::to_owned),
            session_title: string(&object, "session_title").map(str::to_owned),
            cwd,
        },
        "SessionEnd" => AgentEvent::SessionEnded {
            reason: string(&object, "reason").map(str::to_owned),
            session_id: string(&object, "session_id").map(str::to_owned),
        },
        "UserPromptSubmit" => AgentEvent::PromptSubmitted {
            prompt: string(&object, "prompt").unwrap_or_default().to_owned(),
            titles: input.transcript.and_then(transcript_titles),
            cwd,
        },
        "PreToolUse" => pre_tool_use(&object),
        "Notification" => match string(&object, "notification_type") {
            Some("permission_prompt") => AgentEvent::ApprovalRequested {
                detail: string(&object, "message").map(str::to_owned),
            },
            _ => extension(&event_name, object),
        },
        "PreCompact" => AgentEvent::Compacting {
            context_tokens: object.get("current_token_count").and_then(Value::as_u64),
        },
        "Stop" => AgentEvent::TurnFinished {
            titles: input.transcript.and_then(transcript_titles),
        },
        "StopFailure" => AgentEvent::Failed {
            // Recorded payloads carry the reason under `error`; the shell
            // receiver expected `error_type`, kept as a fallback.
            error: string(&object, "error")
                .or_else(|| string(&object, "error_type"))
                .unwrap_or("error")
                .to_owned(),
        },
        "CwdChanged" => {
            let new_cwd = ["new_cwd", "newCwd", "cwd"]
                .iter()
                .find_map(|key| string(&object, key))
                .unwrap_or_default()
                .to_owned();
            AgentEvent::CwdChanged {
                new_cwd,
                old_cwd: ["old_cwd", "oldCwd", "previous_cwd"]
                    .iter()
                    .find_map(|key| string(&object, key))
                    .map(str::to_owned),
            }
        }
        _ => extension(&event_name, object),
    };
    Ok(vec![event])
}

/// Titles are read from the transcript on the two events the shell receiver
/// read it on: prompt submit and stop.
pub(crate) fn transcript_path(input: RawHookInput<'_>) -> Result<Option<String>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    if !matches!(
        string(&object, "hook_event_name"),
        Some("UserPromptSubmit" | "Stop")
    ) {
        return Ok(None);
    }
    Ok(string(&object, "transcript_path")
        .filter(|path| {
            std::path::Path::new(path)
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
        })
        .map(str::to_owned))
}

fn pre_tool_use(object: &Map<String, Value>) -> AgentEvent {
    let tool = string(object, "tool_name").unwrap_or_default();
    let tool_input = object.get("tool_input");
    if tool == "AskUserQuestion" {
        // The question text is what the attention card shows; fall back to
        // the tool name when the payload shape is not the documented one.
        let question = tool_input
            .and_then(|input| input.get("questions"))
            .and_then(|questions| questions.get(0))
            .and_then(|question| question.get("question"))
            .and_then(Value::as_str)
            .or_else(|| {
                tool_input
                    .and_then(|input| input.get("question"))
                    .and_then(Value::as_str)
            })
            .unwrap_or("AskUserQuestion");
        return AgentEvent::WaitingForInput {
            detail: Some(question.to_owned()),
        };
    }
    // Prefer the concrete argument over the bare tool name so a permission
    // prompt that follows can show what needs approval.
    let argument = tool_input
        .and_then(|input| input.get("command").or_else(|| input.get("file_path")))
        .and_then(Value::as_str);
    let detail = match argument {
        Some(argument) if !argument.is_empty() => format!("{tool}: {argument}"),
        _ => tool.to_owned(),
    };
    AgentEvent::ToolStarted {
        tool: tool.to_owned(),
        detail: Some(detail),
    }
}

/// The latest `ai-title` line of a transcript. The legacy receiver used that
/// one record for both title fields, so a separate `custom-title` record must
/// not change the result while the shell remains the rollback backend.
fn transcript_titles(transcript: &[u8]) -> Option<Titles> {
    for line in transcript.split(|byte| *byte == b'\n').rev() {
        // Most lines are conversation records; a substring check keeps the
        // JSON parse for the few that can carry a title.
        if !contains(line, br#"ai-title""#) {
            continue;
        }
        let Ok(Value::Object(record)) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if string(&record, "type") != Some("ai-title") {
            continue;
        }
        let titles = Titles {
            session_title: string(&record, "customTitle").map(str::to_owned),
            generated_title: string(&record, "aiTitle").map(str::to_owned),
        };
        return (titles.session_title.is_some() || titles.generated_title.is_some())
            .then_some(titles);
    }
    None
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn extension(name: &str, object: Map<String, Value>) -> AgentEvent {
    AgentEvent::Extension {
        name: name.to_owned(),
        payload: Value::Object(object),
    }
}

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ClaudeAdapter;
    use limpid_agent_model::ProviderAdapter;

    fn events(payload: &str, transcript: Option<&str>) -> Vec<AgentEvent> {
        normalize(RawHookInput {
            bytes: payload.as_bytes(),
            transcript: transcript.map(str::as_bytes),
        })
        .expect("normalizes")
    }

    #[test]
    fn transcript_titles_use_only_the_latest_ai_title_record() {
        let transcript = concat!(
            "{\"type\":\"ai-title\",\"aiTitle\":\"first\",\"customTitle\":\"first custom\"}\n",
            "not json\n",
            "{\"type\":\"custom-title\",\"customTitle\":\"mine\"}\n",
            "{\"type\":\"ai-title\",\"aiTitle\":\"second\"}\n",
        );
        let actual = events(r#"{"hook_event_name":"Stop"}"#, Some(transcript));
        assert_eq!(
            actual,
            vec![AgentEvent::TurnFinished {
                titles: Some(Titles {
                    session_title: None,
                    generated_title: Some("second".into()),
                }),
            }]
        );
        assert_eq!(
            events(
                r#"{"hook_event_name":"Stop"}"#,
                Some("{\"type\":\"custom-title\",\"customTitle\":\"mine\"}\n")
            ),
            vec![AgentEvent::TurnFinished { titles: None }]
        );
        assert_eq!(
            events(
                r#"{"hook_event_name":"Stop"}"#,
                Some("{\"type\":\"user\"}\n")
            ),
            vec![AgentEvent::TurnFinished { titles: None }]
        );
    }

    #[test]
    fn ask_user_question_reports_the_question_text() {
        let payload = r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?"}]}}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::WaitingForInput {
                detail: Some("Which color?".into())
            }]
        );
        let payload =
            r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::WaitingForInput {
                detail: Some("AskUserQuestion".into())
            }]
        );
    }

    #[test]
    fn tool_detail_prefers_the_command_then_the_path_then_the_name() {
        let payload = r#"{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/a.txt"}}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::ToolStarted {
                tool: "Edit".into(),
                detail: Some("Edit: /a.txt".into())
            }]
        );
        let payload = r#"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{}}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::ToolStarted {
                tool: "Read".into(),
                detail: Some("Read".into())
            }]
        );
    }

    #[test]
    fn other_notifications_and_unknown_events_pass_through_as_extensions() {
        let payload =
            r#"{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"m"}"#;
        assert!(matches!(
            events(payload, None).as_slice(),
            [AgentEvent::Extension { name, .. }] if name == "Notification"
        ));
        let payload = r#"{"hook_event_name":"SubagentStart"}"#;
        assert!(matches!(
            events(payload, None).as_slice(),
            [AgentEvent::Extension { name, .. }] if name == "SubagentStart"
        ));
        assert!(matches!(
            events(r#"{"cwd":"/x"}"#, None).as_slice(),
            [AgentEvent::Extension { name, .. }] if name == "unknown"
        ));
    }

    #[test]
    fn stop_failure_reads_error_then_error_type() {
        let payload = r#"{"hook_event_name":"StopFailure","error":"server_error"}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::Failed {
                error: "server_error".into()
            }]
        );
        let payload = r#"{"hook_event_name":"StopFailure","error_type":"rate_limit"}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::Failed {
                error: "rate_limit".into()
            }]
        );
    }

    #[test]
    fn transcript_is_requested_only_for_prompt_and_stop() {
        let stop = r#"{"hook_event_name":"Stop","transcript_path":"/t/x.jsonl"}"#;
        assert_eq!(
            transcript_path(RawHookInput {
                bytes: stop.as_bytes(),
                transcript: None
            })
            .expect("ok"),
            Some("/t/x.jsonl".into())
        );
        let tool = r#"{"hook_event_name":"PreToolUse","transcript_path":"/t/x.jsonl"}"#;
        assert_eq!(
            transcript_path(RawHookInput {
                bytes: tool.as_bytes(),
                transcript: None
            })
            .expect("ok"),
            None
        );
        let other = r#"{"hook_event_name":"Stop","transcript_path":"/etc/passwd"}"#;
        assert_eq!(
            transcript_path(RawHookInput {
                bytes: other.as_bytes(),
                transcript: None
            })
            .expect("ok"),
            None
        );
    }

    #[test]
    fn worktree_intent_only_comes_from_a_bash_pre_tool_use() {
        let payload = r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/r","tool_input":{"command":"git worktree add -b demo ../demo"}}"#;
        let intent = ClaudeAdapter
            .worktree_intent(RawHookInput {
                bytes: payload.as_bytes(),
                transcript: None,
            })
            .expect("ok")
            .expect("intent");
        assert_eq!(intent.branch, "demo");
        assert_eq!(intent.cwd.as_deref(), Some("/r"));
        let payload = r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git worktree add -b demo ../demo"}}"#;
        assert_eq!(
            ClaudeAdapter
                .worktree_intent(RawHookInput {
                    bytes: payload.as_bytes(),
                    transcript: None
                })
                .expect("ok"),
            None
        );
    }
}
