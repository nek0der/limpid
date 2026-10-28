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

use crate::cache::CacheWindow;
use crate::command::{CommandOutcome, ResumeIntent};
use crate::provider::{ProviderDescriptor, ProviderId};
use crate::record::{RunRecord, RunState, WaitKind};
use crate::turn::{ConversationKey, ConversationTurns, TurnSummary};
use crate::usage::UsageLimit;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

/// How long a resume intent stays usable, and equally how long a kill marker
/// counts as evidence that Limpid ended the run. A restore reads both in the
/// same pass, so they are one constant.
pub const RESUME_WINDOW_SECS: u64 = 24 * 60 * 60;
/// How long a finished run the user has already seen keeps its badge before it
/// ages out.
pub const VIEWED_FINISHED_RETENTION_SECS: u64 = 24 * 60 * 60;
/// How long a notification may wait for its pane to become reachable.
pub const NOTIFICATION_PENDING_LIFETIME_MS: u64 = 300_000;
/// How long a finished turn's notification waits before it is announced. An
/// instruction queued while the agent worked starts the next turn moments
/// after the `Stop`, and no hook says one was queued, so a run back at work
/// within this time drops the notice (no notification when the next
/// instruction is already queued). Monotonic, like the pending lifetime.
pub const FINISHED_NOTICE_HOLD_MS: u64 = 1_500;
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

/// Viewed marks, as runtime id to the episode token they were taken against.
/// Keying by episode rather than by run is what makes a mark expire when the
/// run enters a new episode: the same run finishing a second time is unseen
/// again.
///
/// Inputs written before `dismissed` marks went (hand-written fixtures,
/// captured inputs) may still carry them. The field is not denied, so such an
/// input still reads, and its marks count for nothing.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttentionMarks {
    #[serde(default)]
    pub viewed: BTreeMap<String, String>,
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
    /// Endpoint key, as in `attachments`, to where the endpoint's tmux pane
    /// sits in each pane attached to it. Keyed by the endpoint and not by the
    /// pane, because two runs of one tmux session reach the same pane from
    /// different tmux panes, and only one of them can be the active one.
    #[serde(default)]
    pub locations: BTreeMap<String, BTreeMap<Uuid, PaneLocation>>,
}

impl PanePresence {
    /// Whether `pane` shows the run whose tmux endpoint is `endpoint` (its
    /// `RuntimePresentation::tmux_endpoint_key`). A run outside tmux is always
    /// shown in its pane, and so is a tmux run whose location is not known:
    /// the probe reports where a run sits, not that it is hidden.
    #[must_use]
    pub fn shows(&self, endpoint: Option<&str>, pane: &Uuid) -> bool {
        endpoint
            .and_then(|key| self.locations.get(key))
            .and_then(|locations| locations.get(pane))
            .is_none_or(|location| location.is_active)
    }
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

/// Where keys go: the focused tab and pane. Picks the pane a notification
/// opens when its run is in several. What the user has seen is not read from
/// here but from `seen_panes`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Focus {
    pub tab: Uuid,
    pub pane: Uuid,
}

/// What a pane's program last reported about itself over OSC 7501. Only the
/// report about the program as a whole is kept, not the records it keeps
/// for parts of its work.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgramStatus {
    /// The program's own name for itself (`claude-code`); empty when it
    /// sent none.
    pub app: String,
    pub state: ProgramState,
    /// ISO-8601 UTC, when the terminal forwarded the report.
    pub observed_at: String,
}

/// The states a program reports, as the protocol names them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProgramState {
    /// At rest, waiting for the person's next instruction.
    Idle,
    Working,
    /// Finished a piece of work the person has not looked at yet.
    Done,
    /// Cannot go on until the person does something.
    Blocked,
    Error,
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
    /// The person's home directory (`HOME`), where each provider's default
    /// configuration directory is (`ProviderDescriptor::default_home`).
    /// `None` leaves nothing to read a provider's internal agent directories
    /// against, and every record counts as the person's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// Each provider's default home under `home`, as the host found it on
    /// disk with its symlinks resolved, where that differs from the path as
    /// written. A record names a directory of that home by either path: a
    /// `~/.codex` that links to a dotfiles volume is the target's path once
    /// the agent canonicalized it. The rules read no disk, so the host
    /// resolves it.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub resolved_homes: BTreeMap<ProviderId, String>,
    #[serde(default)]
    pub records: Vec<RecordFile>,
    #[serde(default)]
    pub session_records: Vec<RecordFile>,
    #[serde(default)]
    pub cwd_events: Vec<RecordFile>,
    #[serde(default)]
    pub worktree_events: Vec<WorktreeEventFile>,
    /// Every turn record found, named by its turn id. `content` is sent only
    /// for a file that is new or changed since the host last sent it; `None`
    /// means "as before", and the summary carried in `ProjectionState.turns`
    /// stands. A turn whose name is missing here is gone.
    #[serde(default)]
    pub turn_files: Vec<RecordFile>,
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
    /// The panes the person can see now: on screen in a window while the
    /// application is in front, the unfocused leaves of a split included.
    /// Wider than `focus`, which is the one pane keys go to. A run that
    /// finishes in one of these has been seen.
    #[serde(default)]
    pub seen_panes: Vec<Uuid>,
    /// The latest status each pane's program reported about itself with the
    /// Program Status Protocol (OSC 7501), as the terminal forwarded it. A
    /// pane whose program cleared its record, or never sent one, is absent.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub program_status: BTreeMap<Uuid, ProgramStatus>,
    /// What became of the previous pass's commands.
    #[serde(default)]
    pub acknowledged: Vec<CommandOutcome>,
    /// The first pass after launch, which records what exists and announces
    /// nothing. Without it every run visible at startup would fire.
    #[serde(default)]
    pub is_bootstrap: bool,
    /// What the turn retention sweep needs from the host. Absent until
    /// the host has read everything that protects a turn: before then no
    /// turn is deleted, since a turn not yet known to be unread would look
    /// like one that may go.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_sweep: Option<TurnSweepInput>,
}

/// The limits turns are kept within, and the turns the host protects.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnSweepInput {
    /// A turn started longer ago than this goes.
    pub max_age_secs: u64,
    /// Turns of one conversation past this many, newest first, go.
    pub max_per_conversation: u32,
    /// Past this many bytes of turn snapshots in one repository
    /// (`TurnSummary::added_bytes`), the oldest turns that may go, go too,
    /// whatever their age. `None` sets no such limit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_repository_bytes: Option<u64>,
    /// Past this many turns kept in all, the oldest that may go, go, read
    /// ones before unread: every pass carries a summary of each, and past
    /// the bridge's input limit no pass runs. `None` sets no such limit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_turns: Option<u64>,
    /// Turns the host knows a person still needs read: unread ones (after
    /// the viewed line, or answered without being seen) whose session is
    /// open, for up to 90 days. Spared the age limit, not the count limits,
    /// and holding back nothing after them.
    #[serde(default)]
    pub protected_turn_ids: BTreeSet<String>,
    /// Turns held for now: in a range a review has open or a draft comment
    /// belongs to, or read a moment ago. Kept, and while they are, no later
    /// turn of their worktree goes either.
    #[serde(default)]
    pub held_turn_ids: BTreeSet<String>,
    /// Conversations shown in a pane now. Their latest turns
    /// (`TURNS_KEPT_PER_SHOWN_CONVERSATION`) stay whatever their age, so a
    /// session kept open for weeks still has its recent history.
    #[serde(default)]
    pub shown_conversations: BTreeSet<ConversationKey>,
}

/// The latest turns of a conversation shown in a pane that age never takes.
pub const TURNS_KEPT_PER_SHOWN_CONVERSATION: usize = 20;
/// The most turns one pass deletes, oldest first. A first sweep over a long
/// history spreads over several passes rather than holding git for all of
/// it at once.
pub const MAX_TURN_DELETIONS_PER_PASS: usize = 100;

/// What the launch and terminate rules read. They run when there is no
/// interface yet or none left, so they see the state directories and the
/// process table and nothing else.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LifecycleInput {
    #[serde(default)]
    pub providers: BTreeMap<ProviderId, ProviderDescriptor>,
    #[serde(default)]
    pub records: Vec<RecordFile>,
    #[serde(default)]
    pub session_records: Vec<RecordFile>,
    #[serde(default)]
    pub resume_intents: Vec<ResumeIntent>,
    #[serde(default)]
    pub pid_status: BTreeMap<String, PidStatus>,
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
    /// What was read of each turn record, by turn id, so a pass only parses
    /// the files that changed.
    #[serde(default)]
    pub turns: BTreeMap<String, TurnSummary>,
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
    /// The episode the run was in, which is what decides whether asking for
    /// input again is a new thing to say or a repeat of the same one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode_token: Option<String>,
    /// The episode of the run's last end (a finish or a failure) the
    /// outbox is done with: announced, or seen with nothing to announce. A
    /// finish in that episode is the end of work the run did outside a turn
    /// after it, and is not news; an end the outbox only held (no pane to
    /// show it yet) or never saw (two writes inside one pass) still is.
    /// Absent in an outbox from before the field existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_token: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingNotification {
    pub runtime_id: String,
    pub state: RunState,
    /// The record write this entry was raised for.
    pub event_token: String,
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
    /// The tmux endpoint key the run's record names (`PanePresence`), when
    /// it is hosted in tmux. The host looks the run's own locations up by
    /// it, so it never has to rebuild which run a record is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tmux_endpoint_key: Option<String>,
    /// Identifies one record write. What the host echoes back after delivering
    /// a notification, so a stale delivery cannot retire a newer entry.
    pub event_token: String,
    /// Identifies a stretch of the same state. What viewed marks are taken
    /// against, and what decides a repeat from a new episode.
    pub episode_token: String,
    /// The agent's process, as its hooks recorded it. The host compares it with
    /// what is in front of a pane before typing there, which a process name
    /// cannot settle: one provider can run under an interpreter's name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<String>,
    /// The provider's session id, as the run's hooks reported it. What an
    /// approval request names its agent by, so the host places a request in
    /// the panes this run is attached to now (a tmux run writes no session
    /// hint for its launch pane, and may be attached elsewhere).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The conversation the run's turns are numbered in: its session, or the
    /// run itself until it reports one.
    pub conversation: ConversationKey,
    /// The turn the run is in or last finished, as its record names it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_turn_id: Option<String>,
}

/// What a pane's badge shows. Mirrors what the record carries, minus identity
/// and transport fields the interface has no use for.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Badge {
    pub state: RunState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// What the run waits on and the tool it waits to use (`RunRecord`),
    /// present only while it waits in `NeedsInput`. The interface words an
    /// approval and a question from these, and reads `detail` for them
    /// only when a record from before the fields leaves them out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wait_kind: Option<WaitKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
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
    /// The worktree the run's latest prompt was given in (`RunRecord`), which
    /// the app's restore gate reads as Rust's does.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree_root: Option<String>,
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
    /// Present only for providers with the cache window capability. The
    /// interface derives whether the cache is about to expire from this and
    /// its own clock, so the projection does not have to run on a timer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_window: Option<CacheWindow>,
    /// The usage limit the run stopped at, present only while it rests in
    /// error.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_limit: Option<UsageLimit>,
    /// Why the run stopped when no hook said so, present only on the badge
    /// of a run in error the projection put there itself.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_reason: Option<StopReason>,
    /// Whether the session holds a conversation to resume (`RunRecord`):
    /// `false` for one started anew and never prompted, which has no
    /// transcript, so its stop offers no resume as the launch rules
    /// retire it quietly (`session_lifecycle`). Absent when the record does
    /// not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub has_prompt: Option<bool>,
}

/// A stop the projection read from the facts rather than from a hook.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StopReason {
    /// The process died in the middle of work, with no hook to say how: a
    /// crash, a kill, the terminal going away. The badge shows the run in
    /// error for the one pass before its record is retired, so the
    /// interface can keep the stop and its resume.
    ProcessExited,
    /// The person declined the question or permission prompt the run waited
    /// on, which no hook reports (Esc at Claude's prompt). The projection
    /// read it from the transcript the record names, and the badge shows the
    /// turn stopped until the record is written to say so. The interface
    /// says the wait was declined rather than answered.
    WaitDeclined,
    /// The person stopped the run's work (Esc or Ctrl+C at Claude's
    /// prompt), which no hook reports. The agent's own status report said
    /// it is idle again, and the badge shows the turn stopped until the
    /// record is written to say so. The person stopped it where they were
    /// looking, so the finish is not announced.
    Interrupted,
    /// A reason a newer writer added, read as no reason at all.
    #[serde(other)]
    Unknown,
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
    /// Every conversation with a recorded turn, in key order; `None` when
    /// neither a turn nor the set of live runs changed since the previous
    /// pass (and that pass had turns), and the host keeps what it has. A
    /// person who has run a thousand turns would otherwise have every one of
    /// them sent back on every hook write.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversations: Option<Vec<ConversationTurns>>,
    /// How soon the host should run a pass though nothing it watches has
    /// changed, in milliseconds: a finished turn's notice is held
    /// (`FINISHED_NOTICE_HOLD_MS`) and only a pass after the hold releases
    /// it. `None` when nothing is held.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_pass_in_ms: Option<u64>,
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
    fn a_pane_shows_a_run_unless_its_own_endpoint_is_behind_another_tmux_pane_there() {
        // Keys in the shape the core builds (`socket|serverPid|serverStartedAt|pane`).
        let key = |tmux_pane: &str| format!("/tmp/socket|4242|1700000000|{tmux_pane}");
        let pane = Uuid::from_u128(1);
        let other = Uuid::from_u128(2);
        let behind = key("%4");
        let in_front = key("%3");
        let mut presence = PanePresence::default();
        presence.locations.insert(
            behind.clone(),
            [(pane, PaneLocation { is_active: false })]
                .into_iter()
                .collect(),
        );
        presence.locations.insert(
            in_front.clone(),
            [(pane, PaneLocation { is_active: true })]
                .into_iter()
                .collect(),
        );

        assert!(!presence.shows(Some(&behind), &pane));
        assert!(presence.shows(Some(&in_front), &pane));
        // A run outside tmux is in its pane, whatever tmux runs there too.
        assert!(presence.shows(None, &pane));
        // The probe knows the endpoint, but not in this pane; or does not
        // know the endpoint at all.
        assert!(presence.shows(Some(&behind), &other));
        assert!(presence.shows(Some(&key("%9")), &pane));
    }

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
                event_token: "4".to_owned(),
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
    fn marks_from_an_input_that_still_carries_dismissed_ones_read() {
        let marks: AttentionMarks =
            serde_json::from_str(r#"{"viewed":{"claude:a":"t1"},"dismissed":{"claude:b":"t2"}}"#)
                .expect("marks with dismissed ones parse");
        assert_eq!(
            marks.viewed,
            BTreeMap::from([("claude:a".to_owned(), "t1".to_owned())])
        );
        let input: ProjectionInput = serde_json::from_value(serde_json::json!({
            "now": {"wall": "2026-10-17T00:00:00Z", "monotonicMs": 0},
            "marks": {"viewed": {}, "dismissed": {"claude:b": "t2"}}
        }))
        .expect("an input with dismissed marks parses");
        assert!(input.marks.viewed.is_empty());
    }

    #[test]
    fn the_resume_window_covers_both_the_intent_and_the_kill_marker() {
        // The launch rule reads the intent's age and the kill marker's age in
        // the same pass; one window keeps them from drifting apart.
        assert_eq!(RESUME_WINDOW_SECS, 86_400);
        assert_eq!(VIEWED_FINISHED_RETENTION_SECS, 86_400);
    }
}
