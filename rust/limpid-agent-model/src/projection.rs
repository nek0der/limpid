//! What the reader side puts in and gets out.
//!
//! The application watches directories, asks the operating system which
//! processes are alive and which pane has focus, and hands all of it to one
//! pure function. That function returns what to show and what to change, and
//! the host applies both. Nothing here touches a file, a timer, or a provider
//! by name.
//!
//! Two things make the shape less obvious than "records in, badges out".
//! First, the projection remembers: which revisions it has already accepted,
//! which attention episode each run is in, which notifications are still
//! waiting for a pane to become reachable, which cwd and worktree events it
//! has already routed. That memory is `ProjectionState`, carried in and back
//! out so the host can hold it without reading it. Second, it needs two
//! clocks. Record comparison and retention are wall time, because records
//! carry wall timestamps; a pending notification's lifetime is monotonic
//! uptime, because a clock adjustment must not expire or revive one.

use crate::command::{CommandOutcome, ResumeIntent};
use crate::provider::{ProviderDescriptor, ProviderId};
use crate::record::{RunRecord, RunState};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

/// How long a resume intent stays usable, and equally how long a kill marker
/// counts as evidence that Limpid ended the run. The two were separate
/// literals with the same value; a restore reads both, so they are one
/// constant.
pub const RESUME_WINDOW_SECS: u64 = 24 * 60 * 60;
/// How long a finished run the user has already seen keeps its badge before it
/// counts as dismissed.
pub const VIEWED_FINISHED_RETENTION_SECS: u64 = 24 * 60 * 60;
/// How long a notification may wait for its pane to become reachable.
pub const NOTIFICATION_PENDING_LIFETIME_MS: u64 = 300_000;
/// Longest notification body, in characters, before it is elided.
pub const NOTIFICATION_BODY_CHARS: usize = 80;

/// The two clocks one projection pass runs against.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Instants {
    /// ISO-8601 UTC, compared against record timestamps.
    pub wall: String,
    /// Milliseconds of uptime, immune to clock adjustments.
    pub monotonic_ms: u64,
}

/// Whether a process is still there. The host evaluates this, because asking
/// is a system call.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PidStatus {
    Alive,
    Dead,
    /// Neither confirmed: a missing pid, or a query that failed. Never treated
    /// as evidence of death, so a run is not retired on a guess.
    Unknown,
}

/// One file the host found in a watched directory. Content is text because
/// records are JSON; a file that is not valid UTF-8 cannot be one.
///
/// `None` means the file is there but could not be read this pass. That is not
/// the same as absent: a run whose record momentarily fails to read must keep
/// its badge rather than blink out and come back, so the projection holds the
/// copy it already accepted.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordFile {
    pub provider: ProviderId,
    /// File name without the suffix, which is the record's storage id.
    pub name: String,
    #[serde(default)]
    pub content: Option<String>,
}

/// A worktree creation event, which is named rather than keyed by pane because
/// the hook writes one file per event.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeEventFile {
    pub provider: ProviderId,
    pub file_name: String,
    pub content: String,
}

/// Viewed and dismissed marks, as runtime id to the episode token they were
/// taken against. Keying by episode rather than by run is what makes a mark
/// expire when the run enters a new episode: the same run finishing a second
/// time is unseen again.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttentionMarks {
    #[serde(default)]
    pub viewed: BTreeMap<String, String>,
    #[serde(default)]
    pub dismissed: BTreeMap<String, String>,
}

/// Which panes a tmux endpoint currently reaches, and whether each pane is the
/// active one in its window. A run hosted in tmux belongs to every attached
/// pane, so one record can light up several badges.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PanePresence {
    /// Endpoint key to attached panes. The host builds the key; the projection
    /// only matches records against it.
    #[serde(default)]
    pub attachments: BTreeMap<String, Vec<Uuid>>,
    #[serde(default)]
    pub locations: BTreeMap<Uuid, PaneLocation>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneLocation {
    pub is_active: bool,
}

/// How well a run's panes could be resolved. Notifications wait on
/// `Unresolved` rather than firing at nothing or dropping the transition.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AttachmentResolution {
    Attached,
    Detached,
    Unresolved,
}

/// A tab and the split-tree leaves it holds, in tree order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabPanes {
    pub id: Uuid,
    pub panes: Vec<Uuid>,
}

/// Where the user is looking, when the window is key and a pane is first
/// responder.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Focus {
    pub tab: Uuid,
    pub pane: Uuid,
}

/// Everything one projection pass reads.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectionInput {
    /// The descriptors of the providers installed in this build. The rules
    /// branch on capabilities, never on a provider name, so the host supplies
    /// the registry rather than the core holding one.
    #[serde(default)]
    pub providers: BTreeMap<ProviderId, ProviderDescriptor>,
    #[serde(default)]
    pub records: Vec<RecordFile>,
    #[serde(default)]
    pub session_records: Vec<RecordFile>,
    #[serde(default)]
    pub cwd_events: Vec<RecordFile>,
    #[serde(default)]
    pub worktree_events: Vec<WorktreeEventFile>,
    #[serde(default)]
    pub resume_intents: Vec<ResumeIntent>,
    #[serde(default)]
    pub marks: AttentionMarks,
    #[serde(default)]
    pub presence: PanePresence,
    /// Every tab and the split-tree leaves it holds. This is also where live
    /// panes come from: a pane is alive exactly when a tab still holds it, so
    /// the two are one field rather than two that can disagree.
    #[serde(default)]
    pub tabs: Vec<TabPanes>,
    /// Keyed by the pid string the record carries, so the projection never
    /// parses one.
    #[serde(default)]
    pub pid_status: BTreeMap<String, PidStatus>,
    #[serde(default)]
    pub focus: Option<Focus>,
    /// What became of the previous pass's commands.
    #[serde(default)]
    pub acknowledged: Vec<CommandOutcome>,
    /// The first pass after launch, which records what exists and announces
    /// nothing. Without it every run visible at startup would fire.
    #[serde(default)]
    pub is_bootstrap: bool,
}

/// What one pass remembers for the next. The host stores it without reading
/// it; the shape is free to change as long as it round-trips.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectionState {
    /// Records accepted so far, by storage id. Held rather than re-read so a
    /// transient read failure does not make a live run disappear.
    #[serde(default)]
    pub accepted: BTreeMap<String, AcceptedRun>,
    #[serde(default)]
    pub episodes: BTreeMap<String, EpisodeStamp>,
    #[serde(default)]
    pub outbox: OutboxState,
    #[serde(default)]
    pub cwd_seen: BTreeMap<Uuid, String>,
    #[serde(default)]
    pub worktree_seen: BTreeSet<String>,
}

/// A record the projection has taken as current, with the provider it came
/// from so the projection never has to guess from the directory.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AcceptedRun {
    pub provider: ProviderId,
    pub record: RunRecord,
}

/// The attention episode a run is in. The token changes when the state
/// changes, which is what makes a viewed mark expire.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EpisodeStamp {
    pub state: RunState,
    pub token: String,
}

/// Notification memory: what each runtime was last seen as, and which
/// announcements are still waiting for a reachable pane.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutboxState {
    #[serde(default)]
    pub previous: BTreeMap<String, ObservedRuntime>,
    /// Keyed by the deduplication key so the same episode cannot queue twice.
    #[serde(default)]
    pub pending: BTreeMap<String, PendingNotification>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservedRuntime {
    pub state: RunState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub event_token: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingNotification {
    pub runtime_id: String,
    pub state: RunState,
    /// Monotonic uptime when it was queued.
    pub created_at_ms: u64,
}

/// One run as the interface shows it. A tmux-hosted run appears in every pane
/// its endpoint reaches, which is why `panes` is a list.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimePresentation {
    /// `provider:runId`, stable across passes and used as the mark key.
    pub id: String,
    pub provider: ProviderId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
    pub badge: Badge,
    pub panes: Vec<Uuid>,
    pub attachment: AttachmentResolution,
    pub episode_token: String,
}

/// What a pane's badge shows. Mirrors what the record carries, minus identity
/// and transport fields the interface has no use for.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Badge {
    pub state: RunState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_started_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_tmux_hosted: Option<bool>,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_base_tree: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_root: Option<String>,
    /// Present only for providers with the session title capability; the tab
    /// title rule requires it before it will use a session title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_session_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_generated_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_started_at: Option<String>,
}

/// What a pane can resume, taken from the provider's hint.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
}

/// What one pass decides to show.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Projection {
    pub runtimes: Vec<RuntimePresentation>,
    /// Pane to provider to badge. Only the dominant record per provider and
    /// pane survives; the rest are still runtimes.
    pub badges: BTreeMap<Uuid, BTreeMap<ProviderId, Badge>>,
    pub sessions: BTreeMap<Uuid, BTreeMap<ProviderId, SessionInfo>>,
    /// Tabs whose title the projection resolved. A tab missing here keeps
    /// whatever title it has.
    pub tab_titles: BTreeMap<Uuid, String>,
    /// Marks still worth keeping. Everything else refers to runs that are gone
    /// and would otherwise accumulate forever.
    pub marks_to_keep: AttentionMarks,
    /// Panes where offering to resume makes sense, per provider.
    pub resume_candidates: BTreeMap<Uuid, BTreeSet<ProviderId>>,
}

impl RuntimePresentation {
    /// The mark and outbox key for a run. Built here so the host and the rules
    /// cannot disagree about its shape.
    #[must_use]
    pub fn identifier(provider: &ProviderId, run_id: &str) -> String {
        format!("{provider}:{run_id}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_state_round_trips_so_the_host_can_hold_it_opaquely() {
        let mut state = ProjectionState::default();
        state.episodes.insert(
            "claude:RUN".to_owned(),
            EpisodeStamp {
                state: RunState::Finished,
                token: "4".to_owned(),
            },
        );
        state.outbox.pending.insert(
            "claude:RUN|4|finished".to_owned(),
            PendingNotification {
                runtime_id: "claude:RUN".to_owned(),
                state: RunState::Finished,
                created_at_ms: 1_000,
            },
        );
        state
            .cwd_seen
            .insert(Uuid::nil(), "2026-09-14T12:00:00Z".to_owned());

        let text = serde_json::to_string(&state).expect("encode");
        let back: ProjectionState = serde_json::from_str(&text).expect("decode");
        assert_eq!(back, state);
    }

    #[test]
    fn an_empty_input_decodes_from_an_empty_object() {
        // The host builds the input incrementally; a field it has nothing for
        // must not be an error, or every new field would break the boundary.
        let input: ProjectionInput = serde_json::from_str("{}").expect("decode");
        assert_eq!(input, ProjectionInput::default());
        assert!(!input.is_bootstrap);
    }

    #[test]
    fn the_runtime_identifier_joins_the_provider_and_run() {
        let provider = ProviderId::new("codex").expect("provider id");
        assert_eq!(
            RuntimePresentation::identifier(&provider, "RUN"),
            "codex:RUN"
        );
    }

    #[test]
    fn the_resume_window_covers_both_the_intent_and_the_kill_marker() {
        // The launch rule reads the intent's age and the kill marker's age in
        // the same pass; one window keeps them from drifting apart.
        assert_eq!(RESUME_WINDOW_SECS, 86_400);
        assert_eq!(VIEWED_FINISHED_RETENTION_SECS, 86_400);
    }
}
