//! Which run record the projection takes: revisions, unreadable files, and
//! runs whose process died or ended.

use super::*;

fn accept(previous: &ProjectionState, files: Vec<RecordFile>) -> BTreeMap<String, AcceptedRun> {
    accept_records(
        previous,
        &ProjectionInput {
            records: files,
            ..ProjectionInput::default()
        },
    )
}

fn state_with(accepted: BTreeMap<String, AcceptedRun>) -> ProjectionState {
    ProjectionState {
        accepted,
        ..ProjectionState::default()
    }
}

/// A run in `state` whose process `4242` the host found dead, with the
/// extra record fields `extra` (each starting with a comma).
fn dead_run(state: &str, extra: &str) -> (ProjectionState, Projection, Vec<Command>) {
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let mut input = finished_input(Vec::new());
    let dead = record(Some(4), "2026-09-14T12:03:00Z", "finished").replace(
        r#""state":"finished""#,
        &format!(r#""state":"{state}","pid":"4242","detail":"Bash"{extra}"#),
    );
    input.records = vec![file(Some(dead))];
    input.pid_status = [("4242".to_owned(), limpid_agent_model::PidStatus::Dead)]
        .into_iter()
        .collect();
    project(&ProjectionState::default(), &input, &now)
}

#[test]
fn a_codex_run_left_running_whose_process_died_is_a_stop_without_a_failure_notice() {
    // Codex reports no session end, so a quit after an interrupt, or at
    // an approval prompt, leaves the run running with its pid gone: the
    // stop is kept, but nothing announces it as a failure.
    let codex = ProviderId::new("codex").expect("provider id");
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let mut input = finished_input(Vec::new());
    input.providers = [(
        codex.clone(),
        limpid_provider_codex::CodexAdapter.descriptor().clone(),
    )]
    .into_iter()
    .collect();
    let dead = record(Some(4), "2026-09-14T12:03:00Z", "running")
        .replace(r#""state":"running""#, r#""state":"running","pid":"4242""#);
    input.records = vec![RecordFile {
        provider: codex,
        name: RUN.to_owned(),
        content: Some(dead),
    }];
    input.pid_status = [("4242".to_owned(), limpid_agent_model::PidStatus::Dead)]
        .into_iter()
        .collect();

    let (_, projection, commands) = project(&ProjectionState::default(), &input, &now);

    let badge = &projection.runtimes[0].badge;
    assert_eq!(badge.state, RunState::Error);
    assert_eq!(
        badge.stop_reason,
        Some(limpid_agent_model::StopReason::ProcessExited)
    );
    assert!(
        !commands
            .iter()
            .any(|command| matches!(command.op, CommandOp::Notify(_)))
    );
}

fn retires(commands: &[Command]) -> bool {
    commands.iter().any(|command| {
        matches!(command.op, CommandOp::Retire)
            || command
                .then
                .iter()
                .any(|next| matches!(next.op, CommandOp::Retire))
    })
}

#[test]
fn a_run_whose_process_died_at_work_shows_once_as_stopped_before_it_is_retired() {
    // No hook reports a crash or a kill, so the pass that retires the
    // record is the only one that can say the run stopped. It shows the
    // run in error then, with why, so the interface keeps the stop.
    for state in ["running", "needsInput", "compacting"] {
        let (_, projection, commands) = dead_run(state, "");
        let badge = &projection.runtimes[0].badge;
        assert_eq!(badge.state, RunState::Error, "{state}");
        assert_eq!(
            badge.stop_reason,
            Some(limpid_agent_model::StopReason::ProcessExited)
        );
        // What it was doing is not why it stopped.
        assert_eq!(badge.detail, None);
        assert!(retires(&commands), "{state}");
        let json = serde_json::to_value(&projection).expect("encode");
        assert_eq!(
            json["runtimes"][0]["badge"]["stopReason"],
            serde_json::json!("processExited")
        );
    }
}

#[test]
fn the_pass_that_retires_a_run_offers_no_resume_from_the_hint_it_deletes() {
    // The hint goes with the record, but the session it named is still
    // handed over for the stop this pass shows. What is withheld is the
    // candidate: a restored pane types its resume from it, and a run
    // that nothing claimed is not to come back at launch.
    let pane: Uuid = PANE.parse().expect("pane");
    let hint = |run_id: &str| RecordFile {
        provider: claude(),
        name: PANE.to_owned(),
        content: Some(format!(
            r#"{{"schemaVersion":1,"paneId":"{PANE}","runId":"{run_id}","sessionId":"S","cwd":"/tmp/repo"}}"#
        )),
    };
    let with_hint = |run_id: &str| {
        let now = Instants {
            wall: "2026-09-14T12:04:00Z".to_owned(),
            monotonic_ms: 0,
        };
        let mut input = finished_input(Vec::new());
        let mut resumable = descriptor();
        resumable.capabilities.insert(Capability::Resume);
        input.providers.insert(claude(), resumable);
        let dead = record(Some(4), "2026-09-14T12:03:00Z", "running")
            .replace(r#""state":"running""#, r#""state":"running","pid":"4242""#);
        input.records = vec![file(Some(dead))];
        input.pid_status = [("4242".to_owned(), limpid_agent_model::PidStatus::Dead)]
            .into_iter()
            .collect();
        input.session_records = vec![hint(run_id)];
        project(&ProjectionState::default(), &input, &now)
    };

    let (_, projection, commands) = with_hint(RUN);
    assert!(retires(&commands));
    assert_eq!(
        projection.sessions[&pane][&claude()].cwd.as_deref(),
        Some("/tmp/repo")
    );
    assert!(!projection.resume_candidates.contains_key(&pane));

    // A hint a newer run took is left on disk by the host's precondition,
    // and is still that run's to offer.
    let (_, projection, _) = with_hint("BBBBBBBB-1111-4111-8111-BBBBBBBBBBB1");
    assert!(projection.resume_candidates[&pane].contains(&claude()));
}

#[test]
fn a_stopped_run_says_whether_its_session_holds_a_conversation() {
    // A session never prompted has no transcript to resume, which the
    // stop it leaves must know: the launch rules retire it quietly, and
    // a resume offered for it could only fail.
    for (extra, has_prompt) in [
        (r#","hasPrompt":false"#, Some(false)),
        (r#","hasPrompt":true"#, Some(true)),
        ("", None),
    ] {
        let (_, projection, _) = dead_run("running", extra);
        let badge = &projection.runtimes[0].badge;
        assert_eq!(badge.has_prompt, has_prompt, "{extra}");
        let json = serde_json::to_value(&projection).expect("encode");
        assert_eq!(
            json["runtimes"][0]["badge"].get("hasPrompt"),
            has_prompt.map(serde_json::Value::Bool).as_ref(),
            "{extra}"
        );
    }
}

#[test]
fn a_run_that_ended_or_that_limpid_stopped_is_retired_without_a_stop() {
    // At rest, ended by its own hook, stopped by Limpid on quit, or hosted
    // in tmux: none of these is a run that died at work.
    for (state, extra) in [
        ("finished", ""),
        ("idle", ""),
        ("unknown", ""),
        ("running", r#","killedByLimpidAt":"2026-09-14T12:03:30Z""#),
    ] {
        let (_, projection, _) = dead_run(state, extra);
        let badge = &projection.runtimes[0].badge;
        assert_ne!(badge.state, RunState::Error, "{state}{extra}");
        assert_eq!(badge.stop_reason, None, "{state}{extra}");
    }
    let (_, projection, commands) = dead_run("running", r#","tmuxSocketPath":"/tmp/s""#);
    assert_eq!(projection.runtimes[0].badge.stop_reason, None);
    assert!(!retires(&commands));
}

#[test]
fn a_lower_revision_never_replaces_a_higher_one() {
    // Two writers can race on the same run across a backend switch. The
    // revision is what orders them; a stale read must not roll the badge
    // back to a state the run has already left.
    let first = accept(
        &ProjectionState::default(),
        vec![file(Some(record(
            Some(4),
            "2026-09-14T12:03:00Z",
            "finished",
        )))],
    );
    assert_eq!(first[RUN].record.state, RunState::Finished);

    let second = accept(
        &state_with(first.clone()),
        vec![file(Some(record(
            Some(2),
            "2026-09-14T12:01:00Z",
            "running",
        )))],
    );
    assert_eq!(second[RUN].record.state, RunState::Finished);

    let third = accept(
        &state_with(first),
        vec![file(Some(record(
            Some(5),
            "2026-09-14T12:04:00Z",
            "unknown",
        )))],
    );
    assert_eq!(third[RUN].record.state, RunState::Unknown);
}

#[test]
fn records_without_revisions_fall_back_to_the_timestamp() {
    // Version 2 records predate revisions. The format is fixed-width UTC,
    // so comparing the text orders them.
    let first = accept(
        &ProjectionState::default(),
        vec![file(Some(record(None, "2026-09-14T12:03:00Z", "finished")))],
    );
    let older = accept(
        &state_with(first.clone()),
        vec![file(Some(record(None, "2026-09-14T12:01:00Z", "running")))],
    );
    assert_eq!(older[RUN].record.state, RunState::Finished);

    // A numbered record is the one a version 3 writer produced, so it wins
    // over an unnumbered one whatever the timestamps say.
    let numbered = accept(
        &state_with(first),
        vec![file(Some(record(Some(1), "2026-09-14T12:00:00Z", "idle")))],
    );
    assert_eq!(numbered[RUN].record.state, RunState::Idle);
}

#[test]
fn a_file_that_cannot_be_read_keeps_the_record_already_accepted() {
    // A read can fail while a hook is mid-write. Dropping the run would
    // make its badge blink out and come back on the next scan.
    let first = accept(
        &ProjectionState::default(),
        vec![file(Some(record(
            Some(4),
            "2026-09-14T12:03:00Z",
            "running",
        )))],
    );
    let unreadable = accept(&state_with(first.clone()), vec![file(None)]);
    assert_eq!(unreadable[RUN].record.state, RunState::Running);

    // A file that is gone is a different matter: the run was retired.
    let removed = accept(&state_with(first), Vec::new());
    assert!(removed.is_empty());
}

#[test]
fn a_record_that_disagrees_with_its_file_name_is_ignored() {
    // The file name is the only thing separating one run's record from
    // another's, so a mismatch is not trustworthy enough to display.
    let mut misnamed = file(Some(record(Some(1), "2026-09-14T12:00:00Z", "running")));
    misnamed.name = "SOMETHING-ELSE".to_owned();
    assert!(accept(&ProjectionState::default(), vec![misnamed]).is_empty());
}

/// A badge is named by the provider's title for the session, else the one it
/// generated, else the opening prompt, whichever provider it is, and only
/// once the run has reported its conversation.
#[test]
fn a_badge_is_named_only_with_its_conversation() {
    let titled = |session_id: &str| {
        let json = format!(
            r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{RUN}","revision":1,
               "state":"finished","updatedAt":"2026-10-28T00:00:00Z",{session_id}
               "providerSessionTitle":"Renamed","providerGeneratedTitle":"Generated",
               "firstPrompt":"Opening prompt"}}"#
        );
        let record = RunRecord::decode(json.as_bytes()).expect("record");
        badge_from(&record, Some(&descriptor()))
    };
    let known = titled(r#""sessionId":"c","#);
    assert_eq!(known.conversation_id.as_deref(), Some("c"));
    assert_eq!(badge_title(&known), Ok(Some("Renamed".to_owned())));
    let generated = Badge {
        provider_session_title: None,
        ..known
    };
    assert_eq!(badge_title(&generated), Ok(Some("Generated".to_owned())));

    let prompt = Badge {
        provider_generated_title: None,
        ..generated
    };
    assert_eq!(badge_title(&prompt), Ok(Some("Opening prompt".to_owned())));

    // A record without a conversation may be left from a session that has
    // ended, its opening prompt with it, so it names nothing.
    let unknown = titled("");
    assert_eq!(unknown.conversation_id, None);
    assert_eq!(badge_title(&unknown), Ok(None));
}

#[test]
fn launch_order_reaches_the_runtime_badge_without_precision_loss() {
    let mut input = finished_input(Vec::new());
    let ordered = record(Some(4), "2026-09-14T12:03:00Z", "finished").replace(
        "\"state\":\"finished\"",
        "\"state\":\"finished\",\"runLaunchOrder\":18446744073709551615,\"parentRunID\":\"parent\",\"runObservedOrder\":18446744073709551615",
    );
    input.records = vec![file(Some(ordered))];
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now());
    assert_eq!(
        projection.runtimes[0].badge.run_launch_order,
        Some(u64::MAX)
    );
    assert_eq!(
        projection.runtimes[0].badge.parent_run_id.as_deref(),
        Some("parent")
    );
    assert_eq!(
        projection.runtimes[0].badge.run_observed_order,
        Some(u64::MAX)
    );
}
