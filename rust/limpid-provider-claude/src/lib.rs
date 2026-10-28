//! Claude Code adapter: descriptor, install recipe, and approval translation.
//!
//! `normalize` maps hook payloads to neutral events; the hook runtime applies
//! them to run records.

mod approval;
mod awaited;
mod cache;
mod descriptor;
mod normalize;
mod tokens;
mod transcript;
mod usage;

use limpid_agent_model::{
    AgentEvent, ApprovalDecision, ApprovalRequest, CommandRun, EventId, HookContext, InstallRecipe,
    MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderAdapter, ProviderDescriptor, ProviderOutput,
    RawHookInput, TurnReading, TurnUsage, WorktreeIntent, parse_object,
};
use serde_json::Value;

/// The Claude Code provider.
#[derive(Debug, Default, Clone, Copy)]
pub struct ClaudeAdapter;

/// Stable provider id.
pub const PROVIDER_ID: &str = "claude";

impl ProviderAdapter for ClaudeAdapter {
    fn descriptor(&self) -> &ProviderDescriptor {
        descriptor::descriptor()
    }

    fn install_recipe(&self) -> InstallRecipe {
        descriptor::install_recipe()
    }

    fn normalize(
        &self,
        input: RawHookInput<'_>,
        _context: &HookContext,
    ) -> Result<Vec<AgentEvent>, NormalizeError> {
        normalize::normalize(input)
    }

    fn approval_request(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<ApprovalRequest>, NormalizeError> {
        approval::approval_request(input.bytes)
    }

    fn approval_output(&self, decision: &ApprovalDecision, request: &Value) -> ProviderOutput {
        approval::approval_output(decision, request)
    }

    fn event_id(
        &self,
        input: RawHookInput<'_>,
        context: &HookContext,
    ) -> Result<Option<EventId>, NormalizeError> {
        normalize::event_id(input, context, &self.descriptor().id)
    }

    fn transcript_path(&self, input: RawHookInput<'_>) -> Result<Option<String>, NormalizeError> {
        normalize::transcript_path(input)
    }

    fn turn_transcript_path(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<String>, NormalizeError> {
        normalize::turn_transcript_path(input)
    }

    fn transcript_shows_wait_declined(&self, transcript: &[u8]) -> bool {
        awaited::transcript_awaited_call_interrupted(transcript)
    }

    fn worktree_intent(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<WorktreeIntent>, NormalizeError> {
        WorktreeIntent::from_hook_payload(input.bytes, "Bash")
    }

    fn command_run(&self, input: RawHookInput<'_>) -> Result<Option<CommandRun>, NormalizeError> {
        normalize::command_run(input)
    }

    fn turn_marker(&self, input: RawHookInput<'_>) -> Option<String> {
        let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
        if object.get("hook_event_name").and_then(Value::as_str) != Some("UserPromptSubmit") {
            return None;
        }
        object
            .get("prompt_id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
    }

    fn turn_reading(&self, input: RawHookInput<'_>, marker: Option<&str>) -> TurnReading {
        let Some(transcript) = input.transcript else {
            return TurnReading::default();
        };
        let path = normalize::transcript_path(input).ok().flatten();
        tokens::transcript_turn_reading(transcript, marker, path.as_deref())
    }

    fn transcript_turn_reading(
        &self,
        transcript: &[u8],
        path: &str,
        marker: Option<&str>,
    ) -> TurnReading {
        tokens::transcript_turn_reading(transcript, marker, Some(path))
    }

    fn subagent_usage(&self, transcript: &[u8]) -> Option<TurnUsage> {
        tokens::subagent_transcript_usage(transcript)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marker(payload: &str) -> Option<String> {
        ClaudeAdapter.turn_marker(RawHookInput {
            bytes: payload.as_bytes(),
            transcript: None,
        })
    }

    #[test]
    fn only_a_prompt_names_its_turn() {
        assert_eq!(
            marker(r#"{"hook_event_name":"UserPromptSubmit","prompt_id":"p1"}"#),
            Some("p1".into())
        );
        assert_eq!(
            marker(r#"{"hook_event_name":"UserPromptSubmit","prompt_id":""}"#),
            None
        );
        assert_eq!(
            marker(r#"{"hook_event_name":"Stop","prompt_id":"p1"}"#),
            None
        );
    }
}
