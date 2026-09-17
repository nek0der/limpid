//! Regenerates the projection corpus from the recorded hook fixtures.
//!
//! The reader side needs record sets to project, and hand-writing them would
//! let the hook fixtures and the reader corpus drift: a provider schema change would
//! update the hook fixtures and leave the reader corpus describing records no
//! hook writes any more. So every record under `rust/fixtures/projection/` is
//! produced by replaying hook fixtures through the real runtime.
//!
//! Each case owns a `scenario.json` naming the runs to replay and the wall
//! clock each payload lands at. Timestamps are explicit because retention
//! rules (a viewed finish older than a day, a resume intent past its window)
//! are only reachable with a controlled clock.
//!
//! Run it with `scripts/derive-projection-corpus.sh`. The generated records are
//! committed and reviewed like the `expected.json` goldens they feed.

use limpid_agent_hook::{HookEnv, HookOutcome, HookRuntime, NoSnapshots, run_hook};
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// One case's recipe. `runs` is ordered, and so is each run's `replay`, because
/// the record a step writes depends on the record the step before it left.
#[derive(Deserialize)]
struct Scenario {
    /// Why this case exists, in one line. Read by whoever reviews the records.
    #[allow(dead_code)]
    description: String,
    runs: Vec<RunSpec>,
}

#[derive(Deserialize)]
struct RunSpec {
    provider: String,
    pane: String,
    run: String,
    /// The agent pid to export. `None` leaves it unset, which is how a
    /// tmux-hosted pane reaches the hook.
    #[serde(default)]
    pid: Option<String>,
    /// Set to run in tmux, which changes the record's endpoint fields.
    #[serde(default)]
    tmux: bool,
    /// What the shim exports as `LIMPID_AGENT_TMUX_HOST_MODE` for a run in
    /// tmux: `limpidHosted` keeps the resume hint, `manual` or nothing
    /// withholds it.
    #[serde(default, rename = "tmuxHostMode")]
    tmux_host_mode: Option<String>,
    replay: Vec<Step>,
}

#[derive(Deserialize)]
struct Step {
    /// A hook fixture case, as `<provider>/<case>`; the provider defaults to
    /// the run's when the case carries no slash.
    case: String,
    payload: String,
    now: String,
}

/// The directories a generated case owns. Everything else in the case
/// directory is hand-authored and left alone.
const GENERATED: [&str; 5] = [
    "agent-states",
    "codex-agent-states",
    "sessions",
    "codex-sessions",
    "cwd-events",
];

fn main() -> ExitCode {
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures");
    let projection = fixtures.join("projection");
    let mut cases: Vec<PathBuf> = match fs::read_dir(&projection) {
        Ok(entries) => entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.join("scenario.json").is_file())
            .collect(),
        Err(error) => {
            eprintln!("cannot read {}: {error}", projection.display());
            return ExitCode::FAILURE;
        }
    };
    cases.sort();

    for case in &cases {
        if let Err(error) = derive(case, &fixtures) {
            eprintln!("{}: {error}", case.display());
            return ExitCode::FAILURE;
        }
        println!("{}", case.file_name().unwrap_or_default().to_string_lossy());
    }
    println!("{} case(s)", cases.len());
    ExitCode::SUCCESS
}

fn derive(case: &Path, fixtures: &Path) -> Result<(), String> {
    let text = fs::read_to_string(case.join("scenario.json"))
        .map_err(|error| format!("scenario.json: {error}"))?;
    let scenario: Scenario =
        serde_json::from_str(&text).map_err(|error| format!("scenario.json: {error}"))?;

    for directory in GENERATED {
        let path = case.join(directory);
        if path.exists() {
            fs::remove_dir_all(&path).map_err(|error| format!("{directory}: {error}"))?;
        }
    }

    for run in &scenario.runs {
        let env = environment(case, run);
        for step in &run.replay {
            let payload = payload_bytes(fixtures, &run.provider, step)?;
            let runtime = HookRuntime {
                env: &env,
                snapshots: &NoSnapshots,
                now: step.now.clone(),
            };
            match run_hook(&run.provider, &payload, &runtime) {
                HookOutcome::Applied => {}
                other => {
                    return Err(format!(
                        "{}/{} replayed as {other:?}, expected Applied",
                        step.case, step.payload
                    ));
                }
            }
        }
    }
    prune_lock_sidecars(case)
}

/// Drops the `.flock` files the runtime leaves beside every record it writes.
/// They are runtime scaffolding rather than state, and committing empty lock
/// files would put noise in every corpus diff.
fn prune_lock_sidecars(case: &Path) -> Result<(), String> {
    for directory in GENERATED {
        let path = case.join(directory);
        let Ok(entries) = fs::read_dir(&path) else {
            continue;
        };
        for entry in entries.flatten() {
            if entry.path().extension().is_some_and(|it| it == "flock") {
                fs::remove_file(entry.path())
                    .map_err(|error| format!("{}: {error}", entry.path().display()))?;
            }
        }
    }
    Ok(())
}

/// Points the runtime's directories straight at the case directory so the
/// generated tree mirrors what the application watches on disk.
fn environment(case: &Path, run: &RunSpec) -> HookEnv {
    let at = |name: &str| case.join(name).display().to_string();
    let prefix = if run.provider == "claude" {
        "LIMPID"
    } else {
        "LIMPID_CODEX"
    };
    let mut pairs = vec![
        ("LIMPID_PANE_ID".to_owned(), run.pane.clone()),
        ("LIMPID_AGENT_RUN_ID".to_owned(), run.run.clone()),
        (
            format!("{prefix}_AGENT_STATES_DIR"),
            at(if run.provider == "claude" {
                "agent-states"
            } else {
                "codex-agent-states"
            }),
        ),
        (
            format!("{prefix}_SESSIONS_DIR"),
            at(if run.provider == "claude" {
                "sessions"
            } else {
                "codex-sessions"
            }),
        ),
    ];
    if run.provider == "claude" {
        pairs.push(("LIMPID_CWD_EVENTS_DIR".to_owned(), at("cwd-events")));
    }
    if let Some(pid) = &run.pid {
        pairs.push((
            format!("LIMPID_{}_PID", run.provider.to_uppercase()),
            pid.clone(),
        ));
    }
    if run.tmux {
        // A fixed endpoint keeps the generated records stable; the server pid
        // and start time are what the reader correlates panes by.
        pairs.push((
            "TMUX".to_owned(),
            "/tmp/limpid-corpus-socket,4242,0".to_owned(),
        ));
        pairs.push(("TMUX_PANE".to_owned(), "%3".to_owned()));
        if let Some(mode) = &run.tmux_host_mode {
            pairs.push(("LIMPID_AGENT_TMUX_HOST_MODE".to_owned(), mode.clone()));
        }
    }
    HookEnv::from_pairs(pairs)
}

fn payload_bytes(fixtures: &Path, provider: &str, step: &Step) -> Result<Vec<u8>, String> {
    let (provider, case) = match step.case.split_once('/') {
        Some((provider, case)) => (provider, case),
        None => (provider, step.case.as_str()),
    };
    let path = fixtures
        .join(provider)
        .join("2026-09")
        .join(case)
        .join(&step.payload);
    fs::read(&path).map_err(|error| format!("{}: {error}", path.display()))
}
