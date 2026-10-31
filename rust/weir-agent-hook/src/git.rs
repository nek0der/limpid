//! Turn snapshots: the working tree captured at each end of a turn, so the
//! turn record can say what the turn changed and the review surface can show
//! it. The runtime runs git through a trait so tests replay events without a
//! repository.

use std::cell::Cell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::mpsc;
use std::time::Duration;
use weir_agent_core::SnapshotTaken;
use weir_agent_model::{DiffStat, GitContext, SkippedFile, SnapshotStatus};

/// Untracked files larger than this are left out of a snapshot and listed on
/// the turn record instead: hashing them would slow every prompt, and a
/// build product or a dump is rarely what a turn is reviewed for.
pub const LARGE_FILE_BYTES: u64 = 5 * 1024 * 1024;

/// Which end of a turn a snapshot is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TurnSide {
    Begin,
    End,
}

impl TurnSide {
    fn name(self) -> &'static str {
        match self {
            Self::Begin => "begin",
            Self::End => "end",
        }
    }
}

/// Git operations around a turn.
pub trait SnapshotRunner {
    /// Captures the working tree under `cwd` for one end of a turn in
    /// `pane_id`, whose scratch index it stages into. The turn record names
    /// the tree; only the turn's own refs (`pin`) keep it from `git gc`, so
    /// without a turn nothing does.
    fn capture(&self, cwd: &Path, pane_id: &str, side: TurnSide) -> SnapshotTaken;

    /// The git directory of the worktree under `cwd`, where its lock lives
    /// (`worktree_lock`), and the worktree's root; `None` outside a
    /// repository, and for a runner that takes no snapshots. A pane with
    /// snapshots turned off (`WEIR_TURN_SNAPSHOT=0`) so takes no lock: its
    /// agent may start while another pane's turn is restored in the same
    /// worktree. We accept that for a setting that already gives up the
    /// turn's record.
    fn worktree(&self, cwd: &Path) -> Option<(PathBuf, PathBuf)>;

    /// What changed between two trees of the repository at `root`; `None`
    /// when git could not say.
    fn diff(&self, root: &Path, begin: &str, end: &str) -> Option<DiffStat>;

    /// Points `refs/weir/turns/<turn_id>/<side>` at `tree`, so the tree
    /// outlives `git gc` for as long as the turn is kept.
    ///
    /// # Errors
    ///
    /// Returns a message when git refused the ref.
    fn pin(&self, root: &Path, turn_id: &str, side: TurnSide, tree: &str) -> Result<(), String>;

    /// Removes both of `turn_id`'s refs in the repository at `root`, in
    /// one transaction, so its trees go with the next `git gc` and never one
    /// ref without the other. A ref already gone is not an error: a deletion
    /// cut short is finished by asking again. When the file system shows
    /// `root` is no repository now (a removed worktree: the directory is
    /// gone, it has no `.git`, or its `.git` file points at a git directory
    /// that is gone), the refs are reached through `common_dir`, the
    /// repository's own git directory, which every worktree's refs live
    /// in. `false` when neither is there, which leaves nothing to reach
    /// the refs through. Git failing for any other reason (no usable git,
    /// an ownership check) is an error, so the record stays.
    ///
    /// # Errors
    ///
    /// Returns a message when git refused to delete the refs.
    fn unpin(&self, root: &Path, common_dir: Option<&Path>, turn_id: &str) -> Result<bool, String>;

    /// Removes the pane's scratch index files, and the pane's
    /// `refs/weir/turn/<pane>` that builds before turn records moved at
    /// every prompt, so a repository they left one in is cleaned up all the
    /// same. Turn refs are not the pane's: they stay until their turn is
    /// deleted.
    ///
    /// # Errors
    ///
    /// Returns a message when removal failed for a reason other than there
    /// being nothing to remove.
    fn remove(&self, cwd: &Path, pane_id: &str) -> Result<(), String>;
}

/// A runner that never snapshots, for hosts that disabled turn snapshots
/// (`WEIR_TURN_SNAPSHOT=0`) and for tests. A turn still gets a record; it
/// says the snapshots were disabled.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoSnapshots;

impl SnapshotRunner for NoSnapshots {
    fn capture(&self, _cwd: &Path, _pane_id: &str, _side: TurnSide) -> SnapshotTaken {
        taken(SnapshotStatus::Disabled)
    }

    fn worktree(&self, _cwd: &Path) -> Option<(PathBuf, PathBuf)> {
        None
    }

    fn diff(&self, _root: &Path, _begin: &str, _end: &str) -> Option<DiffStat> {
        None
    }

    fn pin(
        &self,
        _root: &Path,
        _turn_id: &str,
        _side: TurnSide,
        _tree: &str,
    ) -> Result<(), String> {
        Ok(())
    }

    fn unpin(
        &self,
        _root: &Path,
        _common_dir: Option<&Path>,
        _turn_id: &str,
    ) -> Result<bool, String> {
        Ok(true)
    }

    fn remove(&self, _cwd: &Path, _pane_id: &str) -> Result<(), String> {
        Ok(())
    }
}

fn taken(status: SnapshotStatus) -> SnapshotTaken {
    SnapshotTaken {
        status,
        skipped: Vec::new(),
        git_context: None,
    }
}

fn failed(reason: &str) -> SnapshotTaken {
    taken(SnapshotStatus::Failed {
        reason: reason.to_owned(),
    })
}

/// The real thing: `git` invoked as a subprocess, the way the shell receiver
/// did, with `GIT_OPTIONAL_LOCKS=0` so a snapshot never contends with the
/// user's own git commands.
#[derive(Clone, Copy, Debug, Default)]
pub struct GitSnapshots;

impl GitSnapshots {
    pub(crate) fn run(cwd: &Path, args: &[&str], index: Option<&Path>) -> Option<Vec<u8>> {
        let mut command = Self::command(cwd, args, index);
        command.stdin(std::process::Stdio::null());
        let output = output(&mut command).ok()?;
        output.status.success().then_some(output.stdout)
    }

    /// `run`, with `input` on the command's standard input. Read from a
    /// file rather than a pipe: this runs inside the app as well, where a
    /// write to a pipe git already closed would raise `SIGPIPE`, which the
    /// app does not ignore.
    fn run_with_input(cwd: &Path, args: &[&str], input: &[u8]) -> Option<Vec<u8>> {
        Self::run_with_input_index(cwd, args, input, None)
    }

    /// `run_with_input`, against the private index `index`.
    pub(crate) fn run_with_input_index(
        cwd: &Path,
        args: &[&str],
        input: &[u8],
        index: Option<&Path>,
    ) -> Option<Vec<u8>> {
        let file = input_file(input).ok()?;
        let mut command = Self::command(cwd, args, index);
        command.stdin(std::process::Stdio::from(file));
        let output = output(&mut command).ok()?;
        output.status.success().then_some(output.stdout)
    }

    pub(crate) fn command(
        cwd: &Path,
        args: &[&str],
        index: Option<&Path>,
    ) -> std::process::Command {
        let mut command = std::process::Command::new("git");
        // The hook inherits the agent's environment. The variables git
        // itself clears before running in another repository (`git
        // rev-parse --local-env-vars`) would point it away from `cwd`; a
        // namespace would move our refs under `refs/namespaces/`; and a
        // pathspec mode would stop the literal exclusions below from
        // matching, failing every snapshot of a repository with a large file.
        for variable in [
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_CONFIG",
            "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_COUNT",
            "GIT_OBJECT_DIRECTORY",
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_IMPLICIT_WORK_TREE",
            "GIT_GRAFT_FILE",
            "GIT_INDEX_FILE",
            "GIT_NO_REPLACE_OBJECTS",
            "GIT_REPLACE_REF_BASE",
            "GIT_PREFIX",
            "GIT_SHALLOW_FILE",
            "GIT_COMMON_DIR",
            "GIT_NAMESPACE",
            "GIT_LITERAL_PATHSPECS",
            "GIT_GLOB_PATHSPECS",
            "GIT_NOGLOB_PATHSPECS",
            "GIT_ICASE_PATHSPECS",
        ] {
            command.env_remove(variable);
        }
        command
            .env("GIT_OPTIONAL_LOCKS", "0")
            .arg("-C")
            .arg(cwd)
            .args(args)
            .stderr(std::process::Stdio::null());
        if let Some(index) = index {
            command.env("GIT_INDEX_FILE", index);
        }
        command
    }

    pub(crate) fn git(cwd: &Path, args: &[&str], index: Option<&Path>) -> Option<String> {
        Self::run(cwd, args, index).map(|stdout| String::from_utf8_lossy(&stdout).trim().to_owned())
    }

    /// The git directory and worktree root for `cwd`, when it is inside a
    /// non-bare repository. One `rev-parse` answers every question: a
    /// turn's hook runs git about ten times, and starting git is most of
    /// what a snapshot of a small repository costs.
    pub(crate) fn repository(cwd: &Path) -> Option<(PathBuf, PathBuf)> {
        Self::repository_and_common(cwd).map(|(git_dir, root, _)| (git_dir, root))
    }

    /// `repository`, with the git directory every worktree of the
    /// repository shares (`git_dir` itself for the main worktree), from the
    /// same `rev-parse`.
    pub(crate) fn repository_and_common(cwd: &Path) -> Option<(PathBuf, PathBuf, PathBuf)> {
        Self::repository_and_common_checked(cwd).ok().flatten()
    }

    /// `repository_and_common`, telling a git that could not be asked from
    /// a folder that is no repository: `Ok(None)` when `cwd` is gone, is no
    /// directory, or git failed in a folder with no `.git` of its own (not
    /// inside a worktree); an error when git could not be started, was
    /// ended by a signal, or failed in a folder that has a `.git`. A
    /// caller that reads what the repository holds must not take the second
    /// for the first, which reads as a repository with nothing in it.
    pub(crate) fn repository_and_common_checked(
        cwd: &Path,
    ) -> std::io::Result<Option<(PathBuf, PathBuf, PathBuf)>> {
        // A folder that is gone is no repository. Git would fail there as
        // it fails in any folder, so we tell it apart before asking.
        match std::fs::metadata(cwd) {
            Ok(metadata) if !metadata.is_dir() => return Ok(None),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            _ => {}
        }
        let mut command = Self::command(
            cwd,
            &[
                "rev-parse",
                "--is-inside-work-tree",
                "--is-bare-repository",
                "--absolute-git-dir",
                "--show-toplevel",
                "--path-format=absolute",
                "--git-common-dir",
            ],
            None,
        );
        command.stdin(std::process::Stdio::null());
        let output = output(&mut command)?;
        if output.status.code().is_none() {
            return Err(std::io::Error::other("git rev-parse was ended by a signal"));
        }
        if !output.status.success() {
            // Git fails the same way outside a repository and in one it
            // refuses to read (a damaged `.git`, an owner `safe.directory`
            // does not trust). A folder with its own `.git` is the second.
            if std::fs::symlink_metadata(cwd.join(".git")).is_ok() {
                return Err(std::io::Error::other(
                    "git rev-parse failed in a folder that has a .git",
                ));
            }
            return Ok(None);
        }
        let answer = String::from_utf8_lossy(&output.stdout);
        let mut lines = answer.trim().lines();
        let mut next = || lines.next().unwrap_or_default();
        let (inside, bare, git_dir, root, common_dir) = (next(), next(), next(), next(), next());
        if inside != "true"
            || bare != "false"
            || git_dir.is_empty()
            || root.is_empty()
            || common_dir.is_empty()
        {
            return Ok(None);
        }
        Ok(Some((git_dir.into(), root.into(), common_dir.into())))
    }

    /// The untracked files over `LARGE_FILE_BYTES`, as `index` sees them.
    /// Each comes with its path as git printed it, which is what the
    /// exclusion has to name: a name that is not UTF-8 is recorded lossily
    /// but still left out.
    pub(crate) fn large_untracked(root: &Path, index: &Path) -> Vec<(Vec<u8>, SkippedFile)> {
        let Some(listing) = Self::run(
            root,
            &["ls-files", "-z", "--others", "--exclude-standard"],
            Some(index),
        ) else {
            return Vec::new();
        };
        let mut skipped: Vec<(Vec<u8>, SkippedFile)> = listing
            .split(|byte| *byte == 0)
            .filter(|path| !path.is_empty())
            .filter_map(|raw| {
                let metadata = std::fs::symlink_metadata(root.join(path_from_bytes(raw)?)).ok()?;
                if !metadata.is_file() || metadata.len() <= LARGE_FILE_BYTES {
                    return None;
                }
                let mtime = metadata
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                    .map_or_else(String::new, |since| {
                        format!("{}.{:09}", since.as_secs(), since.subsec_nanos())
                    });
                Some((
                    raw.to_vec(),
                    SkippedFile {
                        path: String::from_utf8_lossy(raw).into_owned(),
                        size_bytes: metadata.len(),
                        mtime,
                    },
                ))
            })
            .collect();
        skipped.sort_by(|(_, first), (_, second)| first.cmp(second));
        skipped
    }

    /// Makes `index` a copy of the real index of the repository at `root`
    /// (`git_dir`) that reads every file, ready for `stage`. The real index
    /// is never written. Seeding from it keeps `add -A` fast on a large
    /// repository; a missing real index only means a cold start.
    ///
    /// `add -A` skips a file marked assume-unchanged and keeps the index's
    /// content in its place, so the copy's marks are cleared: otherwise a
    /// turn's snapshot would hold the index's content where the user had
    /// edited the file, and a restore to that snapshot would write over the
    /// edit. A skip-worktree file (a sparse checkout) is not on disk at all
    /// and keeps its mark; the answer says whether there was one.
    ///
    /// # Errors
    ///
    /// Returns the git step that failed. A copy whose marks could not be
    /// cleared would capture the wrong content, so it is no capture.
    pub(crate) fn seed_index(
        git_dir: &Path,
        root: &Path,
        index: &Path,
    ) -> Result<Seeded, &'static str> {
        // The previous copy goes first: without a real index to copy (a
        // repository before its first add) the old one would stay, and a
        // file it holds would be hashed however large it has grown since.
        // So does the lock a git we stopped (`COMMAND_LIMIT`) left on it,
        // which would fail every capture after.
        let _ = std::fs::remove_file(index);
        let mut lock = index.as_os_str().to_owned();
        lock.push(".lock");
        let _ = std::fs::remove_file(PathBuf::from(lock));
        let _ = std::fs::copy(git_dir.join("index"), index);
        // "<tag> <path>\0": `S` or `s` is skip-worktree; a lower-case tag is
        // assume-unchanged.
        let listing = Self::run(root, &["ls-files", "-v", "-z"], Some(index)).ok_or("ls-files")?;
        let mut seeded = Seeded {
            has_skip_worktree: false,
        };
        let mut assumed = Vec::new();
        for line in listing
            .split(|byte| *byte == 0)
            .filter(|line| line.len() > 2)
        {
            let (tag, path) = (line[0], &line[2..]);
            if tag == b'S' || tag == b's' {
                seeded.has_skip_worktree = true;
            } else if tag.is_ascii_lowercase() {
                assumed.extend_from_slice(path);
                assumed.push(0);
            }
        }
        if !assumed.is_empty() {
            Self::run_with_input_index(
                root,
                &["update-index", "--no-assume-unchanged", "-z", "--stdin"],
                &assumed,
                Some(index),
            )
            .ok_or("update-index")?;
        }
        Ok(seeded)
    }

    /// Stages the working tree into `index`, leaving out `skipped`. The
    /// paths go through a file rather than the command line, which a long
    /// list would overflow, and as literal pathspecs, so a name with a glob
    /// character excludes only itself.
    pub(crate) fn stage(
        root: &Path,
        index: &Path,
        skipped: &[(Vec<u8>, SkippedFile)],
    ) -> Option<()> {
        if skipped.is_empty() {
            return Self::run(root, &["add", "-A"], Some(index)).map(|_| ());
        }
        let mut pathspecs = b".\0".to_vec();
        for (raw, _) in skipped {
            pathspecs.extend_from_slice(b":(exclude,literal)");
            pathspecs.extend_from_slice(raw);
            pathspecs.push(0);
        }
        let list = index.with_extension("pathspec");
        std::fs::write(&list, pathspecs).ok()?;
        let list_argument = format!("--pathspec-from-file={}", list.display());
        let staged = Self::run(
            root,
            &["add", "-A", &list_argument, "--pathspec-file-nul"],
            Some(index),
        );
        let _ = std::fs::remove_file(&list);
        staged.map(|_| ())
    }

    /// The bytes of the blobs `end` holds that `begin` did not, before
    /// compression: what the turn added. A blob already in a commit is
    /// counted too, and the work between turns, which the begin ref keeps,
    /// is not. `None` when git could not say.
    fn added_bytes(root: &Path, begin: &str, end: &str) -> Option<u64> {
        let raw = Self::git(root, &["diff-tree", "-r", "--no-renames", begin, end], None)?;
        // ":<old mode> <new mode> <old id> <new id> <status>\t<path>"; a
        // deletion's new id is all zeros, and a submodule's is a commit.
        let mut blobs: Vec<&str> = raw
            .lines()
            .filter_map(|line| {
                let fields: Vec<&str> = line.split(' ').collect();
                (fields.len() >= 5 && fields[1] != "160000")
                    .then(|| fields[3])
                    .filter(|id| is_object_id(id))
            })
            .collect();
        blobs.sort_unstable();
        blobs.dedup();
        if blobs.is_empty() {
            return Some(0);
        }
        let mut input = blobs.join("\n");
        input.push('\n');
        let sizes = Self::run_with_input(
            root,
            &["cat-file", "--batch-check=%(objectsize)"],
            input.as_bytes(),
        )?;
        String::from_utf8_lossy(&sizes)
            .lines()
            .map(|line| line.trim().parse::<u64>().ok())
            .sum()
    }

    /// The commit and branch the turn started on; `None` before the first
    /// commit, when there is nothing to compare a later checkout against.
    fn context(root: &Path) -> Option<GitContext> {
        // `--abbrev-ref` prints `HEAD` for a detached head, which no branch
        // can be named; the `--` keeps a file called HEAD from making the
        // revision ambiguous. The common directory comes first, as an
        // absolute path: the turn refs live there, for every worktree.
        let answer = Self::git(
            root,
            &[
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
                "HEAD",
                "--abbrev-ref",
                "HEAD",
                "--",
            ],
            None,
        )?;
        let mut lines = answer.lines();
        // Absolute only: a relative one would be read against whatever
        // directory git later runs in.
        let common_dir = lines
            .next()
            .filter(|line| Path::new(line).is_absolute())
            .map(str::to_owned);
        let head = lines.next().filter(|head| is_object_id(head))?.to_owned();
        let branch = lines
            .next()
            .filter(|branch| !branch.is_empty() && *branch != "HEAD")
            .map(str::to_owned);
        Some(GitContext {
            head,
            branch,
            root: root.to_string_lossy().into_owned(),
            common_dir,
            extra: BTreeMap::new(),
        })
    }
}

/// This is how long one git command may run before we stop it. A clean,
/// smudge, or process filter that never answers would otherwise hold the
/// hook, and in the app the one queue every restore, discard, and undo runs
/// on, for good. It is generous, so that hashing a large working tree on a
/// cold cache, which is slow but ends, still ends.
const COMMAND_LIMIT: Duration = Duration::from_secs(120);

/// This is how long a stopped git's output may take to close once its
/// process group is killed. Only a process that left the group can hold it open
/// past that, and we do not wait on it.
const STOPPED_WAIT: Duration = Duration::from_secs(5);

thread_local! {
    /// Inside a `GitScope`, this says whether one of its git commands ran
    /// out of time; it is `None` outside one.
    static SCOPE: Cell<Option<bool>> = const { Cell::new(None) };

    /// This holds a shorter `COMMAND_LIMIT` for the tests on this thread.
    #[cfg(test)]
    static TEST_LIMIT: Cell<Option<Duration>> = const { Cell::new(None) };
}

/// This groups the git commands of one operation (a restore, an undo, a
/// discard, a recovery) on this thread. Once one of them runs out of time,
/// the rest fail without starting: git hung on a filter would hang the same
/// way on each later path, and a restore writes and checks a path at a time.
/// The operation then ends as any git failure ends it, its journal and pins
/// left for recovery to settle.
pub(crate) struct GitScope {
    is_outermost: bool,
}

impl GitScope {
    pub(crate) fn begin() -> Self {
        let is_outermost = SCOPE.get().is_none();
        if is_outermost {
            SCOPE.set(Some(false));
        }
        Self { is_outermost }
    }
}

impl Drop for GitScope {
    fn drop(&mut self) {
        if self.is_outermost {
            SCOPE.set(None);
        }
    }
}

fn command_limit() -> Duration {
    #[cfg(test)]
    if let Some(limit) = TEST_LIMIT.get() {
        return limit;
    }
    COMMAND_LIMIT
}

/// Shortens `COMMAND_LIMIT` for the rest of the test on this thread. Only
/// the Unix tests stop a git that runs too long.
#[cfg(all(test, unix))]
pub(crate) fn limit_commands_for_test(limit: Duration) {
    TEST_LIMIT.set(Some(limit));
}

fn timed_out(what: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::TimedOut, what)
}

/// Returns `command`'s output, as `Command::output` gives it, unless it runs
/// past `COMMAND_LIMIT`. Git runs in a process group of its own, so the
/// filters it started go with it when the group is killed.
///
/// # Errors
///
/// Returns `TimedOut` when the command ran out of time, or an earlier one of
/// the same `GitScope` did. Otherwise it returns the error from starting git,
/// from starting the thread that waits on it, from that thread ending without
/// an answer, or from reading git's output and reaping it.
pub(crate) fn output(command: &mut Command) -> std::io::Result<Output> {
    if SCOPE.get() == Some(true) {
        return Err(timed_out("an earlier git command ran out of time"));
    }
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(command, 0);
    command.stdout(Stdio::piped());
    let child = command.spawn()?;
    let group = child.id();
    let (sender, receiver) = mpsc::channel();
    // `wait_with_output` reads the output to its end and then reaps git; a
    // thread does it, so this one can stop waiting.
    let waiter = std::thread::Builder::new()
        .name("weir-git-wait".to_owned())
        .spawn(move || {
            let _ = sender.send(child.wait_with_output());
        });
    let answer = match waiter {
        Ok(_) => receiver.recv_timeout(command_limit()),
        Err(error) => {
            kill_group(group);
            return Err(error);
        }
    };
    match answer {
        Ok(output) => output,
        Err(mpsc::RecvTimeoutError::Disconnected) => Err(std::io::Error::other(
            "the thread waiting on git ended without an answer",
        )),
        Err(mpsc::RecvTimeoutError::Timeout) => {
            kill_group(group);
            SCOPE.with(|scope| {
                if scope.get().is_some() {
                    scope.set(Some(true));
                }
            });
            // Git is reaped once its output closes. The group's id stays git's
            // until then, so the kill cannot reach another process.
            let _ = receiver.recv_timeout(STOPPED_WAIT);
            Err(timed_out("git ran out of time"))
        }
    }
}

/// Kills the process group git leads, and everything in it.
#[cfg(unix)]
fn kill_group(group: u32) {
    if let Ok(group) = libc::pid_t::try_from(group) {
        // SAFETY: `killpg` takes plain integers and touches no memory of
        // ours. The group is git's while git or a filter it started is
        // there; one that ended in the instant since we stopped waiting
        // leaves an id far too briefly free to be given out again.
        unsafe {
            libc::killpg(group, libc::SIGKILL);
        }
    }
}

/// Elsewhere git runs in no group of its own, so there is nothing to kill:
/// we stop waiting, and the thread reaps git when it ends.
#[cfg(not(unix))]
fn kill_group(_group: u32) {}

/// Puts `input` in a file of its own, read from its start, for a git
/// command's standard input. The input names paths of the user's repository,
/// and the temporary directory may be shared, so the file is the user's alone
/// and made new, never one another process placed there. We remove its name
/// as soon as it is made, before anything is written: the open file is all
/// git needs, so a write that fails leaves nothing behind. Removing the name
/// is best effort, and a removal that fails is ignored.
fn input_file(input: &[u8]) -> std::io::Result<std::fs::File> {
    use std::io::{Seek, Write};
    let path = std::env::temp_dir().join(format!("weir-git-input-{}", uuid::Uuid::new_v4()));
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(&path)?;
    let _ = std::fs::remove_file(&path);
    file.write_all(input)?;
    file.rewind()?;
    Ok(file)
}

/// This is what `GitSnapshots::seed_index` found in the index it made.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Seeded {
    /// This is true when a file is marked skip-worktree: a sparse checkout,
    /// whose files the capture keeps as the index has them.
    pub(crate) has_skip_worktree: bool,
}

/// A path as git printed it. Unix paths are bytes, so any name git lists can
/// be opened; elsewhere only UTF-8 names can.
#[cfg(unix)]
#[allow(clippy::unnecessary_wraps)] // The same signature as the fallible form below.
pub(crate) fn path_from_bytes(raw: &[u8]) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(raw)))
}

#[cfg(not(unix))]
pub(crate) fn path_from_bytes(raw: &[u8]) -> Option<PathBuf> {
    std::str::from_utf8(raw).ok().map(PathBuf::from)
}

/// The git directory of the repository at `root`, as the file system
/// shows it: its `.git` directory, or, for a linked worktree, the one its
/// `.git` file names. `None` says the repository is gone for certain; git
/// failing says nothing about it. The path is handed to git as
/// `--git-dir`, so a broken `.git` fails rather than sending git up to a
/// repository above it.
fn reachable_git_dir(root: &Path) -> Option<PathBuf> {
    let dot_git = root.join(".git");
    if dot_git.is_dir() {
        return Some(dot_git);
    }
    let text = std::fs::read_to_string(&dot_git).ok()?;
    text.lines()
        .find_map(|line| line.strip_prefix("gitdir:"))
        .map(|target| root.join(target.trim()))
        .filter(|target| target.is_dir())
}

/// Pane ids are lowercased in snapshot names so the same pane maps to one
/// scratch index whichever case the environment used.
fn pane_key(pane_id: &str) -> String {
    pane_id.to_ascii_lowercase()
}

/// An object id as git prints one: 40 hex digits, or 64 in a SHA-256
/// repository. Not all zeros, which names no object: git reads it as "no
/// value" (a deletion's new side), and `update-ref` given it deletes the ref
/// it was asked to set.
pub(crate) fn is_object_id(value: &str) -> bool {
    matches!(value.len(), 40 | 64)
        && value.bytes().all(|byte| byte.is_ascii_hexdigit())
        && value.bytes().any(|byte| byte != b'0')
}

impl SnapshotRunner for GitSnapshots {
    fn capture(&self, cwd: &Path, pane_id: &str, side: TurnSide) -> SnapshotTaken {
        let Some((git_dir, root)) = Self::repository(cwd) else {
            return taken(SnapshotStatus::NotGit);
        };
        let key = pane_key(pane_id);
        let directory = git_dir.join("weir");
        if std::fs::create_dir_all(&directory).is_err() {
            return failed("snapshot directory");
        }
        // Each end has its own scratch index, so the end of one turn and the
        // start of the next in the same pane cannot write into one file.
        let index = directory.join(match side {
            TurnSide::Begin => format!("turn-{key}.index"),
            TurnSide::End => format!("turn-{key}.end.index"),
        });
        // A skip-worktree file keeps what the index holds, which is what a
        // sparse checkout has; a restore to the snapshot refuses there.
        if let Err(step) = Self::seed_index(&git_dir, &root, &index) {
            return failed(step);
        }
        let skipped = Self::large_untracked(&root, &index);
        if Self::stage(&root, &index, &skipped).is_none() {
            return failed("add");
        }
        let Some(tree) =
            Self::git(&root, &["write-tree"], Some(&index)).filter(|tree| is_object_id(tree))
        else {
            return failed("write-tree");
        };
        SnapshotTaken {
            status: SnapshotStatus::Captured {
                tree,
                root: root.to_string_lossy().into_owned(),
            },
            skipped: skipped.into_iter().map(|(_, file)| file).collect(),
            git_context: match side {
                TurnSide::Begin => Self::context(&root),
                TurnSide::End => None,
            },
        }
    }

    fn worktree(&self, cwd: &Path) -> Option<(PathBuf, PathBuf)> {
        Self::repository(cwd)
    }

    fn diff(&self, root: &Path, begin: &str, end: &str) -> Option<DiffStat> {
        // We use plumbing, so the person's diff settings (an external tool,
        // `diff.renames`) cannot change what is counted; `diff.renameLimit`
        // still applies, and past it an inexact rename counts as a delete and
        // an add. Renames are found at git's default similarity, as the
        // Changes panel counts them: a file moved untouched is one file with
        // no lines, not a delete and an add.
        // The paths a restore checks and the bytes a turn added still read a
        // rename as a delete and an add, since each side is a path there.
        let output = Self::git(
            root,
            &["diff-tree", "-r", "--numstat", "-M", begin, end],
            None,
        )?;
        let mut stat = DiffStat {
            files: 0,
            added: 0,
            removed: 0,
            // Telling the agent's edits from a command's needs the tool
            // events between the snapshots; until then it is never claimed.
            has_shell_changes: false,
            added_bytes: Self::added_bytes(root, begin, end),
        };
        for line in output.lines().filter(|line| !line.is_empty()) {
            let mut fields = line.splitn(3, '\t');
            // A binary file reads `-`: it counts as a changed file with no
            // lines.
            let added = fields
                .next()
                .and_then(|value| value.parse::<u32>().ok())
                .unwrap_or(0);
            let removed = fields
                .next()
                .and_then(|value| value.parse::<u32>().ok())
                .unwrap_or(0);
            stat.files = stat.files.saturating_add(1);
            stat.added = stat.added.saturating_add(added);
            stat.removed = stat.removed.saturating_add(removed);
        }
        Some(stat)
    }

    fn pin(&self, root: &Path, turn_id: &str, side: TurnSide, tree: &str) -> Result<(), String> {
        let name = format!("refs/weir/turns/{turn_id}/{}", side.name());
        Self::git(root, &["update-ref", &name, tree], None)
            .map(|_| ())
            .ok_or_else(|| format!("update-ref {name}"))
    }

    fn unpin(&self, root: &Path, common_dir: Option<&Path>, turn_id: &str) -> Result<bool, String> {
        let Some(git_dir) = reachable_git_dir(root).or_else(|| {
            common_dir
                .filter(|directory| directory.is_dir())
                .map(Path::to_path_buf)
        }) else {
            return Ok(false);
        };
        let commands = format!(
            "delete refs/weir/turns/{turn_id}/{}\ndelete refs/weir/turns/{turn_id}/{}\n",
            TurnSide::Begin.name(),
            TurnSide::End.name()
        );
        // Run from the git directory when the worktree is gone: `-C` needs a
        // directory that is there.
        let cwd = if root.is_dir() {
            root.to_path_buf()
        } else {
            git_dir.clone()
        };
        let git_dir = format!("--git-dir={}", git_dir.display());
        Self::run_with_input(
            &cwd,
            &[&git_dir, "update-ref", "--stdin"],
            commands.as_bytes(),
        )
        .map(|_| true)
        .ok_or_else(|| format!("update-ref --stdin: delete refs/weir/turns/{turn_id}"))
    }

    fn remove(&self, cwd: &Path, pane_id: &str) -> Result<(), String> {
        let Some(git_dir) = Self::git(cwd, &["rev-parse", "--absolute-git-dir"], None) else {
            return Ok(());
        };
        let git_dir = PathBuf::from(git_dir);
        let key = pane_key(pane_id);
        let mut names = vec![key.clone()];
        // Builds before pane ids were normalized wrote the raw id.
        if key != pane_id {
            names.push(pane_id.to_owned());
        }
        for name in names {
            let _ = Self::git(
                cwd,
                &["update-ref", "-d", &format!("refs/weir/turn/{name}")],
                None,
            );
            // The read index is what the review of earlier builds wrote; the
            // run owns its removal.
            for file in [
                format!("turn-{name}.index"),
                format!("turn-{name}.end.index"),
                format!("turn-{name}.read.index"),
            ] {
                let _ = std::fs::remove_file(git_dir.join("weir").join(file));
            }
        }
        Ok(())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::{GitScope, GitSnapshots, input_file, limit_commands_for_test};
    use std::io::Read;
    use std::os::unix::fs::MetadataExt;
    use std::time::{Duration, Instant};

    /// A git that never answers is stopped at the limit with what it
    /// started, and the rest of its operation's git commands fail without
    /// starting; outside the operation git runs again.
    #[test]
    fn a_git_past_the_limit_is_stopped_with_what_it_started() {
        limit_commands_for_test(Duration::from_millis(300));
        let scratch = tempfile::tempdir().expect("scratch");
        let pid_file = scratch.path().join("pid");
        // We use a shell alias: git starts it as its own child, as it starts a
        // filter, and it records its pid before it hangs.
        let alias = format!(
            "alias.hang=!echo $$ > '{}'; exec sleep 30",
            pid_file.display()
        );
        let started = Instant::now();
        {
            let _git = GitScope::begin();
            assert_eq!(
                GitSnapshots::run(scratch.path(), &["-c", &alias, "hang"], None),
                None
            );
            assert!(started.elapsed() < Duration::from_secs(10));
            let again = Instant::now();
            assert_eq!(
                GitSnapshots::run(scratch.path(), &["--version"], None),
                None
            );
            assert!(again.elapsed() < Duration::from_millis(100), "not started");
        }
        assert!(GitSnapshots::run(scratch.path(), &["--version"], None).is_some());

        let pid: libc::pid_t = std::fs::read_to_string(&pid_file)
            .expect("pid")
            .trim()
            .parse()
            .expect("a pid");
        let deadline = Instant::now() + Duration::from_secs(5);
        // SAFETY: `kill` with signal 0 sends nothing; it only asks whether
        // the process is there.
        while unsafe { libc::kill(pid, 0) } == 0 {
            assert!(
                Instant::now() < deadline,
                "the alias's sleep is still there"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The input file is the user's alone, has no name left for another
    /// process to open or for a failed run to leave behind, and reads from
    /// its start.
    #[test]
    fn git_input_is_private_unnamed_and_read_from_its_start() {
        let mut file = input_file(b"refs/weir/turns/a\n").expect("input file");
        let metadata = file.metadata().expect("metadata");
        assert_eq!(metadata.mode() & 0o777, 0o600);
        assert_eq!(metadata.nlink(), 0, "the name is gone");
        let mut read = Vec::new();
        file.read_to_end(&mut read).expect("read");
        assert_eq!(read, b"refs/weir/turns/a\n");
    }
}
