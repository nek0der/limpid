//! Codex CLI adapter: descriptor, install recipe, and approval translation.
//!
//! `normalize` maps hook payloads to neutral events; the hook runtime applies
//! them to run records.

mod approval;
mod descriptor;
mod normalize;
mod usage;

use limpid_agent_model::{
    AgentEvent, ApprovalDecision, ApprovalRequest, HookContext, InstallRecipe, NormalizeError,
    ProviderAdapter, ProviderDescriptor, ProviderOutput, RawHookInput, RunRecord, WorktreeIntent,
};
use serde_json::Value;

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

    fn applies_to(&self, input: RawHookInput<'_>, record: Option<&RunRecord>) -> bool {
        normalize::applies_to(input, record)
    }
}
