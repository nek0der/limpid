//! Side effects the projection asks its host to perform.
//!
//! The rule functions own no file and no clock, so everything they decide to
//! change on disk leaves as a `Command`. Each one carries the precondition the
//! host rechecks inside the file lock, because the projection reasoned about a
//! snapshot and the file may have moved on since: a hook writing a new
//! revision, another pane taking over a resume hint. Declaring the
//! precondition with the command keeps that check in one place instead of
//! spreading compare-and-set logic through the host.
//!
//! Commands nest. `then` runs only after its parent, and `on_mismatch` says
//! whether a failed precondition stops the chain or lets it continue. Retiring
//! a dead record is the case that needs both: the resume hint may belong to a
//! newer run, in which case the hint is left alone and the record is still
//! retired.

use crate::provider::ProviderId;
use crate::record::RunState;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use uuid::Uuid;

/// Retired records kept before the oldest are dropped.
pub const MAX_RETIRED_RECORDS: u32 = 200;
/// How long a retired record stays readable, in seconds.
pub const RETIRED_RECORD_LIFETIME_SECS: u64 = 7 * 24 * 60 * 60;
/// Records a pane-scoped store keeps before the oldest are dropped.
pub const MAX_PANE_RECORDS: u32 = 200;

/// One side effect, its precondition, and what follows it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Command {
    pub op: CommandOp,
    pub target: Target,
    pub expect: Precondition,
    pub on_mismatch: OnMismatch,
    /// Runs after this command, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub then: Vec<Command>,
}

impl Command {
    /// A command with no follow-up that aborts its chain on a mismatch, which
    /// is the safe default for anything that removes state.
    #[must_use]
    pub fn new(op: CommandOp, target: Target, expect: Precondition) -> Self {
        Self {
            op,
            target,
            expect,
            on_mismatch: OnMismatch::Abort,
            then: Vec::new(),
        }
    }

    /// Lets the chain continue even when this command's precondition fails.
    #[must_use]
    pub fn continuing(mut self) -> Self {
        self.on_mismatch = OnMismatch::Continue;
        self
    }

    #[must_use]
    pub fn then(mut self, next: Command) -> Self {
        self.then.push(next);
        self
    }
}

/// What the host does to the target.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum CommandOp {
    /// Move a run record into the retired directory. Not a delete: a record
    /// that turns out to have been live is still recoverable by hand.
    Retire,
    /// Apply a patch to a run record in place.
    Update(RecordPatch),
    /// Remove the target file.
    Delete,
    /// Write a resume intent so the next launch can restore the run.
    WriteResumeIntent(ResumeIntent),
    /// Drop retired records past the count or age limit.
    PruneRetired { max: u32, lifetime_secs: u64 },
    /// Drop pane-scoped records whose pane is gone, then cap what is left.
    CleanupPaneStore { keep: BTreeSet<Uuid>, max: u32 },
    /// Deliver a notification. The host decides whether the pane is focused
    /// and applies its own rate limit; the projection only decides that the
    /// transition is worth announcing.
    Notify(NotifyCommand),
    /// Record that the user has seen a finished run's current episode.
    MarkViewed { runtime_id: String, token: String },
    /// Hand a cwd change to whatever suggests moving the pane's worktree.
    CwdChanged {
        pane: Uuid,
        new_cwd: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        old_cwd: Option<String>,
    },
    /// Refetch git state for a repository an agent just created a worktree in.
    GitSyncRefetch { repo_root: String },
}

/// What the command addresses. The host needs this separately from the verb
/// because it decides which file to lock before it can check anything.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "target", rename_all = "camelCase")]
pub enum Target {
    /// A run record inside a provider's state directory.
    Record {
        provider: ProviderId,
        storage_id: String,
    },
    /// A pane's resume hint.
    SessionHint { provider: ProviderId, pane: Uuid },
    /// A resume intent, named by the run that owns it.
    ResumeIntent { run_id: String },
    /// A pane's cwd event file.
    CwdEvent { pane: Uuid },
    /// One file in a provider's worktree event directory.
    WorktreeEvent {
        provider: ProviderId,
        file_name: String,
    },
    /// A provider's retired directory, for the sweep.
    RetiredRecords { provider: ProviderId },
    /// A provider's pane-scoped store, for the capped cleanup.
    PaneStore {
        provider: ProviderId,
        store: PaneStoreKind,
    },
    /// Nothing on disk. Notifications, viewed marks, and git refetches are
    /// performed without taking a lock.
    Host,
}

/// Which pane-scoped store a cleanup addresses.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PaneStoreKind {
    Sessions,
    CwdEvents,
}

/// What must still be true when the host takes the lock.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "expect", rename_all = "camelCase")]
pub enum Precondition {
    /// Nothing to check, because the target is not a file.
    None,
    /// The file is still there.
    Exists,
    /// The record is the one the projection read. Used before retiring, where
    /// acting on a record a hook has since rewritten would drop live state.
    RecordUnchanged {
        storage_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        revision: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pid: Option<String>,
        updated_at: String,
    },
    /// The record still names the same process at the same revision. Used by
    /// the launch and terminate rules, which only care that no hook has run in
    /// between.
    PidAndRevision {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pid: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        revision: Option<u64>,
    },
    /// The resume hint still names this run. A hint that has moved on belongs
    /// to a newer run on the same pane and is not this one's to remove.
    /// Absent matches a hint with no run id, which is what records from before
    /// run ids existed produce.
    HintOwner {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        run_id: Option<String>,
    },
}

/// What a failed precondition does to the rest of the chain.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OnMismatch {
    /// Keep going. The mismatch is a fact about the target, not a reason to
    /// abandon the rest: a resume hint that belongs to a newer run should stay
    /// while the dead record it was attached to is still retired.
    Continue,
    /// Stop. A lock conflict always aborts, whatever this says, because a busy
    /// file means the projection read a snapshot someone is mid-write on.
    Abort,
}

/// Fields a record update may change. `Keep` is the default so a patch names
/// only what it touches.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordPatch {
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub state: Patch<RunState>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub pid: Patch<String>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub killed_by_limpid_at: Patch<String>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub resume_attempted_at: Patch<String>,
}

/// One field of a patch. Clearing and leaving alone are different intents, so
/// they are different variants rather than `Option<Option<T>>`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Patch<T> {
    #[default]
    Keep,
    Clear,
    Set(T),
}

impl<T> Patch<T> {
    #[must_use]
    pub fn is_keep(&self) -> bool {
        matches!(self, Self::Keep)
    }
}

/// The intent written at terminate so the next launch can tell a run Limpid
/// killed from one that died on its own.
///
/// The field names and types match what the store already writes, so moving
/// the rule into Rust needs no migration: identifiers keep their `ID` suffix,
/// the pid stays the string the record carries rather than a parsed number,
/// and the timestamp is ISO-8601 because the encoder writes dates that way.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResumeIntent {
    #[serde(rename = "runID")]
    pub run_id: String,
    #[serde(rename = "paneID")]
    pub pane_id: Uuid,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    /// The run that owned the resume hint when the intent was written. Absent
    /// for intents written before hints recorded their owner.
    #[serde(
        rename = "ownerRunID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub owner_run_id: Option<String>,
    pub pid: String,
    pub created_at: String,
}

/// Why a notification is being raised. The title text is the host's to build,
/// because it is localized and names the provider from the registry.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NotificationKind {
    Finished,
    NeedsInput,
    Failed,
}

/// Everything the host needs to deliver one notification, plus what it must
/// echo back so the projection can retire the pending entry.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotifyCommand {
    pub provider: ProviderId,
    pub kind: NotificationKind,
    pub tab: Uuid,
    pub pane: Uuid,
    pub runtime_id: String,
    /// Prompt or detail text, already truncated. Absent when the run left
    /// nothing worth quoting.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    /// False for errors, which reach the history without interrupting: the
    /// agent's own dialog is already on screen at that moment.
    pub presents_banner: bool,
    /// The host marks the history row read instead of banner-ing when the
    /// target pane already has focus.
    pub suppress_when_pane_focused: bool,
    /// Identifies the attention episode, which is what the history uses to
    /// tell a repeated ask from a new one.
    pub episode_token: String,
    /// Echoed back in the outcome so a delivery for a write the run has since
    /// moved past does not clear a newer pending entry.
    pub event_token: String,
    pub state: RunState,
}

/// What became of a command, fed back into the next projection pass.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
pub enum CommandOutcome {
    /// The host delivered a notification for this runtime at this state.
    Notified {
        runtime_id: String,
        event_token: String,
        state: RunState,
    },
    /// The precondition held and the command ran.
    Applied { target: Target },
    /// The precondition did not hold. Whether the chain continued is already
    /// decided by `on_mismatch`; this only reports what happened.
    Mismatched { target: Target },
    /// The file was locked by a writer, so nothing was attempted.
    Busy { target: Target },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider() -> ProviderId {
        ProviderId::new("claude").expect("provider id")
    }

    #[test]
    fn a_chain_declares_its_own_mismatch_behaviour() {
        let retire = Command::new(
            CommandOp::Retire,
            Target::Record {
                provider: provider(),
                storage_id: "RUN".to_owned(),
            },
            Precondition::RecordUnchanged {
                storage_id: "RUN".to_owned(),
                revision: Some(4),
                pid: Some("42".to_owned()),
                updated_at: "2026-09-14T12:00:00Z".to_owned(),
            },
        );
        let chain = Command::new(
            CommandOp::Delete,
            Target::SessionHint {
                provider: provider(),
                pane: Uuid::nil(),
            },
            Precondition::HintOwner {
                run_id: Some("RUN".to_owned()),
            },
        )
        .continuing()
        .then(retire);

        // Dropping the hint is best-effort because it may belong to a newer
        // run, but the retirement it leads to must not act on a record that
        // changed underneath.
        assert_eq!(chain.on_mismatch, OnMismatch::Continue);
        assert_eq!(chain.then[0].on_mismatch, OnMismatch::Abort);
    }

    #[test]
    fn a_patch_serializes_only_the_fields_it_touches() {
        let patch = RecordPatch {
            state: Patch::Set(RunState::Unknown),
            pid: Patch::Clear,
            ..RecordPatch::default()
        };
        let text = serde_json::to_string(&patch).expect("encode");
        assert!(text.contains("\"state\""), "{text}");
        assert!(text.contains("\"pid\":\"clear\""), "{text}");
        assert!(!text.contains("killedByLimpidAt"), "{text}");
        let back: RecordPatch = serde_json::from_str(&text).expect("decode");
        assert_eq!(back, patch);
    }

    #[test]
    fn commands_round_trip_through_json() {
        let command = Command::new(
            CommandOp::PruneRetired {
                max: MAX_RETIRED_RECORDS,
                lifetime_secs: RETIRED_RECORD_LIFETIME_SECS,
            },
            Target::RetiredRecords {
                provider: provider(),
            },
            Precondition::None,
        );
        let text = serde_json::to_string(&command).expect("encode");
        let back: Command = serde_json::from_str(&text).expect("decode");
        assert_eq!(back, command);
    }

    #[test]
    fn a_resume_intent_round_trips_the_shape_already_on_disk() {
        // Pinned against what the store writes today. A rename or a retyped
        // pid here would orphan every intent a previous release left behind.
        let text = r#"{"runID":"RUN","paneID":"11111111-1111-4111-8111-111111111111",
            "sessionID":"S","ownerRunID":"OWNER","pid":"4242",
            "createdAt":"2026-09-14T12:00:00Z"}"#;
        let intent: ResumeIntent = serde_json::from_str(text).expect("decode");
        assert_eq!(intent.pid, "4242");
        assert_eq!(intent.owner_run_id.as_deref(), Some("OWNER"));
        let back = serde_json::to_string(&intent).expect("encode");
        assert!(back.contains("\"runID\""), "{back}");
        assert!(back.contains("\"createdAt\""), "{back}");

        // An intent from before hints recorded their owner still decodes.
        let legacy = r#"{"runID":"RUN","paneID":"11111111-1111-4111-8111-111111111111",
            "sessionID":"S","pid":"4242","createdAt":"2026-09-14T12:00:00Z"}"#;
        let intent: ResumeIntent = serde_json::from_str(legacy).expect("decode legacy");
        assert!(intent.owner_run_id.is_none());
    }
}
