//! These tests end a turn the person stopped, which no hook reports, as the
//! app's writer does once a pass reads it (`end_stopped_turn`): a wait
//! declined at Claude's own prompt, read from the transcript or from Claude's
//! own status report, and work stopped with Esc or Ctrl+C, read from that
//! report. They run against a real scratch repository, so the turn's end
//! snapshot and difference are the hook's own. They are Unix only, since the
//! hook runtime itself only runs there.
#![cfg(unix)]

mod support;

use std::fs;
use std::path::{Path, PathBuf};
use support::{RUN, Repo, SESSION_START, call, only_turn, prompt};
use weir_agent_hook::{
    GitSnapshots, HookLog, StoppedTurnEnd, StoppedTurnRequest, end_stopped_turn,
};
use weir_agent_model::{
    ChangeSummary, ProviderId, RunRecord, RunState, SnapshotStatus, TurnPhase, TurnUsage,
    run_record_file_name,
};

const OPEN: &[u8] = include_bytes!("../../fixtures/transcripts/claude-2.1.309-question-open.jsonl");
const DECLINED: &[u8] =
    include_bytes!("../../fixtures/transcripts/claude-2.1.309-question-declined.jsonl");
const NOW: &str = "2026-10-23T00:00:00Z";

/// This is a run in `repo` whose turn waits on Claude's question, with the
/// transcript the question named still showing it up.
struct Waiting {
    repo: Repo,
    states: PathBuf,
    transcript: PathBuf,
}

impl Waiting {
    fn new(name: &str) -> Self {
        let repo = Repo::new(name);
        let states = repo.root.join("support/states");
        let transcript = repo.root.join("session.jsonl");
        fs::write(&transcript, OPEN).expect("transcript");
        call(&states, SESSION_START);
        call(&states, &prompt(&repo.path));
        call(&states, &question(&repo.path, &transcript));
        let waiting = Self {
            repo,
            states,
            transcript,
        };
        let record = waiting.record();
        assert_eq!(record.state, RunState::NeedsInput);
        assert_eq!(
            record.transcript_path.as_deref(),
            waiting.transcript.to_str()
        );
        waiting
    }

    fn record_path(&self) -> PathBuf {
        self.states.join(run_record_file_name(RUN))
    }

    fn record(&self) -> RunRecord {
        RunRecord::decode(&fs::read(self.record_path()).expect("record")).expect("decodes")
    }

    /// Returns what a pass that read the record now would hand the writer.
    fn request(&self) -> StoppedTurnRequest {
        let record = self.record();
        StoppedTurnRequest {
            provider: ProviderId::new("claude").expect("id"),
            state_directory: self.states.clone(),
            storage_id: RUN.to_owned(),
            episode_token: record.state_episode_token.expect("token"),
            turn_id: record.current_turn_id,
            transcript_path: record.transcript_path.expect("transcript"),
            by_program_status: false,
        }
    }

    /// The person presses Esc: Claude appends the rejection and the
    /// interrupt, and sends no hook.
    fn decline(&self) {
        fs::write(&self.transcript, DECLINED).expect("transcript");
    }
}

fn question(cwd: &Path, transcript: &Path) -> Vec<u8> {
    serde_json::json!({
        "hook_event_name": "PreToolUse",
        "session_id": "s1",
        "cwd": cwd,
        "tool_name": "AskUserQuestion",
        "tool_use_id": "toolu_012criWbA7VgNjK5tUaemUuB",
        "tool_input": {"questions": [{"question": "Which color?", "options": []}]},
        "transcript_path": transcript,
    })
    .to_string()
    .into_bytes()
}

fn end(request: &StoppedTurnRequest) -> StoppedTurnEnd {
    end_stopped_turn(request, &GitSnapshots, NOW, &HookLog::disabled())
}

#[test]
fn a_declined_wait_ends_the_run_and_its_turn_as_an_interrupt_does() {
    let waiting = Waiting::new("declined");
    fs::write(waiting.repo.path.join("README.md"), "fixture\nchanged\n").expect("edit");
    waiting.decline();
    let before = waiting.record();
    let request = waiting.request();

    assert_eq!(end(&request), StoppedTurnEnd::Ended);
    let record = waiting.record();
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.run_started_at, None);
    assert_eq!(record.wait_kind, None);
    assert_eq!(record.detail, None);
    assert_eq!(record.transcript_path, None);
    assert_eq!(record.state_episode_token, before.state_episode_token);
    assert_eq!(record.current_turn_id, before.current_turn_id);
    assert_eq!(record.pid, before.pid);
    assert_eq!(
        record.revision,
        before.revision.map(|revision| revision + 1)
    );

    let turn = only_turn(&waiting.states);
    assert_eq!(Some(&turn.turn_id), before.current_turn_id.as_ref());
    assert_eq!(turn.phase, TurnPhase::Interrupted);
    assert_eq!(turn.finished_at.as_deref(), Some(NOW));
    assert!(
        matches!(turn.end, SnapshotStatus::Captured { .. }),
        "{:?}",
        turn.end
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
    assert!(
        support::turn_ref(&waiting.repo, &turn.turn_id, "end").is_some(),
        "the end is pinned"
    );

    // We ask again, as a retry or a later pass would: the record is no
    // longer the wait, so nothing is written twice.
    let written = fs::read(waiting.record_path()).expect("record");
    assert_eq!(end(&request), StoppedTurnEnd::MovedOn);
    assert_eq!(fs::read(waiting.record_path()).expect("record"), written);
}

#[test]
fn a_record_that_moved_on_is_not_written() {
    let waiting = Waiting::new("moved-on");
    waiting.decline();
    let request = waiting.request();
    // The person types the next prompt before the write lands.
    call(&waiting.states, &prompt(&waiting.repo.path));
    let moved = fs::read(waiting.record_path()).expect("record");
    let next_turn = waiting.record().current_turn_id;
    assert_ne!(next_turn, request.turn_id);

    assert_eq!(end(&request), StoppedTurnEnd::MovedOn);
    assert_eq!(fs::read(waiting.record_path()).expect("record"), moved);
    let record = waiting.record();
    assert_eq!(record.state, RunState::Running);
    assert_eq!(record.current_turn_id, next_turn);

    // A request for another episode of the same run is not this wait's.
    let waiting = Waiting::new("other-episode");
    waiting.decline();
    let stale = StoppedTurnRequest {
        episode_token: "another".to_owned(),
        ..waiting.request()
    };
    let unchanged = fs::read(waiting.record_path()).expect("record");
    assert_eq!(end(&stale), StoppedTurnEnd::MovedOn);
    assert_eq!(fs::read(waiting.record_path()).expect("record"), unchanged);
}

#[test]
fn a_wait_whose_transcript_still_shows_it_open_is_not_written() {
    let waiting = Waiting::new("open");
    let unchanged = fs::read(waiting.record_path()).expect("record");
    assert_eq!(end(&waiting.request()), StoppedTurnEnd::NotDeclined);
    assert_eq!(fs::read(waiting.record_path()).expect("record"), unchanged);
    let turn = only_turn(&waiting.states);
    assert_eq!(turn.phase, TurnPhase::Started);

    // Nor is a request that names a file other than a transcript written.
    waiting.decline();
    let elsewhere = StoppedTurnRequest {
        transcript_path: "relative/session.jsonl".to_owned(),
        ..waiting.request()
    };
    assert_eq!(end(&elsewhere), StoppedTurnEnd::NotDeclined);
    assert_eq!(fs::read(waiting.record_path()).expect("record"), unchanged);
}

#[test]
fn a_request_that_names_no_record_is_refused() {
    let waiting = Waiting::new("no-record");
    waiting.decline();
    let outside = StoppedTurnRequest {
        storage_id: "../escape".to_owned(),
        ..waiting.request()
    };
    assert_eq!(end(&outside), StoppedTurnEnd::Failed);
    let unknown = StoppedTurnRequest {
        provider: ProviderId::new("other").expect("id"),
        ..waiting.request()
    };
    assert_eq!(end(&unknown), StoppedTurnEnd::Failed);
    assert_eq!(waiting.record().state, RunState::NeedsInput);
}

#[test]
fn a_wait_the_agent_reported_idle_after_ends_without_the_transcript() {
    // "No" at Claude's permission prompt leaves no line in the transcript
    // that reads declined; Claude's own OSC 7501 report says it is idle.
    let waiting = Waiting::new("reported-idle");
    let request = StoppedTurnRequest {
        by_program_status: true,
        ..waiting.request()
    };
    assert_eq!(end(&request), StoppedTurnEnd::Ended);
    assert_eq!(waiting.record().state, RunState::Finished);
    assert_eq!(only_turn(&waiting.states).phase, TurnPhase::Interrupted);

    // The record check still stops a write the next prompt overtook.
    let waiting = Waiting::new("reported-idle-moved-on");
    let request = StoppedTurnRequest {
        by_program_status: true,
        ..waiting.request()
    };
    call(&waiting.states, &prompt(&waiting.repo.path));
    let moved = fs::read(waiting.record_path()).expect("record");
    assert_eq!(end(&request), StoppedTurnEnd::MovedOn);
    assert_eq!(fs::read(waiting.record_path()).expect("record"), moved);
}

/// Returns a prompt in `cwd` that names its transcript and its id, as
/// Claude Code's `UserPromptSubmit` does.
fn named_prompt(cwd: &Path, transcript: &Path) -> Vec<u8> {
    serde_json::json!({
        "hook_event_name": "UserPromptSubmit",
        "session_id": "s1",
        "prompt": "change it",
        "prompt_id": "p1",
        "cwd": cwd,
        "transcript_path": transcript,
    })
    .to_string()
    .into_bytes()
}

#[test]
fn work_the_person_stopped_ends_its_turn_with_what_it_used() {
    let repo = Repo::new("interrupted");
    let states = repo.root.join("support/states");
    let transcript = repo.root.join("session.jsonl");
    // The prompt, a response that started a tool, and the line Claude
    // writes when Esc stops it.
    let lines = [
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"role":"user","content":"change it"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"req_1","message":{"id":"msg_1","role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"output_tokens":40}}}"#,
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t"}]}}"#,
        r#"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
    ];
    fs::write(&transcript, lines.join("\n") + "\n").expect("transcript");
    call(&states, SESSION_START);
    call(&states, &named_prompt(&repo.path, &transcript));
    fs::write(repo.path.join("README.md"), "fixture\nchanged\n").expect("edit");
    let record_path = states.join(run_record_file_name(RUN));
    let read = || RunRecord::decode(&fs::read(&record_path).expect("record")).expect("decodes");
    let before = read();
    assert_eq!(before.state, RunState::Running);
    assert_eq!(before.transcript_path.as_deref(), transcript.to_str());

    // Claude reported itself idle; the pass hands the writer the turn.
    let request = StoppedTurnRequest {
        provider: ProviderId::new("claude").expect("id"),
        state_directory: states.clone(),
        storage_id: RUN.to_owned(),
        episode_token: before.state_episode_token.clone().expect("token"),
        turn_id: before.current_turn_id.clone(),
        transcript_path: before.transcript_path.clone().expect("transcript"),
        by_program_status: true,
    };
    assert_eq!(end(&request), StoppedTurnEnd::Ended);
    let record = read();
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.run_started_at, None);
    assert_eq!(record.transcript_path, None);
    assert_eq!(record.state_episode_token, before.state_episode_token);

    let turn = only_turn(&states);
    assert_eq!(turn.phase, TurnPhase::Interrupted);
    assert_eq!(turn.finished_at.as_deref(), Some(NOW));
    assert!(
        matches!(turn.changes, ChangeSummary::Changed { files: 1, .. }),
        "{:?}",
        turn.changes
    );
    assert_eq!(
        turn.usage,
        Some(TurnUsage {
            input_tokens: 10,
            cache_write_tokens: 200,
            cache_read_tokens: 3000,
            output_tokens: 40,
            is_partial: false,
        }),
        "what the turn used up to the Esc, read from the transcript"
    );

    // A retry finds the record no longer that turn.
    assert_eq!(end(&request), StoppedTurnEnd::MovedOn);
}

#[test]
fn a_stopped_turn_waits_for_lines_that_reach_the_transcript_after_the_report() {
    // Claude reports itself idle a few milliseconds before the stopped
    // reply's lines reach the file.
    let repo = Repo::new("late-lines");
    let states = repo.root.join("support/states");
    let transcript = repo.root.join("session.jsonl");
    let prompt_line = r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"role":"user","content":"change it"}}"#;
    fs::write(&transcript, format!("{prompt_line}\n")).expect("transcript");
    call(&states, SESSION_START);
    call(&states, &named_prompt(&repo.path, &transcript));
    let record =
        RunRecord::decode(&fs::read(states.join(run_record_file_name(RUN))).expect("record"))
            .expect("decodes");
    let request = StoppedTurnRequest {
        provider: ProviderId::new("claude").expect("id"),
        state_directory: states.clone(),
        storage_id: RUN.to_owned(),
        episode_token: record.state_episode_token.expect("token"),
        turn_id: record.current_turn_id,
        transcript_path: record.transcript_path.expect("transcript"),
        by_program_status: true,
    };
    let late = {
        let transcript = transcript.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(200));
            let lines = [
                prompt_line,
                r#"{"type":"assistant","isSidechain":false,"requestId":"req_1","message":{"id":"msg_1","role":"assistant","usage":{"input_tokens":4,"cache_creation_input_tokens":319,"cache_read_input_tokens":45055,"output_tokens":6}}}"#,
                r#"{"type":"user","isSidechain":false,"message":{"role":"user","content":"[Request interrupted by user]"}}"#,
            ];
            fs::write(&transcript, lines.join("\n") + "\n").expect("transcript");
        })
    };
    assert_eq!(end(&request), StoppedTurnEnd::Ended);
    late.join().expect("writer");
    let usage = only_turn(&states).usage.expect("usage");
    assert_eq!(
        (
            usage.input_tokens,
            usage.cache_write_tokens,
            usage.output_tokens
        ),
        (4, 319, 6)
    );
    assert!(!usage.is_partial);
}
