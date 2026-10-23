//! Discarding hunks the review showed: taking them back out of the
//! files as they are now, under the same lock, journal, and undo as a
//! restore (`RestoreOperation::Discard`).
//!
//! The review diffs one turn range, its first turn's start against its
//! last turn's end. A discard diffs the same two trees again, with the
//! options the review uses, and finds each hunk by its `@@` line, so what
//! is taken back is the hunk the person saw. Each is then looked for in its
//! file as the working tree holds it now (`hunks::reverse`): a hunk whose
//! lines changed since, by a later turn or by hand, is reported and left in
//! place, and the others are written as one operation. Undone, the files go
//! back to what they held before the discard (`undo_restore`).

use super::{
    Change, Entry, NO_SEAMS, PathState, Plan, Refusal, StateDirectory, Worktree, git_failed,
    new_op_id, stop_if_asked,
};
use crate::git::{GitScope, GitSnapshots, is_object_id};
use crate::hunks::{self, Text};
use limpid_agent_model::{PathChangeKind, RestoreJournal, RestoreOperation, RestoreStage};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

/// What to discard, as JSON from the app.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscardRequest {
    pub root: PathBuf,
    /// The trees the review diffed: the range's first turn's start and its
    /// last turn's end.
    pub from_tree: String,
    pub to_tree: String,
    /// The range's last turn, which the journal names.
    pub turn_id: String,
    #[serde(default)]
    pub turn_number: Option<u32>,
    pub pane_id: String,
    pub files: Vec<DiscardFile>,
    #[serde(default)]
    pub state_directories: Vec<StateDirectory>,
}

/// The hunks of one file to discard, by their `@@` lines.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscardFile {
    pub path: String,
    pub hunks: Vec<String>,
}

/// How a discard ended.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "outcome")]
pub enum DiscardOutcome {
    /// Nothing was written: why.
    Refused { refusal: Refusal },
    /// Each hunk's result; the journal when anything was written.
    Finished {
        journal: Option<Box<RestoreJournal>>,
        hunks: Vec<HunkResult>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HunkResult {
    pub path: String,
    pub header: String,
    pub result: HunkOutcome,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HunkOutcome {
    /// Taken out of the file.
    Discarded,
    /// Its lines are not in the file as the review showed them: a later
    /// turn or a hand changed them, or the range's diff no longer has it.
    NotFound,
    /// Its file holds what it held: the discard stopped or failed before
    /// writing it, or another writer changed a file of the discard while it
    /// ran and the discard took the rest back.
    NotWritten,
    /// How it ended could not be read again, or its file holds neither
    /// what it held nor what the discard wrote: it may have been written.
    Unknown,
    /// Git converts the file on checkout (line endings, a filter), so it
    /// could not be written back byte for byte.
    Converted,
    /// A link, a submodule, or a directory is there now, or the file's
    /// kind changed since the range: no line of it is the hunk's.
    Unsupported,
}

/// Discards the hunks `request` names.
#[must_use]
pub fn discard_hunks(request: &DiscardRequest, now: &str) -> DiscardOutcome {
    let _git = GitScope::begin();
    match discard_inner(request, now) {
        Ok((journal, hunks)) => DiscardOutcome::Finished {
            journal: journal.map(Box::new),
            hunks,
        },
        Err(refusal) => DiscardOutcome::Refused { refusal },
    }
}

type Discarded = (Option<RestoreJournal>, Vec<HunkResult>);

fn discard_inner(request: &DiscardRequest, now: &str) -> Result<Discarded, Refusal> {
    if !is_object_id(&request.from_tree) || !is_object_id(&request.to_tree) {
        return Err(Refusal::TurnNotCaptured);
    }
    let worktree = Worktree::open(&request.root)?;
    let lock = worktree.lock()?;
    let _ = worktree.settle_interrupted(now);
    worktree.check_agents(&request.state_directories)?;
    worktree.check_no_merge()?;
    let context = worktree.context();
    let op_id = new_op_id();
    let before_tree = worktree.capture(&format!("{op_id}-before"))?;
    stop_if_asked(&lock)?;
    let mut results = Vec::new();
    let mut edits = Vec::new();
    for file in &request.files {
        let (edit, file_results) = worktree.discard_in(&before_tree, request, file)?;
        results.extend(file_results);
        edits.extend(edit);
    }
    if edits.is_empty() {
        return Ok((None, results));
    }
    let target_tree = worktree
        .tree_with(&before_tree, &edits, &format!("{op_id}-target"))
        .ok_or_else(|| git_failed("target tree"))?;
    let changes = worktree
        .changes(&before_tree, &target_tree)
        .ok_or_else(|| git_failed("diff-tree"))?;
    worktree.check_writable(&changes)?;
    stop_if_asked(&lock)?;
    let plan = Plan {
        op_id,
        operation: RestoreOperation::Discard,
        turn_id: request.turn_id.clone(),
        turn_number: request.turn_number,
        pane_id: request.pane_id.clone(),
        undoes: None,
        context,
        before_tree,
        target_tree,
        changes,
        recorded_untracked: Vec::new(),
    };
    let journal = worktree.run(plan, &lock, now, &NO_SEAMS)?;
    // A file that holds what it held keeps its hunks; one that holds
    // neither, or could not be read again, may hold part of the discard,
    // and keeps its undo.
    if journal.stage != RestoreStage::Applied {
        let states: Option<HashMap<String, PathState>> =
            worktree.read_planned(&journal).ok().map(|reading| {
                reading
                    .paths
                    .into_iter()
                    .map(|path| (path.change.display, path.state))
                    .collect()
            });
        for result in &mut results {
            if result.result != HunkOutcome::Discarded {
                continue;
            }
            result.result = match states.as_ref().and_then(|states| states.get(&result.path)) {
                Some(PathState::Target) => HunkOutcome::Discarded,
                Some(PathState::Before) => HunkOutcome::NotWritten,
                Some(PathState::Other) | None => HunkOutcome::Unknown,
            };
        }
    }
    Ok((Some(journal), results))
}

impl Worktree {
    /// The hunks of `file` taken back out of what `before` (the working
    /// tree, as captured) holds: the change to write, if any hunk was, and
    /// each hunk's result.
    fn discard_in(
        &self,
        before: &str,
        request: &DiscardRequest,
        file: &DiscardFile,
    ) -> Result<(Option<Change>, Vec<HunkResult>), Refusal> {
        let raw = file.path.as_bytes().to_vec();
        let patch = self
            .range_patch(&request.from_tree, &request.to_tree, &file.path)
            .ok_or_else(|| git_failed("diff"))?;
        let hunks = hunks::parse(&patch).ok_or_else(|| git_failed("diff"))?;
        let chosen: Vec<Option<usize>> = file
            .hunks
            .iter()
            .map(|header| {
                let header = hunks::ranges(header);
                hunks.iter().position(|hunk| hunk.header == header)
            })
            .collect();
        let now = self.entry(before, &raw)?;
        let result = |header: &String, outcome| HunkResult {
            path: file.path.clone(),
            header: header.clone(),
            result: outcome,
        };
        if let Some(outcome) = self.unfit(
            &file.path,
            now.as_ref(),
            self.entry(&request.to_tree, &raw)?.as_ref(),
        )? {
            let results = file
                .hunks
                .iter()
                .map(|header| result(header, outcome))
                .collect();
            return Ok((None, results));
        }
        let current = match &now {
            Some(entry) => Text::from_bytes(
                &self
                    .blob(&entry.object)
                    .ok_or_else(|| git_failed("cat-file"))?,
            ),
            None => Text::from_bytes(b""),
        };
        let indices: Vec<usize> = chosen.iter().flatten().copied().collect();
        let (text, outcomes) = hunks::reverse(current, &hunks, &indices);
        let mut outcomes = outcomes.into_iter();
        let results: Vec<HunkResult> = file
            .hunks
            .iter()
            .zip(&chosen)
            .map(|(header, index)| {
                let outcome = match index.and_then(|_| outcomes.next()) {
                    Some(Ok(())) => HunkOutcome::Discarded,
                    _ => HunkOutcome::NotFound,
                };
                result(header, outcome)
            })
            .collect();
        if !results
            .iter()
            .any(|hunk| hunk.result == HunkOutcome::Discarded)
        {
            return Ok((None, results));
        }
        let started = self.entry(&request.from_tree, &raw)?;
        // A file the range added, every line of it taken back, goes.
        if text.is_empty() && started.is_none() {
            let change = now.map(|_| Change {
                raw,
                display: file.path.clone(),
                kind: PathChangeKind::Delete,
                mode: "000000".to_owned(),
                object: String::new(),
            });
            return Ok((change, results));
        }
        let object = self
            .write_blob(&text.into_bytes())
            .ok_or_else(|| git_failed("hash-object"))?;
        let mode = now
            .as_ref()
            .or(started.as_ref())
            .map_or_else(|| "100644".to_owned(), |entry| entry.mode.clone());
        let change = Change {
            raw,
            display: file.path.clone(),
            kind: if now.is_some() {
                PathChangeKind::Modify
            } else {
                PathChangeKind::Add
            },
            mode,
            object,
        };
        Ok((Some(change), results))
    }

    /// One file's patch between two trees, with the review's output options
    /// (`ReviewGit.diffOptions`) and three lines of context: the hunks and
    /// their `@@` lines are the ones the review showed. The review's rename
    /// detection (`-M`) and submodule options are left out, as they change
    /// nothing for a file whose hunks can be discarded: the review offers
    /// no discard of a renamed file (`ReviewHunkDiscardRules`), and with one
    /// path named there is nothing to pair; a submodule has no hunks.
    pub(super) fn range_patch(&self, from: &str, to: &str, path: &str) -> Option<Vec<u8>> {
        GitSnapshots::run(
            &self.root,
            &[
                "--literal-pathspecs",
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--no-color",
                "--src-prefix=a/",
                "--dst-prefix=b/",
                "--output-indicator-new=+",
                "--output-indicator-old=-",
                "--output-indicator-context= ",
                "--unified=3",
                from,
                to,
                "--",
                path,
            ],
            None,
        )
    }

    /// What `tree` has at `raw`.
    fn entry(&self, tree: &str, raw: &[u8]) -> Result<Option<Entry>, Refusal> {
        Ok(self
            .entries(tree, &[raw.to_vec()])
            .ok_or_else(|| git_failed("read trees"))?
            .remove(raw))
    }

    /// Why no hunk of the file at `path` can be taken back, `now` being what
    /// the working tree holds there and `ended` what the range ended with:
    /// a directory, a submodule, or a link there holds no line of the file,
    /// nor does a file whose kind changed since the range; and a file git
    /// converts could not be written back as it is.
    fn unfit(
        &self,
        path: &str,
        now: Option<&Entry>,
        ended: Option<&Entry>,
    ) -> Result<Option<HunkOutcome>, Refusal> {
        let Some(now) = now else { return Ok(None) };
        if matches!(now.mode.as_str(), "040000" | "160000" | "120000")
            || ended.is_some_and(|ended| ended.mode != now.mode)
        {
            return Ok(Some(HunkOutcome::Unsupported));
        }
        Ok(self
            .is_converted(path, now)?
            .then_some(HunkOutcome::Converted))
    }

    /// Whether git converts the file between the working tree and its blob
    /// (line endings, a filter): what is on disk is not the blob, or a
    /// checkout of the blob would not write it back as it is. Its hunks
    /// are taken back in the blob, so the file could not be written back
    /// byte for byte, nor its undo.
    fn is_converted(&self, path: &str, entry: &Entry) -> Result<bool, Refusal> {
        let blob = self
            .blob(&entry.object)
            .ok_or_else(|| git_failed("cat-file"))?;
        let on_disk = std::fs::read(self.root.join(path)).map_err(|_| git_failed("read"))?;
        if on_disk != blob {
            return Ok(true);
        }
        let path = format!("--path={path}");
        let checked_out = GitSnapshots::run(
            &self.root,
            &["cat-file", "--filters", &path, &entry.object],
            None,
        )
        .ok_or_else(|| git_failed("cat-file"))?;
        Ok(checked_out != blob)
    }

    /// The files of `changes` a checkout would not write as their blobs
    /// are (line endings, a filter, set since the discard): its undo
    /// writes blobs back, and would not give the file its bytes again.
    pub(super) fn converted_on_checkout(&self, changes: &[Change]) -> Result<Vec<String>, Refusal> {
        let mut converted = Vec::new();
        for change in changes
            .iter()
            .filter(|change| !change.is_deletion() && change.mode.starts_with("100"))
        {
            let blob = self
                .blob(&change.object)
                .ok_or_else(|| git_failed("cat-file"))?;
            let path = format!("--path={}", change.display);
            let checked_out = GitSnapshots::run(
                &self.root,
                &["cat-file", "--filters", &path, &change.object],
                None,
            )
            .ok_or_else(|| git_failed("cat-file"))?;
            if checked_out != blob {
                converted.push(change.display.clone());
            }
        }
        Ok(converted)
    }

    pub(super) fn blob(&self, object: &str) -> Option<Vec<u8>> {
        GitSnapshots::run(&self.root, &["cat-file", "blob", object], None)
    }

    /// Stores `bytes` as they are: they are a blob's own content, already
    /// past the filters a checkout applies.
    fn write_blob(&self, bytes: &[u8]) -> Option<String> {
        GitSnapshots::run_with_input_index(
            &self.root,
            &["hash-object", "-w", "--no-filters", "--stdin"],
            bytes,
            None,
        )
        .map(|stdout| String::from_utf8_lossy(&stdout).trim().to_owned())
        .filter(|object| is_object_id(object))
    }
}
