//! Turn snapshots: the working tree captured when a prompt is submitted so
//! the review surface can show what the turn changed. The runtime runs git
//! through a trait so tests replay events without a repository.

use std::path::Path;

/// The result of capturing a turn snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnSnapshot {
    /// The tree object id written from the private index.
    pub tree: String,
    /// The repository root the snapshot belongs to.
    pub root: String,
}

/// Git operations around a turn.
pub trait SnapshotRunner {
    /// Captures the working tree under `cwd` for `pane_id`. `None` when
    /// `cwd` is not inside a non-bare repository or git is unavailable.
    fn capture(&self, cwd: &Path, pane_id: &str) -> Option<TurnSnapshot>;

    /// Removes the snapshot ref and index files for `pane_id`.
    ///
    /// # Errors
    ///
    /// Returns a message when removal failed for a reason other than there
    /// being nothing to remove.
    fn remove(&self, cwd: &Path, pane_id: &str) -> Result<(), String>;
}

/// A runner that never snapshots, for hosts that disabled turn snapshots
/// (`LIMPID_TURN_SNAPSHOT=0`) and for tests.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoSnapshots;

impl SnapshotRunner for NoSnapshots {
    fn capture(&self, _cwd: &Path, _pane_id: &str) -> Option<TurnSnapshot> {
        None
    }

    fn remove(&self, _cwd: &Path, _pane_id: &str) -> Result<(), String> {
        Ok(())
    }
}

/// The real thing: `git` invoked as a subprocess, the way the shell receiver
/// did, with `GIT_OPTIONAL_LOCKS=0` so a snapshot never contends with the
/// user's own git commands.
#[derive(Clone, Copy, Debug, Default)]
pub struct GitSnapshots;

impl GitSnapshots {
    fn git(cwd: &Path, args: &[&str], index: Option<&Path>) -> Option<String> {
        let mut command = std::process::Command::new("git");
        command
            .env("GIT_OPTIONAL_LOCKS", "0")
            .arg("-C")
            .arg(cwd)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        if let Some(index) = index {
            command.env("GIT_INDEX_FILE", index);
        }
        let output = command.output().ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    }

    /// The git directory and worktree root for `cwd`, when it is inside a
    /// non-bare repository.
    fn repository(cwd: &Path) -> Option<(std::path::PathBuf, std::path::PathBuf)> {
        if Self::git(cwd, &["rev-parse", "--is-inside-work-tree"], None)? != "true" {
            return None;
        }
        if Self::git(cwd, &["rev-parse", "--is-bare-repository"], None)? != "false" {
            return None;
        }
        let git_dir = Self::git(cwd, &["rev-parse", "--absolute-git-dir"], None)?;
        let root = Self::git(cwd, &["rev-parse", "--show-toplevel"], None)?;
        if git_dir.is_empty() || root.is_empty() {
            return None;
        }
        Some((git_dir.into(), root.into()))
    }
}

/// Pane ids are lowercased in snapshot names so the same pane maps to one
/// ref whichever case the environment used.
fn pane_key(pane_id: &str) -> String {
    pane_id.to_ascii_lowercase()
}

impl SnapshotRunner for GitSnapshots {
    fn capture(&self, cwd: &Path, pane_id: &str) -> Option<TurnSnapshot> {
        let (git_dir, root) = Self::repository(cwd)?;
        let key = pane_key(pane_id);
        let directory = git_dir.join("limpid");
        std::fs::create_dir_all(&directory).ok()?;
        let index = directory.join(format!("turn-{key}.index"));
        // Seeding the private index from the real one keeps `add -A` fast on
        // large repositories; a missing real index only means a cold start.
        let _ = std::fs::copy(git_dir.join("index"), &index);
        Self::git(&root, &["add", "-A"], Some(&index))?;
        let tree = Self::git(&root, &["write-tree"], Some(&index))?;
        if tree.len() != 40 || !tree.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        Self::git(
            &root,
            &["update-ref", &format!("refs/limpid/turn/{key}"), &tree],
            None,
        )?;
        Some(TurnSnapshot {
            tree,
            root: root.to_string_lossy().into_owned(),
        })
    }

    fn remove(&self, cwd: &Path, pane_id: &str) -> Result<(), String> {
        let Some(git_dir) = Self::git(cwd, &["rev-parse", "--absolute-git-dir"], None) else {
            return Ok(());
        };
        let git_dir = std::path::PathBuf::from(git_dir);
        let key = pane_key(pane_id);
        let mut names = vec![key.clone()];
        // Builds before pane ids were normalized wrote the raw id.
        if key != pane_id {
            names.push(pane_id.to_owned());
        }
        for name in names {
            let _ = Self::git(
                cwd,
                &["update-ref", "-d", &format!("refs/limpid/turn/{name}")],
                None,
            );
            let _ = std::fs::remove_file(git_dir.join("limpid").join(format!("turn-{name}.index")));
            // The review surface writes this one; the run owns its removal.
            let _ = std::fs::remove_file(
                git_dir
                    .join("limpid")
                    .join(format!("turn-{name}.read.index")),
            );
        }
        Ok(())
    }
}
