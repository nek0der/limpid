//! Provider-neutral vocabulary for agent integrations.
//!
//! This crate defines what a provider adapter produces and what the core
//! rules consume: provider identity and capabilities, the neutral event
//! vocabulary, the per-run record that state files carry, the approval
//! request and decision shapes, and what the reader side projects records
//! into. It depends on no provider and holds no
//! registry; `ProviderId` validates only its string form so model types remain
//! independent of the installed adapter set.

mod adapter;
mod approval;
mod command;
mod event;
mod projection;
mod provider;
mod record;
mod timestamp;
mod worktree;

#[cfg(feature = "conformance")]
pub mod conformance;

pub use adapter::{
    HookContext, MAX_HOOK_INPUT_BYTES, NormalizeError, ProviderAdapter, RawHookInput, TmuxEndpoint,
    parse_object,
};
pub use approval::{ApprovalDecision, ApprovalRequest, ProviderOutput};
pub use command::{
    Command, CommandOp, CommandOutcome, MAX_PANE_RECORDS, MAX_RETIRED_RECORDS, NotificationKind,
    NotifyCommand, OnMismatch, PaneStoreKind, Patch, Precondition, RETIRED_RECORD_LIFETIME_SECS,
    RecordPatch, ResumeIntent, Target,
};
pub use event::{AgentEvent, Titles};
pub use projection::{
    AcceptedRun, AttachmentResolution, AttentionMarks, Badge, EpisodeStamp, Focus, Instants,
    NOTIFICATION_BODY_CHARS, NOTIFICATION_PENDING_LIFETIME_MS, ObservedRuntime, PaneLocation,
    PanePresence, PendingNotification, PidStatus, Projection, ProjectionInput, ProjectionState,
    RESUME_WINDOW_SECS, RecordFile, RuntimePresentation, SessionInfo, TabPanes,
    VIEWED_FINISHED_RETENTION_SECS, WorktreeEventFile,
};
pub use provider::{
    Capability, InstallRecipe, ProviderDescriptor, ProviderId, ProviderIdError, SettingsFragment,
};
pub use record::{MAX_RECORD_TEXT_BYTES, RecordError, RunRecord, RunRecordV2, RunState};
pub use timestamp::{
    days_from_civil, format_utc_seconds, parse_utc_seconds, seconds_between, unix_seconds,
};
pub use worktree::WorktreeIntent;
