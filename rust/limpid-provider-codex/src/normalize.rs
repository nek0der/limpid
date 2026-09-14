//! Maps Codex CLI hook payloads to neutral events.
//!
//! The mapping mirrors what `codex-shim/limpid-hook` did and is checked
//! against the recorded fixtures under `rust/fixtures/codex`. Codex has no
//! session titles, so prompt and stop events carry none.

use limpid_agent_model::{
    AgentEvent, MAX_HOOK_INPUT_BYTES, NormalizeError, RawHookInput, parse_object,
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
            compact: false,
            session_id: string(&object, "session_id").map(str::to_owned),
            session_title: None,
            cwd,
        },
        "SessionEnd" => AgentEvent::SessionEnded {
            reason: string(&object, "reason").map(str::to_owned),
            session_id: string(&object, "session_id").map(str::to_owned),
        },
        "UserPromptSubmit" => AgentEvent::PromptSubmitted {
            prompt: string(&object, "prompt").unwrap_or_default().to_owned(),
            titles: None,
            cwd,
        },
        "PreToolUse" => {
            let tool = string(&object, "tool_name").unwrap_or_default().to_owned();
            AgentEvent::ToolStarted {
                detail: Some(tool.clone()),
                tool,
            }
        }
        "PostToolUse" => AgentEvent::ToolFinished {
            tool: string(&object, "tool_name").map(str::to_owned),
        },
        "PermissionRequest" => AgentEvent::ApprovalRequested {
            detail: string(&object, "message").map(str::to_owned),
        },
        "PreCompact" => AgentEvent::Compacting {
            context_tokens: object.get("current_token_count").and_then(Value::as_u64),
        },
        "PostCompact" => AgentEvent::CompactionFinished,
        "Interrupt" => AgentEvent::Interrupted,
        // Codex's Stop schema carries no error today; the branch stays for a
        // future schema that does, matching the receiver it replaces.
        "Stop" => match string(&object, "error_type") {
            Some(error) if !error.is_empty() => AgentEvent::Failed {
                error: error.to_owned(),
            },
            _ => AgentEvent::TurnFinished { titles: None },
        },
        _ => AgentEvent::Extension {
            name: event_name.clone(),
            payload: Value::Object(object),
        },
    };
    Ok(vec![event])
}

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn events(payload: &str) -> Vec<AgentEvent> {
        normalize(RawHookInput {
            bytes: payload.as_bytes(),
            transcript: None,
        })
        .expect("normalizes")
    }

    #[test]
    fn stop_with_an_error_type_fails_and_without_one_finishes() {
        assert_eq!(
            events(r#"{"hook_event_name":"Stop","error_type":"timeout"}"#),
            vec![AgentEvent::Failed {
                error: "timeout".into()
            }]
        );
        assert_eq!(
            events(r#"{"hook_event_name":"Stop","error_type":""}"#),
            vec![AgentEvent::TurnFinished { titles: None }]
        );
    }

    #[test]
    fn tool_events_carry_the_tool_name_only() {
        assert_eq!(
            events(
                r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#
            ),
            vec![AgentEvent::ToolStarted {
                tool: "Bash".into(),
                detail: Some("Bash".into())
            }]
        );
        assert_eq!(
            events(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#),
            vec![AgentEvent::ToolFinished {
                tool: Some("Bash".into())
            }]
        );
    }

    #[test]
    fn unsubscribed_events_pass_through_as_extensions() {
        for payload in [
            r#"{"hook_event_name":"CwdChanged","new_cwd":"/x"}"#,
            r#"{"hook_event_name":"Notification","notification_type":"permission_prompt"}"#,
            r#"{"hook_event_name":"StopFailure","error":"x"}"#,
        ] {
            assert!(
                matches!(events(payload).as_slice(), [AgentEvent::Extension { .. }]),
                "{payload}"
            );
        }
    }
}
