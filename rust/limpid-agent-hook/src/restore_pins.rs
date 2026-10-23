//! The refs that pin the trees a journal names, and the files under
//! the common git directory that say which refs an operation may hold, so a
//! crash between a ref and its journal leaves a name to sweep by.

use super::journal::{StoreError, is_final};
use super::{GitSnapshots, Worktree, is_object_id, is_op_id, is_there, same_path};
use crate::records::{atomic_write, ensure_user_only_directory};
use limpid_agent_model::{
    RESTORE_DIRECTORY, RESTORE_JOURNAL_FILE_SUFFIX, RestoreJournal, restore_current_ref,
    restore_refs,
};
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

/// Where the files that say an operation may hold refs live, under the
/// repository's common git directory (`<common>/limpid/`). A file is made,
/// with the refs it is about to pin, before the first of them, and removed
/// after the last, so a crash between a ref and its journal leaves a name
/// to sweep by. It does not say the refs are there, only that they may be.
///
/// Refs are shared by every worktree of a repository and journals are not:
/// each file names the git directory of the worktree whose journal it
/// serves, and only that worktree sweeps it, under its own lock, while the
/// worktree is there. Once git removes the worktree, its journals are gone
/// with it, and any worktree of the repository drops its refs.
///
/// A journal with no file here is not migrated: only earlier development
/// builds wrote one, as no release before them has the restore. Its refs go by
/// name with it, as every operation's do (`release_refs`).
pub(super) const REFS_DIRECTORY: &str = "restore-refs";

/// What a file in `REFS_DIRECTORY` ends with; the rest is its operation id.
pub(super) const REFS_FILE_SUFFIX: &str = ".refs";

/// The refs an operation may hold all start so, and a name read from a
/// file in `REFS_DIRECTORY` is dropped only when it does.
pub(super) const RESTORE_REF_PREFIX: &str = "refs/limpid/undo";

impl Worktree {
    /// This worktree's git directory as the files in `REFS_DIRECTORY` name
    /// it: from the common git directory, where those files are too, so the
    /// name holds when the repository moves. `.` for the main worktree,
    /// `worktrees/<name>` for a linked one; `None` when the git directory
    /// is neither, or its name does not lead back to it (a name that is not
    /// UTF-8 would be written lossily), and nothing is pinned.
    pub(super) fn owner(&self) -> Option<String> {
        let name = if same_path(&self.git_dir, &self.common_dir) {
            ".".to_owned()
        } else {
            let parent = self.git_dir.parent()?;
            let is_linked = parent.file_name().is_some_and(|name| name == "worktrees")
                && parent
                    .parent()
                    .is_some_and(|common| same_path(common, &self.common_dir));
            if !is_linked {
                return None;
            }
            format!("worktrees/{}", self.git_dir.file_name()?.to_str()?)
        };
        // On disk, not as text: `rev-parse` gave both paths lossily, so a
        // name that is not UTF-8 reads the same in each and leads nowhere.
        let resolved = fs::canonicalize(self.common_dir.join(&name)).ok()?;
        (is_worktree_name(&name) && fs::canonicalize(&self.git_dir).ok()? == resolved)
            .then_some(name)
    }

    /// The name a file in `REFS_DIRECTORY` gives its worktree. A file
    /// earlier development builds wrote names the absolute git directory: one
    /// in this repository's common directory reads as its name there, and
    /// one elsewhere (the repository moved since) as no name, whose refs
    /// stay.
    pub(super) fn owner_named(&self, owner: &NotedOwner) -> Option<String> {
        match owner {
            NotedOwner::Name(name) => is_worktree_name(name).then(|| name.clone()),
            NotedOwner::Path(path) => {
                if same_path(path, &self.common_dir) {
                    return Some(".".to_owned());
                }
                let parent = path.parent()?;
                let is_linked = parent.file_name().is_some_and(|name| name == "worktrees")
                    && parent
                        .parent()
                        .is_some_and(|common| same_path(common, &self.common_dir));
                let name = format!("worktrees/{}", path.file_name()?.to_str()?);
                (is_linked && is_worktree_name(&name)).then_some(name)
            }
        }
    }

    /// Whether a worktree of the repository other than this one has a
    /// journal of `op_id`; `None` when the worktrees cannot be listed, which
    /// counts as yes.
    pub(super) fn is_journaled_elsewhere(&self, op_id: &str) -> Option<bool> {
        let mut git_dirs = vec![self.common_dir.clone()];
        match fs::read_dir(self.common_dir.join("worktrees")) {
            Ok(entries) => {
                for entry in entries {
                    git_dirs.push(entry.ok()?.path());
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return None,
        }
        let file = format!("{op_id}{RESTORE_JOURNAL_FILE_SUFFIX}");
        Some(git_dirs.iter().any(|git_dir| {
            !same_path(git_dir, &self.git_dir)
                && is_there(&git_dir.join("limpid").join(RESTORE_DIRECTORY).join(&file))
        }))
    }

    /// Whether the worktree a file in `REFS_DIRECTORY` names is one git has
    /// removed, and its journals with it. Only a linked worktree's git
    /// directory goes; the main one never does.
    pub(super) fn is_removed(&self, name: &str) -> bool {
        name != "." && is_worktree_name(name) && !is_there(&self.common_dir.join(name))
    }

    pub(super) fn refs_directory(&self) -> PathBuf {
        self.common_dir.join("limpid").join(REFS_DIRECTORY)
    }

    pub(super) fn refs_file(&self, op_id: &str) -> PathBuf {
        self.refs_directory()
            .join(format!("{op_id}{REFS_FILE_SUFFIX}"))
    }

    /// Pins every tree `journal` names until nothing reads them again:
    /// what was there before, which an undo writes back; the target, which
    /// every later look at the planned paths compares with (a turn's own
    /// refs may go with the turn first); the expected tree, which recovery
    /// compares with; and the tree a partly applied restore found, which
    /// its undo compares with. An `undo-current` the stage no longer names
    /// (a crash after it was pinned, and recovery found the restore
    /// applied) goes in the same step, so the refs are the journal's. In
    /// one transaction: all or none.
    pub(super) fn pin_trees(&self, journal: &RestoreJournal) -> Result<(), StoreError> {
        let pinned = checked_trees(journal).ok_or(StoreError::Unpinnable)?;
        let noted = self
            .noted(&journal.op_id)
            .map(|noted| noted.names)
            .unwrap_or_default();
        self.note_refs(&journal.op_id, &noted, &pinned)?;
        let mut commands: Vec<String> = pinned
            .iter()
            .map(|(name, tree)| format!("update {name} {tree}\n"))
            .collect();
        // Only when the file says it may be there: a `delete` takes
        // `packed-refs.lock` even for a ref that is not, and every restore
        // would be refused while something else holds it.
        let current = restore_current_ref(&journal.op_id);
        if noted.contains(&current) && !pinned.iter().any(|(name, _)| *name == current) {
            commands.push(format!("delete {current}\n"));
        }
        if self.update_refs(&commands.concat()) {
            Ok(())
        } else {
            Err(StoreError::UpdateRef)
        }
    }

    pub(super) fn update_refs(&self, commands: &str) -> bool {
        GitSnapshots::run_with_input_index(
            &self.root,
            &["update-ref", "--stdin"],
            commands.as_bytes(),
            None,
        )
        .is_some()
    }

    /// Writes the file that says the operation may hold refs, with the
    /// refs it is about to pin added to `noted`, those it names already,
    /// before the first of them. Refused, and nothing is pinned, when this
    /// worktree has no name the file can give it (`owner`).
    pub(super) fn note_refs(
        &self,
        op_id: &str,
        noted: &BTreeSet<String>,
        pinned: &[(String, &str)],
    ) -> Result<(), StoreError> {
        let file = self.refs_file(op_id);
        let mut names = noted.clone();
        names.extend(pinned.iter().map(|(name, _)| name.clone()));
        if is_there(&file) && names.len() == noted.len() {
            return Ok(());
        }
        let owner = self.owner().ok_or(StoreError::NoOwner)?;
        let contents = std::iter::once(format!("owner {owner}\n"))
            .chain(names.iter().map(|name| format!("ref {name}\n")))
            .collect::<Vec<_>>()
            .concat();
        ensure_user_only_directory(&self.refs_directory());
        atomic_write(&file, contents.as_bytes()).map_err(StoreError::RefsFile)
    }

    /// What the file for `op_id` says, if there is one.
    pub(super) fn noted(&self, op_id: &str) -> Option<Noted> {
        let contents = fs::read_to_string(self.refs_file(op_id)).ok()?;
        Some(Noted::parse(op_id, &contents))
    }

    /// Drops the refs of an operation, which would pin its trees for good,
    /// and then the file that names them: a crash between the two leaves
    /// the file, and a later sweep drops what is left. The refs are those
    /// the file names, so a later build's refs go too, and every one this
    /// build makes, for a file that names none. When git refuses one of the
    /// file's names, the ones this build makes go on their own, and the
    /// file stays.
    pub(super) fn release_refs(&self, op_id: &str) {
        let deletes = |names: &BTreeSet<String>| {
            names
                .iter()
                .map(|name| format!("delete {name}\n"))
                .collect::<Vec<_>>()
                .concat()
        };
        let mut names = self
            .noted(op_id)
            .map(|noted| noted.names)
            .unwrap_or_default();
        let ours: BTreeSet<String> = restore_refs(op_id).into_iter().collect();
        names.extend(ours.iter().cloned());
        if self.update_refs(&deletes(&names)) {
            let _ = fs::remove_file(self.refs_file(op_id));
        } else if names != ours {
            let _ = self.update_refs(&deletes(&ours));
        }
    }

    /// The operations whose refs nothing reads any more. Read without the
    /// lock to tell whether to take it, and again under it to act.
    ///
    /// Journals no file in `REFS_DIRECTORY` names are not looked for, nor
    /// pinned after the fact: only earlier development builds wrote them (no
    /// release before them has the restore), and they keep the two refs those
    /// builds made, which go by name with the journal (`release_refs`).
    pub(super) fn leftover_refs(&self) -> Vec<String> {
        let mut leftover = Vec::new();
        let owner = self.owner();
        let Ok(entries) = fs::read_dir(self.refs_directory()) else {
            return leftover;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(op_id) = name.strip_suffix(REFS_FILE_SUFFIX) else {
                continue;
            };
            if !is_op_id(op_id) {
                continue;
            }
            // A file that names no worktree we can place is left with its
            // refs.
            let Some(noted_by) = self
                .noted(op_id)
                .and_then(|noted| noted.owner)
                .and_then(|noted_by| self.owner_named(&noted_by))
            else {
                continue;
            };
            let is_leftover = if owner.as_ref() == Some(&noted_by) {
                // A file that is there but not one this build reads may be
                // a newer writer's journal: its refs stay.
                !is_there(&self.journal_path(op_id))
                    || self
                        .journal(op_id)
                        .ok()
                        .flatten()
                        .is_some_and(|journal| journal.is_writable() && is_final(&journal))
            } else {
                self.is_removed(&noted_by) && !is_there(&self.journal_path(op_id))
            };
            // Whatever the file says, a journal of the operation in another
            // worktree is live, and its refs stay: a damaged file must not
            // read a live worktree as removed.
            if is_leftover && self.is_journaled_elsewhere(op_id) == Some(false) {
                leftover.push(op_id.to_owned());
            }
        }
        leftover
    }

    /// Drops the refs a crash left behind (between an operation's refs and
    /// its journal, between dropping a journal and its refs, or between
    /// finishing one and dropping them) and those of a worktree git has
    /// removed. Under the lock, so no operation of this worktree is between
    /// its refs and its journal.
    pub(super) fn settle_refs(&self) {
        for op_id in self.leftover_refs() {
            self.release_refs(&op_id);
        }
    }

    /// Drops the refs of `journal` once nothing can take it back: aborted,
    /// undone, or an undo, which is not undone in turn.
    pub(super) fn release_finished_refs(&self, journal: &RestoreJournal) {
        if is_final(journal) {
            self.release_refs(&journal.op_id);
        }
    }
}

/// What a file in `REFS_DIRECTORY` says: the worktree whose journal it
/// serves, and the refs the operation may hold.
pub(super) struct Noted {
    pub(super) owner: Option<NotedOwner>,
    pub(super) names: BTreeSet<String>,
}

/// How a file in `REFS_DIRECTORY` names its worktree.
pub(super) enum NotedOwner {
    /// From the common git directory (`Worktree::owner`).
    Name(String),
    /// The absolute git directory, as earlier development builds wrote it.
    Path(PathBuf),
}

impl Noted {
    /// Reads a file: one `owner <name>` line (or `gitdir <path>`, from an
    /// earlier development build) and one `ref <name>` line per ref. A name
    /// that is not one of `op_id`'s restore refs is left out: a damaged file
    /// never drops a ref of anything else, nor one git refuses. A file with
    /// more than one owner line names no owner: which one is true cannot be
    /// told, and a wrong one could read a live worktree as removed.
    pub(super) fn parse(op_id: &str, contents: &str) -> Self {
        let mut owners = Vec::new();
        let mut names = BTreeSet::new();
        for line in contents.lines() {
            if let Some(name) = line.strip_prefix("owner ") {
                owners.push(NotedOwner::Name(name.to_owned()));
            } else if let Some(path) = line.strip_prefix("gitdir ") {
                owners.push(NotedOwner::Path(PathBuf::from(path)));
            } else if let Some(name) = line.strip_prefix("ref ")
                && is_restore_ref(name, op_id)
            {
                names.insert(name.to_owned());
            }
        }
        let owner = match <[NotedOwner; 1]>::try_from(owners) {
            Ok([owner]) => Some(owner),
            Err(_) => None,
        };
        Self { owner, names }
    }
}

/// Whether `name` is a restore ref of `op_id`, as this build or a later one
/// names it: `refs/limpid/undo/<op_id>`, or `refs/limpid/undo-<kind>/<op_id>`
/// with a kind of lower-case letters.
pub(super) fn is_restore_ref(name: &str, op_id: &str) -> bool {
    let Some(kind) = name
        .strip_prefix(RESTORE_REF_PREFIX)
        .and_then(|rest| rest.strip_suffix(op_id))
        .and_then(|rest| rest.strip_suffix('/'))
    else {
        return false;
    };
    kind.is_empty()
        || kind.strip_prefix('-').is_some_and(|kind| {
            !kind.is_empty() && kind.bytes().all(|byte| byte.is_ascii_lowercase())
        })
}

/// Whether `name` is how a file in `REFS_DIRECTORY` may name a worktree:
/// `.`, or `worktrees/<name>` with one plain component, so joined to the
/// common git directory it stays inside it.
pub(super) fn is_worktree_name(name: &str) -> bool {
    name == "."
        || name.strip_prefix("worktrees/").is_some_and(|name| {
            !name.is_empty()
                && name != "."
                && name != ".."
                && !name
                    .chars()
                    .any(|character| character == '/' || character.is_control())
        })
}

/// The trees `journal` names with their refs, when every one is fit for an
/// `update-ref --stdin` line: an operation id for the name, and an object
/// id for the tree. A journal is ours to write, but a damaged one must not
/// make a line that deletes a ref (an empty value, or all zeros) or adds a
/// command (a line break).
pub(super) fn checked_trees(journal: &RestoreJournal) -> Option<Vec<(String, &str)>> {
    let pinned = journal.pinned_trees();
    (is_op_id(&journal.op_id) && pinned.iter().all(|(_, tree)| is_object_id(tree)))
        .then_some(pinned)
}
