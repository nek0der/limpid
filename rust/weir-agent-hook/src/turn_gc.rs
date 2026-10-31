//! Deleting turns: a turn's record and the refs that pin its two snapshots
//! go together. The record alone would leave refs no sweep ever finds
//! again, keeping their trees from `git gc` for good; the refs alone would
//! leave a record that reads as incomplete.
//!
//! The record is read where it is first, and only one this build may delete
//! is touched. It is then renamed aside, atomically, so no reader sees a
//! turn whose refs are going; the refs are deleted in every repository the
//! record names; and only then is the renamed record removed. A deletion cut
//! short leaves the renamed record, which the next call finishes; a ref git
//! refused puts the record back, so the next sweep asks again. A turn whose
//! two snapshots were taken in different repositories (the agent changed
//! directory mid-turn) may have lost the first repository's refs by then;
//! the record still names them, and the next sweep finishes the job.

use crate::git::SnapshotRunner;
use crate::turn::is_turn_id;
use crate::worktree_lock::{self, Shared, WorktreeLockPaths};
use serde::Serialize;
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::Duration;
use weir_agent_model::{
    SnapshotStatus, TURN_RECORD_FILE_SUFFIX, TurnRecord, turn_record_file_name,
};

/// How long a deletion waits for a restore of the worktree whose refs it
/// deletes before leaving the turn to the next sweep.
pub const RESTORE_WAIT: Duration = Duration::from_secs(2);
const RESTORE_POLL: Duration = Duration::from_millis(25);

/// What became of one turn asked to be deleted.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(
    tag = "outcome",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum TurnDeletion {
    /// The record and its refs are gone.
    Deleted { turn_id: String },
    /// The record is gone, but a repository it names could not be reached
    /// (the worktree was removed, or is no repository now), so its refs may
    /// still be there. Nothing this record says leads to them any more.
    DeletedLeavingRefs { turn_id: String, roots: Vec<String> },
    /// There was no record to delete: an earlier call took it.
    AlreadyGone { turn_id: String },
    /// The record is not one this build may delete (a newer schema, a value
    /// read only as unknown, another turn's id inside): left as it is, since
    /// its refs may be named where this build cannot read.
    Unreadable { turn_id: String },
    /// Something refused: the id is not a turn id, a restore holds the
    /// worktree (`restoreInProgress`), the turn was written again meanwhile,
    /// the record could not be moved or removed, or git would not delete the
    /// refs. The record stays.
    Failed { turn_id: String, reason: String },
}

impl TurnDeletion {
    fn turn_id(&self) -> &str {
        match self {
            Self::Deleted { turn_id }
            | Self::DeletedLeavingRefs { turn_id, .. }
            | Self::AlreadyGone { turn_id }
            | Self::Unreadable { turn_id }
            | Self::Failed { turn_id, .. } => turn_id,
        }
    }
}

/// Deletes each of `turn_ids` from the turns directory `directory`, after
/// finishing any deletion an earlier call left cut short. A turn finished
/// that way is reported as what became of it then, whether it was asked
/// for or not: the host forgets what it kept about a turn it is told is
/// gone, and with no ids at all the call only finishes those.
pub fn delete_turns(
    directory: &Path,
    turn_ids: &[String],
    snapshots: &dyn SnapshotRunner,
) -> Vec<TurnDeletion> {
    delete_turns_waiting(directory, turn_ids, snapshots, RESTORE_WAIT)
}

/// `delete_turns`, waiting up to `restore_wait` for a restore of a
/// worktree whose refs it deletes.
pub fn delete_turns_waiting(
    directory: &Path,
    turn_ids: &[String],
    snapshots: &dyn SnapshotRunner,
    restore_wait: Duration,
) -> Vec<TurnDeletion> {
    let locks = Locks {
        snapshots,
        wait: restore_wait,
        under_restore: RefCell::new(BTreeSet::new()),
        git_dirs: RefCell::new(BTreeMap::new()),
    };
    let mut finished: BTreeMap<String, TurnDeletion> = finish_interrupted(directory, &locks)
        .into_iter()
        .map(|deletion| (deletion.turn_id().to_owned(), deletion))
        .collect();
    let mut deletions: Vec<TurnDeletion> = turn_ids
        .iter()
        .map(|turn_id| {
            finished
                .remove(turn_id)
                .unwrap_or_else(|| delete_turn(directory, turn_id, &locks))
        })
        .collect();
    deletions.extend(finished.into_values());
    deletions
}

/// The worktree locks one call takes, so a restore reading a turn's trees
/// does not lose their refs midway. A restore is not asked to stop for a
/// deletion: the next sweep deletes the turn instead. A worktree found
/// under restore is not waited for again in the same call, so a batch of
/// its turns costs one wait.
struct Locks<'a> {
    snapshots: &'a dyn SnapshotRunner,
    wait: Duration,
    under_restore: RefCell<BTreeSet<PathBuf>>,
    /// Each root's git directory, asked of git once per call.
    git_dirs: RefCell<BTreeMap<PathBuf, Option<PathBuf>>>,
}

impl Locks<'_> {
    /// The lock of every root's worktree, held shared, or `None` when a
    /// restore holds one of them. A root that is no repository now has no
    /// lock to take.
    fn take(&self, roots: &BTreeSet<PathBuf>) -> Option<Vec<Shared>> {
        let mut held = Vec::new();
        for root in roots {
            let git_dir = self
                .git_dirs
                .borrow_mut()
                .entry(root.clone())
                .or_insert_with(|| self.snapshots.worktree(root).map(|(git_dir, _)| git_dir))
                .clone();
            let Some(git_dir) = git_dir else {
                continue;
            };
            if self.under_restore.borrow().contains(&git_dir) {
                return None;
            }
            match worktree_lock::acquire_shared_quietly(
                &WorktreeLockPaths::new(&git_dir),
                self.wait,
                RESTORE_POLL,
            ) {
                Shared::NotReleased => {
                    self.under_restore.borrow_mut().insert(git_dir);
                    return None;
                }
                shared => held.push(shared),
            }
        }
        Some(held)
    }
}

/// Where a record waits while its refs are deleted. Hidden, and with a
/// suffix no reader lists as a turn.
fn aside(directory: &Path, turn_id: &str) -> PathBuf {
    directory.join(format!(".{}.deleting", turn_record_file_name(turn_id)))
}

/// The record at `path`, when it is `turn_id`'s and this build may delete
/// it.
fn deletable(path: &Path, turn_id: &str) -> Option<TurnRecord> {
    fs::read(path)
        .ok()
        .and_then(|bytes| TurnRecord::decode(&bytes).ok())
        .filter(|turn| turn.turn_id == turn_id && turn.is_writable())
}

fn delete_turn(directory: &Path, turn_id: &str, locks: &Locks<'_>) -> TurnDeletion {
    let snapshots = locks.snapshots;
    let owned = turn_id.to_owned();
    if !is_turn_id(turn_id) {
        return TurnDeletion::Failed {
            turn_id: owned,
            reason: "not a turn id".to_owned(),
        };
    }
    let record = directory.join(turn_record_file_name(turn_id));
    let aside = aside(directory, turn_id);
    if aside.exists() && record.exists() {
        // The turn was written again after a deletion was cut short: the
        // newer record names the same refs, and what to do with it is the
        // next sweep's to decide.
        let _ = fs::remove_file(&aside);
        return TurnDeletion::Failed {
            turn_id: owned,
            reason: "written again".to_owned(),
        };
    }
    let is_aside = aside.exists();
    if !is_aside {
        // Read where it is: a record not ours to delete is not even moved,
        // which would wake every watcher of the directory for nothing.
        match fs::metadata(&record) {
            Err(error) if error.kind() == ErrorKind::NotFound => {
                return TurnDeletion::AlreadyGone { turn_id: owned };
            }
            _ => {}
        }
    }
    let Some(first) = deletable(if is_aside { &aside } else { &record }, turn_id) else {
        if is_aside {
            put_back(&aside, &record);
        }
        return TurnDeletion::Unreadable { turn_id: owned };
    };
    // The locks come before the record moves: a restore reading the turn
    // under its own lock finds it where it was.
    let roots = roots(&first);
    let Some(_locks) = locks.take(&roots) else {
        return TurnDeletion::Failed {
            turn_id: owned,
            reason: "restoreInProgress".to_owned(),
        };
    };
    if !is_aside && let Err(deletion) = move_aside(&record, &aside, &owned) {
        return deletion;
    }
    // Read again as it is now: a writer may have replaced it between. One
    // that names other repositories is the next sweep's, under their locks.
    let Some(turn) = deletable(&aside, turn_id) else {
        put_back(&aside, &record);
        return TurnDeletion::Unreadable { turn_id: owned };
    };
    if self::roots(&turn) != roots {
        put_back(&aside, &record);
        return TurnDeletion::Failed {
            turn_id: owned,
            reason: "written again".to_owned(),
        };
    }
    let mut unreachable = Vec::new();
    for root in roots {
        let common_dir = turn
            .git_context
            .as_ref()
            .and_then(|context| context.common_dir.as_deref())
            .map(Path::new);
        match snapshots.unpin(&root, common_dir, turn_id) {
            Ok(true) => {}
            Ok(false) => unreachable.push(root.to_string_lossy().into_owned()),
            Err(reason) => {
                put_back(&aside, &record);
                return TurnDeletion::Failed {
                    turn_id: owned,
                    reason,
                };
            }
        }
    }
    match fs::remove_file(&aside) {
        Ok(()) => {}
        // Another call finished it first.
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => {
            return TurnDeletion::Failed {
                turn_id: owned,
                reason: format!("remove: {error}"),
            };
        }
    }
    if unreachable.is_empty() {
        TurnDeletion::Deleted { turn_id: owned }
    } else {
        TurnDeletion::DeletedLeavingRefs {
            turn_id: owned,
            roots: unreachable,
        }
    }
}

/// Moves the record aside, atomically, so no reader sees a turn whose refs
/// are going.
fn move_aside(record: &Path, aside: &Path, turn_id: &str) -> Result<(), TurnDeletion> {
    match fs::rename(record, aside) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == ErrorKind::NotFound => Err(TurnDeletion::AlreadyGone {
            turn_id: turn_id.to_owned(),
        }),
        Err(error) => Err(TurnDeletion::Failed {
            turn_id: turn_id.to_owned(),
            reason: format!("move aside: {error}"),
        }),
    }
}

/// Puts a record back where readers find it, unless a newer one was
/// written there meanwhile: linked rather than renamed, so it fails instead
/// of replacing the newer one, which is the turn's now, and the copy aside
/// is dropped. On any other failure the copy stays aside, for the next call.
fn put_back(aside: &Path, record: &Path) {
    match fs::hard_link(aside, record) {
        Ok(()) => {
            let _ = fs::remove_file(aside);
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            let _ = fs::remove_file(aside);
        }
        Err(_) => {}
    }
}

/// The repositories the record's snapshots were taken in, each once.
fn roots(turn: &TurnRecord) -> BTreeSet<PathBuf> {
    [&turn.begin, &turn.end]
        .into_iter()
        .filter_map(|status| match status {
            SnapshotStatus::Captured { root, .. } => Some(PathBuf::from(root)),
            _ => None,
        })
        .collect()
}

/// Finishes the deletions an earlier call left with the record aside, and
/// reports what became of each.
fn finish_interrupted(directory: &Path, locks: &Locks<'_>) -> Vec<TurnDeletion> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    let suffix = format!("{TURN_RECORD_FILE_SUFFIX}.deleting");
    entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            name.strip_prefix('.')
                .and_then(|rest| rest.strip_suffix(&suffix))
                .map(str::to_owned)
        })
        .map(|turn_id| delete_turn(directory, &turn_id, locks))
        .collect()
}
