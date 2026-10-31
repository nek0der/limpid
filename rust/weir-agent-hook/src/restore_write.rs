//! Writing the paths of one operation without writing over what another
//! writer put there: a restore, its undo, a rollback, a discard.
//!
//! Each path is made first under the operation's staging area,
//! `<root>/.weir-<op>/`, by `checkout-index` (so filters and line
//! endings are a checkout's), and then exchanged with what the path holds
//! (`swap::exchange`). What comes out is compared with what the path was
//! before git read it (a `Stamp`): a save that landed in between goes back,
//! and one that cannot is kept aside, never deleted. A file that came out
//! as read is kept until the operation ends and looked at again then, so a
//! write through a descriptor opened before the exchange is not lost
//! either. A crash leaves every written path whole, old or new; one taken
//! out for a deletion may be in the staging area, where recovery
//! (`recover_staging`) judges it with everything else the area holds.
//! The area ignores itself (`.gitignore`), so no capture, status, or
//! `git add -A` takes what it keeps.
//!
//! The staging area is inside the worktree so it is on the same volume as
//! every path (a worktree may be on another volume than its git
//! directory), and an operation is refused on a volume that cannot exchange
//! two names, or rename only onto nothing (`check_volume`): one that
//! claims to and overwrites (FAT) is caught by asking the volume, not by
//! trying.

use super::{Change, Refusal, Worktree, remove_empty_parents};
use crate::git::{GitSnapshots, path_from_bytes};
use crate::swap;
use std::collections::HashMap;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use weir_agent_model::{FailedPath, FailedReason};

/// Why a path the writer was given holds something other than what it
/// writes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Unwritten {
    /// Another writer changed the path after it was read; it is left as
    /// that writer made it, for the check afterwards to find.
    ChangedWhileWriting,
    /// Another writer's save came out of the path and could not go back:
    /// it is at this place in the staging area, relative to the worktree,
    /// and `Writer::finish` names it.
    KeptAside(String),
    /// The write failed; the text says how, for the journal's reader.
    Failed(String),
}
/// What the staging area's own `.gitignore` says: everything in it.
const IGNORE_ALL: &str = "*\n";

/// Where a test steps into a write: after git read a group, before any
/// of it is written; after a path was exchanged, before what came out is
/// looked at; and at the end, before the files taken out are looked at
/// again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Moment {
    AfterRead,
    AfterSwap,
    AtFinish,
}

/// What a path is on disk, as far as telling a later write goes: the same
/// file, at the same size, modified at the same moment, with the same
/// bytes. An editor's save changes one of them, whether it writes in place
/// or renames a new file over the path, and a write that puts the old
/// modification time back still changes the bytes. Not its change time,
/// which an exchange itself changes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Stamp {
    size_bytes: u64,
    modified: Option<std::time::SystemTime>,
    is_symlink: bool,
    is_directory: bool,
    /// A hash of the bytes (of a link, its target); `None` for a directory
    /// or what could not be read, which is never taken for unchanged.
    content_hash: Option<u64>,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    #[cfg(unix)]
    mode: u32,
}

impl Stamp {
    pub(super) fn of(path: &Path) -> Option<Self> {
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        let metadata = fs::symlink_metadata(path).ok()?;
        let content_hash = if metadata.file_type().is_symlink() {
            fs::read_link(path)
                .ok()
                .map(|target| hash_bytes(target.as_os_str().as_encoded_bytes()))
        } else if metadata.is_file() {
            hash_file(path)
        } else {
            None
        };
        Some(Self {
            size_bytes: metadata.len(),
            modified: metadata.modified().ok(),
            is_symlink: metadata.file_type().is_symlink(),
            is_directory: metadata.is_dir(),
            content_hash,
            #[cfg(unix)]
            device: metadata.dev(),
            #[cfg(unix)]
            inode: metadata.ino(),
            #[cfg(unix)]
            mode: metadata.mode(),
        })
    }

    /// Whether `other` is this, and this is known whole: a stamp whose
    /// bytes could not be read matches nothing.
    fn is_same(&self, other: &Self) -> bool {
        self.content_hash.is_some() && self == other
    }
}

/// A hash of `bytes`, for telling two readings of one path apart within
/// one operation, never stored.
fn hash_bytes(bytes: &[u8]) -> u64 {
    use std::hash::Hasher;
    let mut hasher = std::hash::DefaultHasher::new();
    hasher.write(bytes);
    hasher.finish()
}

/// A hash of the bytes of the file at `path`, read in pieces.
fn hash_file(path: &Path) -> Option<u64> {
    use std::hash::Hasher;
    use std::io::Read;
    let mut file = fs::File::open(path).ok()?;
    let mut hasher = std::hash::DefaultHasher::new();
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).ok()?;
        if read == 0 {
            return Some(hasher.finish());
        }
        hasher.write(&buffer[..read]);
    }
}

/// A file the operation took out of a path, kept until the operation ends.
struct Displaced {
    display: String,
    parked: PathBuf,
    /// What the path was before git read it, which the file must still be
    /// to go.
    seen: Stamp,
    raw: Vec<u8>,
    /// The tree whose content git read at the path: the file goes only if
    /// that tree gives its bytes back, raw or through a checkout's
    /// filters. A filter that reads two files the same (`ident`) would
    /// otherwise let a save go that no tree holds.
    expected: String,
}

/// Writes the paths of one operation from one tree (`index`), batch by
/// batch, and settles at the end what came out of them.
pub(super) struct Writer<'a> {
    worktree: &'a Worktree,
    op_id: String,
    index: PathBuf,
    staging: PathBuf,
    batch: usize,
    displaced: Vec<Displaced>,
    kept: Vec<FailedPath>,
    /// The tree the current `write` checks each path against.
    expected: String,
    /// Run at each `Moment`: a test's way to save a file then.
    between: &'a dyn Fn(Moment),
}

fn nothing(_: Moment) {}

impl<'a> Writer<'a> {
    /// A writer of `tree`'s content at the paths it is given. `side` names
    /// its private index and its part of the staging area (`target`,
    /// `back`). `None` when git cannot read the tree.
    pub(super) fn new(worktree: &'a Worktree, op_id: &str, tree: &str, side: &str) -> Option<Self> {
        let index = worktree.index(&format!("{op_id}-{side}"));
        let _ = fs::remove_file(&index);
        GitSnapshots::run(&worktree.root, &["read-tree", tree], Some(&index))?;
        let area = worktree.staging(op_id);
        Some(Self {
            worktree,
            op_id: op_id.to_owned(),
            index,
            staging: area.join(side),
            batch: 0,
            displaced: Vec::new(),
            kept: Vec::new(),
            expected: String::new(),
            between: &nothing,
        })
    }

    pub(super) fn with_between(mut self, between: &'a dyn Fn(Moment)) -> Self {
        self.between = between;
        self
    }

    /// Makes `under`, in the staging area, ignored by git, before anything
    /// goes in: each directory made or opened from the worktree without
    /// following a link, and the `.gitignore` only made new.
    fn prepare(&self, under: &Path) -> Result<(), String> {
        let root = &self.worktree.root;
        let area = self.worktree.staging(&self.op_id);
        let inside = under.strip_prefix(root).map_err(|_| "staging".to_owned())?;
        swap::make_directories(root, inside).map_err(|error| error.to_string())?;
        let ignore = area.join(".gitignore");
        if fs::symlink_metadata(&ignore).is_err() {
            let made = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&ignore)
                .and_then(|mut file| std::io::Write::write_all(&mut file, IGNORE_ALL.as_bytes()));
            if let Err(error) = made
                && error.kind() != ErrorKind::AlreadyExists
            {
                return Err(error.to_string());
            }
        }
        Ok(())
    }

    /// Writes `batch` where each path still holds what `expected` has
    /// there: the deletions first, then the rest, each group read just
    /// before it is written (a file renamed only in case is the same file
    /// to the volume, and must be gone before its new name is read).
    /// Returns what became of each path; one another writer changed since
    /// is left out, for the check afterwards to find, and one in a group
    /// git could not read is not written (`read`).
    pub(super) fn write(
        &mut self,
        expected: &str,
        batch: &[Change],
    ) -> Vec<(Change, Result<(), Unwritten>)> {
        let (deletions, writes): (Vec<Change>, Vec<Change>) =
            batch.iter().cloned().partition(Change::is_deletion);
        expected.clone_into(&mut self.expected);
        let mut results = Vec::new();
        for group in [deletions, writes] {
            if group.is_empty() {
                continue;
            }
            let seen: HashMap<Vec<u8>, Option<Stamp>> = group
                .iter()
                .map(|change| (change.raw.clone(), self.worktree.stamp(&change.raw)))
                .collect();
            let Some((unchanged, _moved)) =
                self.worktree.still_holding(expected, &group, &self.op_id)
            else {
                results.extend(
                    group
                        .into_iter()
                        .map(|change| (change, Err(Unwritten::Failed("read".to_owned())))),
                );
                continue;
            };
            (self.between)(Moment::AfterRead);
            let ready = if unchanged.iter().any(|change| !change.is_deletion()) {
                self.stage(&unchanged)
            } else {
                None
            };
            for change in unchanged {
                let seen = seen
                    .get(&change.raw)
                    .cloned()
                    .flatten()
                    .filter(|stamp| !stamp.is_directory);
                let result = if change.is_deletion() {
                    self.delete(&change, seen)
                } else {
                    match &ready {
                        Some(ready) => self.swap_in(&change, seen, ready),
                        None => Err(Unwritten::Failed("checkout-index".to_owned())),
                    }
                };
                results.push((change, result));
            }
        }
        results
    }

    /// Makes `changes` under a fresh `gen-<n>`, then names it `ready-<n>`
    /// in one rename, so recovery tells half-made files (in `gen-`, the
    /// writer's own, gone) from made ones. `None` when nothing could be
    /// made.
    fn stage(&mut self, changes: &[Change]) -> Option<PathBuf> {
        self.batch += 1;
        let made = self.staging.join(format!("gen-{}", self.batch));
        let ready = self.staging.join(format!("ready-{}", self.batch));
        self.prepare(&made).ok()?;
        // Made just now and gone to without a link; checked again right
        // before git writes under it, which follows the path it is given.
        let inside = made.strip_prefix(&self.worktree.root).ok()?;
        if !swap::is_plain_directory(&self.worktree.root, inside) {
            return None;
        }
        let prefix = format!("--prefix={}/", made.display());
        let args = ["checkout-index", "-f", "-z", "--stdin", prefix.as_str()];
        let paths = |changes: &[&Change]| -> Vec<u8> {
            changes
                .iter()
                .flat_map(|change| {
                    let mut path = change.raw.clone();
                    path.push(0);
                    path
                })
                .collect()
        };
        let writes: Vec<&Change> = changes
            .iter()
            .filter(|change| !change.is_deletion())
            .collect();
        let root = &self.worktree.root;
        if GitSnapshots::run_with_input_index(root, &args, &paths(&writes), Some(&self.index))
            .is_none()
        {
            // One at a time, to say which. A path not made, or made only
            // in part (a full disk), is missing from `ready-`, and
            // `swap_in` reports it.
            for change in &writes {
                let is_made = GitSnapshots::run_with_input_index(
                    root,
                    &args,
                    &paths(&[*change]),
                    Some(&self.index),
                )
                .is_some();
                if !is_made && let Some(relative) = path_from_bytes(&change.raw) {
                    let _ = fs::remove_file(made.join(relative));
                }
            }
        }
        fs::rename(&made, &ready).ok()?;
        Some(ready)
    }

    /// Takes a path the operation deletes out to `out/`, and keeps it
    /// there until the end if it is what was read; a save made after the
    /// read goes back.
    fn delete(&mut self, change: &Change, seen: Option<Stamp>) -> Result<(), Unwritten> {
        let relative =
            path_from_bytes(&change.raw).ok_or_else(|| Unwritten::Failed("path".to_owned()))?;
        let path = self.worktree.root.join(&relative);
        match fs::symlink_metadata(&path) {
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(Unwritten::Failed(error.to_string())),
            Ok(metadata) if metadata.is_dir() => {
                return Err(Unwritten::Failed("a directory".to_owned()));
            }
            Ok(_) => {}
        }
        let parked = self.staging.join("out").join(&relative);
        if let Some(parent) = parked.parent() {
            self.prepare(parent).map_err(Unwritten::Failed)?;
        }
        let root = &self.worktree.root;
        let inside = self.inside(&parked);
        swap::rename_new(root, &relative, &inside)
            .map_err(|error| Unwritten::Failed(error.to_string()))?;
        match (Stamp::of(&parked), seen) {
            (Some(out), Some(seen)) if out.is_same(&seen) => {
                remove_empty_parents(&self.worktree.root, &relative);
                self.displaced.push(Displaced {
                    display: change.display.clone(),
                    parked,
                    seen,
                    raw: change.raw.clone(),
                    expected: self.expected.clone(),
                });
                Ok(())
            }
            // Saved after the read: back where it was, unless something
            // took the path meanwhile, in which case it stays aside.
            _ => match swap::rename_new(root, &inside, &relative) {
                Ok(()) => Err(Unwritten::ChangedWhileWriting),
                Err(_) => Err(self.keep(&change.display, &parked)),
            },
        }
    }

    /// Exchanges a path with what `ready` holds for it. What comes out
    /// stays until the end if it is what was read; a save made after the
    /// read goes back, if the path is still what was put there.
    fn swap_in(
        &mut self,
        change: &Change,
        seen: Option<Stamp>,
        ready: &Path,
    ) -> Result<(), Unwritten> {
        let relative =
            path_from_bytes(&change.raw).ok_or_else(|| Unwritten::Failed("path".to_owned()))?;
        let path = self.worktree.root.join(&relative);
        let made = ready.join(&relative);
        let Some(ours) = Stamp::of(&made) else {
            return Err(Unwritten::Failed("checkout-index".to_owned()));
        };
        let root = self.worktree.root.clone();
        let made_inside = self.inside(&made);
        let now = fs::symlink_metadata(&path).ok();
        if now.as_ref().is_some_and(fs::Metadata::is_dir) {
            let _ = fs::remove_file(&made);
            return Err(Unwritten::Failed("a directory".to_owned()));
        }
        let Some(_) = now else {
            if seen.is_some() {
                // Deleted after it was read: the deletion stands.
                let _ = fs::remove_file(&made);
                return Err(Unwritten::ChangedWhileWriting);
            }
            if let Err(error) = swap::make_parents(&root, &relative) {
                let _ = fs::remove_file(&made);
                return Err(Unwritten::Failed(error.to_string()));
            }
            return swap::rename_new(&root, &made_inside, &relative).map_err(|error| {
                let _ = fs::remove_file(&made);
                if error.kind() == ErrorKind::AlreadyExists {
                    Unwritten::ChangedWhileWriting
                } else {
                    Unwritten::Failed(error.to_string())
                }
            });
        };
        if let Err(error) = swap::exchange(&root, &made_inside, &relative) {
            let is_made_ours = Stamp::of(&made).is_some_and(|now| now.is_same(&ours));
            let is_path_there = fs::symlink_metadata(&path).is_ok();
            if is_made_ours {
                // Nothing came out: the call failed (a lock flag, a link
                // in the way), or the path went before it ran, which is
                // another writer's deletion and stands.
                let _ = fs::remove_file(&made);
                return Err(if is_path_there {
                    Unwritten::Failed(error.to_string())
                } else {
                    Unwritten::ChangedWhileWriting
                });
            }
            // What is at `made` came out of the path and the path is gone
            // since: that is all there is of it, and it stays aside.
            if fs::symlink_metadata(&made).is_ok() && !is_path_there {
                return Err(self.keep(&change.display, &made));
            }
            if !is_path_there {
                return Err(Unwritten::Failed(error.to_string()));
            }
        }
        (self.between)(Moment::AfterSwap);
        match (Stamp::of(&made), seen) {
            (Some(out), Some(seen)) if out.is_same(&seen) => {
                self.displaced.push(Displaced {
                    display: change.display.clone(),
                    parked: made,
                    seen,
                    raw: change.raw.clone(),
                    expected: self.expected.clone(),
                });
                Ok(())
            }
            _ => {
                // Saved after the read: what came out is that save. It goes
                // back only while the path is still what was put there; a
                // save on top of that stays, and this one is kept aside.
                let is_ours = Stamp::of(&path).is_some_and(|now| now.is_same(&ours));
                if !is_ours || swap::exchange(&root, &made_inside, &relative).is_err() {
                    return Err(self.keep(&change.display, &made));
                }
                if Stamp::of(&made).is_some_and(|now| now.is_same(&ours)) {
                    let _ = fs::remove_file(&made);
                    Err(Unwritten::ChangedWhileWriting)
                } else {
                    Err(self.keep(&change.display, &made))
                }
            }
        }
    }

    /// `path`, a place in the worktree, relative to it.
    fn inside(&self, path: &Path) -> PathBuf {
        path.strip_prefix(&self.worktree.root)
            .unwrap_or(path)
            .to_path_buf()
    }

    /// Records that a save of `display` stays at `parked`, and says so.
    fn keep(&mut self, display: &str, parked: &Path) -> Unwritten {
        let at = parked
            .strip_prefix(&self.worktree.root)
            .unwrap_or(parked)
            .display()
            .to_string();
        self.kept.push(FailedPath {
            path: display.to_owned(),
            reason: FailedReason::KeptAside { at: at.clone() },
            detail: None,
        });
        Unwritten::KeptAside(at)
    }

    /// Ends the writing, whatever ended it: each file taken out goes if it
    /// is still what was read, and stays aside if it was written to since.
    /// Returns the paths whose saves stay aside, for the journal.
    pub(super) fn finish(mut self) -> Vec<FailedPath> {
        let _ = fs::remove_file(&self.index);
        (self.between)(Moment::AtFinish);
        let displaced = std::mem::take(&mut self.displaced);
        // Asked of git first; each file is looked at again right before it
        // goes, so a write while git was asked is not lost.
        let restorable = self.worktree.restorable(&displaced);
        for (displaced, is_restorable) in displaced.into_iter().zip(restorable) {
            let is_unchanged =
                Stamp::of(&displaced.parked).is_some_and(|now| now.is_same(&displaced.seen));
            if is_restorable && is_unchanged {
                let _ = fs::remove_file(&displaced.parked);
            } else {
                self.keep(&displaced.display, &displaced.parked);
            }
        }
        remove_empty_tree(&self.staging);
        clear_area(&self.worktree.staging(&self.op_id));
        self.kept
    }
}

impl Worktree {
    /// Whether a tree holds the bytes of each of `displaced`, so that it may
    /// go: its own tree's blob at its path, as it is or as a checkout's
    /// filters write it, with its executable bit. (An undo writes the
    /// checkout's form; the blob keeps the other.) Asked of git once for
    /// the raw bytes, and file by file only for the rest.
    fn restorable(&self, displaced: &[Displaced]) -> Vec<bool> {
        let mut entries: HashMap<&str, HashMap<Vec<u8>, super::Entry>> = HashMap::new();
        let trees: std::collections::BTreeSet<&str> = displaced
            .iter()
            .map(|displaced| displaced.expected.as_str())
            .collect();
        for tree in trees {
            let raws: Vec<Vec<u8>> = displaced
                .iter()
                .filter(|displaced| displaced.expected == tree)
                .map(|displaced| displaced.raw.clone())
                .collect();
            entries.insert(tree, self.entries(tree, &raws).unwrap_or_default());
        }
        // Git reads one path per line and drops a carriage return before the
        // break, so a name holding either goes file by file.
        let files: Vec<&Displaced> = displaced
            .iter()
            .filter(|displaced| {
                let name = displaced.parked.as_os_str().as_encoded_bytes();
                !name.contains(&b'\n')
                    && !name.contains(&b'\r')
                    && fs::symlink_metadata(&displaced.parked)
                        .is_ok_and(|metadata| metadata.is_file())
            })
            .collect();
        let mut paths = Vec::new();
        for file in &files {
            paths.extend_from_slice(file.parked.as_os_str().as_encoded_bytes());
            paths.push(b'\n');
        }
        let hashes: HashMap<&Path, String> = if files.is_empty() {
            HashMap::new()
        } else {
            GitSnapshots::run_with_input_index(
                &self.root,
                &["hash-object", "--no-filters", "--stdin-paths"],
                &paths,
                None,
            )
            .map(|output| {
                files
                    .iter()
                    .map(|file| file.parked.as_path())
                    .zip(String::from_utf8_lossy(&output).lines().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
        };
        displaced
            .iter()
            .map(|displaced| {
                let Some(entry) = entries
                    .get(displaced.expected.as_str())
                    .and_then(|entries| entries.get(&displaced.raw))
                else {
                    return false;
                };
                let Some(relative) = path_from_bytes(&displaced.raw) else {
                    return false;
                };
                let is_raw_blob = hashes.get(displaced.parked.as_path()) == Some(&entry.object)
                    && mode_of(&displaced.parked).as_deref() == Some(entry.mode.as_str());
                is_raw_blob || self.holds(&displaced.parked, &relative, entry)
            })
            .collect()
    }

    /// Where the operation `op_id` makes and takes out files, a part for
    /// each writer of it.
    pub(super) fn staging(&self, op_id: &str) -> PathBuf {
        self.root.join(format!(".weir-{op_id}"))
    }

    /// What `raw` is on disk now.
    pub(super) fn stamp(&self, raw: &[u8]) -> Option<Stamp> {
        path_from_bytes(raw).and_then(|relative| Stamp::of(&self.root.join(relative)))
    }

    /// Refuses a volume of `changes` (or of the worktree) that cannot
    /// exchange two names and rename onto nothing in one step: writing
    /// there could not keep another writer's save.
    pub(super) fn check_volume(&self, changes: &[Change]) -> Result<(), Refusal> {
        let mut asked = HashMap::new();
        // The staging area is on the worktree's own volume: a path on
        // another one (a mount inside the worktree) cannot be exchanged
        // with it.
        let home = device(&self.root);
        let places = std::iter::once(self.root.clone()).chain(
            changes
                .iter()
                .filter_map(|change| path_from_bytes(&change.raw))
                .map(|relative| self.root.join(relative)),
        );
        for place in places {
            // The nearest place that exists: a new directory is made on
            // its parent's volume.
            let Some(existing) = place
                .ancestors()
                .find(|path| fs::symlink_metadata(path).is_ok())
            else {
                continue;
            };
            let Some(device) = device(existing) else {
                continue;
            };
            if home.is_some_and(|home| home != device) {
                return Err(Refusal::UnsupportedVolume);
            }
            let supported = *asked
                .entry(device)
                .or_insert_with(|| swap::can_exchange(existing));
            if !supported {
                return Err(Refusal::UnsupportedVolume);
            }
        }
        Ok(())
    }

    /// Judges what the staging area of the interrupted operation `op_id`
    /// still holds: half-made files (`gen-`) were the writer's own and go;
    /// a made or taken-out file that is what the path held before, or what
    /// the operation writes, goes too (a tree holds it); anything else is
    /// another writer's save, and stays aside. Nothing is deleted that
    /// could not be read.
    ///
    /// `None` when the area, or a directory in it, is not a plain directory
    /// of the worktree: a link would take the deletions to wherever it
    /// points, so nothing is touched and the operation stays unsettled.
    ///
    /// Each level is opened from the one above without following a link,
    /// and listed and cleared through what was opened (`HeldDirectory`):
    /// no deletion goes through a path once the level is checked, so one
    /// swapped for a link meanwhile takes nothing with it.
    pub(super) fn recover_staging(
        &self,
        op_id: &str,
        before: &HashMap<Vec<u8>, super::Entry>,
        after: &HashMap<Vec<u8>, super::Entry>,
    ) -> Option<Vec<FailedPath>> {
        let staging = self.staging(op_id);
        if fs::symlink_metadata(&staging).is_err() {
            return Some(Vec::new());
        }
        let area_name = staging.file_name()?;
        let worktree = swap::HeldDirectory::open(&self.root, Path::new("")).ok()?;
        let area = worktree.child(area_name).ok()?;
        let mut kept = Vec::new();
        for (side_name, kind) in area.entries().ok()? {
            if kind != swap::EntryKind::Directory {
                continue;
            }
            let side = area.child(&side_name).ok()?;
            for (part_name, kind) in side.entries().ok()? {
                if kind != swap::EntryKind::Directory {
                    continue;
                }
                let part = side.child(&part_name).ok()?;
                let name = part_name.to_string_lossy();
                if name.starts_with("gen-") {
                    let _ = side.remove_tree(&part_name);
                    continue;
                }
                let judged = Judged {
                    path: staging.join(&side_name).join(&part_name),
                    is_taken_out: name == "out",
                    before,
                    after,
                };
                self.judge(&judged, &part, Path::new(""), &mut kept);
            }
        }
        for (side_name, kind) in area.entries().unwrap_or_default() {
            if kind == swap::EntryKind::Directory {
                area.remove_empty_tree(&side_name);
            }
        }
        let is_cleared = area
            .entries()
            .is_ok_and(|entries| entries.iter().all(|(name, _)| name == ".gitignore"));
        if is_cleared {
            let _ = area.remove_file(std::ffi::OsStr::new(".gitignore"));
            let _ = worktree.remove_dir(area_name);
        }
        Some(kept)
    }

    /// Judges each file under `dir`, the directory at `prefix` in a part of
    /// the staging area, removing it through `dir` when a tree holds it.
    fn judge(
        &self,
        part: &Judged,
        dir: &swap::HeldDirectory,
        prefix: &Path,
        kept: &mut Vec<FailedPath>,
    ) {
        for (name, kind) in dir.entries().unwrap_or_default() {
            let relative = prefix.join(&name);
            if kind == swap::EntryKind::Directory {
                if let Ok(child) = dir.child(&name) {
                    self.judge(part, &child, &relative, kept);
                }
                continue;
            }
            let file = part.path.join(&relative);
            let raw = relative.as_os_str().as_encoded_bytes().to_vec();
            let is_known = [part.before.get(&raw), part.after.get(&raw)]
                .into_iter()
                .flatten()
                .any(|entry| self.holds(&file, &relative, entry));
            if is_known {
                let _ = dir.remove_file(&name);
                continue;
            }
            // Taken out for a deletion and saved to since: its path is
            // empty unless something took it meanwhile, and it goes back
            // there.
            let is_back = part.is_taken_out
                && file.strip_prefix(&self.root).is_ok_and(|inside| {
                    swap::make_parents(&self.root, &relative).is_ok()
                        && swap::rename_new(&self.root, inside, &relative).is_ok()
                });
            if !is_back {
                kept.push(FailedPath {
                    path: relative.to_string_lossy().into_owned(),
                    reason: FailedReason::KeptAside {
                        at: file
                            .strip_prefix(&self.root)
                            .unwrap_or(&file)
                            .display()
                            .to_string(),
                    },
                    detail: None,
                });
            }
        }
    }

    /// Whether `file` is, byte for byte, what checking `entry` out at
    /// `relative` writes: a link's target, or a file's blob through the
    /// path's filters, with the same executable bit. Compared raw, so a
    /// save a filter would read back the same (`ident`) is not taken for
    /// the blob. Not when it cannot be read.
    fn holds(&self, file: &Path, relative: &Path, entry: &super::Entry) -> bool {
        let Ok(metadata) = fs::symlink_metadata(file) else {
            return false;
        };
        if metadata.file_type().is_symlink() {
            return entry.mode == "120000"
                && fs::read_link(file).is_ok_and(|target| {
                    self.blob(&entry.object)
                        .is_some_and(|blob| blob == target.as_os_str().as_encoded_bytes())
                });
        }
        #[cfg(unix)]
        let is_executable = {
            use std::os::unix::fs::PermissionsExt;
            metadata.permissions().mode() & 0o111 != 0
        };
        #[cfg(not(unix))]
        let is_executable = entry.mode == "100755";
        let mode = if is_executable { "100755" } else { "100644" };
        if !metadata.is_file() || entry.mode != mode {
            return false;
        }
        let path = format!("--path={}", relative.display());
        let checked_out = GitSnapshots::run(
            &self.root,
            &["cat-file", "--filters", &path, &entry.object],
            None,
        );
        checked_out.is_some_and(|bytes| fs::read(file).is_ok_and(|on_disk| on_disk == bytes))
    }
}

/// One part of an interrupted operation's staging area being judged: where
/// it is (for reading and for naming what stays aside), whether it holds
/// what the operation took out, and the trees that may hold its files.
struct Judged<'a> {
    path: PathBuf,
    is_taken_out: bool,
    before: &'a HashMap<Vec<u8>, super::Entry>,
    after: &'a HashMap<Vec<u8>, super::Entry>,
}

/// The mode git gives the regular file at `path`, by its executable bit.
fn mode_of(path: &Path) -> Option<String> {
    let metadata = fs::symlink_metadata(path).ok()?;
    if !metadata.is_file() {
        return None;
    }
    #[cfg(unix)]
    let is_executable = {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    };
    #[cfg(not(unix))]
    let is_executable = false;
    Some(if is_executable { "100755" } else { "100644" }.to_owned())
}

/// Removes the staging area once nothing but its `.gitignore` is left.
fn clear_area(area: &Path) {
    let Ok(entries) = fs::read_dir(area) else {
        return;
    };
    let is_empty = entries
        .flatten()
        .all(|entry| entry.file_name() == ".gitignore");
    if is_empty {
        let _ = fs::remove_file(area.join(".gitignore"));
        let _ = fs::remove_dir(area);
    }
}

/// Removes the directories under `dir`, and `dir`, that are empty: the
/// staging area keeps only saves kept aside.
pub(super) fn remove_empty_tree(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            remove_empty_tree(&entry.path());
        }
    }
    let _ = fs::remove_dir(dir);
}

#[cfg(unix)]
fn device(path: &Path) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    fs::symlink_metadata(path)
        .ok()
        .map(|metadata| metadata.dev())
}

#[cfg(not(unix))]
#[allow(clippy::unnecessary_wraps)] // The same signature as the Unix form above.
fn device(_path: &Path) -> Option<u64> {
    Some(0)
}
