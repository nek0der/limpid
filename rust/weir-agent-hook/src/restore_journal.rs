//! The journals of one worktree: where each operation's file
//! is, reading and writing it, marking a restore undone, and dropping the
//! ones past their lifetime. A journal names trees that `git gc` would take,
//! so writing one pins them first (`restore_pins`).

use super::{Refusal, Worktree, git_failed, is_op_id, is_there};
use crate::records::{atomic_write, ensure_user_only_directory};
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use weir_agent_model::{
    FailedPath, RESTORE_DIRECTORY, RESTORE_JOURNAL_FILE_SUFFIX, RestoreJournal, RestoreOperation,
    RestoreStage, StageReason, parse_utc_seconds,
};

/// How long a journal that `may_expire` is kept: an operation nothing can
/// take back, or a discard applied whole. A restore still to be undone is
/// kept however old. Its refs go with it, and each pins a whole tree.
pub(super) const JOURNAL_LIFETIME_SECS: u64 = 30 * 24 * 60 * 60;

impl Worktree {
    pub(super) fn journal_directory(&self) -> PathBuf {
        self.scratch().join(RESTORE_DIRECTORY)
    }

    pub(super) fn journal_path(&self, op_id: &str) -> PathBuf {
        self.journal_directory()
            .join(format!("{op_id}{RESTORE_JOURNAL_FILE_SUFFIX}"))
    }

    /// The journal of `op_id`: `None` when there is none, or the file is
    /// no journal of it this build can decode, which nothing can act on
    /// however often it is read. An error when the file is there but could
    /// not be read, which a later reading may: never `None` in its place,
    /// which reads as an operation that is gone.
    pub(super) fn journal(&self, op_id: &str) -> io::Result<Option<RestoreJournal>> {
        if !is_op_id(op_id) {
            return Ok(None);
        }
        let bytes = match fs::read(self.journal_path(op_id)) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        Ok(RestoreJournal::decode(&bytes)
            .ok()
            .filter(|journal| journal.op_id == op_id))
    }

    /// The journals of the worktree that could be read, and the last read
    /// failure if any: the directory, or a journal in it, is there but
    /// could not be read (`journal`). A worktree that never had one has no
    /// directory, and none. One file that stays unreadable must not keep
    /// every other from being settled or dropped, so the work goes journal
    /// by journal; what lists them for the app says, by the failure, that
    /// the list is not whole (`Recovery::is_incomplete`).
    pub(super) fn readable_journals(&self) -> (Vec<RestoreJournal>, Option<io::Error>) {
        let entries = match fs::read_dir(self.journal_directory()) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return (Vec::new(), None),
            Err(error) => return (Vec::new(), Some(error)),
        };
        let mut journals = Vec::new();
        let mut failure = None;
        for entry in entries {
            let name = match entry {
                Ok(entry) => entry.file_name().to_string_lossy().into_owned(),
                Err(error) => {
                    failure = Some(error);
                    continue;
                }
            };
            let Some(op_id) = name.strip_suffix(RESTORE_JOURNAL_FILE_SUFFIX) else {
                continue;
            };
            match self.journal(op_id) {
                Ok(journal) => journals.extend(journal),
                Err(error) => failure = Some(error),
            }
        }
        (journals, failure)
    }

    /// Writes `journal`, with every tree it names pinned first: a journal
    /// that something may read again never names a tree `git gc` can take.
    /// One nothing can take back is read for its record only, and its refs
    /// go once it is written. Not written when a tree could not be pinned:
    /// the journal on disk stays as it was, which recovery settles.
    pub(super) fn write_journal(&self, journal: &RestoreJournal) -> Result<(), StoreError> {
        if !is_final(journal) {
            self.pin_trees(journal)?;
        }
        self.store(journal)
    }

    /// Writes the journal of an operation under way as it is: its stage
    /// names no tree past the plan's, which `pin_trees` pinned before the
    /// plan was written.
    pub(super) fn write_progress(&self, journal: &RestoreJournal) -> Result<(), StoreError> {
        debug_assert!(journal.stage.is_interrupted());
        self.store(journal)
    }

    pub(super) fn store(&self, journal: &RestoreJournal) -> Result<(), StoreError> {
        ensure_user_only_directory(&self.journal_directory());
        let bytes = journal.encode().map_err(StoreError::Encode)?;
        atomic_write(&self.journal_path(&journal.op_id), &bytes).map_err(StoreError::JournalFile)
    }

    /// Marks the restore an undo took back. Its refs go only once the mark
    /// is written: until then the restore still reads as one to undo.
    pub(super) fn mark_undone(&self, mut restored: RestoreJournal, by: &str, now: &str) {
        // The saves the operation kept aside stay where they are once it is
        // undone: its undo's record names them from now on, written first,
        // so a crash between the two leaves them named by one of them.
        // An undo record this build cannot read or rewrite cannot take
        // them: the restore stays unmarked, for a later build or try.
        let Some(mut undo) = self
            .journal(by)
            .ok()
            .flatten()
            .filter(RestoreJournal::is_writable)
        else {
            return;
        };
        if carry_kept_aside(&restored, &mut undo) && self.write_journal(&undo).is_err() {
            return;
        }
        restored.stage = RestoreStage::Undone { by: by.to_owned() };
        now.clone_into(&mut restored.at);
        if self.write_journal(&restored).is_ok() {
            self.release_refs(&restored.op_id);
        }
    }

    /// Drops the journals, and their refs, past `JOURNAL_LIFETIME_SECS`
    /// that nothing can take back. A restore still to be undone keeps its
    /// record however old. Under the lock, so an undo never loses the
    /// journal it read. The journal goes first, so no journal is left with
    /// its trees let go; refs a crash leaves are swept after.
    pub(super) fn prune(&self, now: &str) {
        // One that could not be read stays for a later call; the refs are
        // swept all the same, as they go by the files that name them.
        for journal in self.readable_journals().0 {
            if journal.is_writable()
                && is_expired(&journal, now)
                && fs::remove_file(self.journal_path(&journal.op_id)).is_ok()
            {
                self.release_refs(&journal.op_id);
            }
        }
        self.settle_refs();
    }
}

/// Why a journal, or the refs that pin the trees it names, was not written.
#[derive(Debug)]
pub(super) enum StoreError {
    /// A tree the journal names is no object id, or its operation id is
    /// not one this build makes: a damaged journal must not make an
    /// `update-ref` line.
    Unpinnable,
    /// This worktree's git directory has no name the file listing the refs
    /// can give it (`Worktree::owner`).
    NoOwner,
    /// The file listing the refs could not be written.
    RefsFile(io::Error),
    /// `git update-ref` did not take the refs.
    UpdateRef,
    /// The journal could not be encoded.
    Encode(serde_json::Error),
    /// The journal's file could not be written.
    JournalFile(io::Error),
}

impl StoreError {
    /// The refusal of an operation that wrote nothing because of this: a
    /// ref git would not take is git's failure, and everything else is
    /// the journal's, whose cause the refusal carries.
    pub(super) fn refusal(&self) -> Refusal {
        match self {
            Self::UpdateRef => git_failed("update-ref"),
            other => Refusal::JournalUnwritable {
                cause: other.to_string(),
            },
        }
    }
}

impl fmt::Display for StoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unpinnable => formatter.write_str("the journal names a tree no ref can pin"),
            Self::NoOwner => {
                formatter.write_str("the worktree has no name the refs file can give it")
            }
            Self::RefsFile(error) => write!(formatter, "refs file: {error}"),
            Self::UpdateRef => formatter.write_str("git update-ref failed"),
            Self::Encode(error) => write!(formatter, "journal encoding: {error}"),
            Self::JournalFile(error) => write!(formatter, "journal file: {error}"),
        }
    }
}

/// Whether nothing can take `journal` back: aborted, undone, or an undo
/// that finished, which is not undone in turn.
pub(super) fn is_final(journal: &RestoreJournal) -> bool {
    match journal.stage {
        RestoreStage::Aborted { .. } | RestoreStage::Undone { .. } => true,
        // An undo is not undone in turn, whole or not: once it settled,
        // nothing reads its trees again. One that stopped partway leaves
        // its restore unmarked, and that restore's refs are what a second
        // undo reads.
        _ => {
            journal.undoes.is_some()
                && !journal.stage.is_interrupted()
                && !journal.stage.is_unknown()
        }
    }
}

/// Whether every planned path holds what the operation writes: applied,
/// or so with another writer's saves kept aside, which its record names.
pub(super) fn is_whole(stage: &RestoreStage) -> bool {
    match stage {
        RestoreStage::Applied => true,
        RestoreStage::PartiallyApplied { reason, .. } => *reason == StageReason::KeptAside,
        _ => false,
    }
}

/// Whether `journal` may go once past its lifetime: final, or a discard
/// applied whole and never undone. A restore still to be undone keeps its
/// record however old; a discard's undo is its hunk's in the review,
/// which no window shows again after it closes, so a whole discard is kept
/// as long as a finished operation and no longer. A restore or a discard
/// that stopped partway is what is left to set right, and its refs are
/// how: it stays. An undo that stopped partway is final, and goes.
pub(super) fn may_expire(journal: &RestoreJournal) -> bool {
    // Its record is where a save it kept aside is named: it stays while
    // the save does.
    if kept_aside_remains(journal) {
        return false;
    }
    is_final(journal)
        || (journal.operation == RestoreOperation::Discard
            && journal.undoes.is_none()
            && is_whole(&journal.stage))
}

/// Adds to `undo`, whole, the saves `restored` kept aside that are still
/// there. Returns whether it added any.
pub(super) fn carry_kept_aside(restored: &RestoreJournal, undo: &mut RestoreJournal) -> bool {
    let RestoreStage::PartiallyApplied { failed, .. } = &restored.stage else {
        return false;
    };
    let named: Vec<&str> = match &undo.stage {
        RestoreStage::PartiallyApplied { failed, .. } => {
            failed.iter().filter_map(FailedPath::kept_at).collect()
        }
        _ => Vec::new(),
    };
    let remaining: Vec<FailedPath> = failed
        .iter()
        .filter(|failed| {
            failed.kept_at().is_some_and(|place| {
                !named.contains(&place) && is_there(&Path::new(&restored.root).join(place))
            })
        })
        .cloned()
        .collect();
    if remaining.is_empty() {
        return false;
    }
    undo.stage = match std::mem::replace(&mut undo.stage, RestoreStage::Applied) {
        RestoreStage::PartiallyApplied {
            reason,
            current_tree,
            kept,
            mut failed,
        } => {
            failed.extend(remaining);
            RestoreStage::PartiallyApplied {
                reason,
                current_tree,
                kept,
                failed,
            }
        }
        _ => RestoreStage::PartiallyApplied {
            reason: StageReason::KeptAside,
            current_tree: undo.expected_after_tree.clone(),
            kept: Vec::new(),
            failed: remaining,
        },
    };
    true
}

/// Whether a save of another writer that the operation kept aside is
/// still where its journal says.
pub(super) fn kept_aside_remains(journal: &RestoreJournal) -> bool {
    let RestoreStage::PartiallyApplied { failed, .. } = &journal.stage else {
        return false;
    };
    failed
        .iter()
        .filter_map(FailedPath::kept_at)
        .any(|place| is_there(&Path::new(&journal.root).join(place)))
}

/// Whether `journal` may go and is past its lifetime.
pub(super) fn is_expired(journal: &RestoreJournal, now: &str) -> bool {
    let age = parse_utc_seconds(now)
        .zip(parse_utc_seconds(&journal.at))
        .map(|(now, at)| now.saturating_sub(at));
    may_expire(journal) && age.is_some_and(|age| age > JOURNAL_LIFETIME_SECS)
}
