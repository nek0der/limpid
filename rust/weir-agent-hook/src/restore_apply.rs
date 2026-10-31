//! Carrying out a planned operation: the journal before the first file, the
//! writes a batch at a time, the check of what the planned paths hold
//! afterwards, the rollback when another writer changed one, and how an
//! operation that stopped early, or that a crash cut short, is settled.

use super::journal::is_whole;
use super::write::{Moment, Unwritten, Writer};
use super::{
    Change, PathState, Plan, Reading, Refusal, Seams, Seed, Worktree, directory_entry, git_failed,
    path_from_bytes,
};
use crate::worktree_lock::{ExclusiveLock, Interruption};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::time::{Duration, Instant};
use weir_agent_model::{
    FailedPath, FailedReason, PathChange, RestoreJournal, RestoreStage, StageReason,
};

/// How many paths are written by one `git checkout-index` between two
/// looks at the lock's markers: a waiting agent waits at most this many.
pub(super) const WRITE_BATCH: usize = 64;

/// How long a batch may take before the rest is written a path at a time.
pub(super) const SLOW_BATCH: Duration = Duration::from_secs(1);

impl Worktree {
    /// Writes `plan` and returns the journal as it ended.
    pub(super) fn run(
        &self,
        plan: Plan,
        lock: &ExclusiveLock,
        now: &str,
        seams: &Seams<'_>,
    ) -> Result<RestoreJournal, Refusal> {
        self.check_volume(&plan.changes)?;
        let op = plan.op_id.clone();
        let expected_after_tree = self
            .tree_with(&plan.before_tree, &plan.changes, &format!("{op}-expected"))
            .ok_or_else(|| git_failed("expected tree"))?;
        // The expected tree must differ from the start at the planned paths
        // and nowhere else: `--index-info` would replace a path a directory
        // took in silence, and the restore would call that applied.
        let planned: BTreeSet<&[u8]> = plan
            .changes
            .iter()
            .map(|change| change.raw.as_slice())
            .collect();
        let differing = self
            .changes(&plan.before_tree, &expected_after_tree)
            .ok_or_else(|| git_failed("diff-tree"))?;
        if differing
            .iter()
            .map(|change| change.raw.as_slice())
            .collect::<BTreeSet<_>>()
            != planned
        {
            return Err(git_failed("plan"));
        }
        let mut journal = RestoreJournal {
            schema_version: RestoreJournal::SCHEMA_VERSION,
            op_id: op.clone(),
            operation: plan.operation,
            root: self.root.to_string_lossy().into_owned(),
            turn_id: plan.turn_id,
            turn_number: plan.turn_number,
            pane_id: plan.pane_id,
            undoes: plan.undoes,
            context_before: plan.context,
            before_tree: plan.before_tree,
            target_tree: plan.target_tree,
            expected_after_tree,
            planned_paths: plan
                .changes
                .iter()
                .map(|change| PathChange {
                    path: change.display.clone(),
                    kind: change.kind,
                })
                .collect(),
            recorded_untracked: plan.recorded_untracked,
            stage: RestoreStage::Planned,
            at: now.to_owned(),
            ran_at: Some(now.to_owned()),
            extra: BTreeMap::new(),
        };
        // The trees first, then the journal that names them: a crash
        // between the two leaves refs that a later sweep drops, never a
        // journal whose trees `git gc` may take.
        if let Err(error) = self
            .pin_trees(&journal)
            .and_then(|()| self.write_progress(&journal))
        {
            self.release_refs(&op);
            return Err(error.refusal());
        }
        (seams.after_journal)();
        let settled = match self.write(&journal, &plan.changes, lock, now, seams.in_write) {
            Written::Stopped(interruption, kept) => self.settle_partial(
                &journal,
                match interruption {
                    Interruption::AgentWaiting | Interruption::AgentAbandoned => {
                        StageReason::AgentStarted
                    }
                },
                kept,
            ),
            Written::Failed(failed) => {
                self.settle_partial(&journal, StageReason::WriteFailed, failed)
            }
            Written::All(kept) => {
                (seams.after_write)();
                journal.stage = RestoreStage::Verifying;
                now.clone_into(&mut journal.at);
                // Not written, the journal stays at its last stage, which
                // recovery settles by what the paths hold, as it settles
                // this one.
                let _ = self.write_progress(&journal);
                self.verify(&journal, lock, kept, seams.in_rollback)
            }
        };
        // Files may be written by now, so a failure here is not "nothing
        // written": the journal is returned as it stands, unfinished, and
        // recovery settles it by what the paths hold.
        let Ok(stage) = settled else {
            return Ok(self.journal(&op).ok().flatten().unwrap_or(journal));
        };
        journal.stage = stage;
        now.clone_into(&mut journal.at);
        // A tree the stage names that cannot be pinned keeps the journal
        // unfinished on disk, as a journal that cannot be written does.
        if self.write_journal(&journal).is_ok() {
            self.release_finished_refs(&journal);
        }
        Ok(journal)
    }

    /// How an operation that stopped early ended, by its planned paths:
    /// aborted when every one holds what was there before, else partly
    /// applied. A path that holds neither may be the restore's half-written
    /// file, so its start is kept with the record.
    pub(super) fn settle_partial(
        &self,
        journal: &RestoreJournal,
        reason: StageReason,
        failed: Vec<FailedPath>,
    ) -> Result<RestoreStage, Refusal> {
        let reading = self.read_planned(journal)?;
        Ok(settled_stage(&reading, reason, failed).unwrap_or(RestoreStage::Applied))
    }

    /// Writes `changes` from the target, a batch at a time, looking at the
    /// lock's markers before each batch. Each path is read just before its
    /// group is written and written only while it still holds what the plan
    /// read there (`Writer`): another writer's save since is left alone, or
    /// kept aside, and the check afterwards finds it.
    pub(super) fn write(
        &self,
        journal: &RestoreJournal,
        changes: &[Change],
        lock: &ExclusiveLock,
        now: &str,
        between: &dyn Fn(Moment),
    ) -> Written {
        let Some(mut writer) = Writer::new(self, &journal.op_id, &journal.target_tree, "target")
            .map(|writer| writer.with_between(between))
        else {
            return Written::Failed(failed_all(changes, "read-tree"));
        };
        let mut progress = journal.clone();
        let batches = Self::write_batches(
            &mut writer,
            &journal.before_tree,
            changes,
            lock,
            &mut |done| {
                progress.stage = RestoreStage::Writing {
                    done: done.to_vec(),
                };
                now.clone_into(&mut progress.at);
                // Progress only: not written, the journal stays at the
                // stage before, and recovery settles it by what the paths
                // hold, never by `done`.
                let _ = self.write_progress(&progress);
            },
        );
        let mut failed = batches.failed;
        failed.extend(writer.finish());
        match batches.stopped {
            Some(interruption) => Written::Stopped(interruption, failed),
            None if failed.iter().all(|failed| failed.kept_at().is_some()) => Written::All(failed),
            None => Written::Failed(failed),
        }
    }

    /// Writes `changes` from `writer`'s tree a batch at a time, each path
    /// only while it still holds what `expected` has there, looking at the
    /// lock's markers before each batch and stopping when a hook asks.
    /// What each path came to is gathered here for the forward write and
    /// the rollback alike: a path another writer changed meanwhile is left
    /// for the check afterwards, as is one whose save was kept aside (the
    /// writer's `finish` names those), and one whose write failed is in
    /// `failed` with how. `after_batch` sees the paths written so far.
    fn write_batches(
        writer: &mut Writer<'_>,
        expected: &str,
        changes: &[Change],
        lock: &ExclusiveLock,
        after_batch: &mut dyn FnMut(&[String]),
    ) -> BatchesWritten {
        let mut written = BatchesWritten::default();
        let mut batches = Batches::new(changes);
        while let Some(batch) = batches.next_batch() {
            if let Some(interruption) = lock.interruption() {
                written.stopped = Some(interruption);
                break;
            }
            let started = Instant::now();
            for (change, result) in writer.write(expected, batch) {
                match result {
                    Ok(()) => written.done.push(change.display),
                    Err(Unwritten::ChangedWhileWriting | Unwritten::KeptAside(_)) => {}
                    Err(Unwritten::Failed(detail)) => written.failed.push(FailedPath {
                        path: change.display,
                        reason: FailedReason::WriteFailed,
                        detail: Some(detail),
                    }),
                }
            }
            batches.took(started.elapsed());
            after_batch(&written.done);
        }
        written
    }

    /// Which of `changes` hold now what `tree` has at their path, and which
    /// moved on since; `None` when git could not say.
    pub(super) fn still_holding(
        &self,
        tree: &str,
        changes: &[Change],
        op_id: &str,
    ) -> Option<(Vec<Change>, Vec<Change>)> {
        let raws: Vec<Vec<u8>> = changes.iter().map(|change| change.raw.clone()).collect();
        let expected = self.entries(tree, &raws)?;
        let (disk, _) =
            self.read_disk(Seed::Entries, &raws, &expected, &format!("{op_id}-check"))?;
        Some(changes.iter().cloned().partition(|change| {
            let now = disk.get(&change.raw).cloned().flatten();
            let wanted = expected.get(&change.raw);
            // A directory the operation's own deletions emptied is gone
            // from disk: it held what it should, file by file.
            now.as_ref() == wanted
                || (now.is_none() && wanted.is_some_and(|entry| *entry == directory_entry()))
        }))
    }

    /// Reads the planned paths again once the write pass finishes: each
    /// holds what the restore wrote there, or another writer changed it
    /// since. That writer's change is kept, and what the restore wrote
    /// elsewhere goes back: a restore is whole or not at all.
    pub(super) fn verify(
        &self,
        journal: &RestoreJournal,
        lock: &ExclusiveLock,
        written_aside: Vec<FailedPath>,
        in_rollback: &dyn Fn(Moment),
    ) -> Result<RestoreStage, Refusal> {
        let reading = self.read_planned(journal)?;
        if reading
            .paths
            .iter()
            .all(|path| path.state == PathState::Target)
        {
            return Ok(
                settled_stage(&reading, StageReason::KeptAside, written_aside)
                    .unwrap_or(RestoreStage::Applied),
            );
        }
        let edited: Vec<String> = reading
            .paths
            .iter()
            .filter(|path| path.state != PathState::Target)
            .map(|path| path.change.display.clone())
            .collect();
        let back: Vec<Change> = reading
            .paths
            .iter()
            .filter(|path| path.state == PathState::Target)
            .map(|path| path.back.clone())
            .collect();
        // A file another writer made where a directory goes back is not
        // written over: that path keeps what the restore wrote.
        // Asked of all of them at once, so a file the rollback itself
        // deletes is not in its own way.
        let in_the_way: HashSet<String> = self.in_the_way(&back).into_iter().collect();
        let (blocked, back): (Vec<Change>, Vec<Change>) = back.into_iter().partition(|change| {
            path_from_bytes(&change.raw).is_some_and(|relative| {
                relative
                    .ancestors()
                    .any(|path| in_the_way.contains(path.to_string_lossy().as_ref()))
            })
        });
        // Only what still holds the restore's content goes back. A prompt
        // waiting goes first: what is not put back yet stays as the restore
        // wrote it, and the record says so. A path the rollback could not
        // write, or all of them when git could not read the tree, is in the
        // record with why.
        let mut is_stopped = false;
        let mut failed = written_aside;
        match Writer::new(self, &journal.op_id, &journal.before_tree, "back")
            .map(|writer| writer.with_between(in_rollback))
        {
            Some(mut writer) => {
                let batches = Self::write_batches(
                    &mut writer,
                    &journal.target_tree,
                    &back,
                    lock,
                    &mut |_| {},
                );
                is_stopped = batches.stopped.is_some();
                failed.extend(batches.failed);
                failed.extend(writer.finish());
            }
            None => failed.extend(failed_all(&back, "read-tree")),
        }
        let after = self.read_planned(journal)?;
        // The stage is what the paths hold now; a failure is said only of a
        // path that still holds what the restore wrote.
        let still_written: HashSet<&str> = after
            .paths
            .iter()
            .filter(|path| path.state == PathState::Target)
            .map(|path| path.change.display.as_str())
            .collect();
        failed.retain(|failed| {
            failed.kept_at().is_some() || still_written.contains(failed.path.as_str())
        });
        let has_kept_aside = failed.iter().any(|failed| failed.kept_at().is_some());
        if !has_kept_aside && still_written.is_empty() {
            return Ok(RestoreStage::Aborted {
                reason: StageReason::ExternalChangeDetected,
            });
        }
        Ok(RestoreStage::PartiallyApplied {
            // Stopped for a prompt, the rollback left the rest as written.
            reason: if is_stopped {
                StageReason::AgentStarted
            } else {
                StageReason::ExternalChangeDetected
            },
            current_tree: after.current_tree,
            kept: edited,
            failed: blocked
                .into_iter()
                .map(|change| FailedPath {
                    path: change.display,
                    reason: FailedReason::InTheWay,
                    detail: None,
                })
                .chain(failed)
                .collect(),
        })
    }

    /// Settles each journal a crash left unfinished, by what its planned
    /// paths hold now: all as it writes them, all as before, or neither. A
    /// finished undo whose restore is not marked yet (a crash came between
    /// the two writes) marks it.
    pub(super) fn settle_interrupted(&self, now: &str) -> Vec<String> {
        let mut settled = Vec::new();
        // One that could not be read stays as it is on disk for a later
        // call; the others are settled all the same.
        for mut journal in self.readable_journals().0 {
            if !journal.is_writable() || !journal.stage.is_interrupted() {
                continue;
            }
            let raws: Vec<Vec<u8>> = journal
                .planned_paths
                .iter()
                .map(|planned| planned.path.as_bytes().to_vec())
                .collect();
            let (Some(before), Some(after)) = (
                self.entries(&journal.before_tree, &raws),
                self.entries(&journal.expected_after_tree, &raws),
            ) else {
                continue;
            };
            // The staging area first: a save it puts back at its path is
            // what that path holds now. One that is not the worktree's own
            // directory is left, and the operation with it.
            let Some(kept) = self.recover_staging(&journal.op_id, &before, &after) else {
                // Said once for this reading: otherwise nothing tells why
                // the operation is still unsettled. The id only; the path
                // is the person's.
                eprintln!(
                    "restore {}: its staging area is not a plain directory of the worktree; left as it is",
                    journal.op_id
                );
                continue;
            };
            let Ok(reading) = self.read_planned(&journal) else {
                continue;
            };
            journal.stage = settled_stage(&reading, StageReason::Interrupted, kept)
                .unwrap_or(RestoreStage::Applied);
            now.clone_into(&mut journal.at);
            if self.write_journal(&journal).is_ok() {
                self.release_finished_refs(&journal);
                settled.push(journal.op_id.clone());
            }
            for side in ["expected", "target", "current", "back", "check"] {
                let _ = fs::remove_file(self.index(&format!("{}-{side}", journal.op_id)));
            }
        }
        for undo in self.readable_journals().0 {
            if !is_whole(&undo.stage) {
                continue;
            }
            let Some(restored) = undo
                .undoes
                .as_deref()
                .and_then(|op| self.journal(op).ok().flatten())
            else {
                continue;
            };
            if restored.is_writable() && !matches!(restored.stage, RestoreStage::Undone { .. }) {
                self.mark_undone(restored, &undo.op_id, now);
            }
        }
        settled
    }
}

/// What `write_batches` came to.
#[derive(Default)]
pub(super) struct BatchesWritten {
    /// The paths written, in order.
    done: Vec<String>,
    /// The paths whose write failed, with how.
    failed: Vec<FailedPath>,
    /// The hook's ask that stopped the writing, if one did.
    stopped: Option<Interruption>,
}

pub(super) enum Written {
    /// Every path written, or left to another writer for the check to
    /// find, with the saves kept aside.
    All(Vec<FailedPath>),
    /// Stopped before the end, with the saves kept aside so far.
    Stopped(Interruption, Vec<FailedPath>),
    Failed(Vec<FailedPath>),
}

/// How an operation that did not finish stands, by what its planned paths
/// hold now: `None` when every one holds what it writes (it is applied),
/// aborted when every one holds what was there before, else partly applied,
/// with the paths that hold neither kept as they are. `failed` says why
/// paths were not written, beside the stage and never instead of it: a
/// failed write whose path holds what the stage says needs no saying, and
/// is left out.
pub(super) fn settled_stage(
    reading: &Reading,
    reason: StageReason,
    mut failed: Vec<FailedPath>,
) -> Option<RestoreStage> {
    let states: Vec<PathState> = reading.paths.iter().map(|path| path.state).collect();
    let is_all_target = states.iter().all(|state| *state == PathState::Target);
    let is_all_before = states.iter().all(|state| *state == PathState::Before);
    // A save kept aside is never "applied" nor "aborted": the record has to
    // say where it is, whatever the paths hold.
    let has_kept_aside = failed.iter().any(|failed| failed.kept_at().is_some());
    if !has_kept_aside && is_all_target {
        return None;
    }
    if !has_kept_aside && is_all_before {
        return Some(RestoreStage::Aborted { reason });
    }
    let unwritten: HashSet<&str> = reading
        .paths
        .iter()
        .filter(|path| path.state != PathState::Target)
        .map(|path| path.change.display.as_str())
        .collect();
    failed.retain(|failed| failed.kept_at().is_some() || unwritten.contains(failed.path.as_str()));
    // Every path as the operation writes it, and saves kept aside: the
    // operation is whole, and only those need saying.
    let reason = if is_all_target {
        StageReason::KeptAside
    } else {
        reason
    };
    Some(RestoreStage::PartiallyApplied {
        reason,
        current_tree: reading.current_tree.clone(),
        kept: reading
            .paths
            .iter()
            .filter(|path| path.state == PathState::Other)
            .map(|path| path.change.display.clone())
            .collect(),
        failed,
    })
}

/// Every one of `changes`, as not written because `step` failed for all.
pub(super) fn failed_all(changes: &[Change], step: &str) -> Vec<FailedPath> {
    changes
        .iter()
        .map(|change| FailedPath {
            path: change.display.clone(),
            reason: FailedReason::WriteFailed,
            detail: Some(step.to_owned()),
        })
        .collect()
}

/// The changes in batches of `WRITE_BATCH`, one path at a time once a batch
/// took longer than `SLOW_BATCH`: a slow filter or file system would
/// otherwise keep a waiting hook past its limit.
pub(super) struct Batches<'a> {
    changes: &'a [Change],
    position: usize,
    size: usize,
}

impl<'a> Batches<'a> {
    fn new(changes: &'a [Change]) -> Self {
        Self {
            changes,
            position: 0,
            size: WRITE_BATCH,
        }
    }

    fn next_batch(&mut self) -> Option<&'a [Change]> {
        if self.position >= self.changes.len() {
            return None;
        }
        let end = (self.position + self.size).min(self.changes.len());
        let batch = &self.changes[self.position..end];
        self.position = end;
        Some(batch)
    }

    fn took(&mut self, elapsed: Duration) {
        if elapsed > SLOW_BATCH {
            self.size = 1;
        }
    }
}
