//! The pane and run ids, the scratch repository, and the hook calls the
//! hook's integration tests share.
//!
//! Each test binary compiles this module on its own and uses only part of
//! it, so what one binary leaves unused is not dead code.
#![allow(dead_code)]

use limpid_agent_hook::{
    GitSnapshots, HookEnv, HookOutcome, HookRuntime, NoSnapshots, TURNS_DIRECTORY, run_hook,
};
use limpid_agent_model::TurnRecord;
use std::fs;
use std::path::{Path, PathBuf};

mod git_runner;

pub const PANE: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10";

pub struct Repo {
    pub root: PathBuf,
    pub path: PathBuf,
}

impl Repo {
    pub fn new(name: &str) -> Self {
        Self::at(name, "repo")
    }

    /// A repository at `root/<directory>`, so a test can pick a directory
    /// name with characters a file URL has to escape.
    pub fn at(name: &str, directory: &str) -> Self {
        let root =
            std::env::temp_dir().join(format!("limpid-hook-git-{name}-{}", uuid::Uuid::new_v4()));
        let path = root.join(directory);
        fs::create_dir_all(&path).expect("repo dir");
        git(&path, &["init", "-q", "-b", "main"]);
        // The code under test runs git with the developer's own
        // configuration, where a global `core.excludesFile` that ignores,
        // say, `*.bin` would hide the fixtures' untracked files from it.
        git(&path, &["config", "core.excludesFile", "/dev/null"]);
        fs::write(path.join("README.md"), "fixture\n").expect("readme");
        git(&path, &["add", "README.md"]);
        git(
            &path,
            &[
                "-c",
                "user.name=fixture",
                "-c",
                "user.email=fixture@example.com",
                "commit",
                "-q",
                "-m",
                "base",
            ],
        );
        Self { root, path }
    }

    pub fn git_dir(&self) -> PathBuf {
        self.path.join(".git")
    }
}

impl Drop for Repo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// Runs git without the developer's own configuration; a failed exit is
/// `None`, which the fixtures here read as their answer.
pub use git_runner::optional as git;

/// A Claude pane whose hook calls each carry the invocation id `call`, as
/// the shim exports it.
pub fn turn_env(states: &Path, call: &str) -> HookEnv {
    provider_env("claude", states, call)
}

/// Returns `turn_env` for `provider`'s pane, whose shim names its own
/// directories.
pub fn provider_env(provider: &str, states: &Path, call: &str) -> HookEnv {
    let prefix = if provider == "claude" {
        "LIMPID"
    } else {
        "LIMPID_CODEX"
    };
    HookEnv::from_pairs([
        ("LIMPID_PANE_ID".to_owned(), PANE.to_owned()),
        ("LIMPID_AGENT_RUN_ID".to_owned(), RUN.to_owned()),
        (
            format!("{prefix}_AGENT_STATES_DIR"),
            states.to_str().expect("path").to_owned(),
        ),
        (
            format!("{prefix}_SESSIONS_DIR"),
            states
                .with_file_name("sessions")
                .to_str()
                .expect("path")
                .to_owned(),
        ),
        (
            format!("LIMPID_{}_PID", provider.to_uppercase()),
            "4242".to_owned(),
        ),
        ("LIMPID_HOOK_INVOCATION_ID".to_owned(), call.to_owned()),
    ])
}

pub const RUN: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11";

pub fn prompt(cwd: &Path) -> Vec<u8> {
    format!(
        r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"change it","cwd":"{}"}}"#,
        cwd.display()
    )
    .into_bytes()
}

pub const STOP: &[u8] = br#"{"hook_event_name":"Stop","session_id":"s1"}"#;
pub const STOP_AFTER_STOP_HOOK: &[u8] =
    br#"{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":true}"#;
pub const SESSION_START: &[u8] =
    br#"{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}"#;

pub fn only_turn(states: &Path) -> TurnRecord {
    let mut turns = read_turns(states).expect("turns");
    assert_eq!(turns.len(), 1, "one turn");
    turns.remove(0)
}

/// Returns every turn record in `states`' turns directory, in directory
/// order. A record that does not decode is `InvalidData`, so no caller can
/// take it for a missing directory; how many there should be, their order,
/// and whether no directory means no turns stay with each caller.
pub fn read_turns(states: &Path) -> std::io::Result<Vec<TurnRecord>> {
    let mut turns = Vec::new();
    for entry in fs::read_dir(states.join(TURNS_DIRECTORY))? {
        let entry = entry?;
        if !entry.file_name().to_string_lossy().ends_with(".turn.json") {
            continue;
        }
        let turn = TurnRecord::decode(&fs::read(entry.path())?)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
        turns.push(turn);
    }
    Ok(turns)
}

/// Sends `payload` as one hook call of the test pane, with a fresh call id.
pub fn call(states: &Path, payload: &[u8]) {
    call_as("claude", states, payload);
}

/// Does what `call` does, for `provider`'s pane.
pub fn call_as(provider: &str, states: &Path, payload: &[u8]) {
    let env = provider_env(provider, states, &uuid::Uuid::new_v4().to_string());
    assert_eq!(
        run_hook(provider, payload, &HookRuntime::new(&env, &GitSnapshots)),
        HookOutcome::Applied
    );
}

/// One finished turn in `repo` that changed README.md, with its states
/// directory.
pub fn recorded_turn(repo: &Repo) -> (PathBuf, TurnRecord) {
    let states = repo.root.join("support/states");
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook(
        "claude",
        SESSION_START,
        &HookRuntime::new(&env, &NoSnapshots),
    );
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook(
        "claude",
        &prompt(&repo.path),
        &HookRuntime::new(&env, &GitSnapshots),
    );
    fs::write(repo.path.join("README.md"), "fixture\nchanged\n").expect("edit");
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook("claude", STOP, &HookRuntime::new(&env, &GitSnapshots));
    let turn = only_turn(&states);
    (states, turn)
}

pub fn turn_ref(repo: &Repo, turn_id: &str, side: &str) -> Option<String> {
    git(
        &repo.path,
        &[
            "rev-parse",
            "--verify",
            "-q",
            &format!("refs/limpid/turns/{turn_id}/{side}"),
        ],
    )
}
