//! Codex CLI adapter: descriptor, install recipe, and approval translation.
//!
//! `normalize` maps hook payloads to neutral events; the hook runtime applies
//! them to run records.

mod approval;
mod descriptor;
mod failure;
mod json;
mod normalize;
mod rate_limits;
mod rollouts;
mod titles;
mod tokens;
mod unprompted;

use limpid_agent_model::{
    AgentEvent, ApprovalDecision, ApprovalRequest, HookContext, InstallRecipe, ListDirectory,
    MAX_HOOK_INPUT_BYTES, NormalizeError, PlanUsageAnswer, ProviderAdapter, ProviderDescriptor,
    ProviderOutput, RawHookInput, RunRecord, Titles, TurnReading, TurnUsage, UnpromptedPrompt,
    WorktreeIntent, parse_object, transcript_path_for_events,
};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

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

    fn plan_usage_answer(&self, answer: &[u8], now: SystemTime) -> PlanUsageAnswer {
        rate_limits::plan_usage(answer, now)
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
        // A subagent's tools reach the pane's run (`normalize`), but under
        // the subagent's own turn: taken for the pane's, one after the
        // parent's `Stop` would begin a turn the person never had.
        let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES).ok()?;
        if normalize::is_subagents(&object) {
            return None;
        }
        turn_id_of(&object, &normalize::TURN_EVENTS)
    }

    fn unprompted_turn_transcript_path(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<String>, NormalizeError> {
        transcript_path_for_events(input, &normalize::TURN_EVENTS)
    }

    fn unprompted_prompt(&self, input: RawHookInput<'_>, marker: &str) -> UnpromptedPrompt {
        let begun = input
            .transcript
            .map(|rollout| unprompted::unprompted_prompt(rollout, marker))
            .unwrap_or_default();
        UnpromptedPrompt {
            cwd: parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)
                .ok()
                .and_then(|object| object.get("cwd").and_then(Value::as_str).map(str::to_owned)),
            ..begun
        }
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
    turn_id_of(&object, events)
}

/// The `turn_id` of a payload object of one of the hook `events`.
fn turn_id_of(object: &serde_json::Map<String, Value>, events: &[&str]) -> Option<String> {
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
    fn every_hook_inside_a_turn_names_it_and_a_stop_reads_its_own() {
        for event in normalize::TURN_EVENTS {
            assert_eq!(
                CodexAdapter.turn_marker(input(&format!(
                    r#"{{"hook_event_name":"{event}","turn_id":"t1"}}"#
                ))),
                Some("t1".into()),
                "{event}"
            );
        }
        assert_eq!(
            CodexAdapter.turn_marker(input(
                r#"{"hook_event_name":"UserPromptSubmit","turn_id":""}"#
            )),
            None
        );
        // A subagent's tool names the subagent's turn, not the pane's.
        assert_eq!(
            CodexAdapter.turn_marker(input(
                r#"{"hook_event_name":"PreToolUse","turn_id":"t2","agent_id":"019a0000-0000-7000-8000-000000000001"}"#
            )),
            None
        );
        // A `/compact` at the prompt is no turn of the person's.
        assert_eq!(
            CodexAdapter.turn_marker(input(r#"{"hook_event_name":"PreCompact","turn_id":"t1"}"#)),
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
