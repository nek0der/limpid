//! Provider-neutral vocabulary for agent integrations.
//!
//! This crate defines what a provider adapter produces and what the core
//! rules consume: provider identity and capabilities, the neutral event
//! vocabulary, the per-run record that state files carry, and the approval
//! request and decision shapes. It depends on no provider and holds no
//! registry; `ProviderId` validates only its string form so model types remain
//! independent of the installed adapter set.

mod adapter;
mod approval;
mod event;
mod provider;
mod record;
mod worktree;

#[cfg(feature = "conformance")]
pub mod conformance;

pub use adapter::{
    HookContext, MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderAdapter, RawHookInput, TmuxEndpoint,
    parse_object,
};
pub use approval::{ApprovalDecision, ApprovalRequest, ProviderOutput};
pub use event::{AgentEvent, Titles};
pub use provider::{
    Capability, InstallRecipe, ProviderDescriptor, ProviderId, ProviderIdError, SettingsFragment,
};
pub use record::{MAX_RECORD_TEXT_BYTES, RecordError, RunRecord, RunRecordV2, RunState};
pub use worktree::WorktreeIntent;
