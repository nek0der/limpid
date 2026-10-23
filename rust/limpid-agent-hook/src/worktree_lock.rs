//! The worktree lock. A restore rewrites the working tree
//! under an exclusive lock; a hook holds the same lock shared from the begin
//! snapshot until the run record that names it is written. So an agent never
//! starts writing while a restore is half done, and a begin snapshot never
//! reads one.
//!
//! A hook that finds a restore under way says so with a marker under
//! `worktree.lock.waiting/`, and the restore stops before its next batch of
//! paths (`Batches`). Past `Limits::snapshot` the hook gives up on its
//! snapshot and says so under `worktree.lock.abandoned/`, which stops the
//! restore the same way, but it still waits for the lock: the agent starts
//! only once the restore has let go. Giving up on the snapshot is not leave
//! to start. Only past `Limits::release`, which stays below every provider's
//! hook timeout, does the hook return without the lock; by then the
//! restore's process has stopped answering, since a dead process's lock goes
//! with its descriptor.
//!
//! Each marker names its process by pid and start time, so one a crash left
//! behind is swept by the next hook or restore to start. This is not the run
//! record's lock (`records::with_record_lock`), which orders the writes to
//! one record and is held for milliseconds.

use crate::process::start_epoch;
use crate::records::{atomic_write, ensure_user_only_directory, open_lock_file};
use std::fs::{self, File, TryLockError};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

const DIRECTORY: &str = "limpid";
const LOCK_FILE: &str = "worktree.lock";
const WAITING_DIRECTORY: &str = "worktree.lock.waiting";
const ABANDONED_DIRECTORY: &str = "worktree.lock.abandoned";

/// How long each side waits.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    /// How long a hook waits for a restore before giving up on its snapshot.
    pub snapshot: Duration,
    /// How long a hook waits for a restore in all.
    pub release: Duration,
    /// How often a waiting side tries the lock again.
    pub poll: Duration,
}

impl Limits {
    /// The hook's: ten seconds for the snapshot, thirty in all, which is
    /// well below the timeout Limpid gives the prompt's hook (600 seconds
    /// for both Claude and Codex), with the snapshot still to take.
    pub const HOOK: Self = Self {
        snapshot: Duration::from_secs(10),
        release: Duration::from_secs(30),
        poll: Duration::from_millis(25),
    };
}

/// Where one worktree's lock and its markers live: under the worktree's own
/// git directory, since a restore rewrites one working tree, not the
/// repository's others.
#[derive(Clone, Debug)]
pub struct WorktreeLockPaths {
    directory: PathBuf,
}

impl WorktreeLockPaths {
    #[must_use]
    pub fn new(git_dir: &Path) -> Self {
        Self {
            directory: git_dir.join(DIRECTORY),
        }
    }

    fn lock(&self) -> PathBuf {
        self.directory.join(LOCK_FILE)
    }

    fn waiting(&self) -> PathBuf {
        self.directory.join(WAITING_DIRECTORY)
    }

    fn abandoned(&self) -> PathBuf {
        self.directory.join(ABANDONED_DIRECTORY)
    }

    fn open(&self) -> Result<File, String> {
        ensure_user_only_directory(&self.directory);
        open_lock_file(&self.lock()).ok_or_else(|| format!("open {}", self.lock().display()))
    }

    /// Removes the markers whose process is gone.
    fn sweep(&self) {
        for directory in [self.waiting(), self.abandoned()] {
            for (path, owner) in markers(&directory) {
                if !owner.is_some_and(MarkerOwner::is_alive) {
                    let _ = fs::remove_file(path);
                }
            }
        }
    }
}

/// What a hook got of the lock.
#[derive(Debug)]
pub enum Shared {
    /// Held with no restore in the way, or after one let go within the
    /// snapshot's limit: the snapshot is taken.
    Held(SharedLock),
    /// Held, but only after the snapshot's limit: the begin is recorded as
    /// skipped.
    HeldLate(SharedLock),
    /// Never held: a restore kept the lock past the hook's whole limit.
    NotReleased,
    /// No lock to take, as when the git directory cannot be written. The
    /// hook goes on as it did before there was a lock.
    Unavailable(String),
}

impl Shared {
    /// Why the begin snapshot is not taken, or `None` when it is.
    #[must_use]
    pub fn snapshot_skip_reason(&self) -> Option<&'static str> {
        match self {
            Self::Held(_) | Self::Unavailable(_) => None,
            Self::HeldLate(_) => Some("restoreInProgress"),
            Self::NotReleased => Some("restoreNotResponding"),
        }
    }
}

/// The shared lock, held until dropped: closing the descriptor lets go.
#[derive(Debug)]
pub struct SharedLock {
    _file: File,
}

/// Takes the lock shared for the hook of run `run_id`, waiting out a
/// restore as the module describes.
#[must_use]
pub fn acquire_shared(paths: &WorktreeLockPaths, run_id: &str, limits: Limits) -> Shared {
    let file = match paths.open() {
        Ok(file) => file,
        Err(reason) => return Shared::Unavailable(reason),
    };
    paths.sweep();
    match file.try_lock_shared() {
        Ok(()) => return Shared::Held(SharedLock { _file: file }),
        Err(TryLockError::WouldBlock) => {}
        Err(TryLockError::Error(error)) => return Shared::Unavailable(error.to_string()),
    }
    let started = Instant::now();
    let waiting = Marker::place(&paths.waiting(), run_id);
    match wait_for_lock(started + limits.snapshot, limits.poll, || {
        file.try_lock_shared()
    }) {
        Waited::Held => return Shared::Held(SharedLock { _file: file }),
        Waited::Failed(reason) => return Shared::Unavailable(reason),
        Waited::TimedOut => {}
    }
    // The abandoned marker goes up before the waiting one comes down, so
    // the restore never sees neither while the hook still waits; when it
    // cannot be placed, the waiting one stays, which stops the restore too.
    let abandoned = Marker::place(&paths.abandoned(), run_id);
    if abandoned.is_placed() {
        drop(waiting);
    }
    match wait_for_lock(started + limits.release, limits.poll, || {
        file.try_lock_shared()
    }) {
        Waited::Held => Shared::HeldLate(SharedLock { _file: file }),
        Waited::Failed(reason) => Shared::Unavailable(reason),
        Waited::TimedOut => {
            // The agent starts now, and a restore still alive would write
            // beside it: the marker stays, so it stops at its next look.
            // Its owner, this hook, is gone by then, and the next hook or
            // restore to start sweeps it.
            abandoned.leave();
            Shared::NotReleased
        }
    }
}

/// Takes the lock shared without asking a restore to stop, trying until
/// `wait` has passed: for work a later pass can do instead (deleting a
/// turn's refs), which a restore does not give way to. `Held`, `NotReleased`
/// while a restore holds it, or `Unavailable`.
#[must_use]
pub fn acquire_shared_quietly(paths: &WorktreeLockPaths, wait: Duration, poll: Duration) -> Shared {
    let file = match paths.open() {
        Ok(file) => file,
        Err(reason) => return Shared::Unavailable(reason),
    };
    match wait_for_lock(Instant::now() + wait, poll, || file.try_lock_shared()) {
        Waited::Held => Shared::Held(SharedLock { _file: file }),
        Waited::TimedOut => Shared::NotReleased,
        Waited::Failed(reason) => Shared::Unavailable(reason),
    }
}

/// This is what trying a lock until a deadline came to.
#[derive(Debug, PartialEq, Eq)]
enum Waited {
    Held,
    TimedOut,
    /// Locking failed for a reason other than the lock being held, as on a
    /// file system without locks: no lock to keep the agent waiting on.
    Failed(String),
}

/// Tries `attempt` (the shared or the exclusive lock) every `poll` until it
/// is held or `deadline` passes. It tries once before looking at the clock,
/// so a deadline already past still gets one try: a lock that is free is
/// taken however late the caller asks. Each caller keeps its own markers
/// and the guard it wraps the held lock in.
fn wait_for_lock(
    deadline: Instant,
    poll: Duration,
    attempt: impl Fn() -> Result<(), TryLockError>,
) -> Waited {
    loop {
        match attempt() {
            Ok(()) => return Waited::Held,
            Err(TryLockError::Error(error)) => return Waited::Failed(error.to_string()),
            Err(TryLockError::WouldBlock) => {}
        }
        let now = Instant::now();
        if now >= deadline {
            return Waited::TimedOut;
        }
        thread::sleep(poll.min(deadline - now));
    }
}

/// Why a restore holding the lock is asked to stop.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interruption {
    /// A hook waits to start its agent: stop before the next batch.
    AgentWaiting,
    /// A hook gave up on its snapshot: stop before the next batch, as for a
    /// waiting one.
    AgentAbandoned,
}

/// Why the exclusive lock was not taken.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExclusiveError {
    /// A hook holds the lock shared (an agent's turn is beginning).
    Busy,
    /// The lock file could not be opened or locked.
    Unavailable(String),
}

/// The exclusive lock a restore holds, until dropped.
#[derive(Debug)]
pub struct ExclusiveLock {
    _file: File,
    paths: WorktreeLockPaths,
}

impl ExclusiveLock {
    /// Takes the lock exclusively, trying until `wait` has passed. Markers
    /// a crashed hook left behind are swept first, so they do not stop the
    /// restore before it starts.
    ///
    /// # Errors
    ///
    /// `Busy` when a hook kept the lock throughout; `Unavailable` when the
    /// lock file could not be opened or locked.
    pub fn acquire(
        paths: &WorktreeLockPaths,
        wait: Duration,
        poll: Duration,
    ) -> Result<Self, ExclusiveError> {
        let file = paths.open().map_err(ExclusiveError::Unavailable)?;
        paths.sweep();
        match wait_for_lock(Instant::now() + wait, poll, || file.try_lock()) {
            Waited::Held => Ok(Self {
                _file: file,
                paths: paths.clone(),
            }),
            Waited::TimedOut => Err(ExclusiveError::Busy),
            Waited::Failed(reason) => Err(ExclusiveError::Unavailable(reason)),
        }
    }

    /// Whether a hook has asked the restore to stop, read before each batch
    /// of paths is written.
    #[must_use]
    pub fn interruption(&self) -> Option<Interruption> {
        if !markers(&self.paths.abandoned()).is_empty() {
            Some(Interruption::AgentAbandoned)
        } else if !markers(&self.paths.waiting()).is_empty() {
            Some(Interruption::AgentWaiting)
        } else {
            None
        }
    }
}

/// The process that placed a marker.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct MarkerOwner {
    pid: u32,
    started_at_epoch_seconds: u64,
}

impl MarkerOwner {
    fn current() -> Option<Self> {
        let pid = std::process::id();
        Some(Self {
            pid,
            started_at_epoch_seconds: start_epoch(pid)?,
        })
    }

    fn parse(text: &str) -> Option<Self> {
        let (pid, started) = text.trim().split_once(' ')?;
        Some(Self {
            pid: pid.parse().ok()?,
            started_at_epoch_seconds: started.parse().ok()?,
        })
    }

    /// Alive when a process with the pid runs and started when the marker
    /// says, so a pid used again by another process does not keep a marker.
    fn is_alive(self) -> bool {
        start_epoch(self.pid) == Some(self.started_at_epoch_seconds)
    }
}

/// The markers in `directory`, each with its owner when it could be read.
/// Names beginning with a dot are an atomic write's temporary files.
fn markers(directory: &Path) -> Vec<(PathBuf, Option<MarkerOwner>)> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    entries
        .filter_map(Result::ok)
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .map(|entry| {
            let owner = fs::read_to_string(entry.path())
                .ok()
                .and_then(|text| MarkerOwner::parse(&text));
            (entry.path(), owner)
        })
        .collect()
}

/// A marker this process placed, removed when dropped.
struct Marker {
    path: Option<PathBuf>,
}

impl Marker {
    fn is_placed(&self) -> bool {
        self.path.is_some()
    }

    /// Leaves the marker in place past this process. Only a hook, which
    /// ends right after, may: a marker whose owner lives on is never swept,
    /// and would stop every restore of the worktree meanwhile.
    fn leave(mut self) {
        self.path = None;
    }

    /// Places a marker for run `run_id`. A run id is only part of the name
    /// once it is safe as one; the pid keeps two hooks of one run apart.
    fn place(directory: &Path, run_id: &str) -> Self {
        let Some(owner) = MarkerOwner::current() else {
            return Self { path: None };
        };
        let run: String = run_id
            .chars()
            .filter(|character| character.is_ascii_alphanumeric() || *character == '-')
            .take(64)
            .collect();
        ensure_user_only_directory(directory);
        let path = directory.join(format!("{run}.{}", owner.pid));
        let written = atomic_write(
            &path,
            format!("{} {}\n", owner.pid, owner.started_at_epoch_seconds).as_bytes(),
        );
        Self {
            path: written.ok().map(|()| path),
        }
    }
}

impl Drop for Marker {
    fn drop(&mut self) {
        if let Some(path) = &self.path {
            let _ = fs::remove_file(path);
        }
    }
}

// Off Unix the hook opens no lock file (`records::open_lock_file`), so
// there is no lock to test there.
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    /// A scratch git directory, which goes when dropped.
    fn temporary_git_dir() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    fn short(snapshot: u64, release: u64) -> Limits {
        Limits {
            snapshot: Duration::from_millis(snapshot),
            release: Duration::from_millis(release),
            poll: Duration::from_millis(5),
        }
    }

    const POLL: Duration = Duration::from_millis(5);

    /// A deadline already past still gets one try, and a lock still held at
    /// the deadline times out rather than failing.
    #[test]
    fn waiting_tries_once_past_the_deadline_and_times_out_while_held() {
        let past = Instant::now();
        let tries = std::cell::Cell::new(0);
        let held = wait_for_lock(past, POLL, || {
            tries.set(tries.get() + 1);
            Ok(())
        });
        assert_eq!((held, tries.get()), (Waited::Held, 1));

        let tries = std::cell::Cell::new(0);
        let busy = wait_for_lock(Instant::now() + POLL * 3, POLL, || {
            tries.set(tries.get() + 1);
            Err(TryLockError::WouldBlock)
        });
        assert_eq!(busy, Waited::TimedOut);
        assert!(tries.get() >= 2, "it polls until the deadline");

        let failed = wait_for_lock(past, POLL, || {
            Err(TryLockError::Error(std::io::Error::other("no locks here")))
        });
        assert_eq!(failed, Waited::Failed("no locks here".to_owned()));
    }

    #[test]
    fn hook_waits_until_restore_releases() {
        let git_dir = temporary_git_dir();
        let paths = WorktreeLockPaths::new(git_dir.path());
        let restore = ExclusiveLock::acquire(&paths, Duration::ZERO, POLL).unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let hook = {
            let paths = paths.clone();
            let barrier = Arc::clone(&barrier);
            thread::spawn(move || {
                barrier.wait();
                let shared = acquire_shared(&paths, "RUN", short(5_000, 10_000));
                (matches!(shared, Shared::Held(_)), Instant::now())
            })
        };
        barrier.wait();
        // The hook says it waits, and the restore sees it.
        let deadline = Instant::now() + Duration::from_secs(5);
        while restore.interruption().is_none() && Instant::now() < deadline {
            thread::sleep(POLL);
        }
        assert_eq!(restore.interruption(), Some(Interruption::AgentWaiting));
        let released = Instant::now();
        drop(restore);
        let (held, returned) = hook.join().unwrap();
        assert!(
            held,
            "the snapshot is taken once the restore lets go in time"
        );
        assert!(returned >= released, "the hook waited for the release");
        assert!(
            markers(&paths.waiting()).is_empty(),
            "the marker goes before the hook returns"
        );
    }

    #[test]
    fn restore_aborts_cooperatively_when_hook_waits() {
        let git_dir = temporary_git_dir();
        let paths = WorktreeLockPaths::new(git_dir.path());
        let restore = ExclusiveLock::acquire(&paths, Duration::ZERO, POLL).unwrap();
        assert_eq!(restore.interruption(), None, "no hook, nothing to stop for");
        let hook = {
            let paths = paths.clone();
            thread::spawn(move || acquire_shared(&paths, "RUN", short(5_000, 10_000)))
        };
        // A restore writing paths one by one stops at the first check after
        // the hook asks.
        let mut written = 0;
        while restore.interruption().is_none() {
            written += 1;
            thread::sleep(POLL);
            assert!(written < 1_000, "the hook never asked");
        }
        drop(restore);
        assert!(matches!(hook.join().unwrap(), Shared::Held(_)));
    }

    #[test]
    fn hook_skips_snapshot_after_bound_but_still_waits_for_release() {
        let git_dir = temporary_git_dir();
        let paths = WorktreeLockPaths::new(git_dir.path());
        let restore = ExclusiveLock::acquire(&paths, Duration::ZERO, POLL).unwrap();
        let hook = {
            let paths = paths.clone();
            thread::spawn(move || {
                let shared = acquire_shared(&paths, "RUN", short(30, 10_000));
                (
                    shared.snapshot_skip_reason(),
                    matches!(shared, Shared::HeldLate(_)),
                    Instant::now(),
                )
            })
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        while restore.interruption() != Some(Interruption::AgentAbandoned)
            && Instant::now() < deadline
        {
            thread::sleep(POLL);
        }
        assert_eq!(restore.interruption(), Some(Interruption::AgentAbandoned));
        // Past the snapshot's limit the hook still holds the agent back: it
        // returns no earlier than the release.
        let released = Instant::now();
        drop(restore);
        let (reason, is_late, returned) = hook.join().unwrap();
        assert_eq!((reason, is_late), (Some("restoreInProgress"), true));
        assert!(
            returned >= released,
            "the agent does not start before the release"
        );
        assert!(markers(&paths.abandoned()).is_empty());
        assert!(markers(&paths.waiting()).is_empty());
    }

    #[test]
    fn hook_returns_without_the_lock_past_its_whole_limit() {
        let git_dir = temporary_git_dir();
        let paths = WorktreeLockPaths::new(git_dir.path());
        let restore = ExclusiveLock::acquire(&paths, Duration::ZERO, POLL).unwrap();
        let shared = acquire_shared(&paths, "RUN", short(20, 60));
        assert!(matches!(shared, Shared::NotReleased));
        assert_eq!(shared.snapshot_skip_reason(), Some("restoreNotResponding"));
        // The abandoned marker stays, so a restore still writing stops.
        assert_eq!(markers(&paths.abandoned()).len(), 1);
        assert_eq!(restore.interruption(), Some(Interruption::AgentAbandoned));
    }

    #[test]
    fn stale_markers_are_cleaned_by_pid() {
        let git_dir = temporary_git_dir();
        let paths = WorktreeLockPaths::new(git_dir.path());
        fs::create_dir_all(paths.waiting()).unwrap();
        fs::create_dir_all(paths.abandoned()).unwrap();
        let current = MarkerOwner::current().unwrap();
        // A process that is gone, one whose pid now names another process,
        // a marker that cannot be read, and a live one.
        fs::write(paths.waiting().join("gone"), "999999 1\n").unwrap();
        fs::write(
            paths.abandoned().join("reused"),
            format!("{} {}\n", current.pid, current.started_at_epoch_seconds + 1),
        )
        .unwrap();
        fs::write(paths.waiting().join("garbage"), "not a marker").unwrap();
        fs::write(
            paths.waiting().join("live"),
            format!("{} {}\n", current.pid, current.started_at_epoch_seconds),
        )
        .unwrap();
        let restore = ExclusiveLock::acquire(&paths, Duration::ZERO, POLL).unwrap();
        let left: Vec<_> = markers(&paths.waiting())
            .into_iter()
            .map(|(path, _)| path.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(left, ["live"]);
        assert!(markers(&paths.abandoned()).is_empty());
        assert_eq!(restore.interruption(), Some(Interruption::AgentWaiting));
        drop(restore);
        // A hook sweeps too: here a marker of a process killed outright.
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let killed = MarkerOwner {
            pid: child.id(),
            started_at_epoch_seconds: start_epoch(child.id()).unwrap(),
        };
        assert!(killed.is_alive());
        fs::write(
            paths.abandoned().join("killed"),
            format!("{} {}\n", killed.pid, killed.started_at_epoch_seconds),
        )
        .unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        // Room for another test's process starting in the moment, which
        // keeps a copy of the restore's descriptor until it runs its program.
        assert!(matches!(
            acquire_shared(&paths, "RUN", short(10, 2_000)),
            Shared::Held(_)
        ));
        assert!(markers(&paths.abandoned()).is_empty());
    }

    #[test]
    fn exclusive_waits_for_shared_release() {
        let git_dir = temporary_git_dir();
        let paths = WorktreeLockPaths::new(git_dir.path());
        let Shared::Held(hook) = acquire_shared(&paths, "RUN", short(10, 20)) else {
            panic!("no restore, so the lock is free");
        };
        // Two hooks share it.
        assert!(matches!(
            acquire_shared(&paths, "OTHER", short(10, 20)),
            Shared::Held(_)
        ));
        assert_eq!(
            ExclusiveLock::acquire(&paths, Duration::from_millis(30), POLL).unwrap_err(),
            ExclusiveError::Busy
        );
        // The restore takes the lock no earlier than the moment the hook
        // lets go, whichever of the two its thread gets to first.
        let barrier = Arc::new(Barrier::new(2));
        let restore = {
            let paths = paths.clone();
            let barrier = Arc::clone(&barrier);
            thread::spawn(move || {
                barrier.wait();
                let has_acquired_lock =
                    ExclusiveLock::acquire(&paths, Duration::from_secs(5), POLL).is_ok();
                (has_acquired_lock, Instant::now())
            })
        };
        barrier.wait();
        let released = Instant::now();
        drop(hook);
        let (has_acquired_lock, returned) = restore.join().unwrap();
        assert!(has_acquired_lock, "taken once the hook lets go");
        assert!(returned >= released, "not before the hook lets go");
    }

    #[test]
    fn a_quiet_reader_neither_asks_the_restore_to_stop_nor_waits_past_its_limit() {
        let git_dir = temporary_git_dir();
        let paths = WorktreeLockPaths::new(git_dir.path());
        let restore = ExclusiveLock::acquire(&paths, Duration::ZERO, POLL).unwrap();
        assert!(matches!(
            acquire_shared_quietly(&paths, Duration::from_millis(20), POLL),
            Shared::NotReleased
        ));
        assert_eq!(restore.interruption(), None);
        drop(restore);
        // Not at once: another test's process starting in the moment keeps
        // a copy of the descriptor until it runs its program.
        assert!(matches!(
            acquire_shared_quietly(&paths, Duration::from_secs(2), POLL),
            Shared::Held(_)
        ));
    }

    #[test]
    fn marker_names_keep_only_safe_characters() {
        let directory = temporary_git_dir();
        let marker = Marker::place(directory.path(), "../../etc/passwd");
        let path = marker.path.clone().unwrap();
        assert_eq!(path.parent(), Some(directory.path()));
        assert!(
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("etcpasswd.")
        );
        drop(marker);
        assert!(!path.exists());
    }
}
