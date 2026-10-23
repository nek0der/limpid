//! Claude Code adapter: descriptor, install recipe, and approval translation.
//!
//! `normalize` maps hook payloads to neutral events; the hook runtime applies
//! them to run records.

mod approval;
mod awaited;
mod cache;
mod descriptor;
mod normalize;
mod usage;

use limpid_agent_model::{
    AgentEvent, ApprovalDecision, ApprovalRequest, CommandRun, EventId, HookContext, InstallRecipe,
    NormalizeError, ProviderAdapter, ProviderDescriptor, ProviderOutput, RawHookInput,
    WorktreeIntent,
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

    fn wait_transcript_path(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<String>, NormalizeError> {
        normalize::wait_transcript_path(input)
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
}
