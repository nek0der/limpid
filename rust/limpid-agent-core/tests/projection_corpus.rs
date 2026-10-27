//! Runs the projection over the recorded corpus and compares it with the
//! committed goldens.
//!
//! The corpus records come from replaying real hook payloads, so a change here
//! is a change in what the interface would show for a session that actually
//! happened. Set `LIMPID_REGENERATE_EXPECTED=1` to rewrite the goldens, then
//! read the diff before committing it: what review covers is the committed
//! file, not the run that produced it.

use limpid_agent_core::project;
use limpid_agent_model::{
    CWD_EVENT_FILE_SUFFIX, Command, Instants, Projection, ProjectionInput, ProjectionState,
    ProviderAdapter, ProviderDescriptor, ProviderId, RUN_RECORD_FILE_SUFFIX, RecordFile,
    SESSION_HINT_FILE_SUFFIX, TURN_RECORD_FILE_SUFFIX, TURNS_DIRECTORY, WorktreeEventFile,
};
use limpid_provider_claude::ClaudeAdapter;
use limpid_provider_codex::CodexAdapter;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

/// What a case's golden holds. Commands are included from the start so a rule
/// that begins emitting one shows up as a diff rather than silently.
#[derive(serde::Serialize, serde::Deserialize, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
struct Expected {
    projection: Projection,
    commands: Vec<Command>,
}

/// The part of a case that is hand-written: everything in the input that does
/// not come from the state directories.
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct CaseInput {
    now: String,
    monotonic_ms: u64,
    #[serde(default)]
    is_bootstrap: bool,
    #[serde(default)]
    tabs: Vec<limpid_agent_model::TabPanes>,
    #[serde(default)]
    pid_status: BTreeMap<String, limpid_agent_model::PidStatus>,
    #[serde(default)]
    focus: Option<limpid_agent_model::Focus>,
    #[serde(default)]
    seen_panes: Vec<uuid::Uuid>,
    #[serde(default)]
    marks: limpid_agent_model::AttentionMarks,
    #[serde(default)]
    presence: limpid_agent_model::PanePresence,
    #[serde(default)]
    resume_intents: Vec<limpid_agent_model::ResumeIntent>,
}

fn corpus() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures/projection")
}

fn provider(name: &str) -> ProviderId {
    ProviderId::new(name).expect("provider id")
}

/// The registry the application passes in, built from the provider crates
/// themselves, so the goldens record what the app shows rather than what a
/// copy of the descriptors would.
fn descriptors() -> BTreeMap<ProviderId, ProviderDescriptor> {
    [
        ClaudeAdapter.descriptor().clone(),
        CodexAdapter.descriptor().clone(),
    ]
    .into_iter()
    .map(|descriptor| (descriptor.id.clone(), descriptor))
    .collect()
}

/// Reads one generated directory the way the application's watcher would: the
/// file stem is the record's storage id, and an unreadable file is reported as
/// present with no content.
fn read_records(
    case: &Path,
    directory: &str,
    suffix: &str,
    provider: &ProviderId,
) -> Vec<RecordFile> {
    let Ok(entries) = fs::read_dir(case.join(directory)) else {
        return Vec::new();
    };
    let mut files: Vec<RecordFile> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let name = path.file_name()?.to_str()?.strip_suffix(suffix)?.to_owned();
            Some(RecordFile {
                provider: provider.clone(),
                content: fs::read_to_string(&path).ok(),
                name,
            })
        })
        .collect();
    files.sort_by(|left, right| left.name.cmp(&right.name));
    files
}

fn read_worktree_events(case: &Path, provider: &ProviderId) -> Vec<WorktreeEventFile> {
    let Ok(entries) = fs::read_dir(case.join("worktree-events")) else {
        return Vec::new();
    };
    let mut files: Vec<WorktreeEventFile> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            Some(WorktreeEventFile {
                provider: provider.clone(),
                file_name: path.file_name()?.to_str()?.to_owned(),
                content: fs::read_to_string(&path).ok()?,
            })
        })
        .collect();
    files.sort_by(|left, right| left.file_name.cmp(&right.file_name));
    files
}

fn build_input(case: &Path) -> (ProjectionInput, Instants) {
    let text = fs::read_to_string(case.join("input.json")).expect("input.json");
    let hand: CaseInput = serde_json::from_str(&text).expect("input.json parses");
    let claude = provider("claude");
    let codex = provider("codex");

    let mut records = read_records(case, "agent-states", RUN_RECORD_FILE_SUFFIX, &claude);
    records.extend(read_records(
        case,
        "codex-agent-states",
        RUN_RECORD_FILE_SUFFIX,
        &codex,
    ));
    let mut session_records = read_records(case, "sessions", SESSION_HINT_FILE_SUFFIX, &claude);
    session_records.extend(read_records(
        case,
        "codex-sessions",
        SESSION_HINT_FILE_SUFFIX,
        &codex,
    ));
    let mut worktree_events = read_worktree_events(case, &claude);
    worktree_events.sort_by(|left, right| left.file_name.cmp(&right.file_name));

    let input = ProjectionInput {
        providers: descriptors(),
        // No case is about a provider's internal agent directories.
        home: None,
        resolved_homes: BTreeMap::new(),
        records,
        session_records,
        cwd_events: read_records(case, "cwd-events", CWD_EVENT_FILE_SUFFIX, &claude),
        worktree_events,
        // A case keeps its turn records in `turns/`, beside its other
        // directories, as it does worktree events; no case has any yet, and
        // the missing directory reads as none.
        turn_files: read_records(case, TURNS_DIRECTORY, TURN_RECORD_FILE_SUFFIX, &claude),
        resume_intents: hand.resume_intents,
        marks: hand.marks,
        presence: hand.presence,
        tabs: hand.tabs,
        pid_status: hand.pid_status,
        focus: hand.focus,
        seen_panes: hand.seen_panes,
        // No case reports a program's status.
        program_status: BTreeMap::new(),
        acknowledged: Vec::new(),
        is_bootstrap: hand.is_bootstrap,
        // No case protects turns yet, so none sweeps them.
        turn_sweep: None,
    };
    let now = Instants {
        wall: hand.now,
        monotonic_ms: hand.monotonic_ms,
    };
    (input, now)
}

#[test]
fn every_case_matches_its_golden() {
    let regenerate = std::env::var_os("LIMPID_REGENERATE_EXPECTED").is_some();
    let mut cases: Vec<PathBuf> = fs::read_dir(corpus())
        .expect("corpus")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.join("input.json").is_file())
        .collect();
    cases.sort();
    assert!(!cases.is_empty(), "the corpus is empty");

    let mut failures = Vec::new();
    for case in &cases {
        let (input, now) = build_input(case);
        let (_, projection, commands) = project(&ProjectionState::default(), &input, &now);
        let actual = Expected {
            projection,
            commands,
        };
        let path = case.join("expected.json");

        if regenerate {
            let text = serde_json::to_string_pretty(&actual).expect("encode");
            fs::write(&path, text + "\n").expect("write golden");
            continue;
        }

        let Ok(text) = fs::read_to_string(&path) else {
            failures.push(format!("{}: no expected.json", case.display()));
            continue;
        };
        let expected: Expected = serde_json::from_str(&text).expect("expected.json parses");
        if expected != actual {
            failures.push(format!(
                "{}:\n  expected {}\n  actual   {}",
                case.display(),
                serde_json::to_string(&expected).unwrap_or_default(),
                serde_json::to_string(&actual).unwrap_or_default()
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
    assert!(
        !regenerate,
        "goldens regenerated; unset LIMPID_REGENERATE_EXPECTED and review the diff"
    );
}

#[test]
fn a_projection_pass_is_idempotent() {
    // Feeding the same records back with the state from the previous pass must
    // not change what is shown. A rule that accidentally depended on the state
    // being empty would only show up here.
    let case = corpus().join("dominance");
    let (input, now) = build_input(&case);
    let (state, first, _) = project(&ProjectionState::default(), &input, &now);
    let (_, second, _) = project(&state, &input, &now);
    assert_eq!(first, second);
}

#[test]
#[ignore = "a measurement: run with --release --ignored --nocapture"]
fn a_pass_over_the_corpus_is_measured() {
    // The projection runs on every watcher burst, so its cost is paid
    // constantly rather than once. A wall-clock ceiling in the debug suite
    // measured the machine and the build profile as much as the rules, so the
    // figure is printed for a person to compare, as `make test-measure` does
    // for the Swift timings.
    let case = corpus().join("dominance");
    let (input, now) = build_input(&case);
    let mut state = ProjectionState::default();

    let started = std::time::Instant::now();
    let rounds = 200;
    for _ in 0..rounds {
        let (next, _, _) = project(&state, &input, &now);
        state = next;
    }
    let each = started.elapsed() / rounds;
    println!(
        "projection: {each:?} per pass over {} records",
        input.records.len()
    );
}

/// One pass as the bridge's engine runs it: the input read in, the pass over
/// the state it keeps, and the answer written out. The state never crosses
/// the boundary.
fn bridged_pass(previous: &ProjectionState, input: &[u8], now: &Instants) -> ProjectionState {
    let input: ProjectionInput = serde_json::from_slice(input).expect("input");
    let (next, projection, commands) = project(previous, &input, now);
    let _ = serde_json::to_vec(&(projection, commands)).expect("answer");
    next
}

/// `total` finished turns, 200 in each conversation as the retention keeps
/// them, with their content as the host sends a record it has not sent yet.
fn turn_files(total: usize) -> Vec<RecordFile> {
    let claude = ProviderId::new("claude").expect("provider");
    (0..total)
        .map(|index| {
            let (conversation, number) = (index / 200, index % 200 + 1);
            let turn_id = format!("00000000-0000-4000-8000-{index:012}");
            RecordFile {
                provider: claude.clone(),
                name: turn_id.clone(),
                content: Some(format!(
                    r#"{{"schemaVersion":1,"turnId":"{turn_id}","provider":"claude",
                       "conversation":{{"provider":"claude","conversationId":"s{conversation}","isFallback":false}},
                       "runId":"R","paneId":"P","displayNumber":{number},"promptHead":"add tests",
                       "startedAt":"2026-10-12T00:00:00Z","finishedAt":"2026-10-12T00:01:30Z",
                       "phase":"finished","begin":{{"kind":"captured","tree":"a","root":"/r"}},
                       "end":{{"kind":"captured","tree":"b","root":"/r"}},
                       "changes":{{"kind":"changed","files":2,"added":94,"removed":2,"hasBashChanges":false}},
                       "durationSeconds":90,"appliedEvents":["claude:invocation:X"]}}"#
                )),
            }
        })
        .collect()
}

/// The time of one warm pass with `files` known, sent by name as the host
/// does once it has sent them, over `rounds` passes; and the input's size.
fn warm_pass(
    input: &mut ProjectionInput,
    now: &Instants,
    files: Vec<RecordFile>,
    rounds: u32,
) -> (std::time::Duration, usize) {
    input.turn_files.clone_from(&files);
    let cold = serde_json::to_vec(&*input).expect("input");
    let mut state = bridged_pass(&ProjectionState::default(), &cold, now);
    input.turn_files = files
        .into_iter()
        .map(|file| RecordFile {
            content: None,
            ..file
        })
        .collect();
    let warm = serde_json::to_vec(&*input).expect("input");
    let started = std::time::Instant::now();
    for _ in 0..rounds {
        state = bridged_pass(&state, &warm, now);
    }
    (started.elapsed() / rounds, warm.len())
}

#[test]
#[ignore = "a measurement: run with --release --ignored --nocapture"]
fn a_pass_over_a_thousand_turns_is_measured() {
    // The measurement: 200 turns in each of five conversations.
    // Compared with the same pass without turns, since what matters is what
    // turns add to every pass.
    let case = corpus().join("dominance");
    let (mut input, now) = build_input(&case);
    let (without, _) = warm_pass(&mut input, &now, Vec::new(), 50);
    let (with, _) = warm_pass(&mut input, &now, turn_files(1000), 50);
    println!("projection: {without:?} per pass without turns, {with:?} with 1000 turns");
}

#[test]
#[ignore = "a measurement: run with --release --ignored --nocapture"]
fn a_pass_over_tens_of_thousands_of_turns_is_measured() {
    // The measurement at scale: 10,000 and 20,000 turns. Only the input
    // crosses the boundary, and by name it stays far under the bridge's
    // 16 MB; the time is printed for the record.
    let case = corpus().join("dominance");
    let (mut input, now) = build_input(&case);
    for total in [10_000, 20_000] {
        let (pass, input_bytes) = warm_pass(&mut input, &now, turn_files(total), 10);
        println!("{total} turns: warm pass {pass:?}, input {input_bytes} bytes by name");
        assert!(input_bytes < 4 * 1024 * 1024, "{input_bytes} bytes");
    }
}
