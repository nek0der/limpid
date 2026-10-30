//! A turn's snapshots against a real scratch repository: what a turn records,
//! and which turn a late write or a late stop belongs to. Unix only: the hook
//! runtime itself only runs there.
#![cfg(unix)]

mod support;

use limpid_agent_hook::{
    GitSnapshots, HookOutcome, HookRuntime, LARGE_FILE_BYTES, NoSnapshots, SnapshotRunner,
    TurnSide, run_hook,
};
use limpid_agent_model::{ChangeSummary, SnapshotStatus, TurnPhase};
use std::fs;
use std::path::{Path, PathBuf};
use support::{
    PANE, RUN, Repo, SESSION_START, STOP, STOP_AFTER_STOP_HOOK, call, call_as, git, only_turn,
    prompt, provider_env, read_turns, turn_env,
};

#[test]
fn capture_writes_a_private_index_without_touching_the_real_index() {
    let repo = Repo::new("capture");
    fs::write(repo.path.join("untracked.txt"), "new\n").expect("untracked");
    let (tree, root) = captured(
        &GitSnapshots
            .capture(&repo.path, PANE, TurnSide::Begin)
            .status,
    );
    assert_eq!(tree.len(), 40);
    assert_eq!(
        Path::new(&root).canonicalize().ok(),
        repo.path.canonicalize().ok()
    );
    let key = PANE.to_ascii_lowercase();
    let pane_ref = format!("refs/limpid/turn/{key}");
    // The pane has no ref of its own: the turn record holds the tree.
    assert_eq!(
        git(&repo.path, &["rev-parse", "--verify", "-q", &pane_ref]),
        None
    );
    assert!(
        repo.git_dir()
            .join("limpid")
            .join(format!("turn-{key}.index"))
            .exists()
    );
    // The untracked file is in the snapshot tree but still untracked for the user.
    assert!(
        git(&repo.path, &["ls-tree", "--name-only", &tree])
            .expect("tree")
            .contains("untracked.txt")
    );
    assert_eq!(
        git(&repo.path, &["status", "--porcelain"]).as_deref(),
        Some("?? untracked.txt")
    );

    // What an earlier build left: the pane's ref, and the read index its
    // review wrote. Removal still takes both.
    git(&repo.path, &["update-ref", &pane_ref, &tree]).expect("earlier ref");
    fs::write(
        repo.git_dir()
            .join("limpid")
            .join(format!("turn-{key}.read.index")),
        b"",
    )
    .expect("read index");
    GitSnapshots.remove(&repo.path, PANE).expect("remove");
    assert_eq!(
        git(&repo.path, &["rev-parse", "--verify", "-q", &pane_ref]),
        None
    );
    assert!(
        !repo
            .git_dir()
            .join("limpid")
            .join(format!("turn-{key}.index"))
            .exists()
    );
    assert!(
        !repo
            .git_dir()
            .join("limpid")
            .join(format!("turn-{key}.read.index"))
            .exists()
    );
}

fn captured(status: &SnapshotStatus) -> (String, String) {
    match status {
        SnapshotStatus::Captured { tree, root } => (tree.clone(), root.clone()),
        other => panic!("not captured: {other:?}"),
    }
}

#[test]
fn a_turn_records_what_it_changed_and_pins_both_trees() {
    let repo = Repo::new("turn");
    let states = repo.root.join("support/states");
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook(
        "claude",
        SESSION_START,
        &HookRuntime::new(&env, &NoSnapshots),
    );
    let first = uuid::Uuid::new_v4().to_string();
    let second = uuid::Uuid::new_v4().to_string();
    let env = turn_env(&states, &first);
    assert_eq!(
        run_hook(
            "claude",
            &prompt(&repo.path),
            &HookRuntime::new(&env, &GitSnapshots)
        ),
        HookOutcome::Applied
    );
    fs::write(repo.path.join("README.md"), "fixture\nchanged\n").expect("edit");
    let env = turn_env(&states, &second);
    assert_eq!(
        run_hook("claude", STOP, &HookRuntime::new(&env, &GitSnapshots)),
        HookOutcome::Applied
    );

    let turn = only_turn(&states);
    assert_eq!(turn.phase, TurnPhase::Finished);
    assert_eq!(turn.display_number, 1);
    assert_eq!(turn.conversation.conversation_id, "s1");
    assert_eq!(
        turn.git_context
            .as_ref()
            .and_then(|context| context.branch.as_deref()),
        Some("main")
    );
    assert!(
        matches!(
            turn.changes,
            ChangeSummary::Changed {
                files: 1,
                added: 1,
                removed: 0,
                ..
            }
        ),
        "{:?}",
        turn.changes
    );
    for side in ["begin", "end"] {
        assert!(
            git(
                &repo.path,
                &[
                    "rev-parse",
                    "--verify",
                    "-q",
                    &format!("refs/limpid/turns/{}/{side}", turn.turn_id)
                ]
            )
            .is_some(),
            "{side} is pinned"
        );
    }
    // Only the turn's refs: the pane has none.
    let key = PANE.to_ascii_lowercase();
    assert!(
        git(
            &repo.path,
            &[
                "rev-parse",
                "--verify",
                "-q",
                &format!("refs/limpid/turn/{key}")
            ]
        )
        .is_none()
    );
}

#[test]
fn large_untracked_files_are_recorded_not_counted() {
    let repo = Repo::new("large");
    let large = vec![b'x'; usize::try_from(LARGE_FILE_BYTES + 1).expect("size")];
    fs::write(repo.path.join("dump.bin"), &large).expect("large");
    fs::write(repo.path.join("small.txt"), "small\n").expect("small");

    let begin = GitSnapshots.capture(&repo.path, PANE, TurnSide::Begin);
    let (tree, _) = captured(&begin.status);
    let names = git(&repo.path, &["ls-tree", "--name-only", &tree]).expect("tree");
    assert!(names.contains("small.txt"));
    assert!(
        !names.contains("dump.bin"),
        "the large file is left out of the tree"
    );
    assert_eq!(begin.skipped.len(), 1);
    assert_eq!(begin.skipped[0].path, "dump.bin");
    assert_eq!(begin.skipped[0].size_bytes, LARGE_FILE_BYTES + 1);

    // The same file at the end is skipped the same way, so the turn is
    // judged, and the skip is reported with the counts.
    let end = GitSnapshots.capture(&repo.path, PANE, TurnSide::End);
    assert_eq!(end.skipped, begin.skipped);
    let (end_tree, _) = captured(&end.status);
    let diff = GitSnapshots
        .diff(&repo.path, &tree, &end_tree)
        .expect("diff");
    assert_eq!(diff.files, 0);
}

/// A file moved untouched counts as the Changes panel counts it: one file,
/// no lines, rather than a hundred lines removed from one path and added
/// at another.
#[test]
fn a_pure_rename_counts_as_one_file_with_no_lines() {
    let repo = Repo::new("rename");
    let lines: Vec<String> = (0..100).map(|line| format!("line {line}")).collect();
    fs::write(repo.path.join("old.txt"), lines.join("\n") + "\n").expect("old");

    let begin = GitSnapshots.capture(&repo.path, PANE, TurnSide::Begin);
    let (tree, _) = captured(&begin.status);
    fs::rename(repo.path.join("old.txt"), repo.path.join("new.txt")).expect("rename");
    let end = GitSnapshots.capture(&repo.path, PANE, TurnSide::End);
    let (end_tree, _) = captured(&end.status);

    let diff = GitSnapshots
        .diff(&repo.path, &tree, &end_tree)
        .expect("diff");
    assert_eq!(
        (diff.files, diff.added, diff.removed),
        (1, 0, 0),
        "a pure rename is one file with no line changes"
    );
}

/// A turn outside any repository still finishes, and no end is taken where
/// the hook happens to run: that directory may be another repository, which
/// would get the turn's refs.
#[test]
fn a_turn_outside_a_repository_finishes_without_an_end_taken_where_the_hook_runs() {
    let scratch = tempfile::tempdir().expect("scratch");
    let outside = scratch.path().to_path_buf();
    let states = outside.join("support/states");
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook(
        "claude",
        &prompt(&outside),
        &HookRuntime::new(&env, &GitSnapshots),
    );
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    let _ = run_hook("claude", STOP, &HookRuntime::new(&env, &GitSnapshots));

    let turn = only_turn(&states);
    assert_eq!(turn.phase, TurnPhase::Finished);
    assert_eq!(turn.begin, SnapshotStatus::NotGit);
    assert_eq!(
        turn.end,
        SnapshotStatus::Skipped {
            reason: "beginNotCaptured".into()
        }
    );
    assert_eq!(
        turn.changes,
        ChangeSummary::Unavailable {
            reason: "notGit".into()
        }
    );
}

#[test]
fn a_stop_sent_again_after_more_work_takes_the_end_again() {
    // Claude keeps working when another Stop hook blocks the stop, and sends
    // Stop again at the real end. What it did in between belongs to the turn.
    let repo = Repo::new("restop");
    let states = repo.root.join("support/states");
    call(&states, SESSION_START);
    call(&states, &prompt(&repo.path));
    call(&states, STOP);
    assert_eq!(only_turn(&states).changes, ChangeSummary::Unchanged);

    fs::write(repo.path.join("README.md"), "fixture\nlater\n").expect("edit");
    call(&states, STOP_AFTER_STOP_HOOK);

    let turn = only_turn(&states);
    assert_eq!(turn.phase, TurnPhase::Finished);
    assert!(
        matches!(turn.changes, ChangeSummary::Changed { files: 1, .. }),
        "{:?}",
        turn.changes
    );
    assert_eq!(turn.applied_events.len(), 3, "the prompt and both stops");
}

const LATE_WRITE: &[u8] = br#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Write","tool_use_id":"toolu_late","tool_input":{"file_path":"README.md"}}"#;
const IDLE_PROMPT: &[u8] = br#"{"hook_event_name":"Notification","session_id":"s1","notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#;

#[test]
fn a_late_tools_change_joins_the_turn_whose_stop_came_first() {
    // Claude's TUI has sent a turn's Stop before the PreToolUse of a tool
    // the turn still ran, with no Stop after it. The idle prompt closes that
    // work, and what it changed belongs to the turn.
    let repo = Repo::new("late-write");
    let states = repo.root.join("support/states");
    call(&states, SESSION_START);
    call(&states, &prompt(&repo.path));
    call(&states, STOP);
    call(&states, LATE_WRITE);
    fs::write(repo.path.join("README.md"), "fixture\nlater\n").expect("edit");
    call(&states, IDLE_PROMPT);

    let turn = only_turn(&states);
    assert_eq!(turn.phase, TurnPhase::Finished);
    assert!(
        matches!(turn.changes, ChangeSummary::Changed { files: 1, .. }),
        "{:?}",
        turn.changes
    );
    assert_eq!(
        turn.applied_events.len(),
        3,
        "the prompt, the stop, the idle prompt"
    );

    // An idle prompt with nothing at work leaves the turn alone.
    fs::write(repo.path.join("README.md"), "fixture\nlater\nagain\n").expect("edit");
    call(&states, IDLE_PROMPT);
    assert_eq!(only_turn(&states), turn);
}

#[test]
fn a_stop_with_no_prompt_of_its_own_leaves_the_ended_turn_alone() {
    // An agent answering a background task stops again without a prompt.
    // What changed while it waited is not the earlier turn's.
    let repo = Repo::new("stop-alone");
    let states = repo.root.join("support/states");
    call(&states, SESSION_START);
    call(&states, &prompt(&repo.path));
    call(&states, STOP);
    let ended = only_turn(&states);

    fs::write(repo.path.join("README.md"), "fixture\nlater\n").expect("edit");
    call(&states, STOP);

    let mut turns = read_turns(&states).expect("turns");
    turns.sort_by_key(|turn| turn.display_number);
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0], ended, "the ended turn keeps its end");
    assert_eq!(
        turns[1].changes,
        ChangeSummary::Unavailable {
            reason: "beginMissing".into()
        }
    );
}

#[test]
fn a_large_file_beside_an_edit_is_counted_as_skipped() {
    let repo = Repo::new("large-turn");
    let states = repo.root.join("support/states");
    let large = vec![b'x'; usize::try_from(LARGE_FILE_BYTES + 1).expect("size")];
    fs::write(repo.path.join("dump.bin"), &large).expect("large");
    call(&states, SESSION_START);
    call(&states, &prompt(&repo.path));
    fs::write(repo.path.join("README.md"), "fixture\nchanged\n").expect("edit");
    call(&states, STOP);

    let turn = only_turn(&states);
    assert_eq!(turn.skipped_begin.len(), 1);
    assert_eq!(turn.skipped_end, turn.skipped_begin);
    assert!(
        matches!(
            turn.changes,
            ChangeSummary::Changed {
                files: 1,
                large_files_skipped: 1,
                ..
            }
        ),
        "{:?}",
        turn.changes
    );
}

#[test]
fn a_large_file_is_excluded_by_its_literal_name() {
    // `a*.bin` as a pattern would also exclude the small `ab.bin`.
    let repo = Repo::new("glob");
    let large = vec![b'x'; usize::try_from(LARGE_FILE_BYTES + 1).expect("size")];
    fs::write(repo.path.join("a*.bin"), &large).expect("large");
    fs::write(repo.path.join("ab.bin"), "small\n").expect("small");

    let begin = GitSnapshots.capture(&repo.path, PANE, TurnSide::Begin);
    let (tree, _) = captured(&begin.status);
    let names = git(&repo.path, &["ls-tree", "--name-only", &tree]).expect("tree");
    assert!(names.lines().any(|name| name == "ab.bin"), "{names}");
    assert!(!names.lines().any(|name| name.contains('*')), "{names}");
    assert_eq!(begin.skipped.len(), 1);
}

#[test]
fn ending_the_session_keeps_the_turns_refs() {
    let repo = Repo::new("session-end");
    let states = repo.root.join("support/states");
    call(&states, SESSION_START);
    call(&states, &prompt(&repo.path));
    call(&states, STOP);
    call(
        &states,
        br#"{"hook_event_name":"SessionEnd","session_id":"s1","reason":"logout"}"#,
    );

    let turn = only_turn(&states);
    for side in ["begin", "end"] {
        assert!(
            git(
                &repo.path,
                &[
                    "rev-parse",
                    "--verify",
                    "-q",
                    &format!("refs/limpid/turns/{}/{side}", turn.turn_id)
                ]
            )
            .is_some(),
            "{side} is kept for the turn"
        );
    }
}

#[test]
fn capture_outside_a_repository_yields_nothing() {
    let scratch = tempfile::tempdir().expect("scratch");
    let outside = scratch.path().join("plain");
    fs::create_dir_all(&outside).expect("plain dir");
    assert_eq!(
        GitSnapshots.capture(&outside, PANE, TurnSide::Begin).status,
        SnapshotStatus::NotGit
    );
    assert_eq!(GitSnapshots.remove(&outside, PANE), Ok(()));
    // No repository means nothing written: not a `.git/limpid` of our own
    // making in the directory, nor beside it.
    assert!(!outside.join(".git").exists());
    assert!(!scratch.path().join(".git").exists());
}

/// The scratch files go in the git directory git names, as an absolute
/// path. `rev-parse --git-dir` prints `.git` at a worktree's top, and an
/// earlier review read that against a root URL with no trailing slash, which
/// resolved to the root's parent: a temporary repository's snapshot landed
/// in `$TMPDIR/.git/limpid`.
#[test]
fn capture_writes_only_inside_the_repository_git_directory() {
    let repo = Repo::new("contained");
    let nested = repo.path.join("src/deep");
    fs::create_dir_all(&nested).expect("nested");
    for cwd in [&repo.path, &nested] {
        captured(&GitSnapshots.capture(cwd, PANE, TurnSide::Begin).status);
        captured(&GitSnapshots.capture(cwd, PANE, TurnSide::End).status);
        GitSnapshots.remove(cwd, PANE).expect("remove");
    }
    assert!(repo.git_dir().join("limpid").is_dir());
    let beside: Vec<_> = fs::read_dir(&repo.root)
        .expect("root")
        .map(|entry| entry.expect("entry").file_name())
        .collect();
    assert_eq!(beside, vec![std::ffi::OsString::from("repo")]);
    assert!(!repo.path.join("src/.git").exists());
    assert!(!nested.join(".git").exists());
}

/// Git, except that the first end snapshot also lets one hook call land,
/// the way a `Stop` can while an idle prompt's end is prepared.
struct LandsDuringTheEnd<'a> {
    states: &'a Path,
    provider: &'a str,
    payload: &'a [u8],
    has_injected_hook: std::cell::Cell<bool>,
}

impl SnapshotRunner for LandsDuringTheEnd<'_> {
    fn capture(
        &self,
        cwd: &Path,
        pane_id: &str,
        side: TurnSide,
    ) -> limpid_agent_core::SnapshotTaken {
        if side == TurnSide::End && !self.has_injected_hook.replace(true) {
            call_as(self.provider, self.states, self.payload);
        }
        GitSnapshots.capture(cwd, pane_id, side)
    }

    fn worktree(&self, cwd: &Path) -> Option<(PathBuf, PathBuf)> {
        GitSnapshots.worktree(cwd)
    }

    fn diff(&self, root: &Path, begin: &str, end: &str) -> Option<limpid_agent_model::DiffStat> {
        GitSnapshots.diff(root, begin, end)
    }

    fn pin(&self, root: &Path, turn_id: &str, side: TurnSide, tree: &str) -> Result<(), String> {
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
fn an_idle_prompt_whose_run_stopped_while_its_end_was_prepared_writes_nothing() {
    // The real `Stop` of the late work came while the idle prompt took the
    // end snapshot. That stop is the turn's real end; the idle prompt's end
    // was prepared for a run that is no longer at work.
    let repo = Repo::new("late-stop");
    let states = repo.root.join("support/states");
    call(&states, SESSION_START);
    call(&states, &prompt(&repo.path));
    call(&states, STOP);
    call(&states, LATE_WRITE);
    fs::write(repo.path.join("README.md"), "fixture\nlater\n").expect("edit");
    let runner = LandsDuringTheEnd {
        states: &states,
        provider: "claude",
        payload: STOP_AFTER_STOP_HOOK,
        has_injected_hook: std::cell::Cell::new(false),
    };
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    assert_eq!(
        run_hook("claude", IDLE_PROMPT, &HookRuntime::new(&env, &runner)),
        HookOutcome::Applied
    );

    let record = limpid_agent_model::RunRecord::decode(
        &fs::read(states.join(limpid_agent_model::run_record_file_name(RUN))).expect("record"),
    )
    .expect("record");
    assert_eq!(record.last_hook_event.as_deref(), Some("turn_finished"));
    assert_eq!(record.state, limpid_agent_model::RunState::Finished);
    let turn = only_turn(&states);
    assert_eq!(
        turn.applied_events.len(),
        3,
        "the prompt and both stops, not the idle prompt"
    );
}

#[test]
fn an_idle_prompt_overtaken_by_a_prompt_while_its_end_was_prepared_writes_nothing() {
    // The person typed on while the idle prompt took the end snapshot: the
    // new turn has begun, and the ended turn keeps the end its `Stop` gave.
    let repo = Repo::new("late-prompt");
    let states = repo.root.join("support/states");
    call(&states, SESSION_START);
    call(&states, &prompt(&repo.path));
    call(&states, STOP);
    call(&states, LATE_WRITE);
    fs::write(repo.path.join("README.md"), "fixture\nlater\n").expect("edit");
    let next_prompt = prompt(&repo.path);
    let runner = LandsDuringTheEnd {
        states: &states,
        provider: "claude",
        payload: &next_prompt,
        has_injected_hook: std::cell::Cell::new(false),
    };
    let env = turn_env(&states, &uuid::Uuid::new_v4().to_string());
    assert_eq!(
        run_hook("claude", IDLE_PROMPT, &HookRuntime::new(&env, &runner)),
        HookOutcome::Applied
    );

    let record = limpid_agent_model::RunRecord::decode(
        &fs::read(states.join(limpid_agent_model::run_record_file_name(RUN))).expect("record"),
    )
    .expect("record");
    assert_eq!(record.last_hook_event.as_deref(), Some("prompt_submitted"));
    assert_eq!(record.state, limpid_agent_model::RunState::Running);
    assert!(record.run_started_at.is_some());
    let mut turns = read_turns(&states).expect("turns");
    turns.sort_by_key(|turn| turn.display_number);
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0].applied_events.len(), 2, "the prompt and its stop");
    assert_eq!(turns[0].changes, ChangeSummary::Unchanged);
    assert_eq!(turns[1].phase, TurnPhase::Started);
}

/// Builds the Codex helper's report of a turn that ended at the usage limit,
/// for the rollout at `rollout`, watched from session `s1`.
fn usage_limit_report(rollout: &Path, failed_at: u64) -> Vec<u8> {
    format!(
        r#"{{"hook_event_name":"LimpidTurnFailed","transcript_path":"{}","session_id":"s1","limpid_failed_at":{failed_at}}}"#,
        rollout.display()
    )
    .into_bytes()
}

const LIMITED_ROLLOUT: &str = r#"{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"event_msg","payload":{"type":"task_complete","error":{"message":"Try again later.","codex_error_info":"usage_limit_exceeded"}}}
"#;

#[test]
fn a_usage_limit_overtaken_by_a_prompt_while_its_end_was_prepared_writes_nothing() {
    // The person sent the next prompt while the end of the limited turn was
    // prepared: the new turn runs, and the old limit must not end it.
    let repo = Repo::new("codex-limit-late-prompt");
    let states = repo.root.join("support/states");
    let rollout = repo.root.join("rollout.jsonl");
    fs::write(&rollout, LIMITED_ROLLOUT).expect("rollout");
    let codex_prompt = |text: &str| {
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"{text}","cwd":"{}"}}"#,
            repo.path.display()
        )
        .into_bytes()
    };
    call_as("codex", &states, SESSION_START);
    call_as("codex", &states, &codex_prompt("first"));
    let record = || {
        limpid_agent_model::RunRecord::decode(
            &fs::read(states.join(limpid_agent_model::run_record_file_name(RUN))).expect("record"),
        )
        .expect("record")
    };
    let reached_at = record()
        .run_started_at
        .as_deref()
        .and_then(limpid_agent_model::parse_utc_seconds)
        .expect("the first turn's start");
    // The next prompt comes a second after the limit, as a person's does.
    while limpid_agent_model::parse_utc_seconds(&limpid_agent_hook::format_utc_seconds(
        std::time::SystemTime::now(),
    ))
    .is_some_and(|now| now <= reached_at)
    {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let next_prompt = codex_prompt("second");
    let runner = LandsDuringTheEnd {
        states: &states,
        provider: "codex",
        payload: &next_prompt,
        has_injected_hook: std::cell::Cell::new(false),
    };
    let env = provider_env("codex", &states, &uuid::Uuid::new_v4().to_string());
    assert_eq!(
        run_hook(
            "codex",
            &usage_limit_report(&rollout, reached_at),
            &HookRuntime::new(&env, &runner)
        ),
        HookOutcome::Applied
    );
    assert!(
        runner.has_injected_hook.get(),
        "the end of the limited turn was prepared"
    );

    let record = record();
    assert_eq!(record.state, limpid_agent_model::RunState::Running);
    assert!(record.run_started_at.is_some(), "the second turn runs");
    assert_eq!(record.usage_limit, None);
    assert_eq!(record.last_prompt.as_deref(), Some("second"));
}

const STOP_FAILURE: &[u8] =
    br#"{"hook_event_name":"StopFailure","session_id":"s1","error":"server_error"}"#;

#[test]
fn a_late_tool_after_a_failure_joins_the_failed_turn_as_failed() {
    // Taking the end again adds what the late work changed; the turn still
    // ended the way it did.
    let repo = Repo::new("late-after-failure");
    let states = repo.root.join("support/states");
    call(&states, SESSION_START);
    call(&states, &prompt(&repo.path));
    call(&states, STOP_FAILURE);
    assert_eq!(only_turn(&states).phase, TurnPhase::Failed);
    call(&states, LATE_WRITE);
    fs::write(repo.path.join("README.md"), "fixture\nlater\n").expect("edit");
    call(&states, IDLE_PROMPT);

    let turn = only_turn(&states);
    assert_eq!(turn.phase, TurnPhase::Failed);
    assert!(
        matches!(turn.changes, ChangeSummary::Changed { files: 1, .. }),
        "{:?}",
        turn.changes
    );
    assert_eq!(turn.applied_events.len(), 3);
}

/// A turn Codex begins itself (a `/goal`) is snapshotted in the directory
/// Codex runs the hook in, the session's, though its first hook is a tool's,
/// whose `cwd` names the folder the tool runs in (Codex 0.166).
#[test]
fn a_codex_goal_turn_is_snapshotted_where_the_hook_runs_not_where_its_first_tool_does() {
    let session = Repo::new("goal-session");
    let other = Repo::new("goal-tool");
    let states = session.root.join("support/states");
    let env = || {
        provider_env("codex", &states, &uuid::Uuid::new_v4().to_string())
            .in_directory(session.path.clone())
    };
    let start = format!(
        r#"{{"hook_event_name":"SessionStart","session_id":"s","cwd":"{}","source":"startup"}}"#,
        session.path.display()
    );
    assert_eq!(
        run_hook(
            "codex",
            start.as_bytes(),
            &HookRuntime::new(&env(), &NoSnapshots)
        ),
        HookOutcome::Applied
    );
    let tool = format!(
        r#"{{"hook_event_name":"PreToolUse","session_id":"s","turn_id":"t1","cwd":"{}","tool_name":"Bash","tool_input":{{"command":"pwd"}},"tool_use_id":"exec-1"}}"#,
        other.path.display()
    );
    assert_eq!(
        run_hook(
            "codex",
            tool.as_bytes(),
            &HookRuntime::new(&env(), &GitSnapshots)
        ),
        HookOutcome::Applied
    );
    let (_, root) = captured(&only_turn(&states).begin);
    assert_eq!(
        Path::new(&root).canonicalize().ok(),
        session.path.canonicalize().ok()
    );
}
