//! The per-turn record the hook runtime writes and the host reads.
//!
//! One record per turn, `turns/<turn_id>.turn.json` in the provider's state
//! directory. It carries what the turn changed (changed, unchanged, or
//! unavailable, never guessed) and the events already applied to it, so a
//! hook the shim retries is applied once. Like the run record, fields and
//! values this version does not know are kept or read as unknown rather than
//! rejected: an older reader must not erase or refuse what a newer writer
//! recorded.

use crate::event::EventId;
use crate::prompt::{PromptKind, RecordedPromptKind, classify_prompt};
use crate::provider::ProviderId;
use crate::serde_helpers::lenient;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// What a turn record's file name ends with; the rest is its turn id.
pub const TURN_RECORD_FILE_SUFFIX: &str = ".turn.json";

/// The file name of the record for `turn_id`.
#[must_use]
pub fn turn_record_file_name(turn_id: &str) -> String {
    format!("{turn_id}{TURN_RECORD_FILE_SUFFIX}")
}

/// The conversation a turn belongs to. A struct, never flattened into a
/// string or used as a JSON map key, so its parts stay readable and a
/// fallback key cannot collide with a real conversation id.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationKey {
    pub provider: ProviderId,
    /// The provider's session id, or the run id when the provider gave none.
    pub conversation_id: String,
    /// True when `conversation_id` is the run id standing in for a session
    /// id the provider did not report.
    pub is_fallback: bool,
}

impl ConversationKey {
    /// The name of the counter file that numbers this conversation's turns.
    /// A stable hash of the key, so the name is safe for any conversation id
    /// and the same in every build; FNV-1a rather than the standard hasher,
    /// whose output may change between Rust releases.
    #[must_use]
    pub fn counter_file_name(&self) -> String {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        let fallback: &[u8] = if self.is_fallback { b"1" } else { b"0" };
        for part in [
            self.provider.as_str().as_bytes(),
            b"\0",
            self.conversation_id.as_bytes(),
            b"\0",
            fallback,
        ] {
            for byte in part {
                hash ^= u64::from(*byte);
                hash = hash.wrapping_mul(0x0100_0000_01b3);
            }
        }
        format!("{hash:016x}{TURN_COUNTER_FILE_SUFFIX}")
    }
}

/// What a turn counter file's name ends with.
pub const TURN_COUNTER_FILE_SUFFIX: &str = ".counter";

/// The per-conversation counter the writer holds a lock on while it numbers
/// a turn. The number only grows: a deleted turn's number is not reused, so
/// "T7" means the same turn for as long as it is shown. The writer checks
/// that `conversation` is the key it hashed to the file name, so the
/// improbable collision of two keys is caught rather than shared.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnCounter {
    pub conversation: ConversationKey,
    pub last_display_number: u32,
    /// Fields this version does not model, preserved verbatim.
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// The repository a turn started in, compared before restoring code to it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitContext {
    pub head: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    pub root: String,
    /// The repository's common git directory, which holds the turn refs of
    /// every worktree: the way to them once a linked worktree is removed,
    /// and what the size limit is counted per.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub common_dir: Option<String>,
    /// Fields this version does not model, preserved verbatim.
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// An untracked file left out of a snapshot for its size (over 5 MB). Two
/// snapshots agree on what they skipped only when the same paths have the
/// same size and modification time.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkippedFile {
    pub path: String,
    #[serde(rename = "size")]
    pub size_bytes: u64,
    /// As the writer formatted it; only compared, never parsed.
    pub mtime: String,
}

/// Where a turn stands. Set by the event that ends the turn, independent of
/// whether its snapshots could be taken: a turn outside Git that ended
/// normally is `Finished`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TurnPhase {
    Started,
    Finished,
    Failed,
    Interrupted,
    /// A phase this version does not know. Never written: a turn whose end
    /// will not come (a later turn of its run overtook it, or its run is
    /// gone) stays `Started` on disk, and the projection reports it as
    /// `Unknown` with its changes unavailable (`TurnSummary::overtaken`).
    #[default]
    #[serde(other)]
    Unknown,
}

/// The state of one of a turn's two snapshots.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum SnapshotStatus {
    Pending,
    Captured {
        tree: String,
        root: String,
    },
    Failed {
        reason: String,
    },
    NotGit,
    Disabled,
    Skipped {
        reason: String,
    },
    #[default]
    #[serde(other)]
    Unknown,
}

/// What a turn changed. `Unchanged` is a finding, not a default: it
/// needs both snapshots and an empty difference between them.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum ChangeSummary {
    Pending,
    Changed {
        files: u32,
        added: u32,
        removed: u32,
        /// Written as `hasBashChanges`, the key every record already has.
        #[serde(rename = "hasBashChanges")]
        has_shell_changes: bool,
        /// Untracked files over the size limit that neither snapshot holds,
        /// so the counts above may be short. Zero is omitted.
        #[serde(default, skip_serializing_if = "is_zero")]
        large_files_skipped: u32,
    },
    Unchanged,
    Unavailable {
        reason: String,
    },
    #[default]
    #[serde(other)]
    Unknown,
}

/// The last check a turn ran: a test or build command the project counts
/// as one, and how it exited.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckResult {
    /// As the agent ran it, so the person sees what was run.
    pub command: String,
    /// `None` when the status is not known to be the check's own: the run
    /// was interrupted or sent to the background, or something after it on
    /// the command line (`| tail`, `|| true`) set the status. The interface
    /// then shows the command with no ✓ or ✗.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// Whether the run was narrowed to part of the suite: a success then
    /// says nothing about the rest.
    pub is_filtered: bool,
}

/// The difference between a turn's two snapshots, as the writer measured it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DiffStat {
    pub files: u32,
    pub added: u32,
    pub removed: u32,
    /// Whether a shell command, not only the agent's edit tools, changed
    /// files during the turn.
    pub has_shell_changes: bool,
    /// The bytes of the blobs the end snapshot holds that the begin snapshot
    /// did not, before compression: what the turn added, not what its begin
    /// ref keeps of the work between turns, which no limit counts.
    /// `None` when they could not be counted.
    pub added_bytes: Option<u64>,
}

impl ChangeSummary {
    /// Decides the summary from the turn's snapshots. `diff` is `None` when
    /// the difference could not be taken. Anything short of two captured
    /// snapshots of the same repository with the same skipped files is
    /// unavailable: the person is told it could not be known rather than that
    /// nothing changed. The reason is one of a fixed set of names, which the
    /// host maps to its words; a snapshot's own reason text stays on the
    /// snapshot. The app reads `beginMissing` and `endMissing` by name
    /// (`ChangeSummary.isLostSnapshot` in Swift) to call the record
    /// incomplete, so renaming either changes what the review says.
    #[must_use]
    pub fn judge(
        phase: TurnPhase,
        begin: &SnapshotStatus,
        end: &SnapshotStatus,
        skipped_begin: &[SkippedFile],
        skipped_end: &[SkippedFile],
        diff: Option<DiffStat>,
    ) -> Self {
        use SnapshotStatus as S;
        let unavailable = |reason: &str| Self::Unavailable {
            reason: reason.to_owned(),
        };
        match (begin, end) {
            (
                S::Captured {
                    root: begin_root, ..
                },
                S::Captured { root: end_root, .. },
            ) => {
                // A turn that moved to another repository has two trees that
                // were never one tree's before and after.
                if begin_root != end_root {
                    return unavailable("rootChanged");
                }
                if !same_files(skipped_begin, skipped_end) {
                    return unavailable("skippedFilesDiffer");
                }
                let Some(diff) = diff else {
                    return unavailable("diffFailed");
                };
                if diff.files == 0 {
                    return Self::Unchanged;
                }
                Self::Changed {
                    files: diff.files,
                    added: diff.added,
                    removed: diff.removed,
                    has_shell_changes: diff.has_shell_changes,
                    large_files_skipped: u32::try_from(skipped_end.len()).unwrap_or(u32::MAX),
                }
            }
            // A record with no begin: the hook missed the prompt, or the
            // writer stopped before the first snapshot (an incomplete
            // record). Whatever the end says, there is nothing to compare it
            // with, and saying why it was not taken would hide that.
            (
                S::Pending,
                S::Captured { .. } | S::NotGit | S::Disabled | S::Failed { .. } | S::Skipped { .. },
            ) => unavailable("beginMissing"),
            (S::NotGit, _) | (_, S::NotGit) => unavailable("notGit"),
            (S::Disabled, _) | (_, S::Disabled) => unavailable("disabled"),
            (S::Failed { .. }, _) | (_, S::Failed { .. }) => unavailable("snapshotFailed"),
            (S::Skipped { .. }, _) | (_, S::Skipped { .. }) => unavailable("snapshotSkipped"),
            (S::Pending | S::Captured { .. }, S::Pending) if phase == TurnPhase::Started => {
                Self::Pending
            }
            (S::Pending | S::Captured { .. }, S::Pending) => unavailable("endMissing"),
            (S::Unknown, _) | (_, S::Unknown) => unavailable("unknown"),
        }
    }
}

#[allow(clippy::trivially_copy_pass_by_ref)] // serde passes the field by reference.
fn is_zero(value: &u32) -> bool {
    *value == 0
}

/// Whether two snapshots skipped the same files, in any order.
fn same_files(first: &[SkippedFile], second: &[SkippedFile]) -> bool {
    let mut first = first.to_vec();
    let mut second = second.to_vec();
    first.sort();
    second.sort();
    first == second
}

/// What the interface shows of one turn, as the projection hands it over:
/// the record without what only the writer needs (the events it applied, the
/// skipped files themselves, fields this version does not model).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnSummary {
    pub turn_id: String,
    pub conversation: ConversationKey,
    pub run_id: String,
    pub pane_id: String,
    pub display_number: u32,
    /// The person's words the turn began from, on one line: the record's
    /// head without the harness blocks that led it. For a prompt the
    /// harness wrote (`prompt_kind`), the record's head as it came, which
    /// is never shown as an instruction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_head: Option<String>,
    /// Who wrote the prompt (`classify_prompt`). Absent, as in a state
    /// carried from before it was kept, or a kind this version does not
    /// know, it reads as the person's words.
    #[serde(default, deserialize_with = "lenient")]
    pub prompt_kind: PromptKind,
    pub started_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<String>,
    pub phase: TurnPhase,
    pub begin: SnapshotStatus,
    pub end: SnapshotStatus,
    pub changes: ChangeSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<u64>,
    /// What the turn added, before compression, that its refs keep from
    /// `git gc` (`TurnRecord::added_bytes`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added_bytes: Option<u64>,
    /// The repository the turn's refs live in, its common git directory,
    /// which the size limit is counted per; absent in a record from
    /// before it was kept, which counts by the worktree it was taken in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_check: Option<CheckResult>,
    /// False for an end-only record nobody prompted: the hook saw no prompt
    /// for it (the agent stopped on its own, answering a background task, or
    /// the prompt came before this build recorded turns). Such a turn is
    /// history, not something to read or decide on.
    pub has_prompt: bool,
    /// Whether this version may delete the record (`TurnRecord::is_writable`):
    /// the retention sweep never chooses one a newer writer wrote, whose refs
    /// may be named where this version cannot read. Absent, as in a state
    /// carried from before it was kept, it reads as not deletable until the
    /// record is read again.
    #[serde(default)]
    pub is_deletable: bool,
}

impl TurnSummary {
    /// The summary of `record`.
    #[must_use]
    pub fn of(record: &TurnRecord) -> Self {
        // A record that kept its kind was judged from the whole prompt; one
        // from before it was kept is judged again from its head, which may
        // have cut a leading block short (it then reads as `Injected`).
        let (prompt_kind, prompt_head) = match (&record.prompt_kind, record.prompt_head.as_deref())
        {
            (Some(kind), _) => (kind.kind(), record.prompt_head.clone()),
            (None, Some(head)) => match classify_prompt(head) {
                (PromptKind::Text, words) => (
                    PromptKind::Text,
                    Some(words.to_owned()).filter(|words| !words.is_empty()),
                ),
                (kind, _) => (kind, record.prompt_head.clone()),
            },
            (None, None) => (PromptKind::Text, None),
        };
        Self {
            turn_id: record.turn_id.clone(),
            conversation: record.conversation.clone(),
            run_id: record.run_id.clone(),
            pane_id: record.pane_id.clone(),
            display_number: record.display_number,
            prompt_head,
            prompt_kind,
            started_at: record.started_at.clone(),
            finished_at: record.finished_at.clone(),
            phase: record.phase,
            begin: record.begin.clone(),
            end: record.end.clone(),
            changes: record.changes.clone(),
            duration_seconds: record.duration_seconds,
            added_bytes: record.added_bytes,
            repository: record
                .git_context
                .as_ref()
                .and_then(|context| context.common_dir.clone()),
            last_check: record.last_check.clone(),
            has_prompt: record.prompt_head.is_some() || record.begin != SnapshotStatus::Pending,
            is_deletable: record.is_writable(),
        }
    }

    /// The summary of a turn whose end will not come: a later turn of its
    /// run overtook it, or its run is gone. Still `Started`, it was
    /// cut short (the person interrupted it, the agent crashed, its pane
    /// closed), so it is not running, and what it changed cannot be known
    /// whatever its record still says. Its phase reads as unknown
    /// rather than interrupted, which would be a guess.
    #[must_use]
    pub fn overtaken(mut self) -> Self {
        if self.phase == TurnPhase::Started {
            self.phase = TurnPhase::Unknown;
            self.changes =
                ChangeSummary::judge(TurnPhase::Unknown, &self.begin, &self.end, &[], &[], None);
        }
        self
    }
}

/// One conversation's turns, in display order. A list rather than a map
/// keyed by the conversation, so the composite key is never a JSON map key.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationTurns {
    pub key: ConversationKey,
    pub turns: Vec<TurnSummary>,
}

/// One turn, as `turns/<turn_id>.turn.json` holds it. Read it with
/// `TurnRecord::decode`, which also decides whether it may be rewritten.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnRecord {
    pub schema_version: u32,
    pub turn_id: String,
    /// The same as `conversation.provider`, which the writer sets both from;
    /// kept on its own so a reader can sort records by provider without the
    /// key.
    pub provider: ProviderId,
    pub conversation: ConversationKey,
    pub run_id: String,
    pub pane_id: String,
    /// From the conversation's counter; never reused after a deletion.
    pub display_number: u32,
    /// The prompt's first characters on one line (`prompt_head` in
    /// `limpid-agent-core`): the person's words without the harness blocks
    /// that led them, or a prompt the harness wrote as it came.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_head: Option<String>,
    /// Who wrote the prompt, judged from the whole prompt when the turn
    /// began (`classify_prompt`). Absent in a record from before it was
    /// kept, whose kind is judged again from its head. A value this version
    /// does not know is kept and written back (`RecordedPromptKind`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_kind: Option<RecordedPromptKind>,
    pub started_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<String>,
    #[serde(default, deserialize_with = "lenient")]
    pub phase: TurnPhase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_context: Option<GitContext>,
    #[serde(default, deserialize_with = "lenient")]
    pub begin: SnapshotStatus,
    #[serde(default, deserialize_with = "lenient")]
    pub end: SnapshotStatus,
    #[serde(default)]
    pub skipped_begin: Vec<SkippedFile>,
    #[serde(default)]
    pub skipped_end: Vec<SkippedFile>,
    #[serde(default, deserialize_with = "lenient")]
    pub changes: ChangeSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_seconds: Option<u64>,
    /// What the turn's end snapshot added to the repository's objects, in
    /// bytes (`DiffStat::added_bytes`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub added_bytes: Option<u64>,
    /// The last check the turn ran, when it ran one. A shape this version
    /// cannot read is dropped and marks the record read lossily, like the
    /// other fields, so it is not written back without it.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient"
    )]
    pub last_check: Option<CheckResult>,
    /// The events already applied, so a retried hook is applied once.
    #[serde(default)]
    pub applied_events: Vec<String>,
    /// Fields this version does not model, preserved verbatim.
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
    /// Set by `decode` when writing the record back would not give the file
    /// back as it was (a value read as `Unknown`, a field or key this version
    /// drops), so the record is then read only, as a newer schema's is. Only
    /// `decode` sets it: read a record through `decode`, never through
    /// `Deserialize` alone.
    #[serde(skip)]
    pub was_decoded_lossily: bool,
}

/// Why turn record bytes could not be read.
#[derive(Debug, thiserror::Error)]
pub enum TurnRecordError {
    #[error("turn record is not valid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("turn record is not a JSON object")]
    NotAnObject,
    #[error("turn record has no schemaVersion")]
    MissingSchemaVersion,
    /// A newer writer's record whose shape this version cannot read. It is
    /// counted but never rewritten or deleted.
    #[error("turn record schema {0} is not readable by this version")]
    UnsupportedSchema(u64),
}

/// What became of an event offered to a turn record. Must be read: the
/// caller applies the event's effect only for `Applied`.
#[must_use]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EventApplication {
    Applied,
    /// Already applied: a hook the shim retried.
    Duplicate,
    /// The event has no identity, so whether it was already applied cannot
    /// be told. It is not applied rather than risk applying it twice.
    Rejected,
}

impl TurnRecord {
    /// The schema version this crate writes. Raised whenever an enum gains
    /// a variant or a variant changes shape, not only when a field moves: an
    /// older reader reads an unknown value as `Unknown` and must know not to
    /// write it back (`was_decoded_lossily`). `promptKind` is the exception: it
    /// only words the turn, and a reader keeps a kind it does not know as it
    /// came (`RecordedPromptKind`), so a new kind needs no new schema.
    pub const SCHEMA_VERSION: u32 = 1;

    /// Decodes a record. A newer schema that still has this version's shape
    /// is read, and `is_writable` says to leave it alone.
    ///
    /// # Errors
    ///
    /// Returns `TurnRecordError` when the bytes are not a JSON object, carry
    /// no schema version, are a newer schema whose shape this version cannot
    /// read, or do not have this version's shape.
    pub fn decode(bytes: &[u8]) -> Result<Self, TurnRecordError> {
        let value: Value = serde_json::from_slice(bytes)?;
        let Some(object) = value.as_object() else {
            return Err(TurnRecordError::NotAnObject);
        };
        let version = object
            .get("schemaVersion")
            .and_then(Value::as_u64)
            .ok_or(TurnRecordError::MissingSchemaVersion)?;
        match serde_json::from_value::<Self>(value.clone()) {
            Ok(mut record) => {
                // Anything a rewrite would not give back as it was read (a
                // value read as `Unknown`, a missing field filled in, a key
                // inside a known value or a skipped file that this version
                // drops) makes the record read only. One comparison of the
                // whole record catches each of them; a false alarm only
                // costs a record this version leaves alone.
                record.was_decoded_lossily =
                    serde_json::to_value(&record).ok().as_ref() != Some(&value);
                Ok(record)
            }
            Err(_) if version > u64::from(Self::SCHEMA_VERSION) => {
                Err(TurnRecordError::UnsupportedSchema(version))
            }
            Err(error) => Err(TurnRecordError::Json(error)),
        }
    }

    /// The record as written to its file.
    ///
    /// # Errors
    ///
    /// Returns `serde_json::Error` only if serialization itself fails.
    pub fn encode(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(self)
    }

    /// Whether this version may rewrite or delete the record. A newer
    /// writer's record, and one with a value this version could only read as
    /// `Unknown`, are read only: rewriting would drop what this version does
    /// not understand about them.
    #[must_use]
    pub fn is_writable(&self) -> bool {
        self.schema_version == Self::SCHEMA_VERSION && !self.was_decoded_lossily
    }

    /// Notes `event` as applied, once. The caller applies the event's effect
    /// only for `Applied`.
    pub fn apply_event(&mut self, event: Option<&EventId>) -> EventApplication {
        let Some(event) = event else {
            return EventApplication::Rejected;
        };
        if self
            .applied_events
            .iter()
            .any(|applied| applied == event.as_str())
        {
            return EventApplication::Duplicate;
        }
        self.applied_events.push(event.as_str().to_owned());
        EventApplication::Applied
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn claude() -> ProviderId {
        ProviderId::new("claude").expect("valid")
    }

    fn record() -> TurnRecord {
        TurnRecord {
            schema_version: TurnRecord::SCHEMA_VERSION,
            turn_id: "4C1E8F7A-0000-4000-8000-000000000001".into(),
            provider: claude(),
            conversation: ConversationKey {
                provider: claude(),
                conversation_id: "session-1".into(),
                is_fallback: false,
            },
            run_id: "R1".into(),
            pane_id: "P1".into(),
            display_number: 7,
            prompt_head: Some("add tests".into()),
            prompt_kind: Some(RecordedPromptKind::Known(PromptKind::Text)),
            started_at: "2026-10-12T00:00:00Z".into(),
            finished_at: None,
            phase: TurnPhase::Started,
            git_context: Some(GitContext {
                head: "abc".into(),
                branch: Some("main".into()),
                root: "/repo".into(),
                common_dir: None,
                extra: BTreeMap::new(),
            }),
            begin: SnapshotStatus::Captured {
                tree: "t1".into(),
                root: "/repo".into(),
            },
            end: SnapshotStatus::Pending,
            skipped_begin: Vec::new(),
            skipped_end: Vec::new(),
            changes: ChangeSummary::Pending,
            duration_seconds: None,
            added_bytes: None,
            applied_events: Vec::new(),
            last_check: None,
            extra: BTreeMap::new(),
            was_decoded_lossily: false,
        }
    }

    fn captured(tree: &str) -> SnapshotStatus {
        SnapshotStatus::Captured {
            tree: tree.into(),
            root: "/repo".into(),
        }
    }

    fn skipped(path: &str, size: u64) -> SkippedFile {
        SkippedFile {
            path: path.into(),
            size_bytes: size,
            mtime: "2026-10-12T00:00:00Z".into(),
        }
    }

    #[test]
    fn turn_record_round_trips_with_unknown_fields() {
        let mut value = serde_json::to_value(record()).expect("serialize");
        value["laterField"] = serde_json::json!({"kept": true});
        let back = TurnRecord::decode(value.to_string().as_bytes()).expect("decode");
        assert_eq!(
            back.extra.get("laterField"),
            Some(&serde_json::json!({"kept": true}))
        );
        assert!(back.is_writable());
        let again: Value = serde_json::from_slice(&back.encode().expect("encode")).expect("json");
        assert_eq!(again, value, "a rewrite keeps what it did not model");
    }

    #[test]
    fn unknown_enum_values_decode_as_unknown() {
        let mut value = serde_json::to_value(record()).expect("serialize");
        value["phase"] = serde_json::json!("paused");
        value["begin"] = serde_json::json!({"kind": "mirrored", "where": "s3"});
        // A known kind in a shape this version does not know.
        value["end"] = serde_json::json!({"kind": "captured", "tree": 3});
        value["changes"] = serde_json::json!({"kind": "estimated", "files": 2});
        let back = TurnRecord::decode(value.to_string().as_bytes()).expect("decode");
        assert_eq!(back.phase, TurnPhase::Unknown);
        assert_eq!(back.begin, SnapshotStatus::Unknown);
        assert_eq!(back.end, SnapshotStatus::Unknown);
        assert_eq!(back.changes, ChangeSummary::Unknown);
        // Writing it back would turn "paused" into "unknown".
        assert!(back.was_decoded_lossily);
        assert!(!back.is_writable());

        // A missing phase, a key inside a known value, and a key on a
        // skipped file would each be lost by a rewrite.
        for change in [
            Box::new(|v: &mut Value| {
                v.as_object_mut().expect("object").remove("phase");
            }) as Box<dyn Fn(&mut Value)>,
            Box::new(|v: &mut Value| v["begin"]["bytes"] = serde_json::json!(5)),
            Box::new(|v: &mut Value| {
                v["skippedEnd"] =
                    serde_json::json!([{"path": "a", "size": 1, "mtime": "t", "inode": 9}]);
            }),
        ] {
            let mut value = serde_json::to_value(record()).expect("serialize");
            change(&mut value);
            let back = TurnRecord::decode(value.to_string().as_bytes()).expect("decode");
            assert!(!back.is_writable(), "{value}");
        }

        // A file that itself says unknown loses nothing.
        let mut plain = serde_json::to_value(record()).expect("serialize");
        plain["phase"] = serde_json::json!("unknown");
        plain["changes"] = serde_json::json!({"kind": "unknown"});
        let back = TurnRecord::decode(plain.to_string().as_bytes()).expect("decode");
        assert!(back.is_writable());
    }

    #[test]
    fn variant_fields_are_camel_case_on_the_wire() {
        let wire = r#"{"kind":"changed","files":2,"added":94,"removed":2,"hasBashChanges":true,"largeFilesSkipped":1}"#;
        let summary: ChangeSummary = serde_json::from_str(wire).expect("reads");
        assert_eq!(
            summary,
            ChangeSummary::Changed {
                files: 2,
                added: 94,
                removed: 2,
                has_shell_changes: true,
                large_files_skipped: 1,
            }
        );
        assert_eq!(
            serde_json::to_value(&summary).expect("writes"),
            serde_json::from_str::<Value>(wire).expect("json")
        );
    }

    #[test]
    fn unchanged_requires_equal_skipped_sets() {
        let empty = DiffStat {
            files: 0,
            added: 0,
            removed: 0,
            has_shell_changes: false,
            added_bytes: None,
        };
        let judge = |begin: &[SkippedFile], end: &[SkippedFile], diff| {
            ChangeSummary::judge(
                TurnPhase::Finished,
                &captured("a"),
                &captured("b"),
                begin,
                end,
                diff,
            )
        };
        assert_eq!(judge(&[], &[], Some(empty)), ChangeSummary::Unchanged);
        let big = [skipped("data.bin", 6_000_000)];
        assert_eq!(judge(&big, &big, Some(empty)), ChangeSummary::Unchanged);
        let grown = [skipped("data.bin", 7_000_000)];
        assert_eq!(
            judge(&big, &grown, Some(empty)),
            ChangeSummary::Unavailable {
                reason: "skippedFilesDiffer".into()
            },
            "a skipped file that changed may be the whole change"
        );
        let both = [skipped("b.bin", 6_000_000), skipped("a.bin", 6_000_000)];
        let reordered = [skipped("a.bin", 6_000_000), skipped("b.bin", 6_000_000)];
        assert_eq!(
            judge(&both, &reordered, Some(empty)),
            ChangeSummary::Unchanged,
            "order does not matter"
        );
        let diff = DiffStat {
            files: 2,
            added: 94,
            removed: 2,
            has_shell_changes: true,
            added_bytes: None,
        };
        assert_eq!(
            judge(&big, &big, Some(diff)),
            ChangeSummary::Changed {
                files: 2,
                added: 94,
                removed: 2,
                has_shell_changes: true,
                large_files_skipped: 1,
            }
        );
        assert_eq!(
            judge(&[], &[], None),
            ChangeSummary::Unavailable {
                reason: "diffFailed".into()
            }
        );
    }

    #[test]
    fn anything_short_of_two_snapshots_is_unavailable_or_pending() {
        let judge = |phase, begin: &SnapshotStatus, end: &SnapshotStatus| {
            ChangeSummary::judge(phase, begin, end, &[], &[], None)
        };
        let reason = |summary: ChangeSummary| match summary {
            ChangeSummary::Unavailable { reason } => reason,
            other => format!("{other:?}"),
        };
        assert_eq!(
            judge(TurnPhase::Started, &captured("a"), &SnapshotStatus::Pending),
            ChangeSummary::Pending
        );
        assert_eq!(
            reason(judge(
                TurnPhase::Unknown,
                &captured("a"),
                &SnapshotStatus::Pending
            )),
            "endMissing"
        );
        assert_eq!(
            reason(judge(
                TurnPhase::Finished,
                &SnapshotStatus::NotGit,
                &SnapshotStatus::NotGit
            )),
            "notGit"
        );
        assert_eq!(
            reason(judge(
                TurnPhase::Finished,
                &captured("a"),
                &SnapshotStatus::Disabled
            )),
            "disabled"
        );
        assert_eq!(
            reason(judge(
                TurnPhase::Finished,
                &SnapshotStatus::Failed { reason: "x".into() },
                &captured("b")
            )),
            "snapshotFailed"
        );
        assert_eq!(
            reason(judge(
                TurnPhase::Finished,
                &captured("a"),
                &SnapshotStatus::Unknown
            )),
            "unknown"
        );
        assert_eq!(
            reason(judge(
                TurnPhase::Finished,
                &SnapshotStatus::Pending,
                &captured("b")
            )),
            "beginMissing"
        );
        // An end-only record says why no end was taken; the missing begin is
        // still what the person is told.
        assert_eq!(
            reason(judge(
                TurnPhase::Interrupted,
                &SnapshotStatus::Pending,
                &SnapshotStatus::Skipped {
                    reason: "beginMissing".into()
                }
            )),
            "beginMissing"
        );
        assert_eq!(
            reason(judge(
                TurnPhase::Finished,
                &captured("a"),
                &SnapshotStatus::Skipped {
                    reason: "lockBusy".into()
                }
            )),
            "snapshotSkipped",
            "a snapshot's own reason text stays on the snapshot"
        );
        let elsewhere = SnapshotStatus::Captured {
            tree: "b".into(),
            root: "/other".into(),
        };
        assert_eq!(
            reason(ChangeSummary::judge(
                TurnPhase::Finished,
                &captured("a"),
                &elsewhere,
                &[],
                &[],
                None
            )),
            "rootChanged"
        );
    }

    #[test]
    fn unsupported_schema_is_read_only() {
        let mut value = serde_json::to_value(record()).expect("serialize");
        value["schemaVersion"] = serde_json::json!(2);
        let readable = TurnRecord::decode(value.to_string().as_bytes()).expect("same shape reads");
        assert!(!readable.is_writable());
        assert!(
            TurnRecord::decode(&serde_json::to_vec(&record()).expect("ok"))
                .expect("v1")
                .is_writable()
        );

        value["turnId"] = serde_json::json!({"reshaped": true});
        assert!(matches!(
            TurnRecord::decode(value.to_string().as_bytes()),
            Err(TurnRecordError::UnsupportedSchema(2))
        ));
        let mut broken = serde_json::to_value(record()).expect("serialize");
        broken["turnId"] = serde_json::json!(5);
        assert!(matches!(
            TurnRecord::decode(broken.to_string().as_bytes()),
            Err(TurnRecordError::Json(_))
        ));
    }

    /// An event applies once per invocation: the same invocation sent again
    /// is a duplicate, a new invocation of the same payload applies again,
    /// and an event with no id is rejected. Each case is the invocations in
    /// order, what each one comes to, and how many the record keeps.
    #[test]
    fn an_event_applies_once_per_invocation() {
        /// An invocation id, or none, and what applying it comes to.
        type Call = (Option<u128>, EventApplication);
        use EventApplication::{Applied, Duplicate, Rejected};
        let cases: [(&str, &[Call], usize); 3] = [
            ("resent", &[(Some(1), Applied), (Some(1), Duplicate)], 1),
            (
                "a new invocation",
                &[(Some(1), Applied), (Some(2), Applied)],
                2,
            ),
            ("no id", &[(None, Rejected)], 0),
        ];
        for (case, calls, kept) in cases {
            let mut record = record();
            for &(invocation, expected) in calls {
                let event =
                    invocation.map(|id| EventId::invocation(&claude(), Uuid::from_u128(id)));
                assert_eq!(record.apply_event(event.as_ref()), expected, "{case}");
            }
            assert_eq!(record.applied_events.len(), kept, "{case}");
        }
    }

    #[test]
    fn counter_file_names_are_stable_and_distinguish_the_fallback() {
        let key = record().conversation;
        assert_eq!(key.counter_file_name(), key.clone().counter_file_name());
        assert!(key.counter_file_name().ends_with(TURN_COUNTER_FILE_SUFFIX));
        let fallback = ConversationKey {
            is_fallback: true,
            ..key.clone()
        };
        assert_ne!(key.counter_file_name(), fallback.counter_file_name());
        // Pinned so a change to the hash, which would orphan every counter
        // on disk, fails here first.
        assert_eq!(key.counter_file_name(), "8004a1f4134b7b55.counter");
    }

    #[test]
    fn a_summary_takes_the_kind_the_record_kept() {
        let mut record = record();
        record.prompt_kind = Some(RecordedPromptKind::Known(PromptKind::Injected));
        record.prompt_head = Some("<system-reminder> a reminder cut short".into());
        let summary = TurnSummary::of(&record);
        assert_eq!(summary.prompt_kind, PromptKind::Injected);
        // A head the writer already took the person's words for is kept as
        // it is, even if it opens like a tag.
        record.prompt_kind = Some(RecordedPromptKind::Known(PromptKind::Text));
        record.prompt_head = Some("<system-reminder> is the tag we add".into());
        assert_eq!(
            TurnSummary::of(&record).prompt_head.as_deref(),
            Some("<system-reminder> is the tag we add")
        );
    }

    #[test]
    fn a_kind_this_version_does_not_know_is_kept_and_written_back() {
        for unknown in [
            Value::from("fromTheFuture"),
            serde_json::json!({"kind": "x"}),
        ] {
            let mut value = serde_json::to_value(record()).expect("record");
            value["promptKind"] = unknown.clone();
            let read =
                TurnRecord::decode(&serde_json::to_vec(&value).expect("bytes")).expect("decode");
            assert_eq!(
                read.prompt_kind,
                Some(RecordedPromptKind::Unrecognized(unknown.clone()))
            );
            assert!(
                read.is_writable(),
                "the kind alone does not make it read only"
            );
            let written: Value =
                serde_json::from_slice(&read.encode().expect("encode")).expect("json");
            assert_eq!(written, value, "written back as it came");
            assert_eq!(TurnSummary::of(&read).prompt_kind, PromptKind::Text);
        }
    }

    #[test]
    fn a_summary_of_an_older_record_judges_the_kind_from_its_head() {
        let mut record = record();
        record.prompt_kind = None;
        assert_eq!(TurnSummary::of(&record).prompt_kind, PromptKind::Text);
        let notification = "<task-notification> <task-id>bmtysm2i6</task-id>";
        record.prompt_head = Some(notification.into());
        let summary = TurnSummary::of(&record);
        assert_eq!(summary.prompt_kind, PromptKind::BackgroundTask);
        // The record keeps the head as it came; so does the summary, for a
        // kind whose own wording replaces it.
        assert_eq!(summary.prompt_head.as_deref(), Some(notification));
        assert_eq!(record.prompt_head.as_deref(), Some(notification));
        assert!(summary.has_prompt);
    }

    #[test]
    fn a_summary_of_an_older_record_shows_the_persons_words_after_a_reminder() {
        let mut record = record();
        record.prompt_kind = None;
        record.prompt_head = Some("<system-reminder>x</system-reminder> add tests".into());
        let summary = TurnSummary::of(&record);
        assert_eq!(summary.prompt_kind, PromptKind::Text);
        assert_eq!(summary.prompt_head.as_deref(), Some("add tests"));
    }

    #[test]
    fn a_summary_without_a_prompt_kind_reads_as_text() {
        let mut value = serde_json::to_value(TurnSummary::of(&record())).expect("summary");
        let object = value.as_object_mut().expect("object");
        assert_eq!(object.remove("promptKind"), Some(Value::from("text")));
        let read: TurnSummary = serde_json::from_value(value.clone()).expect("without kind");
        assert_eq!(read.prompt_kind, PromptKind::Text);
        value["promptKind"] = Value::from("fromTheFuture");
        let read: TurnSummary = serde_json::from_value(value).expect("unknown kind");
        assert_eq!(read.prompt_kind, PromptKind::Text);
    }
}
