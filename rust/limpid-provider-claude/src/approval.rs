//! `PermissionRequest` translation, byte-compatible with the Swift adapter it
//! replaces.

use limpid_agent_model::{
    ApprovalDecision, ApprovalRequest, MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderId,
    ProviderOutput, parse_object,
};
use serde_json::{Value, json};

/// How long the hook helper waits for a decision, below Claude's own hook
/// timeout so the helper answers before the provider gives up on it.
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
    // The approval UI shows the input whole, so it has to be a JSON
    // container; a bare string or number is not a tool input.
    let Some(input) = object
        .get("tool_input")
        .filter(|value| value.is_object() || value.is_array())
    else {
        return Ok(None);
    };
    let summary = input
        .get("command")
        .or_else(|| input.get("description"))
        .and_then(Value::as_str)
        .map(str::to_owned);
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
    // adapter emitted with `.sortedKeys`; the bytes must stay identical.
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
        let allow = approval_output(&ApprovalDecision::AllowOnce)
            .stdout
            .expect("bytes");
        assert_eq!(
            String::from_utf8(allow).expect("utf8"),
            r#"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#
        );
        let deny = approval_output(&ApprovalDecision::Deny {
            message: Some("Blocked".into()),
        })
        .stdout
        .expect("bytes");
        assert_eq!(
            String::from_utf8(deny).expect("utf8"),
            r#"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Blocked"},"hookEventName":"PermissionRequest"}}"#
        );
        assert_eq!(approval_output(&ApprovalDecision::Delegate).stdout, None);
    }
}
