//! What the agent left running after a turn: set by the stop that lists it,
//! kept while the run rests after that turn, and gone with the next turn,
//! failure, interrupt, or session.

use super::*;
use limpid_agent_model::BackgroundWork;

const SHELL: BackgroundWork = BackgroundWork {
    shells: 1,
    subagents: 0,
    others: 0,
};

fn stop(background_work: Option<BackgroundWork>) -> AgentEvent {
    AgentEvent::TurnFinished {
        continues_after_stop_hook: false,
        titles: None,
        cache: None,
        reply: None,
        background_work,
    }
}

/// Replays a recorded Claude case under `fixtures/claude/2026-10` and gives,
/// after each payload, the run's state and what the stop left running.
fn replay(case: &str) -> Vec<(String, RunState, Option<BackgroundWork>)> {
    let adapter = limpid_provider_claude::ClaudeAdapter;
    let case = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures/claude/2026-10")
        .join(case);
    let mut names: Vec<_> = std::fs::read_dir(&case)
        .expect("case")
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| {
            name.starts_with('0') && name.ends_with("json") && !name.contains(".transcript")
        })
        .collect();
    names.sort();
    let mut record: Option<RunRecord> = None;
    let mut seen = Vec::new();
    for name in names {
        let bytes = std::fs::read(case.join(&name)).expect("payload");
        let input = limpid_agent_model::RawHookInput {
            bytes: &bytes,
            transcript: None,
        };
        for event in adapter
            .normalize(input, &limpid_agent_model::HookContext::fixture())
            .expect("normalize")
        {
            if let Some(next) = apply(record.as_ref(), &event, &context(), &claude(), NOW).run {
                record = Some(next);
            }
        }
        let record = record.as_ref().expect("record");
        seen.push((name, record.state, record.background_work));
    }
    seen
}

fn step(
    name: &str,
    state: RunState,
    work: Option<BackgroundWork>,
) -> (String, RunState, Option<BackgroundWork>) {
    (name.to_owned(), state, work)
}

/// The recorded case: a turn starts a shell in the background and ends, and
/// the shell's end opens a turn of Claude's own whose stop lists nothing.
#[test]
fn the_latest_stop_says_what_is_still_running() {
    assert_eq!(
        replay("background-task"),
        vec![
            step("0001-SessionStart.json", RunState::Idle, None),
            step("0002-UserPromptSubmit.json", RunState::Running, None),
            step("0003-Stop.json", RunState::Finished, Some(SHELL)),
            step("0004-UserPromptSubmit.json", RunState::Running, None),
            step("0005-Stop.json", RunState::Finished, None),
            step("0006-SessionEnd.json", RunState::Unknown, None),
        ]
    );
}

/// The recorded case: a turn launches a subagent in the background and
/// ends. The subagent's tools after the stop name it (`agent_id`), and the
/// run stays finished with the subagent counted until its hand-back opens
/// a turn of Claude's own.
#[test]
fn a_background_subagents_tools_leave_the_run_finished() {
    let subagent = Some(BackgroundWork {
        shells: 0,
        subagents: 1,
        others: 0,
    });
    assert_eq!(
        replay("background-subagent"),
        vec![
            step("0001-UserPromptSubmit.json", RunState::Running, None),
            step("0002-PreToolUse.json", RunState::Running, None),
            step("0003-SubagentStart.json", RunState::Running, None),
            step("0004-Stop.json", RunState::Finished, subagent),
            step("0005-PreToolUse.json", RunState::Finished, subagent),
            step("0006-PreToolUse.json", RunState::Finished, subagent),
            step("0007-SubagentStop.json", RunState::Finished, subagent),
            step("0008-UserPromptSubmit.json", RunState::Running, None),
            step("0009-Stop.json", RunState::Finished, None),
        ]
    );
}

/// The agent's own tool after a stop (a stop hook keeping the turn going)
/// is work at the front, and puts the run back to work as before.
#[test]
fn the_agents_own_tool_after_the_stop_is_still_work() {
    let own = AgentEvent::ToolStarted {
        tool: "Bash".into(),
        detail: Some("Bash: make test".into()),
        by_subagent: false,
    };
    let (record, ..) = run(
        &claude(),
        &[started(None), prompt("go"), stop(Some(SHELL)), own],
    );
    assert_eq!(record.state, RunState::Running);
    assert_eq!(record.background_work, Some(SHELL));
}

const SUBAGENT: BackgroundWork = BackgroundWork {
    shells: 0,
    subagents: 1,
    others: 0,
};

fn question_end(by_subagent: bool) -> AgentEvent {
    AgentEvent::ToolFinished {
        tool: Some("AskUserQuestion".into()),
        by_subagent,
    }
}

/// A background subagent's tool ending after the stop (its `PostToolUse`)
/// writes nothing, as its start does: the run stays finished with the
/// subagent counted.
#[test]
fn a_subagents_tool_end_after_the_stop_writes_nothing() {
    let (record, ..) = run(
        &claude(),
        &[started(None), prompt("go"), stop(Some(SUBAGENT))],
    );
    let writes = apply(
        Some(&record),
        &question_end(true),
        &context(),
        &claude(),
        NOW,
    );
    assert_eq!(writes.run, None);
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.background_work, Some(SUBAGENT));
}

/// The agent's own tool ending after a stop still puts the run back to
/// work outside the turn, keeping the stop's count for the rest it returns
/// to.
#[test]
fn the_agents_own_tool_end_after_the_stop_is_still_work() {
    let (record, ..) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            stop(Some(SUBAGENT)),
            question_end(false),
        ],
    );
    assert_eq!(record.state, RunState::Running);
    assert_eq!(record.run_started_at, None);
    assert_eq!(record.outside_turn_rest, Some(RunState::Finished));
    assert_eq!(record.background_work, Some(SUBAGENT));
}

/// A wait a subagent's permission prompt opened after the stop is ended by
/// the subagent's next tool event, as any wait is.
#[test]
fn a_subagents_tool_end_still_ends_its_wait() {
    let approval = AgentEvent::ApprovalRequested {
        detail: Some("Claude needs your permission".into()),
    };
    let (record, ..) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            stop(Some(SUBAGENT)),
            approval,
            question_end(true),
        ],
    );
    assert_eq!(record.state, RunState::Running);
    assert_eq!(record.wait_kind, None);
}

/// At `idle` no stop counted the subagent, so its tools are the one sign of
/// work going on and still show the run working.
#[test]
fn a_subagents_tool_at_idle_still_shows_work() {
    let (record, ..) = run(&claude(), &[started(None), question_end(true)]);
    assert_eq!(record.state, RunState::Running);
    assert_eq!(record.outside_turn_rest, Some(RunState::Idle));
}

/// Work outside the turn (a tool, then the idle prompt) returns the run to
/// the same rest, so what the stop listed still stands; a stop that lists
/// nothing, an empty count included, clears it.
#[test]
fn work_outside_the_turn_keeps_it_and_the_next_stop_replaces_it() {
    let tool = AgentEvent::ToolStarted {
        tool: "Bash".into(),
        detail: Some("Bash: ls".into()),
        by_subagent: false,
    };
    let idle = AgentEvent::AwaitingPrompt {
        awaited_call_ended: false,
    };
    let (record, ..) = run(
        &claude(),
        &[started(None), prompt("go"), stop(Some(SHELL)), tool, idle],
    );
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.background_work, Some(SHELL));

    let (record, ..) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            stop(Some(SHELL)),
            stop(Some(BackgroundWork::default())),
        ],
    );
    assert_eq!(record.background_work, None);
}

/// A stop hook that keeps the turn going leaves the first stop's count on
/// the record while the turn goes on, and the turn's real end replaces it.
#[test]
fn the_stop_after_a_stop_hook_replaces_the_count() {
    let tool = AgentEvent::ToolStarted {
        tool: "Bash".into(),
        detail: Some("Bash: ls".into()),
        by_subagent: false,
    };
    let real_end = AgentEvent::TurnFinished {
        continues_after_stop_hook: true,
        titles: None,
        cache: None,
        reply: None,
        background_work: None,
    };
    let (record, ..) = run(
        &claude(),
        &[started(None), prompt("go"), stop(Some(SHELL)), tool.clone()],
    );
    assert_eq!(record.state, RunState::Running);
    assert_eq!(record.background_work, Some(SHELL));
    let (record, ..) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            stop(Some(SHELL)),
            tool,
            real_end,
        ],
    );
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.background_work, None);
}

/// The person's `/compact` after the turn restarts the session, which rests
/// idle, so the count goes even though the tasks keep running.
#[test]
fn a_compaction_after_the_turn_clears_it() {
    let compacted = AgentEvent::SessionStarted {
        compact: true,
        source: Some(SessionSource::Compact),
        session_id: Some("session-1".into()),
        session_title: None,
        cwd: Some("/repo".into()),
    };
    let (record, ..) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            stop(Some(SHELL)),
            AgentEvent::Compacting,
            compacted,
        ],
    );
    assert_eq!(record.state, RunState::Idle);
    assert_eq!(record.background_work, None);
}

/// Every event that ends the rest the stop described takes the count with
/// it: a later stop is the only one that can say what is still running.
#[test]
fn turns_failures_interrupts_and_sessions_clear_it() {
    let failure = AgentEvent::Failed {
        error: "server_error".into(),
        usage_limit: None,
    };
    let ended = AgentEvent::SessionEnded {
        reason: Some("other".into()),
        session_id: Some("session-1".into()),
    };
    for (case, last) in [
        ("prompt", prompt("next")),
        ("failure", failure),
        ("interrupt", AgentEvent::Interrupted),
        ("session start", started(None)),
        ("session end", ended),
    ] {
        let (record, ..) = run(
            &claude(),
            &[started(None), prompt("go"), stop(Some(SHELL)), last],
        );
        assert_eq!(record.background_work, None, "{case}");
    }
}
