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
    Capability, Command, Instants, Projection, ProjectionInput, ProjectionState,
    ProviderDescriptor, ProviderId, RecordFile, WorktreeEventFile,
};
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

/// Stands in for the registry the application passes in. Only the capabilities
/// the projection branches on matter, so the descriptors are built here rather
/// than pulling in the provider crates, which the core must not depend on.
fn descriptors() -> BTreeMap<ProviderId, ProviderDescriptor> {
    let claude = provider("claude");
    let codex = provider("codex");
    let mut providers = BTreeMap::new();
    providers.insert(
        claude.clone(),
        ProviderDescriptor {
            display_name: "Claude Code".to_owned(),
            capabilities: [
                Capability::SessionTitle,
                Capability::SessionEndDropsSession,
                Capability::Resume,
                Capability::CwdEvents,
                Capability::WorktreeEvents,
                Capability::ApprovalHook,
                Capability::Subagents,
                Capability::TurnSnapshot,
            ]
            .into_iter()
            .collect(),
            pid_sweep_interval_ms: 30_000,
            state_directory: "agent-states".to_owned(),
            session_directory: "sessions".to_owned(),
            cwd_events_directory: Some("cwd-events".to_owned()),
            process_names: vec!["claude".to_owned()],
            session_end_drop_reasons: Vec::new(),
            session_end_restart_reasons: Vec::new(),
            id: claude,
        },
    );
    providers.insert(
        codex.clone(),
        ProviderDescriptor {
            display_name: "Codex".to_owned(),
            capabilities: [
                Capability::Resume,
                Capability::ResumeDefersToOtherLiveSession,
                Capability::WorktreeEvents,
                Capability::ApprovalHook,
                Capability::Subagents,
                Capability::TurnSnapshot,
            ]
            .into_iter()
            .collect(),
            pid_sweep_interval_ms: 3_000,
            state_directory: "codex-agent-states".to_owned(),
            session_directory: "codex-sessions".to_owned(),
            cwd_events_directory: None,
            process_names: vec!["codex".to_owned()],
            session_end_drop_reasons: Vec::new(),
            session_end_restart_reasons: Vec::new(),
            id: codex,
        },
    );
    providers
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
                is_tmux_hosted: directory.ends_with("/tmux-hosted"),
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

    let mut records = read_records(case, "agent-states", ".state.json", &claude);
    records.extend(read_records(
        case,
        "codex-agent-states",
        ".state.json",
        &codex,
    ));
    let mut session_records = read_records(case, "sessions", ".json", &claude);
    session_records.extend(read_records(case, "codex-sessions", ".json", &codex));
    // The hints of runs Limpid hosts in tmux, which the writer keeps in a
    // subdirectory an older build does not descend into
    // (`ResolvedDirectories::HOSTED_SESSION_DIRECTORY`). After the plain ones,
    // as the host reads them, so a pane that has both is read from the hosted
    // one.
    session_records.extend(read_records(case, "sessions/tmux-hosted", ".json", &claude));
    session_records.extend(read_records(
        case,
        "codex-sessions/tmux-hosted",
        ".json",
        &codex,
    ));
    let mut worktree_events = read_worktree_events(case, &claude);
    worktree_events.sort_by(|left, right| left.file_name.cmp(&right.file_name));

    let input = ProjectionInput {
        providers: descriptors(),
        records,
        session_records,
        cwd_events: read_records(case, "cwd-events", ".cwd.json", &claude),
        worktree_events,
        resume_intents: hand.resume_intents,
        marks: hand.marks,
        presence: hand.presence,
        tabs: hand.tabs,
        pid_status: hand.pid_status,
        focus: hand.focus,
        acknowledged: Vec::new(),
        is_bootstrap: hand.is_bootstrap,
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
fn a_pass_is_fast_enough_to_run_on_every_file_change() {
    // The projection runs on every watcher burst, so its cost is paid
    // constantly rather than once. The ceiling is two orders of magnitude
    // above what it actually takes, which makes this a guard against a rule
    // that starts doing real work per pass rather than a benchmark.
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
    assert!(
        each < std::time::Duration::from_millis(10),
        "one pass took {each:?}"
    );
    println!(
        "projection: {each:?} per pass over {} records",
        input.records.len()
    );
}
