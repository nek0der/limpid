//! What the projection puts in sight: seen marks, tmux panes in and out of
//! view, and what reaches a run's badge.

use super::*;

fn viewed_marks(commands: &[Command]) -> usize {
    commands
        .iter()
        .filter(|command| matches!(command.op, CommandOp::MarkViewed { .. }))
        .count()
}

#[test]
fn a_turn_that_finishes_where_the_user_is_looking_is_marked_seen() {
    // Attention otherwise only changes when a pane comes into sight, so
    // without this the run sits in the waiting list unread until the
    // user looks away and back at the pane they were already watching.
    let pane: Uuid = PANE.parse().expect("pane");
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let input = finished_input(vec![pane]);
    let (_, _, commands) = project(&ProjectionState::default(), &input, &now);
    assert_eq!(viewed_marks(&commands), 1);

    // Out of sight (another pane, or the application in the background,
    // which the host reports as nothing seen) nobody saw it, even when
    // its pane is the focused one.
    let mut elsewhere = finished_input(vec![Uuid::new_v4()]);
    elsewhere.focus = Some(Focus {
        tab: Uuid::new_v4(),
        pane,
    });
    let (_, _, commands) = project(&ProjectionState::default(), &elsewhere, &now);
    assert_eq!(viewed_marks(&commands), 0);
    let (_, _, commands) = project(
        &ProjectionState::default(),
        &finished_input(Vec::new()),
        &now,
    );
    assert_eq!(viewed_marks(&commands), 0);
}

#[test]
fn the_first_pass_after_launch_marks_nothing_seen() {
    // What the restore finds was finished before the window existed. The
    // user has not looked at it yet, whatever pane the session says is
    // focused.
    let pane: Uuid = PANE.parse().expect("pane");
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let mut input = finished_input(vec![pane]);
    input.is_bootstrap = true;
    let (state, _, commands) = project(&ProjectionState::default(), &input, &now);
    assert_eq!(viewed_marks(&commands), 0);

    // The pass after it behaves as usual.
    input.is_bootstrap = false;
    let (_, _, commands) = project(&state, &input, &now);
    assert_eq!(viewed_marks(&commands), 1);
}

/// A finished record of `run`, hosted in tmux pane `tmux_pane` of the
/// fixture's socket and launched from the fixture's pane.
fn tmux_record(run: &str, tmux_pane: &str) -> RecordFile {
    RecordFile {
        provider: claude(),
        name: run.to_owned(),
        content: Some(format!(
            r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{run}","revision":4,
               "state":"finished","updatedAt":"2026-09-14T12:03:00Z","isTmuxHosted":true,
               "tmuxSocketPath":"/tmp/socket","tmuxPaneId":"{tmux_pane}",
               "tmuxServerPID":"42","tmuxServerStartedAt":"100"}}"#
        )),
    }
}

/// The fixture's pane attached to each of `endpoints`, with whether the
/// endpoint's tmux pane is the active one there.
fn attached(input: &mut ProjectionInput, pane: Uuid, endpoints: &[(&str, bool)]) {
    for &(key, is_active) in endpoints {
        input
            .presence
            .attachments
            .insert(key.to_owned(), vec![pane]);
        input.presence.locations.insert(
            key.to_owned(),
            [(pane, PaneLocation { is_active })].into_iter().collect(),
        );
    }
}

fn viewed_runtimes(commands: &[Command]) -> Vec<String> {
    commands
        .iter()
        .filter_map(|command| match &command.op {
            CommandOp::MarkViewed { runtime_id, .. } => Some(runtime_id.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn a_tmux_pane_that_is_not_its_windows_active_one_is_out_of_sight() {
    // Focusing the surface that shows a tmux window does not show every
    // pane in that window; only the active one is on screen.
    let pane: Uuid = PANE.parse().expect("pane");
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let mut input = finished_input(vec![pane]);
    input.records = vec![tmux_record(RUN, "%3")];
    attached(&mut input, pane, &[("/tmp/socket|42|100|%3", false)]);
    let (_, _, commands) = project(&ProjectionState::default(), &input, &now);
    assert_eq!(viewed_marks(&commands), 0);

    attached(&mut input, pane, &[("/tmp/socket|42|100|%3", true)]);
    let (_, _, commands) = project(&ProjectionState::default(), &input, &now);
    assert_eq!(viewed_marks(&commands), 1);
}

#[test]
fn a_record_of_an_earlier_tmux_server_does_not_take_a_new_runs_pane() {
    // The tmux server was started again on the same socket and numbered
    // its panes from the start; a run of the old one left its record.
    // Only the new server's tmux pane is attached to the Limpid pane here.
    let pane: Uuid = PANE.parse().expect("pane");
    let stale = "00000000-1111-4111-8111-AAAAAAAAAAA1";
    let fresh = "FFFFFFFF-1111-4111-8111-AAAAAAAAAAA1";
    let record = |run: &str, server_pid: &str, started_at: &str| RecordFile {
        provider: claude(),
        name: run.to_owned(),
        content: Some(format!(
            r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{run}","revision":4,
               "state":"running","updatedAt":"2026-09-14T12:03:00Z","isTmuxHosted":true,
               "tmuxSocketPath":"/tmp/socket","tmuxPaneId":"%0",
               "tmuxServerPID":"{server_pid}","tmuxServerStartedAt":"{started_at}"}}"#
        )),
    };
    let mut input = finished_input(Vec::new());
    input.records = vec![record(stale, "41", "90"), record(fresh, "42", "100")];
    input
        .presence
        .attachments
        .insert("/tmp/socket|41|90|%0".to_owned(), Vec::new());
    input
        .presence
        .attachments
        .insert("/tmp/socket|42|100|%0".to_owned(), vec![pane]);
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };

    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    let panes: Vec<_> = projection
        .runtimes
        .iter()
        .map(|runtime| {
            (
                runtime.id.clone(),
                runtime.panes.clone(),
                runtime.attachment,
            )
        })
        .collect();
    assert_eq!(
        panes,
        vec![
            (
                format!("claude:{stale}"),
                Vec::new(),
                AttachmentResolution::Detached
            ),
            (
                format!("claude:{fresh}"),
                vec![pane],
                AttachmentResolution::Attached
            ),
        ]
    );
    assert_eq!(
        projection
            .badges
            .get(&pane)
            .and_then(|badges| badges.get(&claude()))
            .map(|badge| badge.state),
        Some(RunState::Running)
    );
}

#[test]
fn only_the_run_in_front_of_a_shared_tmux_pane_is_in_sight() {
    // Two runs of one tmux session reach the same pane through its
    // client. Looking at the pane reads the turn of the run whose tmux
    // pane is in front, whichever order the records come in, and not
    // the turn of the run behind it.
    let pane: Uuid = PANE.parse().expect("pane");
    let front = "FFFFFFFF-1111-4111-8111-AAAAAAAAAAA1";
    let behind = "00000000-1111-4111-8111-AAAAAAAAAAA1";
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let mut input = finished_input(vec![pane]);
    input.records = vec![tmux_record(front, "%3"), tmux_record(behind, "%4")];
    attached(
        &mut input,
        pane,
        &[
            ("/tmp/socket|42|100|%3", true),
            ("/tmp/socket|42|100|%4", false),
        ],
    );
    let (_, projection, commands) = project(&ProjectionState::default(), &input, &now);
    assert_eq!(viewed_runtimes(&commands), vec![format!("claude:{front}")]);
    let endpoints: Vec<_> = projection
        .runtimes
        .iter()
        .map(|runtime| runtime.tmux_endpoint_key.clone())
        .collect();
    assert_eq!(
        endpoints,
        vec![
            Some("/tmp/socket|42|100|%4".to_owned()),
            Some("/tmp/socket|42|100|%3".to_owned())
        ]
    );
}

#[test]
fn the_cache_window_reaches_the_badge_only_for_a_provider_that_declares_it() {
    let pane: Uuid = PANE.parse().expect("pane");
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let window = r#","cacheWindow":{"observedAt":"2026-09-14T12:02:00Z","ttlSeconds":3600,"rewriteTokens":573000,"precision":"estimated"}"#;
    let mut input = finished_input(Vec::new());
    let content = record(Some(4), "2026-09-14T12:03:00Z", "finished").replace(
        r#""state":"finished""#,
        &format!(r#""state":"finished"{window}"#),
    );
    input.records = vec![file(Some(content))];

    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    let badge = &projection.badges[&pane][&claude()];
    assert_eq!(badge.cache_window, None, "no capability, no window");
    assert!(projection.runtimes[0].badge.cache_window.is_none());

    let mut declaring = descriptor();
    declaring.capabilities.insert(Capability::CacheWindow);
    input.providers = [(claude(), declaring)].into_iter().collect();
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    let expected = limpid_agent_model::CacheWindow {
        observed_at: "2026-09-14T12:02:00Z".to_owned(),
        ttl_seconds: 3600,
        rewrite_tokens: Some(573_000),
        precision: limpid_agent_model::CachePrecision::Estimated,
    };
    let badge = &projection.badges[&pane][&claude()];
    assert_eq!(badge.cache_window.as_ref(), Some(&expected));
    assert_eq!(
        projection.runtimes[0].badge.cache_window.as_ref(),
        Some(&expected)
    );
    let json = serde_json::to_value(&projection).expect("encode");
    assert_eq!(
        json["runtimes"][0]["badge"]["cacheWindow"]["ttlSeconds"],
        serde_json::json!(3600)
    );
}

#[test]
fn the_wait_kind_and_tool_reach_the_badge_only_while_the_run_waits() {
    let pane: Uuid = PANE.parse().expect("pane");
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let wait = r#","waitKind":"approval","tool":"Bash""#;
    let mut input = finished_input(Vec::new());
    let waiting = record(Some(4), "2026-09-14T12:03:00Z", "finished").replace(
        r#""state":"finished""#,
        &format!(r#""state":"needsInput"{wait}"#),
    );
    input.records = vec![file(Some(waiting))];
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    let badge = &projection.badges[&pane][&claude()];
    assert_eq!(
        badge.wait_kind,
        Some(limpid_agent_model::WaitKind::Approval)
    );
    assert_eq!(badge.tool.as_deref(), Some("Bash"));
    let json = serde_json::to_value(&projection).expect("encode");
    assert_eq!(
        json["runtimes"][0]["badge"]["waitKind"],
        serde_json::json!("approval")
    );
    assert_eq!(
        json["runtimes"][0]["badge"]["tool"],
        serde_json::json!("Bash")
    );

    let running = record(Some(5), "2026-09-14T12:03:30Z", "finished").replace(
        r#""state":"finished""#,
        &format!(r#""state":"running"{wait}"#),
    );
    input.records = vec![file(Some(running))];
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    let badge = &projection.badges[&pane][&claude()];
    assert_eq!(badge.wait_kind, None);
    assert_eq!(badge.tool, None);
}

#[test]
fn the_usage_limit_reaches_the_badge_only_while_the_run_rests_in_error() {
    let pane: Uuid = PANE.parse().expect("pane");
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let limit = r#","usageLimit":{"resetsAt":"2026-09-14T15:00:00Z","window":"five_hour"}"#;
    let mut input = finished_input(Vec::new());
    let errored = record(Some(4), "2026-09-14T12:03:00Z", "finished").replace(
        r#""state":"finished""#,
        &format!(r#""state":"error"{limit}"#),
    );
    input.records = vec![file(Some(errored))];
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    assert_eq!(
        projection.badges[&pane][&claude()].usage_limit,
        Some(limpid_agent_model::UsageLimit {
            resets_at: Some("2026-09-14T15:00:00Z".to_owned()),
            window: Some("five_hour".to_owned()),
        })
    );
    let json = serde_json::to_value(&projection).expect("encode");
    assert_eq!(
        json["runtimes"][0]["badge"]["usageLimit"]["resetsAt"],
        serde_json::json!("2026-09-14T15:00:00Z")
    );

    let resumed = record(Some(5), "2026-09-14T12:03:30Z", "finished").replace(
        r#""state":"finished""#,
        &format!(r#""state":"running"{limit}"#),
    );
    input.records = vec![file(Some(resumed))];
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    assert_eq!(projection.badges[&pane][&claude()].usage_limit, None);
}

#[test]
fn a_tmux_run_names_its_session_and_the_panes_it_is_attached_to_now() {
    // A tmux run writes no session hint for its launch pane, so the host
    // places its approval requests by this session id and these panes.
    let attached = Uuid::new_v4();
    let mut input = finished_input(Vec::new());
    input.records = vec![file(Some(format!(
        r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{RUN}","revision":4,
           "state":"needsInput","updatedAt":"2026-09-14T12:03:00Z","sessionId":"s1",
           "tmuxSocketPath":"/tmp/socket","tmuxPaneId":"%3","isTmuxHosted":true,
           "tmuxServerPID":"42","tmuxServerStartedAt":"100"}}"#
    )))];
    input.tabs.push(TabPanes {
        id: Uuid::new_v4(),
        panes: vec![attached],
    });
    input
        .presence
        .attachments
        .insert("/tmp/socket|42|100|%3".to_owned(), vec![attached]);
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    let runtime = projection.runtimes.first().expect("one runtime");
    assert_eq!(runtime.session_id.as_deref(), Some("s1"));
    assert_eq!(runtime.panes, vec![attached]);
}

#[test]
fn a_tmux_run_waits_rather_than_showing_nowhere() {
    // Until the topology probe reports, the panes a tmux-hosted run
    // occupies are unknown. Treating that as "no panes" would drop its
    // notification instead of holding it.
    let mut record =
        RunRecord::decode(record(Some(1), "2026-09-14T12:00:00Z", "running").as_bytes())
            .expect("record");
    record.tmux_socket_path = Some("/tmp/socket".to_owned());
    record.tmux_pane_id = Some("%3".to_owned());

    let input = ProjectionInput::default();
    let (panes, resolution) = panes_for(&record, &input);
    assert!(panes.is_empty());
    assert_eq!(resolution, AttachmentResolution::Unresolved);
}
