//! `PermissionRequest` translation, producing the same JSON the Swift adapter
//! it replaces emitted (serde does not escape `/`, which JSON treats alike). Codex uses Claude's hook output shape and adds a `turn_id`,
//! which becomes the neutral operation id.

use limpid_agent_model::{
    ApprovalDecision, ApprovalRequest, MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderId,
    ProviderOutput, parse_object,
};
use serde_json::{Value, json};

/// How long the hook helper waits for a decision, below Codex's 600-second
/// hook timeout so the helper answers before the provider gives up on it.
pub const APPROVAL_TIMEOUT_MS: u64 = 570_000;

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
    Ok(Some(ApprovalRequest {
        provider: ProviderId::new(crate::PROVIDER_ID).expect("static id is valid"),
        session_id: object
            .get("session_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        operation_id: object
            .get("turn_id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        tool_name: tool_name.to_owned(),
        summary,
        input: input.clone(),
        timeout_ms: APPROVAL_TIMEOUT_MS,
    }))
}

pub(crate) fn approval_output(decision: &ApprovalDecision) -> ProviderOutput {
    let body = match decision {
        ApprovalDecision::AllowOnce => json!({"behavior": "allow"}),
        ApprovalDecision::Deny {
            message: Some(message),
        } => {
            json!({"behavior": "deny", "message": message})
        }
        ApprovalDecision::Deny { message: None } => json!({"behavior": "deny"}),
        ApprovalDecision::Delegate => return ProviderOutput { stdout: None },
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
    fn keeps_the_turn_identifier_as_correlation_metadata() {
        let payload = br#"{"hook_event_name":"PermissionRequest","session_id":"codex-session","turn_id":"turn-7","tool_name":"shell","tool_input":{"description":"Inspect status"}}"#;
        let request = approval_request(payload).expect("ok").expect("approval");
        assert_eq!(request.provider.as_str(), "codex");
        assert_eq!(request.session_id.as_deref(), Some("codex-session"));
        assert_eq!(request.operation_id.as_deref(), Some("turn-7"));
        assert_eq!(request.tool_name, "shell");
        assert_eq!(request.summary.as_deref(), Some("Inspect status"));
    }

    #[test]
    fn other_events_and_malformed_requests_are_not_approvals() {
        for payload in [
            &br#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#[..],
            br#"{"hook_event_name":"PermissionRequest","tool_name":"","tool_input":{}}"#,
            br#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":7}"#,
        ] {
            assert_eq!(approval_request(payload).expect("ok"), None);
        }
        assert_eq!(approval_request(b"\"x\""), Err(NormalizeError::NotAnObject));
    }

    #[test]
    fn output_bytes_match_the_swift_adapter() {
        let allow = approval_output(&ApprovalDecision::AllowOnce)
            .stdout
            .expect("bytes");
        assert_eq!(
            String::from_utf8(allow).expect("utf8"),
            r#"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        );
        let deny = approval_output(&ApprovalDecision::Deny { message: None })
            .stdout
            .expect("bytes");
        assert_eq!(
            String::from_utf8(deny).expect("utf8"),
            r#"{"hookSpecificOutput":{"decision":{"behavior":"deny"},"hookEventName":"PermissionRequest"}}"#
        );
        assert_eq!(approval_output(&ApprovalDecision::Delegate).stdout, None);
    }
}
