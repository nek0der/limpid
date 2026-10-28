//! Codex CLI adapter: descriptor, install recipe, and approval translation.
//!
//! `normalize` maps hook payloads to neutral events; the hook runtime applies
//! them to run records.

mod approval;
mod descriptor;
mod json;
mod normalize;
mod rollouts;
mod titles;
mod tokens;
mod usage;

use limpid_agent_model::{
    AgentEvent, ApprovalDecision, ApprovalRequest, HookContext, InstallRecipe, ListDirectory,
    MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderAdapter, ProviderDescriptor, ProviderOutput,
    RawHookInput, RunRecord, Titles, TurnReading, TurnUsage, WorktreeIntent, parse_object,
};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// The Codex CLI provider.
#[derive(Debug, Default, Clone, Copy)]
pub struct CodexAdapter;

/// Stable provider id.
pub const PROVIDER_ID: &str = "codex";

impl ProviderAdapter for CodexAdapter {
    fn descriptor(&self) -> &ProviderDescriptor {
        descriptor::descriptor()
    }

    fn install_recipe(&self) -> InstallRecipe {
        descriptor::install_recipe()
    }

    fn home_directory_variable(&self) -> Option<&'static str> {
        Some(normalize::HOME_DIRECTORY_VARIABLE)
    }

    fn normalize(
        &self,
        input: RawHookInput<'_>,
        context: &HookContext,
    ) -> Result<Vec<AgentEvent>, NormalizeError> {
        normalize::normalize(input, context)
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

    fn worktree_intent(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<WorktreeIntent>, NormalizeError> {
        WorktreeIntent::from_hook_payload(input.bytes, "Bash")
    }

    fn transcript_path(&self, input: RawHookInput<'_>) -> Result<Option<String>, NormalizeError> {
        normalize::transcript_path(input)
    }

    fn title_index_path(
        &self,
        input: RawHookInput<'_>,
        context: &HookContext,
    ) -> Result<Option<PathBuf>, NormalizeError> {
        titles::title_index_path(input, context)
    }

    fn indexed_titles(&self, input: RawHookInput<'_>, index: &[u8]) -> Option<Titles> {
        titles::indexed_titles(input, index)
    }

    fn applies_to(&self, input: RawHookInput<'_>, record: Option<&RunRecord>) -> bool {
        normalize::applies_to(input, record)
    }

    fn turn_marker(&self, input: RawHookInput<'_>) -> Option<String> {
        payload_turn_id(input, &["UserPromptSubmit"])
    }

    fn turn_reading(&self, input: RawHookInput<'_>, marker: Option<&str>) -> TurnReading {
        let Some(rollout) = input.transcript else {
            return TurnReading::default();
        };
        let Some(turn_id) = marker
            .map(str::to_owned)
            .or_else(|| payload_turn_id(input, &normalize::TURN_END_EVENTS))
        else {
            return TurnReading::default();
        };
        tokens::rollout_turn_reading(rollout, &turn_id)
    }

    fn subagent_transcripts(
        &self,
        transcript: &Path,
        subagents: &[String],
        list: &ListDirectory<'_>,
    ) -> Vec<PathBuf> {
        rollouts::subagent_rollouts(transcript, subagents, list)
    }

    fn subagent_usage(
        &self,
        transcript: &[u8],
        is_whole: bool,
        marker: Option<&str>,
    ) -> Option<TurnUsage> {
        tokens::subagent_rollout_usage(transcript, is_whole, marker)
    }
}

/// The `turn_id` of a payload of one of the hook `events`.
fn payload_turn_id(input: RawHookInput<'_>, events: &[&str]) -> Option<String> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
    let event = object.get("hook_event_name").and_then(Value::as_str)?;
    if !events.contains(&event) {
        return None;
    }
    object
        .get("turn_id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(payload: &str) -> RawHookInput<'_> {
        RawHookInput {
            bytes: payload.as_bytes(),
            transcript: None,
        }
    }

    #[test]
    fn a_prompt_names_its_turn_and_a_stop_reads_its_own() {
        assert_eq!(
            CodexAdapter.turn_marker(input(
                r#"{"hook_event_name":"UserPromptSubmit","turn_id":"t1"}"#
            )),
            Some("t1".into())
        );
        assert_eq!(
            CodexAdapter.turn_marker(input(
                r#"{"hook_event_name":"UserPromptSubmit","turn_id":""}"#
            )),
            None
        );
        assert_eq!(
            CodexAdapter.turn_marker(input(r#"{"hook_event_name":"Stop","turn_id":"t1"}"#)),
            None
        );
        assert_eq!(
            payload_turn_id(
                input(r#"{"hook_event_name":"Stop","turn_id":"t1"}"#),
                &["Stop"]
            ),
            Some("t1".into())
        );
        // No rollout read, nothing to say.
        assert_eq!(
            CodexAdapter.turn_reading(input(r#"{"hook_event_name":"Stop","turn_id":"t1"}"#), None),
            TurnReading::default()
        );
    }

    #[test]
    fn an_interrupt_reads_the_turn_it_ends_as_a_stop_does() {
        let rollout = concat!(
            r#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
            "\n",
            r#"{"type":"token_usage_record","payload":{"turn_id":"t1","turn_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":7,"total_tokens":127}}}"#,
            "\n",
        );
        for event in normalize::TURN_END_EVENTS {
            let payload = format!(r#"{{"hook_event_name":"{event}","turn_id":"t1"}}"#);
            let reading = CodexAdapter.turn_reading(
                RawHookInput {
                    bytes: payload.as_bytes(),
                    transcript: Some(rollout.as_bytes()),
                },
                None,
            );
            assert_eq!(reading.marker.as_deref(), Some("t1"), "{event}");
            assert!(reading.usage.is_some(), "{event}");
            assert!(
                CodexAdapter
                    .transcript_path(input(&format!(
                        r#"{{"hook_event_name":"{event}","transcript_path":"/tmp/example/rollout.jsonl"}}"#
                    )))
                    .expect("an object")
                    .is_some(),
                "{event}"
            );
        }
        // A prompt's turn begins without a reading of its own.
        assert_eq!(
            CodexAdapter
                .transcript_path(input(
                    r#"{"hook_event_name":"UserPromptSubmit","transcript_path":"/tmp/example/rollout.jsonl"}"#
                ))
                .expect("an object"),
            None
        );
    }
}
