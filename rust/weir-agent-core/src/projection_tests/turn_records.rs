//! The turns the projection shows: carried summaries, incomplete turns, a
//! provider's own agent directory, and conversations.

use super::*;

/// A turn record of conversation `s1` as the hook writes it.
fn turn_json(turn_id: &str, number: u32, phase: &str, changes: &str) -> String {
    format!(
        r#"{{"schemaVersion":1,"turnId":"{turn_id}","provider":"claude",
           "conversation":{{"provider":"claude","conversationId":"s1","isFallback":false}},
           "runId":"{RUN}","paneId":"{PANE}","displayNumber":{number},
           "promptHead":"add tests","startedAt":"2026-10-12T00:00:00Z",
           "phase":"{phase}","begin":{{"kind":"captured","tree":"a","root":"/r"}},
           "end":{{"kind":"pending"}},"changes":{changes},"appliedEvents":[]}}"#
    )
}

fn turn_file(turn_id: &str, content: Option<String>) -> RecordFile {
    RecordFile {
        provider: claude(),
        name: turn_id.to_owned(),
        content,
    }
}

fn turns_of(projection: &Projection) -> Vec<&TurnSummary> {
    projection
        .conversations
        .iter()
        .flatten()
        .flat_map(|conversation| &conversation.turns)
        .collect()
}

const PENDING: &str = r#"{"kind":"pending"}"#;
const T1: &str = "00000000-0000-4000-8000-000000000001";
const T2: &str = "00000000-0000-4000-8000-000000000002";

#[test]
fn content_none_keeps_carried_summary() {
    let first = ProjectionInput {
        turn_files: vec![turn_file(T1, Some(turn_json(T1, 1, "started", PENDING)))],
        ..ProjectionInput::default()
    };
    let (state, _, _) = project(&ProjectionState::default(), &first, &now());
    // The host sends a file it already sent by name only.
    let again = ProjectionInput {
        turn_files: vec![turn_file(T1, None)],
        ..ProjectionInput::default()
    };
    let (kept, projection, _) = project(&state, &again, &now());
    assert_eq!(kept.turns, state.turns);
    assert_eq!(
        projection.conversations, None,
        "nothing changed, so the host keeps what it shows"
    );
    // Content that does not decode is a damaged file, not a passing
    // failure: the turn is not shown from memory.
    let damaged = ProjectionInput {
        turn_files: vec![turn_file(T1, Some("{".to_owned()))],
        ..ProjectionInput::default()
    };
    let (dropped, _, _) = project(&state, &damaged, &now());
    assert!(dropped.turns.is_empty());
}

#[test]
fn removed_name_drops_summary() {
    let first = ProjectionInput {
        turn_files: vec![turn_file(
            T1,
            Some(turn_json(T1, 1, "finished", r#"{"kind":"unchanged"}"#)),
        )],
        ..ProjectionInput::default()
    };
    let (state, _, _) = project(&ProjectionState::default(), &first, &now());
    let (state, projection, _) = project(&state, &ProjectionInput::default(), &now());
    assert_eq!(projection.conversations, Some(Vec::new()));
    assert!(state.turns.is_empty(), "and nothing is carried for it");
}

#[test]
fn a_turn_still_started_behind_a_later_one_reads_as_incomplete() {
    let input = ProjectionInput {
        records: running(),
        turn_files: vec![
            turn_file(T1, Some(turn_json(T1, 1, "started", PENDING))),
            turn_file(T2, Some(turn_json(T2, 2, "started", PENDING))),
        ],
        ..ProjectionInput::default()
    };
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now());
    let turns = turns_of(&projection);
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0].display_number, 1);
    assert_eq!(
        turns[0].phase,
        weir_agent_model::TurnPhase::Unknown,
        "not still running"
    );
    assert_eq!(
        turns[0].changes,
        weir_agent_model::ChangeSummary::Unavailable {
            reason: "endMissing".into()
        }
    );
    assert_eq!(turns[1].phase, weir_agent_model::TurnPhase::Started);
    assert_eq!(
        turns[1].changes,
        weir_agent_model::ChangeSummary::Pending,
        "the latest is still under way"
    );
}

#[test]
fn a_turn_begun_in_the_providers_memory_directory_is_not_shown() {
    // A build before the hook runtime kept Codex's memory agent out of
    // the records left its turn behind, begun in `~/.codex/memories`.
    let begun_in = |root: &str| {
        codex_turn(&turn_json(T1, 1, "started", PENDING))
            .replace(r#""root":"/r""#, &format!(r#""root":"{root}""#))
    };
    let input = |root: &str| ProjectionInput {
        records: running(),
        turn_files: vec![
            RecordFile {
                provider: codex(),
                name: T1.to_owned(),
                content: Some(begun_in(root)),
            },
            turn_file(
                T2,
                Some(turn_json(T2, 2, "finished", r#"{"kind":"unchanged"}"#)),
            ),
        ],
        ..with_memory_agent(ProjectionInput::default())
    };
    // Which paths are the directory is the descriptor's rule
    // (`is_internal_agent_directory`); here, one inside it and one
    // that only has the same names.
    let (state, projection, _) = project(
        &ProjectionState::default(),
        &input("/Users/me/.codex/memories_v2/skills"),
        &now(),
    );
    let turns = turns_of(&projection);
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].turn_id, T2);
    assert!(
        state.turns.contains_key(T1),
        "kept in the state, so retention still reaches it"
    );
    let (_, projection, _) = project(
        &ProjectionState::default(),
        &input("/Users/me/work/.codex/memories"),
        &now(),
    );
    assert_eq!(turns_of(&projection).len(), 2, "the person's work");
    // Without the person's home there is no default home to read the
    // directory against, and the turn is shown.
    let mut without_home = input("/Users/me/.codex/memories");
    without_home.home = None;
    let (_, projection, _) = project(&ProjectionState::default(), &without_home, &now());
    assert_eq!(turns_of(&projection).len(), 2);
}

#[test]
fn a_turn_of_another_provider_in_that_directory_is_shown() {
    // Claude declares no internal agent directory, so a turn the person
    // took with it in `~/.codex/memories` is theirs.
    let memory = turn_json(T1, 1, "started", PENDING)
        .replace(r#""root":"/r""#, r#""root":"/Users/me/.codex/memories""#);
    let input = ProjectionInput {
        records: running(),
        turn_files: vec![turn_file(T1, Some(memory))],
        ..with_memory_agent(ProjectionInput::default())
    };
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now());
    assert_eq!(turns_of(&projection).len(), 1);
}

#[test]
fn a_hint_left_in_the_providers_memory_directory_is_not_offered() {
    let mut input = with_memory_agent(finished_input(Vec::new()));
    let mut resumable = descriptor();
    resumable.capabilities.insert(Capability::Resume);
    input.providers.insert(claude(), resumable);
    if let Some(codex) = input.providers.get_mut(&codex()) {
        codex.capabilities.insert(Capability::Resume);
    }
    let hint = |provider: ProviderId, cwd: &str| RecordFile {
        provider,
        name: PANE.to_owned(),
        content: Some(format!(
            r#"{{"schemaVersion":1,"paneId":"{PANE}","runId":"{RUN}","sessionId":"memory-thread","cwd":"{cwd}"}}"#
        )),
    };
    let pane: Uuid = PANE.parse().expect("pane");
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };

    input.session_records = vec![hint(codex(), "/Users/me/.codex/memories")];
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    assert!(
        !projection.sessions.contains_key(&pane),
        "nothing to resume"
    );
    assert!(!projection.resume_candidates.contains_key(&pane));

    // The person's own, though the path has the same names in it, and
    // another provider's session the person ran there.
    for (provider, cwd) in [
        (codex(), "/Users/me/work/.codex/memories"),
        (claude(), "/Users/me/.codex/memories"),
    ] {
        input.session_records = vec![hint(provider.clone(), cwd)];
        let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
        assert_eq!(
            projection.sessions[&pane][&provider].cwd.as_deref(),
            Some(cwd),
            "{provider} in {cwd}"
        );
        assert!(projection.resume_candidates[&pane].contains(&provider));
    }
}

#[test]
fn a_hint_in_the_memory_directory_of_a_symlinked_home_is_not_offered() {
    // `~/.codex` links to a dotfiles volume, and the record names the
    // target, as an agent that canonicalized its home writes it.
    let mut input = with_memory_agent(finished_input(Vec::new()));
    if let Some(codex) = input.providers.get_mut(&codex()) {
        codex.capabilities.insert(Capability::Resume);
    }
    input.session_records = vec![RecordFile {
        provider: codex(),
        name: PANE.to_owned(),
        content: Some(format!(
            r#"{{"schemaVersion":1,"paneId":"{PANE}","runId":"{RUN}","sessionId":"memory-thread","cwd":"/Volumes/Dotfiles/.codex/memories"}}"#
        )),
    }];
    let pane: Uuid = PANE.parse().expect("pane");
    let now = Instants {
        wall: "2026-09-14T12:04:00Z".to_owned(),
        monotonic_ms: 0,
    };

    // Without the host's reading of the link, the path is the person's.
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    assert!(projection.resume_candidates[&pane].contains(&codex()));

    input
        .resolved_homes
        .insert(codex(), "/Volumes/Dotfiles/.codex".to_owned());
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now);
    assert!(!projection.sessions.contains_key(&pane));
    assert!(!projection.resume_candidates.contains_key(&pane));

    // The resolved home is the provider's own: another provider's run
    // there is the person's.
    let mut other = input.clone();
    other.resolved_homes = BTreeMap::from([(claude(), "/Volumes/Dotfiles/.codex".to_owned())]);
    let (_, projection, _) = project(&ProjectionState::default(), &other, &now);
    assert!(projection.resume_candidates[&pane].contains(&codex()));
}

/// `input` with the person's home and a provider that runs an agent of
/// its own under its home, as Codex declares it.
fn with_memory_agent(mut input: ProjectionInput) -> ProjectionInput {
    let mut codex_descriptor = descriptor();
    codex_descriptor.id = codex();
    codex_descriptor.internal_agent_directories =
        vec!["memories".to_owned(), "memories_v2".to_owned()];
    input.providers.insert(codex(), codex_descriptor);
    input.home = Some("/Users/me".to_owned());
    input
}

/// A turn record of `turn_json`'s shape, written by Codex.
fn codex_turn(json: &str) -> String {
    json.replace(r#""provider":"claude""#, r#""provider":"codex""#)
}

#[test]
fn a_started_turn_whose_run_is_gone_reads_as_incomplete() {
    // The agent crashed or its pane closed: no later turn will come.
    let files = vec![turn_file(T1, Some(turn_json(T1, 1, "started", PENDING)))];
    let live = ProjectionInput {
        records: running(),
        turn_files: files.clone(),
        ..ProjectionInput::default()
    };
    let (state, projection, _) = project(&ProjectionState::default(), &live, &now());
    assert_eq!(
        turns_of(&projection)[0].phase,
        weir_agent_model::TurnPhase::Started
    );

    let gone = ProjectionInput {
        turn_files: files
            .into_iter()
            .map(|file| turn_file(&file.name, None))
            .collect(),
        ..ProjectionInput::default()
    };
    let (_, projection, _) = project(&state, &gone, &now());
    let turns = turns_of(&projection);
    assert_eq!(turns.len(), 1, "sent again although no turn changed");
    assert_eq!(turns[0].phase, weir_agent_model::TurnPhase::Unknown);
    assert_eq!(
        turns[0].changes,
        weir_agent_model::ChangeSummary::Unavailable {
            reason: "endMissing".into()
        }
    );
}

#[test]
fn a_turn_record_under_another_name_is_not_shown() {
    let input = ProjectionInput {
        turn_files: vec![turn_file(T2, Some(turn_json(T1, 1, "started", PENDING)))],
        ..ProjectionInput::default()
    };
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now());
    assert_eq!(projection.conversations, Some(Vec::new()));
}

#[test]
fn an_end_nobody_prompted_says_it_had_no_prompt() {
    let end_only = format!(
        r#"{{"schemaVersion":1,"turnId":"{T1}","provider":"claude",
           "conversation":{{"provider":"claude","conversationId":"s1","isFallback":false}},
           "runId":"{RUN}","paneId":"{PANE}","displayNumber":3,
           "startedAt":"2026-10-12T00:00:00Z","phase":"finished",
           "begin":{{"kind":"pending"}},"end":{{"kind":"skipped","reason":"beginMissing"}},
           "changes":{{"kind":"unavailable","reason":"beginMissing"}},"appliedEvents":[]}}"#
    );
    let input = ProjectionInput {
        turn_files: vec![
            turn_file(T1, Some(end_only)),
            turn_file(
                T2,
                Some(turn_json(T2, 4, "finished", r#"{"kind":"unchanged"}"#)),
            ),
        ],
        ..ProjectionInput::default()
    };
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now());
    let turns = turns_of(&projection);
    assert!(!turns[0].has_prompt);
    assert!(turns[1].has_prompt);
}

#[test]
fn a_runtime_names_its_conversation_and_current_turn() {
    let mut input = finished_input(Vec::new());
    input.records = vec![file(Some(format!(
        r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{RUN}","revision":4,
           "state":"finished","updatedAt":"2026-09-14T12:03:00Z","sessionId":"s1",
           "currentTurnId":"{T1}"}}"#
    )))];
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now());
    let runtime = &projection.runtimes[0];
    assert_eq!(runtime.conversation.conversation_id, "s1");
    assert!(!runtime.conversation.is_fallback);
    assert_eq!(runtime.current_turn_id.as_deref(), Some(T1));

    // Before it reports a session, the run is its own conversation.
    let (_, projection, _) = project(
        &ProjectionState::default(),
        &finished_input(Vec::new()),
        &now(),
    );
    assert!(projection.runtimes[0].conversation.is_fallback);
    assert_eq!(projection.runtimes[0].conversation.conversation_id, RUN);
}

#[test]
fn a_later_turn_of_another_run_does_not_overtake() {
    // The same conversation resumed in a second pane: both runs live,
    // each with its own turn under way.
    let other = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA2";
    let mut records = running();
    records.push(RecordFile {
        provider: claude(),
        name: other.to_owned(),
        content: Some(format!(
            r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{other}","revision":1,
               "state":"running","updatedAt":"2026-10-12T00:00:30Z"}}"#
        )),
    });
    let input = ProjectionInput {
        records,
        turn_files: vec![
            turn_file(T1, Some(turn_json(T1, 1, "started", PENDING))),
            turn_file(
                T2,
                Some(turn_json(T2, 2, "started", PENDING).replace(RUN, other)),
            ),
        ],
        ..ProjectionInput::default()
    };
    let (_, projection, _) = project(&ProjectionState::default(), &input, &now());
    let turns = turns_of(&projection);
    assert_eq!(turns.len(), 2);
    assert!(
        turns
            .iter()
            .all(|turn| turn.phase == weir_agent_model::TurnPhase::Started),
        "each still runs"
    );
}
