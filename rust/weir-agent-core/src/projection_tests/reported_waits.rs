//! These tests cover a wait only the agent's own status report shows: an MCP
//! server's request for input, a question left after the turn, a sign-in.
//! No hook announces them, so the projection reads them from the report the
//! pane last made (OSC 7501) and shows the run waiting until the next one.

use super::*;

/// A run at work inside a turn, whose record last changed at 12:03:00.
fn working() -> ProjectionInput {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "running").replace(
        r#""state":"running""#,
        r#""state":"running","tool":"mcp__docs__search","runStartedAt":"2026-09-14T12:02:00Z","stateEpisodeToken":"5""#,
    );
    input.records = vec![file(Some(content))];
    input
}

/// `input` with the pane last reporting `state` and `kind` at `at`.
fn reporting(
    input: ProjectionInput,
    state: ProgramState,
    kind: Option<BlockedKind>,
    at: &str,
) -> ProjectionInput {
    super::reported_status(input, &[], "claude-code", (state, kind), at)
}

fn pass(
    previous: &ProjectionState,
    input: &ProjectionInput,
) -> (ProjectionState, Projection, Vec<Command>) {
    project_with(previous, input, &now(), &mut |_, _| false)
}

fn notifies(commands: &[Command]) -> bool {
    commands
        .iter()
        .any(|command| matches!(command.op, CommandOp::Notify(_)))
}

#[test]
fn a_question_report_shows_the_run_waiting_and_announces_it() {
    let (state, projection, _) = pass(&ProjectionState::default(), &working());
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);

    // An MCP server asked for input: the agent reports a block on a question.
    let input = reporting(
        working(),
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (state, projection, commands) = pass(&state, &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::Question));
    assert_eq!(badge.detail, None, "the report carries no words Weir reads");
    assert_eq!(badge.tool, None);
    assert!(notifies(&commands), "a new wait is news");

    // The person answered; the agent reports its work again.
    let input = reporting(
        working(),
        ProgramState::Working,
        None,
        "2026-09-14T12:03:20Z",
    );
    let (_, projection, commands) = pass(&state, &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
    assert!(!notifies(&commands));
}

/// A second request in the same turn writes no record, so it waits in the
/// episode of the first; it is still a new wait, and announced as one.
#[test]
fn a_second_question_in_the_same_turn_is_announced_again() {
    let question = |at| {
        reporting(
            working(),
            ProgramState::Blocked,
            Some(BlockedKind::Question),
            at,
        )
    };
    let (state, _, _) = pass(&ProjectionState::default(), &working());
    let (state, _, first) = pass(&state, &question("2026-09-14T12:03:10Z"));
    let answered = reporting(
        working(),
        ProgramState::Working,
        None,
        "2026-09-14T12:03:20Z",
    );
    let (state, _, _) = pass(&state, &answered);
    let (_, projection, second) = pass(&state, &question("2026-09-14T12:03:30Z"));
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);
    assert!(notifies(&first));
    assert!(notifies(&second), "the second wait is news too");
}

#[test]
fn an_auth_report_shows_the_run_waiting_on_a_sign_in() {
    let input = reporting(
        working(),
        ProgramState::Blocked,
        Some(BlockedKind::Auth),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::SignIn));
}

#[test]
fn a_question_left_after_the_turn_shows_on_a_finished_run() {
    // Codex blocks on an async question only once its turn is over.
    let input = reporting(
        finished_input(Vec::new()),
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::Question));
    assert_eq!(badge.stop_reason, None);
}

#[test]
fn a_block_without_a_question_or_a_sign_in_changes_nothing() {
    // A permission request comes with its own hook, and a block with no kind
    // is a dialog of the agent's own.
    for kind in [Some(BlockedKind::Permission), None] {
        let input = reporting(
            working(),
            ProgramState::Blocked,
            kind,
            "2026-09-14T12:03:10Z",
        );
        let (_, projection, _) = pass(&ProjectionState::default(), &input);
        assert_eq!(
            projection.runtimes[0].badge.state,
            RunState::Running,
            "{kind:?}"
        );
    }
}

#[test]
fn a_report_from_before_the_record_changed_is_no_evidence() {
    let input = reporting(
        working(),
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:02:59Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
}

#[test]
fn a_hook_question_keeps_its_own_words() {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "needsInput").replace(
        r#""state":"needsInput""#,
        r#""state":"needsInput","waitKind":"question","tool":"AskUserQuestion","detail":"Which color?""#,
    );
    input.records = vec![file(Some(content))];
    let input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.wait_kind, Some(WaitKind::Question));
    assert_eq!(badge.detail.as_deref(), Some("Which color?"));
}

/// An approval for the record, as its hook wrote it at 12:03:00.
fn approval() -> ProjectionInput {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "needsInput").replace(
        r#""state":"needsInput""#,
        r#""state":"needsInput","waitKind":"approval","tool":"mcp__docs__search","detail":"mcp__docs__search""#,
    );
    input.records = vec![file(Some(content))];
    input
}

/// While the approval is up, the agent's report of it changes nothing: the
/// hook's wait names the tool.
#[test]
fn an_approval_keeps_its_words_while_the_agent_reports_it() {
    let input = reporting(
        approval(),
        ProgramState::Blocked,
        Some(BlockedKind::Permission),
        "2026-09-14T12:03:00Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.wait_kind, Some(WaitKind::Approval));
    assert_eq!(badge.detail.as_deref(), Some("mcp__docs__search"));
}

/// No hook says an approval was answered. The MCP tool it allowed then asks
/// for input, and the agent reports a question: that is the wait now.
#[test]
fn a_question_reported_after_an_approval_is_the_wait_now() {
    let input = reporting(
        approval(),
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:20Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(badge.wait_kind, Some(WaitKind::Question));
    assert_eq!(badge.detail, None);
    assert_eq!(badge.tool, None);
}

#[test]
fn a_report_from_another_program_in_the_pane_is_not_the_agent_s() {
    let input = super::reported_status(
        working(),
        &[],
        "some-other-tool",
        (ProgramState::Blocked, Some(BlockedKind::Question)),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, _) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
}

/// A run killed with its pane still open, whose record a resume still
/// claims, is not the agent that reports in the pane now: the new agent's
/// wait is not announced a second time under the dead run.
#[test]
fn a_dead_run_still_claimed_by_a_resume_takes_no_report_from_its_pane() {
    let mut input = working();
    let content = input.records[0]
        .content
        .clone()
        .expect("record")
        .replace(r#""state":"running""#, r#""state":"running","pid":"4242""#);
    input.records = vec![file(Some(content))];
    input.pid_status = [("4242".to_owned(), PidStatus::Dead)].into();
    input.resume_intents = vec![weir_agent_model::ResumeIntent {
        run_id: RUN.to_owned(),
        pane_id: PANE.parse().expect("pane"),
        session_id: "session".to_owned(),
        owner_run_id: None,
        pid: "4242".to_owned(),
        created_at: "2026-10-12T00:00:30Z".to_owned(),
    }];
    let input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    assert_eq!(projection.runtimes[0].badge.state, RunState::Running);
    assert!(!notifies(&commands));
}

/// A run whose session ended stays on record (its last wait still named) but
/// is not the agent in the pane any more: the new agent's question is not
/// its wait.
#[test]
fn a_run_whose_session_ended_takes_no_report_from_its_pane() {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "unknown").replace(
        r#""state":"unknown""#,
        r#""state":"unknown","waitKind":"approval""#,
    );
    input.records = vec![file(Some(content))];
    let input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    assert_ne!(projection.runtimes[0].badge.state, RunState::NeedsInput);
    assert!(!notifies(&commands));
}

/// Two live records name the pane: the one that changed last is the agent
/// there now, and the report is its alone.
#[test]
fn of_two_runs_in_a_pane_only_the_latest_takes_its_report() {
    let mut input = working();
    let older = record(Some(3), "2026-09-14T12:01:00Z", "running")
        .replace(RUN, "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2");
    input.records.push(RecordFile {
        name: "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2".to_owned(),
        ..file(Some(older))
    });
    let input = reporting(
        input,
        ProgramState::Blocked,
        Some(BlockedKind::Question),
        "2026-09-14T12:03:10Z",
    );
    let (_, projection, commands) = pass(&ProjectionState::default(), &input);
    let waiting: Vec<_> = projection
        .runtimes
        .iter()
        .filter(|runtime| runtime.badge.state == RunState::NeedsInput)
        .map(|runtime| runtime.run_id.clone())
        .collect();
    assert_eq!(waiting, [Some(RUN.to_owned())]);
    assert_eq!(
        commands
            .iter()
            .filter(|command| matches!(command.op, CommandOp::Notify(_)))
            .count(),
        1
    );
}
