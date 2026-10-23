//! Restoring a worktree to the start of a turn, and undoing that. The
//! real index is never touched: every tree is made in a private index, and
//! files are written from one.
//!
//! A restore runs under the worktree lock, held exclusively
//! (`worktree_lock`), and reads again what the app checked before asking:
//! the turn, every agent's run record, HEAD, the branch, and whether a merge,
//! a rebase, or a conflict is under way. It then works out the paths it will
//! write (the planned paths), computes every tree it depends on, and writes
//! the journal (`RestoreJournal`) before the first file, so a crash at any
//! point leaves enough to settle what happened (`recover`).
//!
//! Everything after the plan looks at the planned paths only: what each one
//! holds now against what the restore writes there and what was there
//! before. A change anywhere else (a `.gitignore` that now shows other
//! files, an editor's temporary file) is not the restore's, and nothing it
//! does reads or writes it. So:
//! - a planned path another writer changed is left as that writer left it,
//!   and the restore takes back what it wrote elsewhere;
//! - an undo writes back only the paths that still hold what the restore
//!   wrote, and refuses when one holds something else;
//! - a path the plan would write over something the capture could not see
//!   (an ignored file, an untracked file past the size limit, a file where a
//!   directory goes) is refused before anything is written.
//!
//! This file plans an operation and reads the worktree; the rest is in its
//! own files: the journals (`restore_journal`), the refs that pin their
//! trees (`restore_pins`), carrying out a plan and settling it
//! (`restore_apply`), writing one path without losing another writer's save
//! (`restore_write`), and discarding hunks (`restore_discard`).

use crate::git::{GitScope, GitSnapshots, is_object_id, path_from_bytes};
use crate::process::start_epoch;
use crate::records::{ensure_user_only_directory, read_record};
use crate::worktree_lock::{ExclusiveError, ExclusiveLock, WorktreeLockPaths};
use journal::{is_expired, is_whole};
use limpid_agent_model::{
    PathChangeKind, RUN_RECORD_FILE_SUFFIX, RestoreContext, RestoreJournal, RestoreOperation,
    RestoreStage, SnapshotStatus, TURNS_DIRECTORY, TurnRecord, turn_record_file_name,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use write::Moment;

#[path = "restore_apply.rs"]
mod apply;
#[path = "restore_journal.rs"]
mod journal;
#[path = "restore_pins.rs"]
mod pins;
#[path = "restore_write.rs"]
mod write;
use std::time::Duration;

/// How long a restore waits for hooks that hold the lock (a turn is
/// beginning) before it refuses with `AgentRecording`.
const LOCK_WAIT: Duration = Duration::from_secs(2);
const LOCK_POLL: Duration = Duration::from_millis(25);

/// The most paths handed to one git call on its command line.
const PATHS_PER_CALL: usize = 200;

/// One provider's state directory, where its run records and turns are.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StateDirectory {
    pub provider: String,
    pub directory: PathBuf,
}

/// Restore the worktree at `root` to the start of `turn_id`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RestoreRequest {
    pub root: PathBuf,
    pub turn_id: String,
    pub pane_id: String,
    pub state_directories: Vec<StateDirectory>,
}

/// Undo the restore `op_id` of the worktree at `root`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UndoRequest {
    pub root: PathBuf,
    pub op_id: String,
    pub state_directories: Vec<StateDirectory>,
}

/// What became of a restore or an undo.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(
    tag = "outcome",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum RestoreOutcome {
    /// Nothing was written.
    Refused { refusal: Refusal },
    /// The journal says how it ended: applied, aborted, or partly applied.
    Finished { journal: Box<RestoreJournal> },
}

/// Why a restore or an undo wrote nothing.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Refusal {
    /// `root` is no worktree of a repository.
    NotARepository,
    /// No turn record of that id, or one this build may not act on.
    TurnNotFound,
    /// The turn's start was not captured, so there is nothing to go back to.
    TurnNotCaptured,
    /// The turn started in another worktree.
    OtherWorktree,
    /// An agent of this worktree is running, waiting for an answer, or
    /// compacting.
    AgentActive { provider: String },
    /// A hook held the lock throughout (a turn is beginning).
    AgentRecording,
    /// A hook asked the restore to stop before it wrote anything.
    AgentStarted,
    /// The lock could not be taken at all.
    LockUnavailable { reason: String },
    /// The worktree is a sparse checkout: files outside it are not on disk,
    /// and a restore would write them.
    SparseCheckout,
    /// A merge, a rebase, a cherry-pick, a revert, or a conflict's
    /// resolution is under way.
    MergeInProgress,
    /// HEAD moved since the turn (or the restore) began.
    HeadMoved,
    /// The branch changed since the turn (or the restore) began.
    BranchChanged,
    /// The restore would write over files no snapshot holds: ignored files,
    /// untracked files past the size limit, or a file where a directory
    /// goes. `paths` are those files.
    PathsInTheWay { paths: Vec<String> },
    /// No journal of that id, or one this build may not rewrite.
    RestoreNotFound,
    /// The restore is not one an undo applies to: not applied, or undone.
    NotUndoable,
    /// A path the restore wrote holds something else now; `paths` are those.
    ChangedSinceRestore { paths: Vec<String> },
    /// The journal, or the file that lists the refs pinning its trees,
    /// could not be written, so nothing was. `cause` says what failed, for
    /// the log.
    JournalUnwritable { cause: String },
    /// The journal of the operation to undo could not be read (not "not
    /// there"); `cause` says what failed, for the log.
    JournalUnreadable { cause: String },
    /// Git failed at `step`.
    Git { step: String },
    /// The worktree's volume cannot exchange two names, or rename onto
    /// nothing, in one step (FAT, exFAT, a network volume): writing there
    /// could lose another writer's save.
    UnsupportedVolume,
    /// The operation renames files to names their volume takes for the
    /// same file (only in case, on a volume that does not tell case
    /// apart); `paths` are the new names.
    RenamedInPlace { paths: Vec<String> },
    /// The undo of a discard would write files git now converts on
    /// checkout, so they would not get their bytes back; `paths` are
    /// those.
    Converted { paths: Vec<String> },
}

/// Restores the worktree to the start of the turn: plans it, then carries
/// out the plan.
#[must_use]
pub fn restore_turn(request: &RestoreRequest, now: &str) -> RestoreOutcome {
    let _git = GitScope::begin();
    outcome(restore_turn_inner(request, now, &NO_SEAMS))
}

/// Where the tests step in: once the journal is written, before the first
/// path (a hook asking the restore to stop); within each path's write
/// (`in_write`); once every path is written, before the planned paths are
/// read again (another writer); and in the rollback's writes.
struct Seams<'a> {
    after_journal: &'a dyn Fn(),
    after_write: &'a dyn Fn(),
    in_write: &'a dyn Fn(Moment),
    in_rollback: &'a dyn Fn(Moment),
}

fn nothing() {}

fn nothing_at(_: Moment) {}

const NO_SEAMS: Seams<'static> = Seams {
    after_journal: &nothing,
    after_write: &nothing,
    in_write: &nothing_at,
    in_rollback: &nothing_at,
};

fn restore_turn_inner(
    request: &RestoreRequest,
    now: &str,
    seams: &Seams<'_>,
) -> Result<RestoreJournal, Refusal> {
    let worktree = Worktree::open(&request.root)?;
    let lock = worktree.lock()?;
    let _ = worktree.settle_interrupted(now);
    let turn = find_turn(&request.state_directories, &request.turn_id)?;
    let SnapshotStatus::Captured {
        tree: target_tree,
        root: turn_root,
    } = &turn.begin
    else {
        return Err(Refusal::TurnNotCaptured);
    };
    if !same_path(Path::new(turn_root), &worktree.root) {
        return Err(Refusal::OtherWorktree);
    }
    worktree.check_agents(&request.state_directories)?;
    worktree.check_no_merge()?;
    let context = worktree.context();
    let started = turn.git_context.as_ref();
    if context.head.as_deref() != started.map(|context| context.head.as_str()) {
        return Err(Refusal::HeadMoved);
    }
    if started.is_some_and(|started| started.branch != context.branch) {
        return Err(Refusal::BranchChanged);
    }
    let op_id = new_op_id();
    let before_tree = worktree.capture(&format!("{op_id}-before"))?;
    stop_if_asked(&lock)?;
    let mut changes = worktree
        .changes(&before_tree, target_tree)
        .ok_or_else(|| git_failed("diff-tree"))?;
    // An untracked file the restore would delete goes only when a turn
    // since the restored one made it.
    let deletions: Vec<Change> = changes
        .iter()
        .filter(|change| change.kind == PathChangeKind::Delete)
        .cloned()
        .collect();
    let untracked = worktree.untracked(&deletions);
    let made = if untracked.is_empty() {
        HashSet::new()
    } else {
        made_by_turns_since(&request.state_directories, &worktree, &turn)
    };
    changes.retain(|change| {
        change.kind != PathChangeKind::Delete
            || !untracked.contains(&change.raw)
            || made.contains(&change.raw)
    });
    let recorded_untracked = changes
        .iter()
        .filter(|change| change.kind == PathChangeKind::Delete && untracked.contains(&change.raw))
        .map(|change| change.display.clone())
        .collect();
    worktree.check_writable(&changes)?;
    stop_if_asked(&lock)?;
    let plan = Plan {
        op_id,
        operation: RestoreOperation::Restore,
        turn_id: turn.turn_id.clone(),
        turn_number: Some(turn.display_number),
        pane_id: request.pane_id.clone(),
        undoes: None,
        context,
        before_tree,
        target_tree: target_tree.clone(),
        changes,
        recorded_untracked,
    };
    worktree.run(plan, &lock, now, seams)
}

/// Undoes the restore `op_id`: writes back what was there before at each
/// path that still holds what the restore wrote. Refused when one holds
/// something else, which only its writer may take back.
#[must_use]
pub fn undo_restore(request: &UndoRequest, now: &str) -> RestoreOutcome {
    let _git = GitScope::begin();
    outcome(undo_restore_inner(request, now))
}

fn undo_restore_inner(request: &UndoRequest, now: &str) -> Result<RestoreJournal, Refusal> {
    let worktree = Worktree::open(&request.root)?;
    let lock = worktree.lock()?;
    let _ = worktree.settle_interrupted(now);
    let restored = worktree
        .journal(&request.op_id)
        .map_err(|error| Refusal::JournalUnreadable {
            cause: error.to_string(),
        })?
        .filter(RestoreJournal::is_writable)
        .ok_or(Refusal::RestoreNotFound)?;
    if restored.undoes.is_some()
        || !matches!(
            restored.stage,
            RestoreStage::Applied | RestoreStage::PartiallyApplied { .. }
        )
    {
        return Err(Refusal::NotUndoable);
    }
    worktree.check_agents(&request.state_directories)?;
    worktree.check_no_merge()?;
    let context = worktree.context();
    if context.head != restored.context_before.head {
        return Err(Refusal::HeadMoved);
    }
    if context.branch != restored.context_before.branch {
        return Err(Refusal::BranchChanged);
    }
    let reading = worktree.read_planned(&restored)?;
    // A partly applied restore recorded what each path held when it
    // settled: a path that holds neither side but is as recorded (another
    // writer's edit the restore kept) has not changed since, and the undo
    // leaves it as it is.
    let recorded = match &restored.stage {
        RestoreStage::PartiallyApplied { current_tree, .. } => {
            let raws: Vec<Vec<u8>> = reading
                .paths
                .iter()
                .filter(|path| path.state == PathState::Other)
                .map(|path| path.change.raw.clone())
                .collect();
            worktree
                .entries(current_tree, &raws)
                .ok_or_else(|| git_failed("read trees"))?
        }
        _ => HashMap::new(),
    };
    let others: Vec<String> = reading
        .paths
        .iter()
        .filter(|path| {
            path.state == PathState::Other && path.now.as_ref() != recorded.get(&path.change.raw)
        })
        .map(|path| path.change.display.clone())
        .collect();
    if !others.is_empty() {
        return Err(Refusal::ChangedSinceRestore { paths: others });
    }
    let changes: Vec<Change> = reading
        .paths
        .iter()
        .filter(|path| path.state == PathState::Target)
        .map(|path| path.back.clone())
        .collect();
    // A file made since where the undo puts a directory back is someone
    // else's, and no ref holds it: the undo does not write over it.
    worktree.check_writable(&changes)?;
    // A discard was refused for a file git converts; one that git came to
    // convert since (attributes set after it) would not get its bytes
    // back from the undo either.
    if restored.operation == RestoreOperation::Discard {
        let converted = worktree.converted_on_checkout(&changes)?;
        if !converted.is_empty() {
            return Err(Refusal::Converted { paths: converted });
        }
    }
    let plan = Plan {
        op_id: new_op_id(),
        operation: restored.operation,
        turn_id: restored.turn_id.clone(),
        turn_number: restored.turn_number,
        pane_id: restored.pane_id.clone(),
        undoes: Some(restored.op_id.clone()),
        context,
        before_tree: reading.current_tree,
        target_tree: restored.before_tree.clone(),
        changes,
        recorded_untracked: Vec::new(),
    };
    let undo = worktree.run(plan, &lock, now, &NO_SEAMS)?;
    if is_whole(&undo.stage) {
        let op = undo.op_id.clone();
        worktree.mark_undone(restored, &op, now);
        // As marked: with the saves the operation kept aside, if any.
        return Ok(worktree.journal(&op).ok().flatten().unwrap_or(undo));
    }
    Ok(undo)
}

/// What `recover` found.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Recovery {
    /// Every journal of the worktree that could be read, oldest first, for
    /// the records.
    pub journals: Vec<RestoreJournal>,
    /// The operations this call settled: a crash had cut them short, and
    /// the person is told once, by the call that found them.
    pub settled: Vec<String>,
    /// Whether `journals` leaves some out: the directory of journals, or a
    /// journal in it, is there but could not be read. Never read as "no
    /// such operation": what the caller knew of the rest stands, and a
    /// later reading may find them.
    pub is_incomplete: bool,
}

/// Settles the journals a crash left unfinished, drops the ones past their
/// lifetime and the refs nothing reads any more, and returns every journal
/// of the worktree that could be read. When a hook holds the lock, the
/// unfinished ones are returned as they are and settled on a later call.
///
/// Journals that are there but cannot be read keep none of the others from
/// this: each is settled or dropped on its own, and the call says the list
/// is incomplete (`Recovery::is_incomplete`) rather than give it as whole.
/// The ones it could not read stay as they are on disk, refs and all. This
/// call can tell what it settled, so it settles; a call that could not
/// tell it settles nothing, as the app hears of a settled operation only
/// from the call that settled it.
///
/// # Errors
///
/// `RecoverError` when git could not be asked where the worktree's journals
/// are: nothing is read or settled then. Never an empty `Recovery` in its
/// place, which reads as a worktree with no operation to show or settle. A
/// folder that is no worktree of a repository has none, and is `Ok`.
pub fn recover(root: &Path, now: &str) -> Result<Recovery, RecoverError> {
    let _git = GitScope::begin();
    let Some(worktree) = Worktree::find(root).map_err(RecoverError::Git)? else {
        return Ok(Recovery::default());
    };
    let (journals, _) = worktree.readable_journals();
    let unmarked_undo = |undo: &RestoreJournal| {
        is_whole(&undo.stage)
            && undo.undoes.as_deref().is_some_and(|op| {
                journals.iter().any(|restored| {
                    restored.op_id == op
                        && restored.is_writable()
                        && !matches!(restored.stage, RestoreStage::Undone { .. })
                })
            })
    };
    let needs_lock = journals.iter().any(|journal| {
        journal.is_writable()
            && (journal.stage.is_interrupted()
                || is_expired(journal, now)
                || unmarked_undo(journal))
    }) || !worktree.leftover_refs().is_empty();
    let mut settled = Vec::new();
    if needs_lock && let Ok(_lock) = worktree.lock() {
        settled = worktree.settle_interrupted(now);
        worktree.prune(now);
    }
    // Read again for what settling and pruning wrote; whether the list is
    // whole is this reading's to say. The app logs that it is not.
    let (mut journals, failure) = worktree.readable_journals();
    // By when each ran: settling one after a crash rewrites its `at`,
    // which would put it after an operation that ran later.
    journals.sort_by(|first, second| {
        ran(first)
            .cmp(ran(second))
            .then(first.op_id.cmp(&second.op_id))
    });
    Ok(Recovery {
        journals,
        settled,
        is_incomplete: failure.is_some(),
    })
}

/// When `journal` ran: its `ran_at`, or `at` in one from before it.
fn ran(journal: &RestoreJournal) -> &str {
    journal.ran_at.as_deref().unwrap_or(&journal.at)
}

/// Why `recover` read nothing. Journals that could not be read are no
/// error: the ones that could are still read and settled
/// (`Recovery::is_incomplete`).
#[derive(Debug)]
pub enum RecoverError {
    /// Git could not be started, or did not finish, to say where the
    /// worktree's git directory is.
    Git(std::io::Error),
}

impl std::fmt::Display for RecoverError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Git(error) => write!(formatter, "git rev-parse: {error}"),
        }
    }
}

impl std::error::Error for RecoverError {}

fn outcome(result: Result<RestoreJournal, Refusal>) -> RestoreOutcome {
    match result {
        Ok(journal) => RestoreOutcome::Finished {
            journal: Box::new(journal),
        },
        Err(refusal) => RestoreOutcome::Refused { refusal },
    }
}

fn git_failed(step: &str) -> Refusal {
    Refusal::Git {
        step: step.to_owned(),
    }
}

/// Stops a restore that has written nothing yet when a hook asks: the
/// agent's turn goes first.
fn stop_if_asked(lock: &ExclusiveLock) -> Result<(), Refusal> {
    match lock.interruption() {
        Some(_) => Err(Refusal::AgentStarted),
        None => Ok(()),
    }
}

fn new_op_id() -> String {
    uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase()
}

/// What one operation writes, worked out before anything is.
struct Plan {
    op_id: String,
    operation: RestoreOperation,
    turn_id: String,
    turn_number: Option<u32>,
    pane_id: String,
    undoes: Option<String>,
    context: RestoreContext,
    before_tree: String,
    target_tree: String,
    /// Deletions first: a file the target has a directory in place of must
    /// go before the directory's files are written.
    changes: Vec<Change>,
    recorded_untracked: Vec<String>,
}

/// One path that differs between two trees.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Change {
    raw: Vec<u8>,
    display: String,
    kind: PathChangeKind,
    /// The mode and object the path has on the side the change goes to;
    /// all zeros for a deletion.
    mode: String,
    object: String,
}

impl Change {
    fn is_deletion(&self) -> bool {
        self.kind == PathChangeKind::Delete
    }
}

/// A file's mode and object, as a tree holds it or as the working tree
/// would be captured.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Entry {
    mode: String,
    object: String,
}

/// The entry a directory has, which no tree stores at its path: a
/// directory on disk equals one in a tree, whatever is under it.
fn directory_entry() -> Entry {
    Entry {
        mode: "040000".to_owned(),
        object: String::new(),
    }
}

/// What a planned path holds on disk, by path, and, from a tree, the tree
/// with them.
type DiskReading = (HashMap<Vec<u8>, Option<Entry>>, Option<String>);

/// What `read_disk`'s private index starts from.
#[derive(Clone, Copy)]
enum Seed<'a> {
    /// A whole tree, whose copy with the paths as they are now is wanted.
    Tree(&'a str),
    /// Only the paths' own entries.
    Entries,
}

/// What a planned path holds now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PathState {
    /// What the operation writes there.
    Target,
    /// What was there before it.
    Before,
    /// Neither: another writer's.
    Other,
}

struct PlannedPath {
    change: Change,
    state: PathState,
    /// What the path holds now.
    now: Option<Entry>,
    /// The change that puts back what was there before.
    back: Change,
}

/// The planned paths of a journal as they are now.
struct Reading {
    paths: Vec<PlannedPath>,
    /// The journal's `before_tree` with each planned path as it is now.
    current_tree: String,
}

/// A worktree of a repository, as git names it.
struct Worktree {
    git_dir: PathBuf,
    root: PathBuf,
    /// The git directory every worktree of the repository shares, where the
    /// refs are: `git_dir` itself for the main worktree.
    common_dir: PathBuf,
}

impl Worktree {
    fn open(root: &Path) -> Result<Self, Refusal> {
        Self::find(root)
            .map_err(|_| git_failed("rev-parse"))?
            .ok_or(Refusal::NotARepository)
    }

    /// The worktree at `root`; `None` when it is no worktree of a
    /// repository, and an error when git could not be asked.
    fn find(root: &Path) -> std::io::Result<Option<Self>> {
        Ok(
            GitSnapshots::repository_and_common_checked(root)?.map(
                |(git_dir, root, common_dir)| Self {
                    git_dir,
                    root,
                    common_dir,
                },
            ),
        )
    }

    fn lock(&self) -> Result<ExclusiveLock, Refusal> {
        ExclusiveLock::acquire(&WorktreeLockPaths::new(&self.git_dir), LOCK_WAIT, LOCK_POLL)
            .map_err(|error| match error {
                ExclusiveError::Busy => Refusal::AgentRecording,
                ExclusiveError::Unavailable(reason) => Refusal::LockUnavailable { reason },
            })
    }

    fn scratch(&self) -> PathBuf {
        self.git_dir.join("limpid")
    }

    /// A private index for one step of one operation.
    fn index(&self, name: &str) -> PathBuf {
        self.scratch().join(format!("restore-{name}.index"))
    }

    /// Refuses while an agent of this worktree is at work or waits for an
    /// answer. A run is this worktree's when its latest prompt was given
    /// here; one whose process is gone is not at work, whatever its record
    /// still says.
    fn check_agents(&self, directories: &[StateDirectory]) -> Result<(), Refusal> {
        for StateDirectory {
            provider,
            directory,
        } in directories
        {
            let Ok(entries) = fs::read_dir(directory) else {
                continue;
            };
            for entry in entries.flatten() {
                if !entry
                    .file_name()
                    .to_string_lossy()
                    .ends_with(RUN_RECORD_FILE_SUFFIX)
                {
                    continue;
                }
                let Some(record) = read_record(&entry.path()) else {
                    continue;
                };
                let is_active = record.state.is_at_work();
                let is_here = [&record.worktree_root, &record.turn_root]
                    .into_iter()
                    .flatten()
                    .any(|root| same_path(Path::new(root), &self.root));
                let is_gone = record
                    .pid
                    .as_deref()
                    .and_then(|pid| pid.parse::<u32>().ok())
                    .is_some_and(|pid| start_epoch(pid).is_none());
                if is_active && is_here && !is_gone {
                    return Err(Refusal::AgentActive {
                        provider: provider.clone(),
                    });
                }
            }
        }
        Ok(())
    }

    fn check_no_merge(&self) -> Result<(), Refusal> {
        let under_way = [
            "MERGE_HEAD",
            "rebase-merge",
            "rebase-apply",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
        ]
        .iter()
        .any(|name| self.git_dir.join(name).exists());
        // A conflict left by `stash pop` or an aborted merge has no head
        // file, only unmerged entries.
        let has_conflicts = GitSnapshots::run(&self.root, &["ls-files", "-u", "-z"], None)
            .is_none_or(|listing| !listing.is_empty());
        if under_way || has_conflicts {
            Err(Refusal::MergeInProgress)
        } else {
            Ok(())
        }
    }

    fn context(&self) -> RestoreContext {
        let head = GitSnapshots::git(&self.root, &["rev-parse", "-q", "--verify", "HEAD"], None)
            .filter(|head| is_object_id(head));
        let branch =
            GitSnapshots::git(&self.root, &["symbolic-ref", "-q", "--short", "HEAD"], None)
                .filter(|branch| !branch.is_empty());
        RestoreContext { head, branch }
    }

    /// Captures the working tree as a tree object, through a fresh private
    /// index named `name`, made the way a turn's snapshot makes its own
    /// (`GitSnapshots::seed_index`). Large untracked files are left out, as
    /// the snapshot leaves them; the plan refuses to write over them. A
    /// skip-worktree file (a sparse checkout) is not on disk at all, so a
    /// restore is refused there.
    fn capture(&self, name: &str) -> Result<String, Refusal> {
        // The private index lives in our scratch directory, which a caller
        // before the lock or the journal may not have made yet.
        ensure_user_only_directory(&self.scratch());
        let index = self.index(name);
        let refusal = match GitSnapshots::seed_index(&self.git_dir, &self.root, &index) {
            Ok(seeded) if seeded.has_skip_worktree => Some(Refusal::SparseCheckout),
            Ok(_) => None,
            Err(step) => Some(git_failed(step)),
        };
        if let Some(refusal) = refusal {
            let _ = fs::remove_file(&index);
            return Err(refusal);
        }
        let skipped = GitSnapshots::large_untracked(&self.root, &index);
        let tree = GitSnapshots::stage(&self.root, &index, &skipped)
            .and_then(|()| GitSnapshots::git(&self.root, &["write-tree"], Some(&index)))
            .filter(|tree| is_object_id(tree));
        let _ = fs::remove_file(&index);
        tree.ok_or_else(|| git_failed("capture"))
    }

    /// The paths that differ from `from` to `to`. Submodules are left out:
    /// a restore does not touch them.
    fn changes(&self, from: &str, to: &str) -> Option<Vec<Change>> {
        let raw = GitSnapshots::run(
            &self.root,
            &["diff-tree", "-r", "-z", "--no-renames", from, to],
            None,
        )?;
        // "-z" gives ":<old mode> <new mode> <old id> <new id> <status>\0<path>\0".
        let mut fields = raw.split(|byte| *byte == 0);
        let mut changes = Vec::new();
        while let Some(header) = fields.next() {
            if header.is_empty() {
                continue;
            }
            let path = fields.next()?;
            let header = String::from_utf8_lossy(header);
            let parts: Vec<&str> = header.trim_start_matches(':').split(' ').collect();
            let [old_mode, new_mode, _old_id, new_id, status] = parts[..] else {
                return None;
            };
            if old_mode == "160000" || new_mode == "160000" {
                continue;
            }
            let kind = match status.chars().next() {
                Some('A') => PathChangeKind::Add,
                Some('D') => PathChangeKind::Delete,
                _ => PathChangeKind::Modify,
            };
            changes.push(Change {
                raw: path.to_vec(),
                display: String::from_utf8_lossy(path).into_owned(),
                kind,
                mode: new_mode.to_owned(),
                object: new_id.to_owned(),
            });
        }
        changes.sort_by_key(|change| (!change.is_deletion(), change.raw.clone()));
        Some(changes)
    }

    /// The paths of `candidates` the real index does not track.
    fn untracked(&self, candidates: &[Change]) -> HashSet<Vec<u8>> {
        let tracked: HashSet<Vec<u8>> = GitSnapshots::run(&self.root, &["ls-files", "-z"], None)
            .map(|listing| {
                listing
                    .split(|byte| *byte == 0)
                    .filter(|path| !path.is_empty())
                    .map(<[u8]>::to_vec)
                    .collect()
            })
            .unwrap_or_default();
        candidates
            .iter()
            .filter(|change| !tracked.contains(&change.raw))
            .map(|change| change.raw.clone())
            .collect()
    }

    /// Refuses `changes` when writing them would lose a file no snapshot
    /// holds, or when they rename a file to a name its volume takes for
    /// the same one.
    fn check_writable(&self, changes: &[Change]) -> Result<(), Refusal> {
        // The new name of such a rename is on disk too, as the old: it
        // would read as a file in the way.
        let renamed = self.renamed_in_place(changes);
        if !renamed.is_empty() {
            return Err(Refusal::RenamedInPlace { paths: renamed });
        }
        let in_the_way = self.in_the_way(changes);
        if !in_the_way.is_empty() {
            return Err(Refusal::PathsInTheWay { paths: in_the_way });
        }
        Ok(())
    }

    /// The paths the plan writes that name, on this volume, the very file
    /// at a path it deletes: a rename only in case (or in Unicode
    /// normalization) where the volume does not tell those apart. Git reads
    /// such a pair through one index entry, so neither the capture nor the
    /// check after the write could tell what each name holds.
    fn renamed_in_place(&self, changes: &[Change]) -> Vec<String> {
        let deleted: HashSet<(u64, u64)> = changes
            .iter()
            .filter(|change| change.is_deletion())
            .filter_map(|change| path_from_bytes(&change.raw))
            .filter_map(|relative| file_identity(&self.root.join(relative)))
            .collect();
        if deleted.is_empty() {
            return Vec::new();
        }
        changes
            .iter()
            .filter(|change| change.kind == PathChangeKind::Add)
            .filter(|change| {
                path_from_bytes(&change.raw).is_some_and(|relative| {
                    let path = self.root.join(&relative);
                    // A name of its own in the directory is another file
                    // (a hard link), which is in the way, not renamed.
                    file_identity(&path).is_some_and(|identity| deleted.contains(&identity))
                        && !is_listed(&path)
                })
            })
            .map(|change| change.display.clone())
            .collect()
    }

    /// The files the plan would write over without having captured them:
    /// something at a path the capture did not see (ignored, or untracked
    /// past the size limit), or a file or a link where a directory of a
    /// written path goes that the plan does not delete. Writing would lose
    /// them, and no undo could bring them back.
    fn in_the_way(&self, changes: &[Change]) -> Vec<String> {
        let deleted: HashSet<&[u8]> = changes
            .iter()
            .filter(|change| change.is_deletion())
            .map(|change| change.raw.as_slice())
            .collect();
        let mut paths = BTreeSet::new();
        for change in changes.iter().filter(|change| !change.is_deletion()) {
            let Some(relative) = path_from_bytes(&change.raw) else {
                continue;
            };
            // A directory at the path is not in the way: the plan's deletions
            // empty it first, and a write fails rather than remove one they
            // do not.
            if change.kind == PathChangeKind::Add
                && fs::symlink_metadata(self.root.join(&relative))
                    .is_ok_and(|metadata| !metadata.is_dir())
            {
                paths.insert(change.display.clone());
            }
            for ancestor in relative.ancestors().skip(1) {
                if ancestor.as_os_str().is_empty() {
                    break;
                }
                let is_directory = fs::symlink_metadata(self.root.join(ancestor))
                    .map_or(true, |metadata| metadata.is_dir());
                if !is_directory && !deleted.contains(ancestor.as_os_str().as_encoded_bytes()) {
                    paths.insert(ancestor.to_string_lossy().into_owned());
                }
            }
        }
        paths.into_iter().collect()
    }

    /// The tree `base` with `changes` applied, made in a private index.
    fn tree_with(&self, base: &str, changes: &[Change], name: &str) -> Option<String> {
        let index = self.index(name);
        let _ = fs::remove_file(&index);
        let tree = GitSnapshots::run(&self.root, &["read-tree", base], Some(&index))
            .and_then(|_| {
                let mut info = Vec::new();
                for change in changes {
                    if change.is_deletion() {
                        // Mode 0 removes the entry.
                        info.extend_from_slice(
                            format!("0 {}\t", "0".repeat(change.object.len().max(40))).as_bytes(),
                        );
                    } else {
                        info.extend_from_slice(
                            format!("{} {}\t", change.mode, change.object).as_bytes(),
                        );
                    }
                    info.extend_from_slice(&change.raw);
                    info.push(0);
                }
                GitSnapshots::run_with_input_index(
                    &self.root,
                    &["update-index", "-z", "--index-info"],
                    &info,
                    Some(&index),
                )
            })
            .and_then(|_| GitSnapshots::git(&self.root, &["write-tree"], Some(&index)))
            .filter(|tree| is_object_id(tree));
        let _ = fs::remove_file(&index);
        tree
    }

    /// The entries `tree` has at `paths`. A path that is a directory in the
    /// tree has the directory's entry (`directory_entry`), which a directory
    /// on disk equals: what is under it is judged by its own planned paths.
    fn entries(&self, tree: &str, paths: &[Vec<u8>]) -> Option<HashMap<Vec<u8>, Entry>> {
        let asked: HashSet<&[u8]> = paths.iter().map(Vec::as_slice).collect();
        let mut entries = HashMap::new();
        for chunk in paths.chunks(PATHS_PER_CALL) {
            let mut command = GitSnapshots::command(
                &self.root,
                &[
                    "--literal-pathspecs",
                    "ls-tree",
                    "-r",
                    "-z",
                    "--full-tree",
                    tree,
                    "--",
                ],
                None,
            );
            for path in chunk {
                if let Some(path) = path_from_bytes(path) {
                    command.arg(path);
                }
            }
            command.stdin(std::process::Stdio::null());
            let output = crate::git::output(&mut command)
                .ok()
                .filter(|output| output.status.success())?;
            // "<mode> <type> <object>\t<path>\0"
            for line in output.stdout.split(|byte| *byte == 0) {
                let Some(tab) = line.iter().position(|byte| *byte == b'\t') else {
                    continue;
                };
                let header = String::from_utf8_lossy(&line[..tab]);
                let parts: Vec<&str> = header.split(' ').collect();
                let path = &line[tab + 1..];
                if let [mode, _kind, object] = parts[..] {
                    entries.insert(
                        path.to_vec(),
                        Entry {
                            mode: mode.to_owned(),
                            object: object.to_owned(),
                        },
                    );
                }
                for (position, _) in path.iter().enumerate().filter(|(_, byte)| **byte == b'/') {
                    if asked.contains(&path[..position]) {
                        entries
                            .entry(path[..position].to_vec())
                            .or_insert_with(directory_entry);
                    }
                }
            }
        }
        Some(entries)
    }

    /// What each of `paths` holds in the working tree, as a capture would
    /// record it: a private index, seeded as `seed` says, takes the paths
    /// (`add -A -f`, so an ignored one is read too), and its entries are
    /// read back; seeded with a tree, the call also returns that tree with
    /// those paths as they are now. A directory is an entry no tree has; the
    /// tree keeps what the seed had there. A missing path is `None`.
    /// `in_seed` are the seed's entries at `paths`.
    fn read_disk(
        &self,
        seed: Seed<'_>,
        paths: &[Vec<u8>],
        in_seed: &HashMap<Vec<u8>, Entry>,
        name: &str,
    ) -> Option<DiskReading> {
        let in_base = in_seed;
        let mut found: HashMap<Vec<u8>, Option<Entry>> = HashMap::new();
        let mut pathspecs = Vec::new();
        for raw in paths {
            let metadata = path_from_bytes(raw)
                .and_then(|relative| fs::symlink_metadata(self.root.join(relative)).ok());
            match metadata {
                Some(metadata) if metadata.is_dir() => {
                    found.insert(raw.clone(), Some(directory_entry()));
                }
                // A path neither on disk nor in the index would fail the
                // whole `add` as a pathspec that matches nothing.
                None if !in_base.contains_key(raw) => {
                    found.insert(raw.clone(), None);
                }
                _ => {
                    pathspecs.extend_from_slice(raw);
                    pathspecs.push(0);
                }
            }
        }
        let index = self.index(name);
        let _ = fs::remove_file(&index);
        let seeded = match seed {
            Seed::Tree(base) => GitSnapshots::run(&self.root, &["read-tree", base], Some(&index)),
            // Only the paths' own entries: reading a whole tree into the
            // index for each batch costs as much as the batch in a large
            // repository.
            Seed::Entries => {
                let mut info = Vec::new();
                for (path, entry) in in_seed
                    .iter()
                    .filter(|(_, entry)| **entry != directory_entry())
                {
                    info.extend_from_slice(format!("{} {}\t", entry.mode, entry.object).as_bytes());
                    info.extend_from_slice(path);
                    info.push(0);
                }
                GitSnapshots::run_with_input_index(
                    &self.root,
                    &["update-index", "--add", "-z", "--index-info"],
                    &info,
                    Some(&index),
                )
            }
        };
        let listing = seeded
            .and_then(|_| {
                pathspecs.is_empty().then(Vec::new).or_else(|| {
                    GitSnapshots::run_with_input_index(
                        &self.root,
                        &[
                            "--literal-pathspecs",
                            "add",
                            "-A",
                            "-f",
                            "--pathspec-from-file=-",
                            "--pathspec-file-nul",
                        ],
                        &pathspecs,
                        Some(&index),
                    )
                })
            })
            .and_then(|_| GitSnapshots::run(&self.root, &["ls-files", "-s", "-z"], Some(&index)));
        let tree = match seed {
            Seed::Tree(_) => Some(
                listing
                    .as_ref()
                    .and_then(|_| GitSnapshots::git(&self.root, &["write-tree"], Some(&index)))
                    .filter(|tree| is_object_id(tree))?,
            ),
            Seed::Entries => None,
        };
        let _ = fs::remove_file(&index);
        let listing = listing?;
        let mut indexed: HashMap<Vec<u8>, Entry> = HashMap::new();
        // "<mode> <object> <stage>\t<path>\0"
        for line in listing.split(|byte| *byte == 0) {
            let Some(tab) = line.iter().position(|byte| *byte == b'\t') else {
                continue;
            };
            let header = String::from_utf8_lossy(&line[..tab]);
            if let [mode, object, _stage] = header.split(' ').collect::<Vec<_>>()[..] {
                indexed.insert(
                    line[tab + 1..].to_vec(),
                    Entry {
                        mode: mode.to_owned(),
                        object: object.to_owned(),
                    },
                );
            }
        }
        for raw in paths {
            found
                .entry(raw.clone())
                .or_insert_with(|| indexed.get(raw).cloned());
        }
        Some((found, tree))
    }

    /// The planned paths of `journal` as they are now: each against what the
    /// operation writes there and what was there before. A journal keeps
    /// its paths as text; APFS takes only UTF-8 names, so that text is the
    /// name.
    fn read_planned(&self, journal: &RestoreJournal) -> Result<Reading, Refusal> {
        let raws: Vec<Vec<u8>> = journal
            .planned_paths
            .iter()
            .map(|change| change.path.as_bytes().to_vec())
            .collect();
        let read_failed = || git_failed("read trees");
        let target = self
            .entries(&journal.target_tree, &raws)
            .ok_or_else(read_failed)?;
        let before = self
            .entries(&journal.before_tree, &raws)
            .ok_or_else(read_failed)?;
        let (disk, current_tree) = self
            .read_disk(
                Seed::Tree(&journal.before_tree),
                &raws,
                &before,
                &format!("{}-current", journal.op_id),
            )
            .and_then(|(disk, tree)| Some((disk, tree?)))
            .ok_or_else(|| git_failed("read planned paths"))?;
        let mut paths = Vec::new();
        for (planned, raw) in journal.planned_paths.iter().zip(raws) {
            let now = disk.get(&raw).cloned().flatten();
            let state = if now.as_ref() == target.get(&raw) {
                PathState::Target
            } else if now.as_ref() == before.get(&raw) {
                PathState::Before
            } else {
                PathState::Other
            };
            // A directory on a side is written by its own paths; at this
            // path, only a file that stands in its way goes.
            let change = |entry: Option<&Entry>| {
                let entry = entry.filter(|entry| **entry != directory_entry());
                Change {
                    raw: raw.clone(),
                    display: planned.path.clone(),
                    kind: if entry.is_some() {
                        PathChangeKind::Modify
                    } else {
                        PathChangeKind::Delete
                    },
                    mode: entry.map_or_else(|| "000000".to_owned(), |entry| entry.mode.clone()),
                    object: entry.map_or_else(String::new, |entry| entry.object.clone()),
                }
            };
            paths.push(PlannedPath {
                change: change(target.get(&raw)),
                state,
                now: now.clone(),
                back: change(before.get(&raw)),
            });
        }
        paths.sort_by_key(|path| (!path.back.is_deletion(), path.back.raw.clone()));
        Ok(Reading {
            paths,
            current_tree,
        })
    }
}

/// Whether something may be at `path`: only a path known to be missing is
/// not, so a save that cannot be looked at for now keeps its record.
fn is_there(path: &Path) -> bool {
    !matches!(fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound)
}

/// Whether the directory of `path` lists its name as it is spelled: on a
/// volume that does not tell case apart, another spelling finds the file
/// but is not its name.
fn is_listed(path: &Path) -> bool {
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return false;
    };
    fs::read_dir(parent)
        .is_ok_and(|entries| entries.flatten().any(|entry| entry.file_name() == name))
}

/// The device and inode of what `path` names, not following a link.
fn file_identity(path: &Path) -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        fs::symlink_metadata(path)
            .ok()
            .map(|metadata| (metadata.dev(), metadata.ino()))
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// Removes the directories a deletion left empty, up to `root`.
fn remove_empty_parents(root: &Path, relative: &Path) {
    let mut parent = relative.parent();
    while let Some(directory) = parent.filter(|directory| !directory.as_os_str().is_empty()) {
        if fs::remove_dir(root.join(directory)).is_err() {
            break;
        }
        parent = directory.parent();
    }
}

/// An operation id as the writer spells it, which is safe as a file and a
/// ref name.
fn is_op_id(value: &str) -> bool {
    uuid::Uuid::parse_str(value)
        .is_ok_and(|uuid| uuid.hyphenated().to_string().to_uppercase() == value)
}

fn same_path(first: &Path, second: &Path) -> bool {
    first == second
        || matches!(
            (fs::canonicalize(first), fs::canonicalize(second)),
            (Ok(first), Ok(second)) if first == second
        )
}

/// Every turn record of the state directories.
fn turns(directories: &[StateDirectory]) -> Vec<TurnRecord> {
    directories
        .iter()
        .filter_map(|state| fs::read_dir(state.directory.join(TURNS_DIRECTORY)).ok())
        .flat_map(Iterator::flatten)
        .filter_map(|entry| {
            fs::read(entry.path())
                .ok()
                .and_then(|bytes| TurnRecord::decode(&bytes).ok())
        })
        .collect()
}

/// The turn `turn_id`, from whichever provider's turns directory has it.
fn find_turn(directories: &[StateDirectory], turn_id: &str) -> Result<TurnRecord, Refusal> {
    if !crate::turn::is_turn_id(turn_id) {
        return Err(Refusal::TurnNotFound);
    }
    directories
        .iter()
        .find_map(|state| {
            let path = state
                .directory
                .join(TURNS_DIRECTORY)
                .join(turn_record_file_name(turn_id));
            let bytes = fs::read(path).ok()?;
            TurnRecord::decode(&bytes)
                .ok()
                .filter(|turn| turn.turn_id == turn_id)
        })
        .ok_or(Refusal::TurnNotFound)
}

/// The paths turns of this worktree made, from `since` on: absent from a
/// turn's start and present at its end. A file made by hand between turns
/// is in no such list, though a later turn's start holds it.
fn made_by_turns_since(
    directories: &[StateDirectory],
    worktree: &Worktree,
    since: &TurnRecord,
) -> HashSet<Vec<u8>> {
    let mut made = HashSet::new();
    for turn in turns(directories) {
        // Within a conversation the number orders turns that started in
        // the same second; across conversations only the time can.
        let is_earlier = if turn.conversation == since.conversation {
            turn.display_number < since.display_number
        } else {
            turn.started_at < since.started_at
        };
        if is_earlier {
            continue;
        }
        let (
            SnapshotStatus::Captured {
                tree: begin,
                root: begin_root,
            },
            SnapshotStatus::Captured { tree: end, .. },
        ) = (&turn.begin, &turn.end)
        else {
            continue;
        };
        if !same_path(Path::new(begin_root), &worktree.root) {
            continue;
        }
        if let Some(changes) = worktree.changes(begin, end) {
            made.extend(
                changes
                    .into_iter()
                    .filter(|change| change.kind == PathChangeKind::Add)
                    .map(|change| change.raw),
            );
        }
    }
    made
}

#[path = "restore_discard.rs"]
mod discard;
pub use discard::{
    DiscardFile, DiscardOutcome, DiscardRequest, HunkOutcome, HunkResult, discard_hunks,
};

// A restore runs under the worktree lock, and off Unix the hook opens no
// lock file (`records::open_lock_file`), so these run on Unix only.
#[cfg(all(test, unix))]
#[path = "restore_tests/mod.rs"]
mod tests;
