//! These tests cover a wait the person declined at the agent's own prompt,
//! which no hook reports: the projection asks about the transcript the
//! record names.

use super::*;

const TRANSCRIPT: &str = "/t/session.jsonl";

/// Builds a run waiting on a question inside a turn, with `extra` record
/// fields (each starting with a comma).
fn waiting(extra: &str) -> ProjectionInput {
    let mut input = finished_input(Vec::new());
    let content = record(Some(5), "2026-09-14T12:03:00Z", "needsInput").replace(
        r#""state":"needsInput""#,
        &format!(
            r#""state":"needsInput","waitKind":"question","detail":"Which color?","runStartedAt":"2026-09-14T12:02:00Z","transcriptPath":"{TRANSCRIPT}"{extra}"#
        ),
    );
    input.records = vec![file(Some(content))];
    input
}

/// Runs one pass of `input` where the transcript reads `is_declined`, and
/// also returns every path the pass asked about.
fn pass(
    previous: &ProjectionState,
    input: &ProjectionInput,
    is_declined: bool,
) -> (ProjectionState, Projection, Vec<Command>, Vec<String>) {
    let mut asked = Vec::new();
    let (state, projection, commands) =
        project_with(previous, input, &now(), &mut |provider, path| {
            assert_eq!(*provider, claude());
            asked.push(path.to_owned());
            is_declined
        });
    (state, projection, commands, asked)
}

#[test]
fn a_declined_wait_shows_as_its_turn_stopped_and_announces_nothing() {
    let input = waiting("");
    let (state, projection, _, asked) = pass(&ProjectionState::default(), &input, false);
    assert_eq!(asked, vec![TRANSCRIPT.to_owned()]);
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::NeedsInput);
    assert_eq!(
        badge.wait_kind,
        Some(limpid_agent_model::WaitKind::Question)
    );
    assert_eq!(badge.detail.as_deref(), Some("Which color?"));

    // The person pressed Esc; the record still says the run waits.
    let (_, projection, commands, _) = pass(&state, &input, true);
    let runtime = &projection.runtimes[0];
    assert_eq!(runtime.badge.state, RunState::Finished);
    assert_eq!(runtime.badge.wait_kind, None);
    assert_eq!(runtime.badge.detail, None);
    assert_eq!(runtime.badge.tool, None);
    assert_eq!(runtime.badge.run_started_at, None);
    assert_eq!(
        runtime.badge.stop_reason,
        Some(limpid_agent_model::StopReason::WaitDeclined),
        "the interface says it was declined, not answered"
    );
    let pane: Uuid = PANE.parse().expect("pane");
    assert_eq!(
        projection.badges[&pane][&claude()].state,
        RunState::Finished,
        "the pane shows what the runtime does"
    );
    assert!(
        !commands
            .iter()
            .any(|command| matches!(command.op, CommandOp::Notify(_))),
        "the person who declined it needs no notice"
    );
}

fn declined_wait_ends(commands: &[Command]) -> Vec<&Command> {
    commands
        .iter()
        .filter(|command| matches!(command.op, CommandOp::EndDeclinedWait { .. }))
        .collect()
}

#[test]
fn a_declined_wait_asks_the_host_to_write_its_end_until_the_record_says_it() {
    let turn = "BBBBBBBB-2222-4222-8222-BBBBBBBBBBB2";
    let input = waiting(&format!(
        r#","stateEpisodeToken":"5","currentTurnId":"{turn}""#
    ));
    let (state, _, commands, _) = pass(&ProjectionState::default(), &input, false);
    assert!(declined_wait_ends(&commands).is_empty(), "a wait still up");

    let (state, _, commands, _) = pass(&state, &input, true);
    let ends = declined_wait_ends(&commands);
    assert_eq!(ends.len(), 1);
    assert_eq!(
        ends[0].op,
        CommandOp::EndDeclinedWait {
            episode_token: "5".to_owned(),
            turn_id: Some(turn.to_owned()),
            transcript_path: TRANSCRIPT.to_owned(),
            by_program_status: false,
        }
    );
    assert_eq!(
        ends[0].target,
        Target::Record {
            provider: claude(),
            storage_id: RUN.to_owned(),
        }
    );
    assert_eq!(ends[0].expect, Precondition::None);
    // The next pass asks again, since the host settles it, not the rules.
    let (state, _, commands, _) = pass(&state, &input, true);
    assert_eq!(declined_wait_ends(&commands).len(), 1);

    // The writer's record is finished in the wait's episode, so nothing is
    // asked, and the finish the badge already showed is not announced.
    let written = input.clone().replace_records(|_| {
        record(Some(6), "2026-09-14T12:04:00Z", "finished").replace(
            r#""state":"finished""#,
            &format!(r#""state":"finished","stateEpisodeToken":"5","currentTurnId":"{turn}""#),
        )
    });
    let (_, projection, commands, asked) = pass(&state, &written, true);
    assert!(asked.is_empty());
    assert!(declined_wait_ends(&commands).is_empty());
    let runtime = &projection.runtimes[0];
    assert_eq!(runtime.badge.state, RunState::Finished);
    assert_eq!(runtime.badge.stop_reason, None);
    assert_eq!(runtime.episode_token, "5");
    assert!(
        !commands
            .iter()
            .any(|command| matches!(command.op, CommandOp::Notify(_))),
        "the record saying what the badge said is no news"
    );
}

#[test]
fn only_a_wait_inside_a_turn_that_names_its_transcript_is_asked_about() {
    // A wait outside a turn is a late tool's permission, which no turn holds.
    let outside = waiting("").replace_records(|content| {
        content.replace(r#","runStartedAt":"2026-09-14T12:02:00Z""#, "")
    });
    let (_, projection, _, asked) = pass(&ProjectionState::default(), &outside, true);
    assert!(asked.is_empty());
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);

    // This record is from before the field, or of a provider that names none.
    let unnamed = waiting("").replace_records(|content| {
        content.replace(&format!(r#","transcriptPath":"{TRANSCRIPT}""#), "")
    });
    let (_, projection, _, asked) = pass(&ProjectionState::default(), &unnamed, true);
    assert!(asked.is_empty());
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);

    // A run at work or at rest is never read for, whatever it names.
    for state in ["running", "finished", "compacting"] {
        let other = waiting("").replace_records(|content| {
            content.replace(r#""state":"needsInput""#, &format!(r#""state":"{state}""#))
        });
        let (_, projection, _, asked) = pass(&ProjectionState::default(), &other, true);
        assert!(asked.is_empty(), "{state}");
        assert_ne!(projection.runtimes[0].badge.state, RunState::NeedsInput);
    }
}

#[test]
fn a_waiting_run_whose_process_died_shows_as_stopped_by_the_exit() {
    let mut input = waiting(r#","pid":"4242""#);
    input.pid_status = [("4242".to_owned(), limpid_agent_model::PidStatus::Dead)]
        .into_iter()
        .collect();
    let (_, projection, _, asked) = pass(&ProjectionState::default(), &input, true);
    assert!(asked.is_empty());
    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::Error);
    assert_eq!(
        badge.stop_reason,
        Some(limpid_agent_model::StopReason::ProcessExited)
    );
}

#[test]
fn a_host_that_reads_no_transcript_keeps_the_wait() {
    let (_, projection, _) = project(&ProjectionState::default(), &waiting(""), &now());
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);
}

trait ReplaceRecords {
    fn replace_records(self, change: impl Fn(&str) -> String) -> Self;
}

impl ReplaceRecords for ProjectionInput {
    fn replace_records(mut self, change: impl Fn(&str) -> String) -> Self {
        for file in &mut self.records {
            file.content = file.content.as_deref().map(&change);
        }
        self
    }
}

/// Returns `input` with Claude's descriptor naming its OSC 7501 app and the
/// run's pane last reporting `state` at `at`.
fn reported(
    mut input: ProjectionInput,
    app: &str,
    state: limpid_agent_model::ProgramState,
    at: &str,
) -> ProjectionInput {
    let mut descriptor = input
        .providers
        .get(&claude())
        .cloned()
        .unwrap_or_else(|| limpid_agent_model::ProviderDescriptor::fixture("claude", []));
    descriptor.program_status_app = Some("claude-code".to_owned());
    input.providers.insert(claude(), descriptor);
    input.program_status.insert(
        PANE.parse().expect("pane"),
        limpid_agent_model::ProgramStatus {
            app: app.to_owned(),
            state,
            observed_at: at.to_owned(),
        },
    );
    input
}

#[test]
fn an_idle_report_after_the_wait_ends_it_without_the_transcript() {
    use limpid_agent_model::ProgramState;
    let base = waiting(r#","stateEpisodeToken":"5""#);

    // The record changed at 12:03:00. Idle reported then or later ends the
    // wait, and the transcript is not asked.
    let input = reported(
        base.clone(),
        "claude-code",
        ProgramState::Idle,
        "2026-09-14T12:03:00Z",
    );
    let (_, projection, commands, asked) = pass(&ProjectionState::default(), &input, false);
    assert!(asked.is_empty(), "the report answers first");
    assert_eq!(
        projection.runtimes[0].badge.stop_reason,
        Some(limpid_agent_model::StopReason::WaitDeclined)
    );
    let ends = declined_wait_ends(&commands);
    assert_eq!(ends.len(), 1);
    assert!(matches!(
        ends[0].op,
        CommandOp::EndDeclinedWait {
            by_program_status: true,
            ..
        }
    ));

    // Blocked is the wait itself, and an idle from before the wait, or under
    // another program's name, says nothing about it.
    for input in [
        reported(
            base.clone(),
            "claude-code",
            ProgramState::Blocked,
            "2026-09-14T12:03:05Z",
        ),
        reported(
            base.clone(),
            "claude-code",
            ProgramState::Idle,
            "2026-09-14T12:02:59Z",
        ),
        reported(
            base.clone(),
            "other-agent",
            ProgramState::Idle,
            "2026-09-14T12:03:05Z",
        ),
    ] {
        let (_, projection, commands, asked) = pass(&ProjectionState::default(), &input, false);
        assert_eq!(
            asked,
            vec![TRANSCRIPT.to_owned()],
            "the transcript is asked"
        );
        assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);
        assert!(declined_wait_ends(&commands).is_empty());
    }

    // A provider that names no app reads no report.
    let mut input = reported(
        base,
        "claude-code",
        ProgramState::Idle,
        "2026-09-14T12:03:05Z",
    );
    input
        .providers
        .get_mut(&claude())
        .expect("claude")
        .program_status_app = None;
    let (_, projection, _, _) = pass(&ProjectionState::default(), &input, false);
    assert_eq!(projection.runtimes[0].badge.state, RunState::NeedsInput);
}
