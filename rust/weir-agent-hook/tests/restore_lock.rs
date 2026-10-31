//! The worktree lock between a restore and the hook: a prompt during a restore
//! waits for it and starts its turn after it, and a deletion leaves the turn
//! to the next sweep. Unix only: the hook runtime itself only runs there.
#![cfg(unix)]

mod support;

use std::cell::RefCell;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};
use support::{RUN, Repo, SESSION_START, only_turn, prompt, recorded_turn, turn_env, turn_ref};
use weir_agent_hook::worktree_lock::{ExclusiveLock, Interruption, Limits, WorktreeLockPaths};
use weir_agent_hook::{
    GitSnapshots, HookOutcome, HookRuntime, NoSnapshots, SnapshotRunner, TURNS_DIRECTORY,
    TurnDeletion, TurnSide, delete_turns, delete_turns_waiting, format_utc_seconds, run_hook,
};
use weir_agent_model::{RunRecord, SnapshotStatus, parse_utc_seconds, run_record_file_name};

/// Git, with a restore of the worktree started while the prompt's snapshot
/// is taken. The restore reads the run record as soon as it holds the lock,
/// which tells whether the hook held it until the record named the turn.
struct ProbingLock {
    git_dir: PathBuf,
    record: PathBuf,
    restore: RefCell<Option<std::thread::JoinHandle<Option<String>>>>,
    seen: RefCell<Vec<String>>,
}

impl SnapshotRunner for ProbingLock {
    fn capture(&self, cwd: &Path, pane_id: &str, side: TurnSide) -> weir_agent_core::SnapshotTaken {
        if side == TurnSide::Begin {
            let paths = WorktreeLockPaths::new(&self.git_dir);
            let is_held =
                ExclusiveLock::acquire(&paths, Duration::ZERO, Duration::from_millis(1)).is_err();
            self.seen
                .borrow_mut()
                .push(format!("held while the snapshot is taken: {is_held}"));
            let record = self.record.clone();
            *self.restore.borrow_mut() = Some(std::thread::spawn(move || {
                let _lock = ExclusiveLock::acquire(
                    &paths,
                    Duration::from_secs(10),
                    Duration::from_millis(1),
                )
                .ok()?;
                fs::read(&record)
                    .ok()
                    .and_then(|bytes| weir_agent_model::RunRecord::decode(&bytes).ok())
                    .and_then(|record| record.current_turn_id)
            }));
        }
        GitSnapshots.capture(cwd, pane_id, side)
    }

    fn worktree(&self, cwd: &Path) -> Option<(PathBuf, PathBuf)> {
        GitSnapshots.worktree(cwd)
    }

    fn diff(&self, root: &Path, begin: &str, end: &str) -> Option<weir_agent_model::DiffStat> {
        GitSnapshots.diff(root, begin, end)
    }

    fn pin(&self, root: &Path, turn_id: &str, side: TurnSide, tree: &str) -> Result<(), String> {
        if let Some(restore) = self.restore.borrow_mut().take() {
            let read = restore.join().expect("restore");
            self.seen.borrow_mut().push(format!(
                "the restore's lock came after the record named the turn: {}",
                read.as_deref() == Some(turn_id)
            ));
        }
        GitSnapshots.pin(root, turn_id, side, tree)
    }

    fn unpin(&self, root: &Path, common_dir: Option<&Path>, turn_id: &str) -> Result<bool, String> {
        GitSnapshots.unpin(root, common_dir, turn_id)
    }

    fn remove(&self, cwd: &Path, pane_id: &str) -> Result<(), String> {
        GitSnapshots.remove(cwd, pane_id)
    }
}

#[test]
fn shared_spans_record_publish() {
    let repo = Repo::new("lock-span");
    let states = repo.root.join("support/states");
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook(
        "claude",
        SESSION_START,
        &HookRuntime::new(&env, &NoSnapshots),
    );
    let probe = ProbingLock {
        git_dir: repo.git_dir(),
        record: states.join(weir_agent_model::run_record_file_name(RUN)),
        restore: RefCell::new(None),
        seen: RefCell::new(Vec::new()),
    };
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook(
        "claude",
        &prompt(&repo.path),
        &HookRuntime::new(&env, &probe),
    );
    assert_eq!(
        *probe.seen.borrow(),
        [
            "held while the snapshot is taken: true",
            "the restore's lock came after the record named the turn: true"
        ]
    );
}

#[test]
fn a_prompt_during_a_restore_waits_for_it_and_skips_its_snapshot() {
    let repo = Repo::new("lock-restore");
    let states = repo.root.join("support/states");
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook(
        "claude",
        SESSION_START,
        &HookRuntime::new(&env, &NoSnapshots),
    );
    let released = prompt_waiting_on_a_restore(&repo, &states, Duration::from_millis(50));
    let turn = only_turn(&states);
    assert_eq!(
        turn.begin,
        SnapshotStatus::Skipped {
            reason: "restoreInProgress".to_owned()
        }
    );
    // Its snapshot given up, the hook still waited for the restore, so the
    // turn starts after it as well.
    assert!(
        parse_utc_seconds(&turn.started_at) >= parse_utc_seconds(&released),
        "started {} before the restore let go at {released}",
        turn.started_at
    );
}

/// A time well before any test runs, given as the hook call's own: a turn
/// stamped with it was stamped when the hook was called, not after a wait.
const CALLED_AT: &str = "2020-01-01T00:00:00Z";

/// The run record's `runStartedAt`, which the prompt sets with the turn.
fn run_started_at(states: &Path) -> Option<String> {
    let bytes = fs::read(states.join(run_record_file_name(RUN))).expect("run record");
    RunRecord::decode(&bytes).expect("decode").run_started_at
}

/// Runs the prompt hook, called at `CALLED_AT`, on another thread while a
/// restore holds the worktree lock. Lets the restore go once the hook asks
/// it to stop (waiting, or past `snapshot` giving up its snapshot), and
/// returns the second the restore let go in.
fn prompt_waiting_on_a_restore(repo: &Repo, states: &Path, snapshot: Duration) -> String {
    let paths = WorktreeLockPaths::new(&repo.git_dir());
    let restore = ExclusiveLock::acquire(&paths, Duration::ZERO, Duration::from_millis(1))
        .expect("no hook holds it");
    let hook = {
        let states = states.to_path_buf();
        let cwd = repo.path.clone();
        std::thread::spawn(move || {
            let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
            let mut runtime = HookRuntime::new(&env, &GitSnapshots);
            CALLED_AT.clone_into(&mut runtime.now);
            runtime.lock_limits = Limits {
                snapshot,
                release: Duration::from_secs(10),
                poll: Duration::from_millis(5),
            };
            run_hook("claude", &prompt(&cwd), &runtime)
        })
    };
    let asked = if snapshot < Duration::from_secs(1) {
        Interruption::AgentAbandoned
    } else {
        Interruption::AgentWaiting
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while restore.interruption() != Some(asked) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(restore.interruption(), Some(asked));
    assert!(
        !hook.is_finished(),
        "the agent waits for the restore to let go"
    );
    let released = format_utc_seconds(SystemTime::now());
    drop(restore);
    assert_eq!(hook.join().expect("hook"), HookOutcome::Applied);
    released
}

/// A prompt kept waiting by a restore starts its turn once it holds the
/// lock, so the app does not count it among the turns the restore took
/// back: its start, and the run's, is at or after the second the restore
/// let go in, though the hook was called long before.
#[test]
fn a_prompt_kept_waiting_by_a_restore_starts_once_the_restore_lets_go() {
    let repo = Repo::new("lock-start");
    let states = repo.root.join("support/states");
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook(
        "claude",
        SESSION_START,
        &HookRuntime::new(&env, &NoSnapshots),
    );
    let released = prompt_waiting_on_a_restore(&repo, &states, Duration::from_secs(5));
    let turn = only_turn(&states);
    assert!(
        matches!(turn.begin, SnapshotStatus::Captured { .. }),
        "the snapshot is still taken"
    );
    assert!(
        parse_utc_seconds(&turn.started_at) >= parse_utc_seconds(&released),
        "started {} before the restore let go at {released}",
        turn.started_at
    );
    assert_eq!(
        run_started_at(&states).as_deref(),
        Some(turn.started_at.as_str())
    );
}

/// Runs the prompt hook in `cwd`, called at `CALLED_AT`, with `limits`, and
/// returns the second just before the call.
fn prompt_called_long_ago(states: &Path, cwd: &Path, limits: Option<Limits>) -> String {
    let env = turn_env(states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook(
        "claude",
        SESSION_START,
        &HookRuntime::new(&env, &NoSnapshots),
    );
    let env = turn_env(states, &uuid::Uuid::new_v4().to_string());
    let mut runtime = HookRuntime::new(&env, &GitSnapshots);
    CALLED_AT.clone_into(&mut runtime.now);
    if let Some(limits) = limits {
        runtime.lock_limits = limits;
    }
    let before = format_utc_seconds(SystemTime::now());
    assert_eq!(
        run_hook("claude", &prompt(cwd), &runtime),
        HookOutcome::Applied
    );
    before
}

/// A prompt that found the lock free is stamped once it holds it too: a
/// restore may have run and let go between the call and the lock.
#[test]
fn a_prompt_with_the_lock_free_is_stamped_once_it_holds_it() {
    let repo = Repo::new("lock-free-start");
    let states = repo.root.join("support/states");
    let before = prompt_called_long_ago(&states, &repo.path, None);
    let turn = only_turn(&states);
    assert!(parse_utc_seconds(&turn.started_at) >= parse_utc_seconds(&before));
    assert_eq!(
        run_started_at(&states).as_deref(),
        Some(turn.started_at.as_str())
    );
}

/// A prompt outside a repository takes no lock and keeps its call's time.
#[test]
fn a_prompt_with_no_lock_keeps_its_call_time() {
    let repo = Repo::new("no-lock-start");
    let states = repo.root.join("support/states");
    let outside = repo.root.join("outside");
    fs::create_dir_all(&outside).expect("outside");
    let _ = prompt_called_long_ago(&states, &outside, None);
    assert_eq!(only_turn(&states).started_at, CALLED_AT);
    assert_eq!(run_started_at(&states).as_deref(), Some(CALLED_AT));
}

/// A restore that never lets go: the hook gives up past its whole limit and
/// the agent starts then, so the turn starts when the hook gave up.
#[test]
fn a_prompt_a_restore_never_lets_go_starts_when_the_hook_gives_up() {
    let repo = Repo::new("lock-never-start");
    let states = repo.root.join("support/states");
    let paths = WorktreeLockPaths::new(&repo.git_dir());
    let restore = ExclusiveLock::acquire(&paths, Duration::ZERO, Duration::from_millis(1))
        .expect("no hook holds it");
    let before = prompt_called_long_ago(
        &states,
        &repo.path,
        Some(Limits {
            snapshot: Duration::from_millis(20),
            release: Duration::from_millis(60),
            poll: Duration::from_millis(5),
        }),
    );
    assert_eq!(restore.interruption(), Some(Interruption::AgentAbandoned));
    drop(restore);
    let turn = only_turn(&states);
    assert_eq!(
        turn.begin,
        SnapshotStatus::Skipped {
            reason: "restoreNotResponding".to_owned()
        }
    );
    assert!(parse_utc_seconds(&turn.started_at) >= parse_utc_seconds(&before));
}

#[test]
fn deleting_a_turn_leaves_it_to_the_next_sweep_while_a_restore_runs() {
    let repo = Repo::new("lock-gc");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    let paths = WorktreeLockPaths::new(&repo.git_dir());
    let restore = ExclusiveLock::acquire(&paths, Duration::ZERO, Duration::from_millis(1))
        .expect("no hook holds it");

    let outcome = delete_turns_waiting(
        &turns,
        std::slice::from_ref(&turn.turn_id),
        &GitSnapshots,
        Duration::from_millis(50),
    );

    assert_eq!(
        outcome,
        vec![TurnDeletion::Failed {
            turn_id: turn.turn_id.clone(),
            reason: "restoreInProgress".to_owned()
        }]
    );
    let record_listing = fs::read_dir(&turns)
        .expect("turns")
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.contains(&turn.turn_id))
        .collect::<Vec<_>>();
    assert_eq!(
        record_listing,
        [format!("{}.turn.json", turn.turn_id)],
        "the record is not moved while the restore runs"
    );
    assert_eq!(
        restore.interruption(),
        None,
        "a sweep does not stop a restore"
    );
    assert!(turn_ref(&repo, &turn.turn_id, "begin").is_some());
    assert!(turns.join(format!("{}.turn.json", turn.turn_id)).exists());
    drop(restore);
    assert_eq!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots),
        vec![TurnDeletion::Deleted {
            turn_id: turn.turn_id.clone()
        }]
    );
}
