//! Work outside a turn: a tool after the turn ended, the idle prompt that
//! settles it, compaction, and the stops a stop hook held back.

use super::*;

fn stop() -> AgentEvent {
    AgentEvent::TurnFinished {
        continues_after_stop_hook: false,
        titles: None,
        cache: None,
        reply: None,
        background_work: None,
    }
}

fn bash(command: &str) -> AgentEvent {
    AgentEvent::ToolStarted {
        tool: "Bash".into(),
        detail: Some(format!("Bash: {command}")),
        by_subagent: false,
    }
}

fn step(prev: &RunRecord, event: &AgentEvent, descriptor: &ProviderDescriptor) -> RunRecord {
    apply(Some(prev), event, &context(), descriptor, LATER)
        .run
        .expect("record")
}

const NOTIFICATION: &str = "<task-notification>\n<task-id>b1</task-id>\n</task-notification>";

/// One rest a tool outside a turn takes the run from: how the run got
/// there, the tool, the event that ends the work, and what follows it.
struct Stretch {
    case: &'static str,
    descriptor: ProviderDescriptor,
    rest: Vec<AgentEvent>,
    tool: AgentEvent,
    /// The rest the idle prompt returns the run to.
    returns_to: RunState,
    end: AgentEvent,
    ends_as: RunState,
}

/// A tool after the run came to rest runs outside a turn, in the rest's
/// episode, and the idle prompt returns the run to that rest, still in
/// its episode: a failure's work settles as finished, and work that
/// began at the prompt goes back there. Codex has no idle prompt, and a
/// tool's end leaves its run running.
#[test]
fn a_tool_outside_a_turn_runs_in_the_rests_episode_until_the_agent_is_idle() {
    let failure = AgentEvent::Failed {
        error: "server_error".into(),
        usage_limit: None,
    };
    let cases = [
        Stretch {
            // The order Claude's TUI sent for a turn a background task's
            // end opened: its `Stop` came before the `PreToolUse` of its
            // last tool, and no `Stop` came after it.
            case: "after a turn a background task opened",
            descriptor: claude(),
            rest: vec![
                started(None),
                prompt("run the build in the background"),
                stop(),
                prompt(NOTIFICATION),
                stop(),
            ],
            tool: bash("tail -n 3 notes.txt"),
            returns_to: RunState::Finished,
            end: AgentEvent::AwaitingPrompt {
                awaited_call_ended: false,
            },
            ends_as: RunState::Finished,
        },
        Stretch {
            case: "after a failure",
            descriptor: claude(),
            rest: vec![started(None), prompt("first"), failure],
            tool: bash("ls"),
            returns_to: RunState::Finished,
            end: AgentEvent::AwaitingPrompt {
                awaited_call_ended: false,
            },
            ends_as: RunState::Finished,
        },
        Stretch {
            case: "at the prompt, before any turn",
            descriptor: claude(),
            rest: vec![started(None)],
            tool: bash("ls"),
            returns_to: RunState::Idle,
            end: AgentEvent::AwaitingPrompt {
                awaited_call_ended: false,
            },
            ends_as: RunState::Idle,
        },
        Stretch {
            case: "after a Codex interrupt",
            descriptor: codex(),
            rest: vec![started(None), prompt("first"), AgentEvent::Interrupted],
            tool: AgentEvent::ToolStarted {
                tool: "shell".into(),
                detail: Some("shell".into()),
                by_subagent: false,
            },
            returns_to: RunState::Finished,
            end: AgentEvent::ToolFinished {
                tool: Some("shell".into()),
                by_subagent: false,
            },
            ends_as: RunState::Running,
        },
    ];
    for stretch in cases {
        let case = stretch.case;
        let (rest, _, _) = run(&stretch.descriptor, &stretch.rest);
        let tool = step(&rest, &stretch.tool, &stretch.descriptor);
        assert_eq!(tool.state, RunState::Running, "{case}");
        assert_eq!(tool.run_started_at, None, "{case}");
        assert_eq!(tool.state_episode_token, rest.state_episode_token, "{case}");
        assert_eq!(tool.outside_turn_rest, Some(stretch.returns_to), "{case}");
        if let AgentEvent::ToolStarted { detail, .. } = &stretch.tool {
            assert_eq!(&tool.detail, detail, "{case}");
        }

        let ended = step(&tool, &stretch.end, &stretch.descriptor);
        assert_eq!(ended.state, stretch.ends_as, "{case}");
        assert_eq!(ended.run_started_at, None, "{case}");
        assert_eq!(
            ended.state_episode_token, rest.state_episode_token,
            "{case}"
        );
        if stretch.ends_as != RunState::Running {
            assert_eq!(ended.detail, None, "{case}");
            assert_eq!(ended.outside_turn_rest, None, "{case}");
            assert_eq!(
                ended.last_hook_event.as_deref(),
                Some("awaiting_prompt"),
                "{case}"
            );
        }
    }
}

#[test]
fn a_tool_call_inside_a_turn_runs_until_the_turn_ends() {
    let (running, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt(NOTIFICATION),
            bash("tail -n 3 notes.txt"),
        ],
    );
    assert_eq!(running.state, RunState::Running);
    assert_eq!(running.detail.as_deref(), Some("Bash: tail -n 3 notes.txt"));
    assert_eq!(running.run_started_at.as_deref(), Some(NOW));
    let finished = step(&running, &stop(), &claude());
    assert_eq!(finished.state, RunState::Finished);
    assert_eq!(finished.run_started_at, None);
    assert_ne!(finished.state_episode_token, running.state_episode_token);
}

#[test]
fn the_idle_prompt_writes_nothing_for_a_run_at_rest_or_waiting() {
    let idle = |events: &[AgentEvent]| {
        let (record, _, _) = run(&claude(), events);
        apply(
            Some(&record),
            &AgentEvent::AwaitingPrompt {
                awaited_call_ended: false,
            },
            &context(),
            &claude(),
            LATER,
        )
        .run
    };
    // A finished turn, and a session at its prompt, already rest.
    assert_eq!(idle(&[started(None), prompt("first"), stop()]), None);
    assert_eq!(idle(&[started(None)]), None);
    // A wait the transcript does not show ended is not ended by the agent
    // being idle, in a turn or out.
    assert_eq!(
        idle(&[
            started(None),
            prompt("first"),
            AgentEvent::WaitingForInput {
                detail: Some("Which color?".into()),
            },
        ]),
        None
    );
    assert_eq!(
        idle(&[
            started(None),
            prompt("first"),
            stop(),
            bash("rm notes.txt"),
            AgentEvent::ApprovalRequested { detail: None },
        ]),
        None
    );
}

/// The `Stop` a stop hook held back comes after the late work, before
/// or after the idle prompt settled it: the turn's real end is news of
/// its own, and begins an episode.
#[test]
fn a_stop_a_stop_hook_held_back_begins_an_episode_after_the_late_work() {
    for is_settled_first in [false, true] {
        let (ended, _, _) = run(&claude(), &[started(None), prompt("first"), stop()]);
        let mut late = step(&ended, &bash("cargo test"), &claude());
        assert_eq!(late.state, RunState::Running);
        assert_eq!(late.state_episode_token, ended.state_episode_token);
        if is_settled_first {
            late = step(
                &late,
                &AgentEvent::AwaitingPrompt {
                    awaited_call_ended: false,
                },
                &claude(),
            );
            assert_eq!(late.state, RunState::Finished);
        }
        let real_end = step(
            &late,
            &AgentEvent::TurnFinished {
                continues_after_stop_hook: true,
                titles: None,
                cache: None,
                reply: None,
                background_work: None,
            },
            &claude(),
        );
        assert_eq!(real_end.state, RunState::Finished, "{is_settled_first}");
        assert_ne!(
            real_end.state_episode_token, ended.state_episode_token,
            "{is_settled_first}"
        );
    }
}

#[test]
fn a_permission_prompt_after_a_late_tool_names_the_tool_not_the_old_error() {
    let (failed, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::Failed {
                error: "server_error".into(),
                usage_limit: None,
            },
        ],
    );
    let tool = step(&failed, &bash("rm notes.txt"), &claude());
    assert_eq!(tool.state, RunState::Running);
    assert_eq!(tool.state_episode_token, failed.state_episode_token);
    let waiting = step(
        &tool,
        &AgentEvent::ApprovalRequested {
            detail: Some("Claude needs your permission".into()),
        },
        &claude(),
    );
    assert_eq!(waiting.state, RunState::NeedsInput);
    assert_eq!(waiting.detail.as_deref(), Some("Bash: rm notes.txt"));
    // A wait is a new thing to say.
    assert_ne!(waiting.state_episode_token, failed.state_episode_token);
}

#[test]
fn a_compaction_mid_turn_keeps_the_turn_open_and_one_after_it_rests() {
    let (mid_turn, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::Compacting,
            compact_start(),
        ],
    );
    assert_eq!(mid_turn.state, RunState::Running);
    assert_eq!(mid_turn.run_started_at.as_deref(), Some(NOW));
    let tool = step(&mid_turn, &bash("ls"), &claude());
    assert_eq!(tool.run_started_at.as_deref(), Some(NOW));

    let (asked_for, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            stop(),
            AgentEvent::Compacting,
            compact_start(),
        ],
    );
    assert_eq!(asked_for.state, RunState::Idle);
    assert_eq!(asked_for.run_started_at, None);
}

fn compact_start() -> AgentEvent {
    AgentEvent::SessionStarted {
        compact: true,
        source: Some(SessionSource::Compact),
        session_id: Some("session-1".into()),
        session_title: None,
        cwd: None,
    }
}

#[test]
fn the_idle_prompt_ends_a_turn_that_stopped_without_a_stop_as_an_interrupt() {
    // An Esc ends Claude's turn without a `Stop`; the person's `/compact`
    // after it keeps the turn open, and only the idle prompt says it is
    // over.
    let (stopped, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            bash("cargo test"),
            AgentEvent::Compacting,
            compact_start(),
        ],
    );
    assert_eq!(stopped.state, RunState::Running);
    let ended = idle_at(&stopped, A_MINUTE_LATER).expect("record");
    let interrupted = step(&stopped, &AgentEvent::Interrupted, &claude());
    assert_eq!(ended.state, interrupted.state);
    assert_eq!(ended.state, RunState::Finished);
    assert_eq!(ended.run_started_at, None);
    assert_eq!(ended.state_episode_token, interrupted.state_episode_token);
    assert_ne!(ended.state_episode_token, stopped.state_episode_token);

    // A turn left compacting ends the same way.
    let (compacting, _, _) = run(
        &claude(),
        &[started(None), prompt("first"), AgentEvent::Compacting],
    );
    let ended = idle_at(&compacting, A_MINUTE_LATER).expect("record");
    assert_eq!(ended.state, RunState::Finished);
    assert_eq!(ended.run_started_at, None);
}

const A_MINUTE_LATER: &str = "2026-09-14T00:01:00Z";

/// Applies the idle prompt at `now`, with what the transcript showed of the
/// call the run waited on.
fn idle_seeing(prev: &RunRecord, awaited_call_ended: bool, now: &str) -> Option<RunRecord> {
    apply(
        Some(prev),
        &AgentEvent::AwaitingPrompt { awaited_call_ended },
        &context(),
        &claude(),
        now,
    )
    .run
}

#[test]
fn the_idle_prompt_ends_a_declined_question_or_permission_as_an_interrupt() {
    // An Esc at Claude's question or permission prompt sends no hook; the
    // transcript the idle prompt reads is what says the call was declined.
    let question = AgentEvent::WaitingForInput {
        detail: Some("Which color?".into()),
    };
    let cases = [
        vec![started(None), prompt("first"), question.clone()],
        // Claude's permission prompt also follows its question tool.
        vec![
            started(None),
            prompt("first"),
            question,
            AgentEvent::ApprovalRequested {
                detail: Some("Claude needs your permission".into()),
            },
        ],
        vec![
            started(None),
            prompt("first"),
            bash("rm notes.txt"),
            AgentEvent::ApprovalRequested { detail: None },
        ],
    ];
    for events in cases {
        let (waiting, _, _) = run(&claude(), &events);
        assert_eq!(waiting.state, RunState::NeedsInput);
        let ended = idle_seeing(&waiting, true, A_MINUTE_LATER).expect("record");
        let interrupted = step(&waiting, &AgentEvent::Interrupted, &claude());
        assert_eq!(ended.state, RunState::Finished);
        assert_eq!(ended.state, interrupted.state);
        assert_eq!(ended.run_started_at, None);
        assert_eq!(ended.wait_kind, None, "the wait is over");
        assert_eq!(ended.state_episode_token, interrupted.state_episode_token);
        assert_ne!(ended.state_episode_token, waiting.state_episode_token);
    }
}

#[test]
fn the_idle_prompt_leaves_a_wait_the_transcript_shows_open() {
    let (waiting, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::WaitingForInput {
                detail: Some("Which color?".into()),
            },
        ],
    );
    // A minute idle with the question still open is a person yet to answer.
    assert_eq!(idle_seeing(&waiting, false, A_MINUTE_LATER), None);
    assert_eq!(waiting.state, RunState::NeedsInput);
    assert!(waiting.run_started_at.is_some());
    // A declined call in a turn too young to have sat idle is the idle
    // prompt of the stretch before, delivered late.
    assert_eq!(idle_seeing(&waiting, true, LATER), None);
    // A late tool's permission outside a turn has no turn for it to end.
    let (late, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            stop(),
            bash("rm notes.txt"),
            AgentEvent::ApprovalRequested { detail: None },
        ],
    );
    assert_eq!(idle_seeing(&late, true, A_MINUTE_LATER), None);
}

fn idle_at(prev: &RunRecord, now: &str) -> Option<RunRecord> {
    idle_seeing(prev, false, now)
}

#[test]
fn an_idle_prompt_just_after_a_prompt_leaves_the_new_turn_open() {
    // The idle prompt of the stretch before, delivered after the next
    // prompt: the turn it finds has not sat idle long enough to be over.
    let (record, _, _) = run(&claude(), &[started(None), prompt("first")]);
    assert_eq!(idle_at(&record, NOW), None);
    assert_eq!(idle_at(&record, LATER), None);
    assert_eq!(idle_at(&record, "2026-09-14T00:00:54Z"), None);
    assert!(idle_at(&record, "2026-09-14T00:00:55Z").is_some());
}

#[test]
fn the_rest_work_outside_a_turn_left_is_kept_only_while_it_lasts() {
    let (ended, _, _) = run(&claude(), &[started(None), prompt("first"), stop()]);
    let tool = step(&ended, &bash("rm notes.txt"), &claude());
    assert_eq!(tool.outside_turn_rest, Some(RunState::Finished));
    let waiting = step(
        &tool,
        &AgentEvent::ApprovalRequested { detail: None },
        &claude(),
    );
    assert_eq!(waiting.outside_turn_rest, Some(RunState::Finished));
    let next_prompt = step(&waiting, &prompt("second"), &claude());
    assert_eq!(next_prompt.outside_turn_rest, None);
    let real_end = step(&tool, &stop(), &claude());
    assert_eq!(real_end.outside_turn_rest, None);
}

#[test]
fn a_codex_compaction_after_the_turn_rests_at_the_prompt() {
    let (record, _, _) = run(
        &codex(),
        &[
            started(None),
            prompt("first"),
            stop(),
            AgentEvent::Compacting,
            AgentEvent::CompactionFinished,
        ],
    );
    assert_eq!(record.state, RunState::Idle);
    assert_eq!(record.run_started_at, None);
}
