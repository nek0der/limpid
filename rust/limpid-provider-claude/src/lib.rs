//! Claude Code adapter: descriptor, install recipe, and approval translation.
//!
//! Hook payload normalization is declared here and implemented in the hook
//! runtime phase; until then `normalize` reports `NotImplemented` so the
//! shell receiver stays the only writer of run records.

mod approval;
mod descriptor;

use limpid_agent_model::{
    AgentEvent, ApprovalDecision, ApprovalRequest, HookContext, InstallRecipe, NormalizeError,
    ProviderAdapter, ProviderDescriptor, ProviderOutput, RawHookInput,
};

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
        _input: RawHookInput<'_>,
        _context: &HookContext,
    ) -> Result<Vec<AgentEvent>, NormalizeError> {
        Err(NormalizeError::NotImplemented)
    }

    fn approval_request(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<ApprovalRequest>, NormalizeError> {
        approval::approval_request(input.bytes)
    }

    fn approval_output(&self, decision: &ApprovalDecision) -> ProviderOutput {
        approval::approval_output(decision)
    }
}
