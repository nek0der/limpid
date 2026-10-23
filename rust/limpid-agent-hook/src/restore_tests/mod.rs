//! Restores against a real scratch repository, with turns recorded the way
//! the hook records them.

use super::apply::{WRITE_BATCH, settled_stage};
use super::journal::{StoreError, is_final};
use super::pins::{Noted, is_restore_ref, is_worktree_name};
use super::write::{Unwritten, Writer};
use super::*;
use crate::worktree_lock::Limits;
use crate::{GitSnapshots, HookEnv, HookOutcome, HookRuntime, run_hook};
use limpid_agent_model::{
    FailedPath, FailedReason, StageReason, restore_current_ref, restore_expected_ref, restore_refs,
    restore_target_ref, restore_undo_ref,
};
use std::process::Command;

mod applying;
mod discarding;
#[path = "../../tests/support/git_runner.rs"]
mod git_runner;
mod pinning;
mod recovery;
mod undoing;
mod writing;

const PANE: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10";
const RUN: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11";
const NOW: &str = "2026-10-13T00:00:00Z";

struct Repo {
    scratch: PathBuf,
    path: PathBuf,
    states: PathBuf,
}

impl Repo {
    fn new(name: &str) -> Self {
        let scratch =
            std::env::temp_dir().join(format!("limpid-restore-{name}-{}", uuid::Uuid::new_v4()));
        let path = scratch.join("repo");
        fs::create_dir_all(&path).unwrap();
        let repo = Self {
            states: scratch.join("states"),
            scratch,
            path,
        };
        repo.git(&["init", "-q", "-b", "main"]);
        // The restore runs git with the developer's own configuration,
        // where a global `core.excludesFile` that ignores, say, `*.bin`
        // would hide the fixtures' untracked files from it.
        repo.git(&["config", "core.excludesFile", "/dev/null"]);
        repo.write("a.txt", "a\n");
        repo.write("keep.txt", "keep\n");
        repo.git(&["add", "-A"]);
        repo.git(&[
            "-c",
            "user.name=fixture",
            "-c",
            "user.email=fixture@example.com",
            "commit",
            "-q",
            "-m",
            "base",
        ]);
        repo
    }

    fn git(&self, args: &[&str]) -> String {
        git_runner::required(&self.path, args)
    }

    fn commit(&self, message: &str) {
        self.git(&[
            "-c",
            "user.name=fixture",
            "-c",
            "user.email=fixture@example.com",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            message,
        ]);
    }

    /// `git` whose failure is an answer, not a broken fixture.
    fn git_status(&self, args: &[&str]) -> Option<String> {
        git_runner::optional(&self.path, args)
    }

    fn git_with_input(&self, args: &[&str], input: &[u8]) {
        use std::io::Write;
        let mut child = Command::new("git")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .arg("-C")
            .arg(&self.path)
            .args(args)
            .stdin(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        assert!(child.wait().unwrap().success(), "git {args:?}");
    }

    fn write(&self, path: &str, contents: &str) {
        let path = self.path.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }

    fn read(&self, path: &str) -> Option<String> {
        fs::read_to_string(self.path.join(path)).ok()
    }

    fn hook(&self, payload: &[u8]) {
        let env = HookEnv::from_pairs([
            ("LIMPID_PANE_ID", PANE),
            ("LIMPID_AGENT_RUN_ID", RUN),
            ("LIMPID_AGENT_STATES_DIR", self.states.to_str().unwrap()),
            (
                "LIMPID_SESSIONS_DIR",
                self.scratch.join("sessions").to_str().unwrap(),
            ),
            // A live process, so the run counts as at work while its
            // record says so.
            ("LIMPID_CLAUDE_PID", &std::process::id().to_string()),
            (
                "LIMPID_HOOK_INVOCATION_ID",
                &uuid::Uuid::new_v4().to_string(),
            ),
        ]);
        let mut runtime = HookRuntime::new(&env, &GitSnapshots);
        runtime.lock_limits = Limits {
            snapshot: Duration::from_millis(50),
            release: Duration::from_millis(100),
            poll: Duration::from_millis(5),
        };
        assert_eq!(run_hook("claude", payload, &runtime), HookOutcome::Applied);
    }

    /// One turn: a prompt, `work` on the working tree, and the stop. Returns
    /// the turn's id.
    fn turn(&self, work: impl FnOnce(&Self)) -> String {
        self.hook(
            format!(
                r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"go","cwd":"{}"}}"#,
                self.path.display()
            )
            .as_bytes(),
        );
        let record = read_record(
            &self
                .states
                .join(limpid_agent_model::run_record_file_name(RUN)),
        )
        .unwrap();
        let turn_id = record.current_turn_id.unwrap();
        work(self);
        self.hook(br#"{"hook_event_name":"Stop","session_id":"s1"}"#);
        turn_id
    }

    fn request(&self, turn_id: &str) -> RestoreRequest {
        RestoreRequest {
            root: self.path.clone(),
            turn_id: turn_id.to_owned(),
            pane_id: PANE.to_owned(),
            state_directories: vec![StateDirectory {
                provider: "claude".to_owned(),
                directory: self.states.clone(),
            }],
        }
    }

    fn restore(&self, turn_id: &str) -> RestoreOutcome {
        restore_turn(&self.request(turn_id), NOW)
    }

    fn undo(&self, op_id: &str) -> RestoreOutcome {
        undo_restore(
            &UndoRequest {
                root: self.path.clone(),
                op_id: op_id.to_owned(),
                state_directories: self.request("").state_directories,
            },
            NOW,
        )
    }

    fn worktree(&self) -> Worktree {
        Worktree::open(&self.path).unwrap()
    }
}

impl Drop for Repo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.scratch);
    }
}

fn finished(outcome: RestoreOutcome) -> RestoreJournal {
    match outcome {
        RestoreOutcome::Finished { journal } => *journal,
        RestoreOutcome::Refused { refusal } => panic!("refused: {refusal:?}"),
    }
}

fn refused(outcome: RestoreOutcome) -> Refusal {
    match outcome {
        RestoreOutcome::Refused { refusal } => refusal,
        RestoreOutcome::Finished { journal } => panic!("finished: {:?}", journal.stage),
    }
}

/// A turn that edits `a.txt`, adds `new/made.txt`, and deletes `keep.txt`.
fn busy_turn(repo: &Repo) -> String {
    repo.turn(|repo| {
        repo.write("a.txt", "a\nchanged\n");
        repo.write("new/made.txt", "made\n");
        fs::remove_file(repo.path.join("keep.txt")).unwrap();
    })
}

/// Places a waiting hook's marker, as a prompt given during a restore does.
fn place_waiting_marker(repo: &Repo) {
    let waiting = repo.worktree().git_dir.join("limpid/worktree.lock.waiting");
    fs::create_dir_all(&waiting).unwrap();
    let me = std::process::id();
    let started = crate::process::start_epoch(me).unwrap();
    fs::write(waiting.join("hook.1"), format!("{me} {started}\n")).unwrap();
}

/// The restore of `turn` with `edit` run once its paths are written and
/// before it looks at the working tree again: another writer, which takes
/// no lock.
fn restore_meeting(repo: &Repo, turn: &str, edit: impl Fn(&Repo)) -> RestoreJournal {
    let seams = Seams {
        after_journal: &nothing,
        after_write: &|| edit(repo),
        in_write: &nothing_at,
        in_rollback: &nothing_at,
    };
    finished(outcome(restore_turn_inner(
        &repo.request(turn),
        NOW,
        &seams,
    )))
}

/// Drops every object no ref reaches, as `git gc` does once its grace
/// period is over.
fn collect_garbage(repo: &Repo) {
    repo.git(&["gc", "--quiet", "--prune=now"]);
}

fn is_pinned(repo: &Repo, name: &str) -> bool {
    repo.git_status(&["rev-parse", "-q", "--verify", name])
        .is_some()
}

/// Every ref an operation holds, and whether the file naming them is there.
fn held(repo: &Repo, op_id: &str) -> (Vec<String>, bool) {
    let names = restore_refs(op_id)
        .into_iter()
        .filter(|name| is_pinned(repo, name))
        .collect();
    (names, repo.worktree().refs_file(op_id).exists())
}
