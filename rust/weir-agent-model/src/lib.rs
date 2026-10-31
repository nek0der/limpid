//! Provider-neutral vocabulary for agent integrations.
//!
//! This crate defines what a provider adapter produces and what the core
//! rules consume: provider identity and capabilities, the neutral event
//! vocabulary, the per-run record that state files carry, the approval
//! request and decision shapes, and what the reader side projects records
//! into. It depends on no provider and holds no registry; `ProviderId`
//! validates only its string form so model types remain independent of the
//! installed adapter set.

mod adapter;
mod approval;
mod background;
mod cache;
mod command;
mod event;
mod layout;
mod projection;
mod prompt;
mod provider;
mod record;
mod restore;
mod serde_helpers;
mod session_settings;
mod timestamp;
mod turn;
mod usage;
mod worktree;

#[cfg(feature = "conformance")]
pub mod conformance;

pub use adapter::{
    CommandRun, FailureReport, FailureWatch, HookContext, ListDirectory, MAX_HOOK_INPUT_BYTES,
    NormalizeError, ProviderAdapter, RawHookInput, SettingsSource, StatusLineAdapter, TmuxEndpoint,
    TurnReading, UnpromptedPrompt, parse_object, transcript_path_for_events,
};
pub use approval::{
    ApprovalDecision, ApprovalQuestion, ApprovalQuestionOption, ApprovalRequest, ProviderOutput,
};
pub use background::BackgroundWork;
pub use cache::{CachePrecision, CacheWindow};
pub use command::{
    Command, CommandOp, CommandOutcome, MAX_PANE_RECORDS, MAX_RETIRED_RECORDS, NotificationKind,
    NotifyCommand, OnMismatch, PaneStoreKind, Patch, Precondition, RETIRED_RECORD_LIFETIME_SECS,
    RecordPatch, ResumeIntent, Target,
};
pub use event::{AgentEvent, EventId, SessionSource, Titles};
pub use layout::{
    CWD_EVENT_FILE_SUFFIX, LOCK_FILE_SUFFIX, SESSION_HINT_FILE_SUFFIX, TURNS_DIRECTORY,
    WORKTREE_EVENT_FILE_SUFFIX, WORKTREE_EVENTS_DIRECTORY, cwd_event_file_name,
    session_hint_file_name,
};
pub use projection::{
    AcceptedRun, AttachmentResolution, AttentionMarks, Badge, BlockedKind, EpisodeStamp,
    FINISHED_NOTICE_HOLD_MS, Focus, Instants, LifecycleInput, MAX_TURN_DELETIONS_PER_PASS,
    NOTIFICATION_BODY_CHARS, NOTIFICATION_PENDING_LIFETIME_MS, ObservedRuntime, OutboxState,
    PaneLocation, PanePresence, PendingNotification, PidStatus, ProgramState, ProgramStatus,
    Projection, ProjectionInput, ProjectionState, RESUME_WINDOW_SECS, RecordFile,
    RuntimePresentation, SessionInfo, StopReason, TURNS_KEPT_PER_SHOWN_CONVERSATION, TabPanes,
    TurnSweepInput, VIEWED_FINISHED_RETENTION_SECS, WorktreeEventFile,
};
pub use prompt::{PromptKind, RecordedPromptKind, classify_prompt};
pub use provider::{
    Capability, InstallRecipe, ProviderDescriptor, ProviderId, ProviderIdError, RecipePlaceholder,
    RecipeVariable, SettingsFragment,
};
pub use record::{
    MAX_RECORD_TEXT_BYTES, RUN_RECORD_FILE_SUFFIX, RecordError, RunRecord, RunRecordV2, RunState,
    WaitKind, run_record_file_name,
};
pub use restore::{
    FailedPath, FailedReason, PathChange, PathChangeKind, RESTORE_DIRECTORY,
    RESTORE_JOURNAL_FILE_SUFFIX, RestoreContext, RestoreJournal, RestoreOperation, RestoreStage,
    StageReason, restore_current_ref, restore_expected_ref, restore_refs, restore_target_ref,
    restore_undo_ref,
};
pub use session_settings::{PermissionMode, SessionSettings};
pub use timestamp::{
    days_from_civil, format_utc_seconds, parse_utc_seconds, seconds_between, unix_seconds,
};
pub use turn::{
    ChangeSummary, CheckMark, CheckResult, ConversationKey, ConversationTurns, DeniedAction,
    DiffStat, EventApplication, GitContext, MAX_CHECK_MARKS, MAX_DENIED_ACTIONS, SkippedFile,
    SnapshotStatus, TURN_COUNTER_FILE_SUFFIX, TURN_RECORD_FILE_SUFFIX, TurnCounter, TurnPhase,
    TurnRecord, TurnRecordError, TurnSummary, TurnUsage, turn_record_file_name,
};
pub use usage::{PlanResetCredits, PlanUsage, PlanUsageAnswer, PlanUsageWindow, UsageLimit};
pub use worktree::WorktreeIntent;
