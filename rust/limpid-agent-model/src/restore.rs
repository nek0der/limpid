//! The restore journal: what restoring a worktree to the start
//! of a turn planned, wrote, and found, one file per operation under the
//! worktree's git directory (`limpid/restores/<op_id>.json`).
//!
//! Every tree a restore depends on is computed before the first file is
//! written, and the journal names them first: the working tree as it was
//! (`before_tree`), the tree to go back to (`target_tree`), and the tree the
//! working tree should be once the restore is done (`expected_after_tree`).
//! So a restore cut short by a crash is finished by comparing the working
//! tree with the two ends, and an undo is refused once the tree has moved on
//! from what the restore left.
//!
//! Most of those trees are reachable from nothing else, so `git gc` would
//! take them. Each tree a journal names is pinned by a ref of its own
//! (`RestoreJournal::pinned_trees`) before the journal that names it is
//! written, and the refs go only once nothing reads the journal's trees
//! again.
//!
//! The hook runtime writes journals and the app only reads them.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Where journals live, under the worktree's `<git_dir>/limpid/`.
pub const RESTORE_DIRECTORY: &str = "restores";

/// What a journal's file name ends with; the rest is its operation id.
pub const RESTORE_JOURNAL_FILE_SUFFIX: &str = ".json";

/// The ref that pins a restore's `before_tree`, so an undo outlives `git gc`.
#[must_use]
pub fn restore_undo_ref(op_id: &str) -> String {
    format!("refs/limpid/undo/{op_id}")
}

/// The ref that pins a restore's `target_tree` while it may be undone: every
/// later look at the planned paths compares with it, and the turn's own refs
/// may go with the turn first.
#[must_use]
pub fn restore_target_ref(op_id: &str) -> String {
    format!("refs/limpid/undo-target/{op_id}")
}

/// The ref that pins a restore's `expected_after_tree`: recovery compares a
/// journal a crash cut short with it, and nothing else holds it when the
/// working tree had changes outside the planned paths.
#[must_use]
pub fn restore_expected_ref(op_id: &str) -> String {
    format!("refs/limpid/undo-expected/{op_id}")
}

/// The ref that pins the `current_tree` of a partly applied restore: its
/// undo reads there what each path held when the restore settled, and the
/// edits of another writer it kept are in no other tree.
#[must_use]
pub fn restore_current_ref(op_id: &str) -> String {
    format!("refs/limpid/undo-current/{op_id}")
}

/// Every ref an operation may hold, for dropping them all.
#[must_use]
pub fn restore_refs(op_id: &str) -> [String; 4] {
    [
        restore_undo_ref(op_id),
        restore_target_ref(op_id),
        restore_expected_ref(op_id),
        restore_current_ref(op_id),
    ]
}

/// What an operation took back: a turn's changes, or hunks the review
/// showed. Both write the same way and are undone the same way; the app
/// shows each in its own place (the restore record, the review's hunk).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RestoreOperation {
    #[default]
    Restore,
    /// Hunks discarded in the review.
    Discard,
}

impl RestoreOperation {
    #[must_use]
    pub fn is_restore(&self) -> bool {
        *self == Self::Restore
    }
}

/// One restore or discard, or one undo of either.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreJournal {
    pub schema_version: u32,
    pub op_id: String,
    /// Absent in a journal from before discards, which was a restore. An
    /// older build keeps it among the fields it does not model.
    #[serde(default, skip_serializing_if = "RestoreOperation::is_restore")]
    pub operation: RestoreOperation,
    /// The worktree written, as `git rev-parse --show-toplevel` gave it.
    pub root: String,
    /// The turn whose start the worktree goes back to. For an undo, the turn
    /// of the restore it undoes.
    pub turn_id: String,
    /// The turn's number in its conversation ("T7"), for the record: the
    /// record names the turn after the turn's own record may be gone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_number: Option<u32>,
    pub pane_id: String,
    /// The restore this one undoes, for an undo.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub undoes: Option<String>,
    /// HEAD and branch when the restore began. An undo is refused when they
    /// changed since: the commits it would go back over are not its own.
    pub context_before: RestoreContext,
    pub before_tree: String,
    pub target_tree: String,
    pub expected_after_tree: String,
    /// The paths the restore writes, in the order it writes them.
    pub planned_paths: Vec<PathChange>,
    /// Untracked files the restore may delete: only those a turn's snapshot
    /// recorded. Other untracked files are left where they are.
    #[serde(default)]
    pub recorded_untracked: Vec<String>,
    pub stage: RestoreStage,
    /// The time of the call that last wrote the journal, as
    /// `format_utc_seconds` gives it: the operation's own call, or a later
    /// one that settled it after a crash or marked it undone. What its
    /// lifetime counts from.
    pub at: String,
    /// The time of the call that ran the operation, as `format_utc_seconds`
    /// gives it. It is taken when the call begins, before it asks for the
    /// worktree lock, so a prompt stamped once its hook holds the lock
    /// never starts before an operation it did not run under. Written with
    /// the plan and never again: a recovery that settles the operation
    /// later rewrites `at`, and a turn that began between the crash and
    /// that recovery began after the operation all the same. Absent in a
    /// journal from earlier builds, whose `at` stands in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ran_at: Option<String>,
    /// Fields this version does not model, preserved verbatim.
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl RestoreJournal {
    pub const SCHEMA_VERSION: u32 = 1;

    /// Decodes a journal.
    ///
    /// # Errors
    ///
    /// Returns the JSON error when the bytes are not a journal this version
    /// can read.
    pub fn decode(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        serde_json::from_slice(bytes)
    }

    /// The journal as written to its file.
    ///
    /// # Errors
    ///
    /// Returns `serde_json::Error` only if serialization itself fails.
    pub fn encode(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec_pretty(self)
    }

    /// Every tree the journal names, each with the ref that pins it.
    #[must_use]
    pub fn pinned_trees(&self) -> Vec<(String, &str)> {
        let mut trees = vec![
            (restore_undo_ref(&self.op_id), self.before_tree.as_str()),
            (restore_target_ref(&self.op_id), self.target_tree.as_str()),
            (
                restore_expected_ref(&self.op_id),
                self.expected_after_tree.as_str(),
            ),
        ];
        if let RestoreStage::PartiallyApplied { current_tree, .. } = &self.stage {
            trees.push((restore_current_ref(&self.op_id), current_tree.as_str()));
        }
        trees
    }

    /// Whether this version may rewrite the journal (finish it, or mark it
    /// undone). A newer writer's journal is read only.
    #[must_use]
    pub fn is_writable(&self) -> bool {
        self.schema_version == Self::SCHEMA_VERSION && !self.stage.is_unknown()
    }
}

/// The head of the repository as a restore found it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreContext {
    /// `None` in a repository with no commit yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
}

/// What a restore does to one path. A rename is a delete and an add.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PathChange {
    pub path: String,
    pub kind: PathChangeKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PathChangeKind {
    /// Written from the target: absent from the working tree before.
    Add,
    /// Written from the target over what was there.
    Modify,
    /// Removed: absent from the target.
    Delete,
}

/// A path the operation could not write, and why.
///
/// `reason` is what the app, an undo, and the journal's retention act on;
/// `detail` is only for a person reading the journal, and nothing parses
/// it. A save kept aside says where it is in a field of its own (`keptAt`).
/// Earlier development builds wrote that place into a journal's reason
/// (`keptAside:<place>`); it is still read so, and written the new way when
/// the journal is next written.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "FailedPathFields", into = "FailedPathFields")]
pub struct FailedPath {
    pub path: String,
    pub reason: FailedReason,
    pub detail: Option<String>,
}

impl FailedPath {
    /// Where another writer's save at the path was kept aside, relative to
    /// the worktree, when it was.
    #[must_use]
    pub fn kept_at(&self) -> Option<&str> {
        match &self.reason {
            FailedReason::KeptAside { at } => Some(at),
            _ => None,
        }
    }
}

/// Why a path was not written, by a stable code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FailedReason {
    /// Another writer saved to the path while it was written, and the
    /// operation moved that save aside to `at`, relative to the worktree,
    /// rather than lose it.
    KeptAside { at: String },
    /// A file another writer made stands where the rollback puts a
    /// directory back.
    InTheWay,
    /// Writing the path failed; `detail` says how.
    WriteFailed,
    /// A code this build does not know, kept as it was written.
    Other(String),
}

/// A `FailedPath` as its journal writes it.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FailedPathFields {
    path: String,
    reason: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    kept_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
}

/// How earlier development builds named a save kept aside: this, then the
/// place.
const LEGACY_KEPT_ASIDE_PREFIX: &str = "keptAside:";

impl From<FailedPathFields> for FailedPath {
    fn from(fields: FailedPathFields) -> Self {
        let reason = match (fields.reason.as_str(), fields.kept_at) {
            ("keptAside", Some(at)) => FailedReason::KeptAside { at },
            ("inTheWay", _) => FailedReason::InTheWay,
            ("writeFailed", _) => FailedReason::WriteFailed,
            (legacy, None) if legacy.starts_with(LEGACY_KEPT_ASIDE_PREFIX) => {
                FailedReason::KeptAside {
                    at: legacy[LEGACY_KEPT_ASIDE_PREFIX.len()..].to_owned(),
                }
            }
            _ => FailedReason::Other(fields.reason),
        };
        Self {
            path: fields.path,
            reason,
            detail: fields.detail,
        }
    }
}

impl From<FailedPath> for FailedPathFields {
    fn from(failed: FailedPath) -> Self {
        let (reason, kept_at) = match failed.reason {
            FailedReason::KeptAside { at } => ("keptAside".to_owned(), Some(at)),
            FailedReason::InTheWay => ("inTheWay".to_owned(), None),
            FailedReason::WriteFailed => ("writeFailed".to_owned(), None),
            FailedReason::Other(code) => (code, None),
        };
        Self {
            path: failed.path,
            reason,
            kept_at,
            detail: failed.detail,
        }
    }
}

/// Why an operation ended short of applied, or applied with saves kept
/// aside: what the app says of it and what an undo and the journal's
/// retention act on. Written as a stable code; a code this build does not
/// know is kept as it was written.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "String", into = "String")]
pub enum StageReason {
    /// A hook asked the operation to stop: an agent's prompt goes first.
    AgentStarted,
    /// A path could not be written.
    WriteFailed,
    /// Another writer changed a planned path while the operation ran.
    ExternalChangeDetected,
    /// A crash cut the operation short, and recovery settled it by what its
    /// planned paths held.
    Interrupted,
    /// Every planned path holds what the operation writes, and saves
    /// another writer made meanwhile were kept aside.
    KeptAside,
    /// A code this build does not know.
    Other(String),
}

impl StageReason {
    /// The code the journal writes.
    #[must_use]
    pub fn code(&self) -> &str {
        match self {
            Self::AgentStarted => "agentStarted",
            Self::WriteFailed => "writeFailed",
            Self::ExternalChangeDetected => "externalChangeDetected",
            Self::Interrupted => "interrupted",
            Self::KeptAside => "keptAside",
            Self::Other(code) => code,
        }
    }
}

impl From<String> for StageReason {
    fn from(code: String) -> Self {
        match code.as_str() {
            "agentStarted" => Self::AgentStarted,
            "writeFailed" => Self::WriteFailed,
            "externalChangeDetected" => Self::ExternalChangeDetected,
            "interrupted" => Self::Interrupted,
            "keptAside" => Self::KeptAside,
            _ => Self::Other(code),
        }
    }
}

impl From<StageReason> for String {
    fn from(reason: StageReason) -> Self {
        match reason {
            StageReason::Other(code) => code,
            known => known.code().to_owned(),
        }
    }
}

/// Where a restore stands.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum RestoreStage {
    /// The trees are computed and nothing is written yet.
    Planned,
    /// Writing; `done` are the paths written so far.
    Writing { done: Vec<String> },
    /// Everything planned is written, and the working tree is being compared
    /// with `expected_after_tree`.
    Verifying,
    /// The working tree is `expected_after_tree`.
    Applied,
    /// A later undo put the working tree back to `before_tree`.
    Undone { by: String },
    /// Nothing the restore wrote is left: the working tree is `before_tree`.
    Aborted { reason: StageReason },
    /// Some of the restore is in the working tree and some is not, as
    /// `current_tree` records. `kept` are the planned paths left as another
    /// writer made them; `failed` the paths that could not be written.
    PartiallyApplied {
        reason: StageReason,
        current_tree: String,
        #[serde(default)]
        kept: Vec<String>,
        #[serde(default)]
        failed: Vec<FailedPath>,
    },
    /// A stage this version does not know.
    #[default]
    #[serde(other)]
    Unknown,
}

impl RestoreStage {
    /// Whether the restore stopped before it finished, with no stage
    /// written after: a crash, which recovery settles.
    #[must_use]
    pub fn is_interrupted(&self) -> bool {
        matches!(self, Self::Planned | Self::Writing { .. } | Self::Verifying)
    }

    #[must_use]
    pub fn is_unknown(&self) -> bool {
        matches!(self, Self::Unknown)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// A journal fixture the app's tests read too (`rust/fixtures/restore`),
    /// so both sides hold the same words.
    fn fixture(name: &str) -> Value {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../fixtures/restore")
            .join(name);
        let bytes =
            std::fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
        serde_json::from_slice(&bytes).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
    }

    fn journal(stage: RestoreStage) -> RestoreJournal {
        RestoreJournal {
            schema_version: RestoreJournal::SCHEMA_VERSION,
            operation: RestoreOperation::Restore,
            op_id: "OP".into(),
            root: "/repo".into(),
            turn_id: "T".into(),
            turn_number: Some(7),
            pane_id: "P".into(),
            undoes: None,
            context_before: RestoreContext {
                head: Some("abc".into()),
                branch: Some("main".into()),
            },
            before_tree: "b".into(),
            target_tree: "t".into(),
            expected_after_tree: "e".into(),
            planned_paths: vec![PathChange {
                path: "a.txt".into(),
                kind: PathChangeKind::Modify,
            }],
            recorded_untracked: vec![],
            stage,
            at: "2026-10-13T00:00:00Z".into(),
            ran_at: Some("2026-10-12T23:59:00Z".into()),
            extra: BTreeMap::new(),
        }
    }

    #[test]
    fn a_journal_round_trips_in_every_stage() {
        for stage in [
            RestoreStage::Planned,
            RestoreStage::Writing {
                done: vec!["a.txt".into()],
            },
            RestoreStage::Verifying,
            RestoreStage::Applied,
            RestoreStage::Undone { by: "OP2".into() },
            RestoreStage::Aborted {
                reason: StageReason::ExternalChangeDetected,
            },
            RestoreStage::PartiallyApplied {
                reason: StageReason::AgentStarted,
                current_tree: "c".into(),
                kept: vec!["a.txt".into()],
                failed: vec![
                    FailedPath {
                        path: "b".into(),
                        reason: FailedReason::WriteFailed,
                        detail: Some("Permission denied (os error 13)".into()),
                    },
                    FailedPath {
                        path: "c".into(),
                        reason: FailedReason::KeptAside {
                            at: ".limpid-OP/target/ready-1/c".into(),
                        },
                        detail: None,
                    },
                ],
            },
        ] {
            let journal = journal(stage);
            let decoded = RestoreJournal::decode(&journal.encode().unwrap()).unwrap();
            assert_eq!(decoded, journal);
            assert!(decoded.is_writable());
        }
    }

    #[test]
    fn a_newer_writers_stage_is_read_but_not_rewritten() {
        let mut value = serde_json::to_value(journal(RestoreStage::Applied)).unwrap();
        value["stage"] = serde_json::json!({"kind": "squashed", "into": "x"});
        value["laterField"] = serde_json::json!(1);
        let decoded = RestoreJournal::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert_eq!(decoded.stage, RestoreStage::Unknown);
        assert!(!decoded.is_writable());
        assert_eq!(decoded.extra.get("laterField"), Some(&serde_json::json!(1)));
    }

    #[test]
    fn only_the_unfinished_stages_are_interrupted() {
        assert!(RestoreStage::Planned.is_interrupted());
        assert!(RestoreStage::Verifying.is_interrupted());
        assert!(!RestoreStage::Applied.is_interrupted());
        assert!(
            !RestoreStage::Aborted {
                reason: StageReason::Interrupted
            }
            .is_interrupted()
        );
    }

    #[test]
    fn every_tree_a_journal_names_is_pinned_by_a_ref_of_its_own() {
        let planned = journal(RestoreStage::Planned);
        assert_eq!(
            planned.pinned_trees(),
            [
                ("refs/limpid/undo/OP".to_owned(), "b"),
                ("refs/limpid/undo-target/OP".to_owned(), "t"),
                ("refs/limpid/undo-expected/OP".to_owned(), "e"),
            ]
        );
        let partial = journal(RestoreStage::PartiallyApplied {
            reason: StageReason::AgentStarted,
            current_tree: "c".into(),
            kept: vec![],
            failed: vec![],
        });
        let pinned = partial.pinned_trees();
        assert_eq!(
            pinned.last(),
            Some(&("refs/limpid/undo-current/OP".to_owned(), "c"))
        );
        // Dropping an operation's refs reaches each of them.
        for (name, _) in &pinned {
            assert!(restore_refs("OP").contains(name), "{name}");
        }
    }

    /// A journal from before discards was a restore, and a restore's
    /// journal reads as before to an older build: it names no operation.
    #[test]
    fn a_journal_without_an_operation_is_a_restore() {
        let restore = journal(RestoreStage::Applied);
        let written: Value = serde_json::from_slice(&restore.encode().unwrap()).unwrap();
        assert_eq!(written, fixture("journal-without-operation.json"));
        let read: RestoreJournal =
            serde_json::from_value(fixture("journal-without-operation.json")).unwrap();
        assert_eq!(read.operation, RestoreOperation::Restore);
        let mut discard = restore;
        discard.operation = RestoreOperation::Discard;
        let written: Value = serde_json::from_slice(&discard.encode().unwrap()).unwrap();
        assert_eq!(written, fixture("journal-discard.json"));
        let read: RestoreJournal = serde_json::from_value(fixture("journal-discard.json")).unwrap();
        assert_eq!(read, discard);
    }

    /// A journal from before `ranAt` reads with none, and is written back
    /// without one: recovery may have rewritten its `at`, so no time the
    /// journal holds is known to be when it ran.
    #[test]
    fn a_journal_from_before_ran_at_keeps_none() {
        let mut value = fixture("journal-without-operation.json");
        value.as_object_mut().unwrap().remove("ranAt");
        let read: RestoreJournal = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(read.ran_at, None);
        let written: Value = serde_json::from_slice(&read.encode().unwrap()).unwrap();
        assert_eq!(written, value);
    }

    /// The codes are the contract: the app and earlier journals read these
    /// exact words.
    #[test]
    fn a_stage_reason_is_written_as_its_code_and_an_unknown_one_is_kept() {
        let partial = RestoreStage::PartiallyApplied {
            reason: StageReason::KeptAside,
            current_tree: "c".into(),
            kept: vec![],
            failed: vec![],
        };
        let value = serde_json::to_value(&partial).unwrap();
        assert_eq!(value["reason"], "keptAside");
        let codes = fixture("stage-reasons.json");
        let reasons = [
            StageReason::AgentStarted,
            StageReason::WriteFailed,
            StageReason::ExternalChangeDetected,
            StageReason::Interrupted,
            StageReason::KeptAside,
        ];
        let written: Vec<Value> = reasons
            .iter()
            .map(|reason| serde_json::to_value(reason).unwrap())
            .collect();
        assert_eq!(Value::Array(written.clone()), codes["written"]);
        for (reason, code) in reasons.into_iter().zip(written) {
            assert_eq!(StageReason::from(code.as_str().unwrap().to_owned()), reason);
        }
        let later_code = codes["later"].as_str().unwrap();
        let later: RestoreStage =
            serde_json::from_value(serde_json::json!({"kind": "aborted", "reason": later_code}))
                .unwrap();
        assert_eq!(
            later,
            RestoreStage::Aborted {
                reason: StageReason::Other(later_code.into())
            }
        );
        assert_eq!(
            serde_json::to_value(&later).unwrap()["reason"],
            later_code,
            "a later build's code survives a rewrite"
        );
    }

    /// A save kept aside names its place in a field of its own; a journal
    /// that put the place into the reason is read the same.
    #[test]
    fn a_kept_aside_place_is_its_own_field_and_the_prefixed_reason_still_reads() {
        let kept = FailedPath {
            path: "a.txt".into(),
            reason: FailedReason::KeptAside {
                at: ".limpid-OP/target/ready-1/a.txt".into(),
            },
            detail: None,
        };
        let paths = fixture("kept-aside.json");
        assert_eq!(serde_json::to_value(&kept).unwrap(), paths["written"]);
        let earlier: FailedPath = serde_json::from_value(paths["earlier"].clone()).unwrap();
        assert_eq!(
            earlier,
            FailedPath {
                path: "c.txt".into(),
                reason: FailedReason::KeptAside {
                    at: ".limpid-OP/target/ready-1/c.txt".into(),
                },
                detail: None,
            }
        );
        assert_eq!(earlier.kept_at(), Some(".limpid-OP/target/ready-1/c.txt"));
        // An earlier build's diagnostic in the reason is no code: kept as
        // written, and no save aside.
        let diagnostic: FailedPath =
            serde_json::from_value(paths["earlierDiagnostic"].clone()).unwrap();
        assert_eq!(
            diagnostic.reason,
            FailedReason::Other("Permission denied (os error 13)".into())
        );
        assert_eq!(diagnostic.kept_at(), None);
        let failed = FailedPath {
            path: "b".into(),
            reason: FailedReason::WriteFailed,
            detail: Some("checkout-index".into()),
        };
        assert_eq!(serde_json::to_value(&failed).unwrap(), paths["writeFailed"]);
    }
}
