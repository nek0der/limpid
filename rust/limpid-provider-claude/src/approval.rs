//! `PermissionRequest` translation, producing the same JSON the Swift adapter
//! it replaces emitted (serde does not escape `/`, which JSON treats alike).

use limpid_agent_model::{
    ApprovalDecision, ApprovalQuestion, ApprovalQuestionOption, ApprovalRequest,
    MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderId, ProviderOutput, parse_object,
};
use serde_json::{Value, json};

/// How long the hook helper waits for a decision, below Claude's own hook
/// timeout so the helper answers before the provider gives up on it.
pub const APPROVAL_TIMEOUT_MS: u64 = 570_000;

/// The tool whose permission request is a question for the user.
pub(crate) const QUESTION_TOOL: &str = "AskUserQuestion";

/// Reads `tool_input.questions[]` into the neutral shape. Entries without a
/// `question` string are skipped rather than failing the whole request, so a
/// partially malformed payload still reaches the card as a plain approval.
pub(crate) fn questions(input: &Value) -> Vec<ApprovalQuestion> {
    let Some(entries) = input.get("questions").and_then(Value::as_array) else {
        return Vec::new();
    };
    entries
        .iter()
        .filter_map(|entry| {
            let prompt = entry.get("question")?.as_str()?.to_owned();
            let options = entry
                .get("options")
                .and_then(Value::as_array)
                .map(|options| {
                    options
                        .iter()
                        .filter_map(|option| {
                            Some(ApprovalQuestionOption {
                                label: option.get("label")?.as_str()?.to_owned(),
                                description: option
                                    .get("description")
                                    .and_then(Value::as_str)
                                    .map(str::to_owned),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(ApprovalQuestion {
                header: entry
                    .get("header")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                prompt,
                options,
                multi_select: entry
                    .get("multiSelect")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            })
        })
        .collect()
}

pub(crate) fn approval_request(bytes: &[u8]) -> Result<Option<ApprovalRequest>, NormalizeError> {
    let object = parse_object(bytes, MAX_HOOK_INPUT_BYTES)?;
    if object.get("hook_event_name").and_then(Value::as_str) != Some("PermissionRequest") {
        return Ok(None);
    }
    let Some(tool_name) = object
        .get("tool_name")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
    else {
        return Ok(None);
    };
    // The approval UI shows the input whole, so it has to be a JSON
    // container; a bare string or number is not a tool input.
    let Some(input) = object
        .get("tool_input")
        .filter(|value| value.is_object() || value.is_array())
    else {
        return Ok(None);
    };
    // The Swift adapter fell back to `description` when `command` was
    // present but not a string, so each key is checked as a string in turn.
    let summary = input
        .get("command")
        .and_then(Value::as_str)
        .or_else(|| input.get("description").and_then(Value::as_str))
        .map(str::to_owned);
    let questions = if tool_name == QUESTION_TOOL {
        questions(input)
    } else {
        Vec::new()
    };
    // The Waiting row shows the summary, so a question shows its first prompt
    // instead of a command that does not exist.
    let summary = questions
        .first()
        .map(|question| question.prompt.clone())
        .or(summary);
    Ok(Some(ApprovalRequest {
        provider: ProviderId::new(crate::PROVIDER_ID).expect("static id is valid"),
        session_id: object
            .get("session_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        operation_id: None,
        tool_name: tool_name.to_owned(),
        summary,
        input: input.clone(),
        timeout_ms: APPROVAL_TIMEOUT_MS,
        questions,
    }))
}

pub(crate) fn approval_output(decision: &ApprovalDecision, request: &Value) -> ProviderOutput {
    let body = match decision {
        ApprovalDecision::AllowOnce => json!({"behavior": "allow"}),
        ApprovalDecision::Deny {
            message: Some(message),
        } => {
            json!({"behavior": "deny", "message": message})
        }
        ApprovalDecision::Deny { message: None } => json!({"behavior": "deny"}),
        ApprovalDecision::Delegate => return ProviderOutput { stdout: None },
        ApprovalDecision::Answer { answers } => {
            // Claude Code takes `updatedInput` as the complete tool input, so
            // we echo the whole original input and set only `answers`; a field
            // we do not know about survives. Only the question tool reads
            // `answers`; for any other tool the rewritten input would run that
            // tool with arguments nobody approved. Without both there is
            // nothing to answer; let the terminal dialog decide.
            let is_question_tool =
                request.get("tool_name").and_then(Value::as_str) == Some(QUESTION_TOOL);
            let Some(mut input) = request
                .get("input")
                .and_then(Value::as_object)
                .filter(|input| {
                    is_question_tool && input.get("questions").is_some_and(Value::is_array)
                })
                .cloned()
            else {
                return ProviderOutput { stdout: None };
            };
            input.insert("answers".to_owned(), json!(answers));
            json!({"behavior": "allow", "updatedInput": input})
        }
    };
    // serde_json's default map keeps keys sorted, which is what the Swift
    // adapter emitted with `.sortedKeys`, so the documents stay identical.
    let output = json!({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": body,
        }
    });
    ProviderOutput {
        stdout: Some(serde_json::to_vec(&output).expect("static shape serializes")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_a_permission_request_without_trusting_pane_identity() {
        let payload = br#"{"hook_event_name":"PermissionRequest","session_id":"claude-session","tool_name":"Bash","tool_input":{"command":"make test"},"LIMPID_PANE_ID":"ignored"}"#;
        let request = approval_request(payload).expect("ok").expect("approval");
        assert_eq!(request.provider.as_str(), "claude");
        assert_eq!(request.session_id.as_deref(), Some("claude-session"));
        assert_eq!(request.operation_id, None);
        assert_eq!(request.tool_name, "Bash");
        assert_eq!(request.summary.as_deref(), Some("make test"));
        assert_eq!(request.input, json!({"command": "make test"}));
        assert_eq!(request.timeout_ms, APPROVAL_TIMEOUT_MS);
    }

    #[test]
    fn description_is_the_fallback_summary_and_arrays_are_accepted() {
        let payload = br#"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"description":"Inspect status"}}"#;
        let request = approval_request(payload).expect("ok").expect("approval");
        assert_eq!(request.summary.as_deref(), Some("Inspect status"));
        let payload = br#"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"command":null,"description":"Inspect status"}}"#;
        let request = approval_request(payload).expect("ok").expect("approval");
        assert_eq!(request.summary.as_deref(), Some("Inspect status"));
        let payload =
            br#"{"hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":[1]}"#;
        assert!(approval_request(payload).expect("ok").is_some());
    }

    #[test]
    fn other_events_and_malformed_requests_are_not_approvals() {
        for payload in [
            &br#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#[..],
            br#"{"hook_event_name":"PermissionRequest","tool_name":"","tool_input":{}}"#,
            br#"{"hook_event_name":"PermissionRequest","tool_input":{}}"#,
            br#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":"ls"}"#,
            br#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#,
        ] {
            assert_eq!(approval_request(payload).expect("ok"), None);
        }
        assert_eq!(approval_request(b"[]"), Err(NormalizeError::NotAnObject));
    }

    #[test]
    fn output_bytes_match_the_swift_adapter() {
        let allow = approval_output(&ApprovalDecision::AllowOnce, &Value::Null)
            .stdout
            .expect("bytes");
        assert_eq!(
            String::from_utf8(allow).expect("utf8"),
            r#"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        );
        let deny = approval_output(
            &ApprovalDecision::Deny {
                message: Some("Blocked".into()),
            },
            &Value::Null,
        )
        .stdout
        .expect("bytes");
        assert_eq!(
            String::from_utf8(deny).expect("utf8"),
            r#"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Blocked"},"hookEventName":"PermissionRequest"}}"#
        );
        assert_eq!(
            approval_output(&ApprovalDecision::Delegate, &Value::Null).stdout,
            None
        );
    }

    #[test]
    fn ask_user_question_carries_typed_questions_and_the_first_prompt_as_summary() {
        let payload = br#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","session_id":"s","tool_input":{"questions":[{"question":"Which color?","header":"Color","multiSelect":true,"options":[{"label":"Red","description":"warm"},{"label":"Blue"}]},{"question":"Which size?","options":[{"label":"S"}]}]}}"#;
        let request = approval_request(payload).expect("ok").expect("approval");
        assert_eq!(request.summary.as_deref(), Some("Which color?"));
        assert_eq!(request.questions.len(), 2);
        let first = &request.questions[0];
        assert_eq!(first.header.as_deref(), Some("Color"));
        assert_eq!(first.prompt, "Which color?");
        assert!(first.multi_select);
        assert_eq!(first.options[0].label, "Red");
        assert_eq!(first.options[0].description.as_deref(), Some("warm"));
        assert_eq!(first.options[1].description, None);
        assert!(!request.questions[1].multi_select);
    }

    #[test]
    fn ask_user_question_without_questions_stays_a_plain_request() {
        let payload = br#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{}}"#;
        let request = approval_request(payload).expect("ok").expect("approval");
        assert!(request.questions.is_empty());
        assert_eq!(request.summary, None);
    }

    #[test]
    fn answer_echoes_the_questions_and_adds_answers() {
        let request = json!({"tool_name": "AskUserQuestion", "input": {"questions": [{"question": "Which color?", "header": "Color", "options": [{"label": "Red"}], "multiSelect": false}]}});
        let mut answers = std::collections::BTreeMap::new();
        answers.insert("Which color?".to_owned(), "Red".to_owned());
        let output = approval_output(&ApprovalDecision::Answer { answers }, &request)
            .stdout
            .expect("bytes");
        assert_eq!(
            String::from_utf8(output).expect("utf8"),
            r#"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"answers":{"Which color?":"Red"},"questions":[{"header":"Color","multiSelect":false,"options":[{"label":"Red"}],"question":"Which color?"}]}},"hookEventName":"PermissionRequest"}}"#
        );
    }

    #[test]
    fn answer_keeps_input_fields_it_does_not_know_and_replaces_answers() {
        let request = json!({"tool_name": "AskUserQuestion", "input": {"questions": [{"question": "q", "options": [{"label": "a"}]}], "metadata": {"source": "x"}, "answers": {"q": "stale"}}});
        let mut answers = std::collections::BTreeMap::new();
        answers.insert("q".to_owned(), "a".to_owned());
        let output = approval_output(&ApprovalDecision::Answer { answers }, &request)
            .stdout
            .expect("bytes");
        let output: Value = serde_json::from_slice(&output).expect("json");
        let input = &output["hookSpecificOutput"]["decision"]["updatedInput"];
        assert_eq!(input["metadata"], json!({"source": "x"}));
        assert_eq!(input["answers"], json!({"q": "a"}));
        assert_eq!(input["questions"][0]["question"], "q");
    }

    #[test]
    fn answer_without_questions_in_the_input_delegates() {
        let answers = std::collections::BTreeMap::new();
        assert_eq!(
            approval_output(
                &ApprovalDecision::Answer { answers },
                &json!({"tool_name": "AskUserQuestion", "input": {}})
            )
            .stdout,
            None
        );
        assert_eq!(
            approval_output(&ApprovalDecision::AllowOnce, &Value::Null)
                .stdout
                .map(|bytes| String::from_utf8(bytes).expect("utf8")),
            Some(r#"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#.to_owned())
        );
    }

    #[test]
    fn answer_for_another_tool_delegates() {
        let request = json!({"tool_name": "Bash", "input": {"command": "ls", "questions": [{"question": "q", "options": [{"label": "a"}]}]}});
        let mut answers = std::collections::BTreeMap::new();
        answers.insert("q".to_owned(), "a".to_owned());
        assert_eq!(
            approval_output(&ApprovalDecision::Answer { answers }, &request).stdout,
            None
        );
    }
}
