//! Replays recorded fixtures through the hook runtime against a scratch
//! state directory and checks what lands on disk.

use limpid_agent_hook::{HookEnv, HookOutcome, HookRuntime, NoSnapshots, run_hook};
use limpid_agent_model::{RunRecord, RunState};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

const PANE: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10";
const RUN: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11";

struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "limpid-hook-replay-{name}-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&root).expect("scratch root");
        Self { root }
    }

    fn env(&self, provider: &str) -> HookEnv {
        HookEnv::from_pairs(self.pairs(provider))
    }

    /// The environment of a pane hosted in tmux, on top of `env`.
    fn tmux_env(&self, provider: &str) -> HookEnv {
        let mut pairs = self.pairs(provider);
        pairs.push((
            "TMUX".to_owned(),
            "/tmp/limpid-test-socket,4242,0".to_owned(),
        ));
        pairs.push(("TMUX_PANE".to_owned(), "%3".to_owned()));
        HookEnv::from_pairs(pairs)
    }

    fn pairs(&self, provider: &str) -> Vec<(String, String)> {
        let mut pairs = vec![
            ("LIMPID_PANE_ID".to_owned(), PANE.to_owned()),
            ("LIMPID_AGENT_RUN_ID".to_owned(), RUN.to_owned()),
            (
                "LIMPID_HOOK_LOG".to_owned(),
                self.root.join("hook.log").display().to_string(),
            ),
        ];
        let prefix = if provider == "claude" {
            "LIMPID"
        } else {
            "LIMPID_CODEX"
        };
        pairs.push((
            format!("{prefix}_AGENT_STATES_DIR"),
            self.root.join("states").display().to_string(),
        ));
        pairs.push((
            format!("{prefix}_SESSIONS_DIR"),
            self.root.join("sessions").display().to_string(),
        ));
        if provider == "claude" {
            pairs.push((
                "LIMPID_CWD_EVENTS_DIR".to_owned(),
                self.root.join("cwd").display().to_string(),
            ));
        }
        // The shim exports the agent pid; without it the runtime walks the
        // process tree, which would make the result depend on what ran the
        // tests.
        pairs.push((
            format!("LIMPID_{}_PID", provider.to_uppercase()),
            "4242".to_owned(),
        ));
        pairs
    }

    fn record(&self) -> Option<RunRecord> {
        let bytes = fs::read(self.root.join("states").join(format!("{RUN}.state.json"))).ok()?;
        Some(RunRecord::decode(&bytes).expect("record decodes"))
    }

    fn hint(&self) -> Option<Value> {
        let bytes = fs::read(self.root.join("sessions").join(format!("{PANE}.json"))).ok()?;
        Some(serde_json::from_slice(&bytes).expect("hint decodes"))
    }

    fn log(&self) -> String {
        fs::read_to_string(self.root.join("hook.log")).unwrap_or_default()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn fixture_case(provider: &str, case: &str) -> Vec<Vec<u8>> {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures")
        .join(provider)
        .join("2026-09")
        .join(case);
    let mut names: Vec<PathBuf> = fs::read_dir(&directory)
        .expect("fixture case")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            let name = path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned();
            path.extension()
                .is_some_and(|extension| extension == "json")
                && !name.ends_with("expected.json")
        })
        .collect();
    names.sort();
    names
        .iter()
        .map(|path| fs::read(path).expect("payload"))
        .collect()
}

fn replay(scratch: &Scratch, provider: &str, payloads: &[Vec<u8>]) -> Vec<HookOutcome> {
    let env = scratch.env(provider);
    let runtime = HookRuntime::new(&env, &NoSnapshots);
    payloads
        .iter()
        .map(|payload| run_hook(provider, payload, &runtime))
        .collect()
}

#[test]
fn claude_session_basic_writes_a_version_three_record_and_drops_the_hint() {
    let scratch = Scratch::new("claude-basic");
    let payloads = fixture_case("claude", "session-basic");
    let outcomes = replay(&scratch, "claude", &payloads[..2]);
    assert!(
        outcomes
            .iter()
            .all(|outcome| *outcome == HookOutcome::Applied)
    );

    let record = scratch.record().expect("record");
    assert_eq!(record.schema_version, 3);
    assert_eq!(record.state, RunState::Running);
    assert_eq!(record.revision, Some(2));
    assert_eq!(record.run_id.as_deref(), Some(RUN));
    assert_eq!(record.pane_id, PANE);
    assert_eq!(record.pid.as_deref(), Some("4242"));
    assert!(record.first_prompt.is_some());
    assert!(record.run_started_at.is_some());
    assert!(record.session_started_at.is_some());
    let hint = scratch.hint().expect("hint");
    assert_eq!(hint["runId"], RUN);
    assert_eq!(hint["sessionId"], "00000000-0000-4000-8000-000000000001");
    // The lock sidecar only exists where the runtime takes file locks.
    assert_eq!(
        scratch
            .root
            .join("states")
            .join(format!("{RUN}.state.json.flock"))
            .exists(),
        cfg!(unix)
    );

    replay(&scratch, "claude", &payloads[2..]);
    let record = scratch.record().expect("record");
    assert_eq!(record.state, RunState::Unknown);
    assert_eq!(record.revision, Some(5));
    assert!(record.first_prompt.is_some(), "prompts survive session end");
    assert_eq!(scratch.hint(), None, "prompt_input_exit drops the hint");
    assert_eq!(scratch.log(), "");
}

#[test]
fn claude_cwd_change_writes_the_cwd_event_and_no_record() {
    let scratch = Scratch::new("claude-cwd");
    let payloads = fixture_case("claude", "cwd-changed");
    replay(&scratch, "claude", &payloads);
    let event: Value = serde_json::from_slice(
        &fs::read(scratch.root.join("cwd").join(format!("{PANE}.cwd.json"))).expect("cwd event"),
    )
    .expect("json");
    assert_eq!(event["schemaVersion"], 1);
    assert_eq!(event["paneId"], PANE);
    assert_eq!(event["newCwd"], "/tmp/example");
    let record = scratch.record().expect("record");
    // Session start, prompt, tool, stop, session end write; the cwd event
    // and the idle notification do not.
    assert_eq!(record.revision, Some(5));
}

#[test]
fn a_signal_keeps_the_hint_for_resume() {
    let scratch = Scratch::new("claude-signal");
    let payloads = fixture_case("claude", "session-end-reasons");
    // startup, prompt, stop, end(clear), start(clear), prompt, stop, end(other)
    replay(&scratch, "claude", &payloads[..4]);
    assert_eq!(scratch.hint(), None, "clear drops the hint");
    replay(&scratch, "claude", &payloads[4..]);
    assert!(scratch.hint().is_some(), "other keeps the hint");
    let record = scratch.record().expect("record");
    assert_eq!(record.state, RunState::Unknown);
    assert_eq!(record.revision, Some(8));
}

#[test]
fn codex_session_keeps_its_hint_and_finishes_tools() {
    let scratch = Scratch::new("codex-basic");
    let payloads = fixture_case("codex", "session-basic");
    replay(&scratch, "codex", &payloads);
    let record = scratch.record().expect("record");
    assert_eq!(record.state, RunState::Unknown);
    assert_eq!(record.revision, Some(6));
    assert_eq!(record.pid.as_deref(), Some("4242"));
    assert!(
        scratch.hint().is_some(),
        "Codex never drops the hint on /quit"
    );
    assert!(!scratch.root.join("cwd").exists());
}

#[test]
fn a_tmux_hosted_pane_records_the_endpoint_and_withholds_the_hint() {
    let scratch = Scratch::new("tmux");
    let payloads = fixture_case("claude", "tmux-hosted");
    let env = scratch.tmux_env("claude");
    let runtime = HookRuntime::new(&env, &NoSnapshots);
    for payload in &payloads[..2] {
        assert_eq!(run_hook("claude", payload, &runtime), HookOutcome::Applied);
    }
    let record = scratch.record().expect("record");
    assert_eq!(record.is_tmux_hosted, Some(true));
    assert_eq!(
        record.tmux_socket_path.as_deref(),
        Some("/tmp/limpid-test-socket")
    );
    assert_eq!(record.tmux_pane_id.as_deref(), Some("%3"));
    assert_eq!(record.tmux_server_pid.as_deref(), Some("4242"));
    // The start time depends on whether pid 4242 exists on this machine;
    // the field is always written so the host can tell "unknown" apart from
    // "not in tmux".
    assert!(record.tmux_server_started_at.is_some());
    assert_eq!(
        record.pid, None,
        "inside tmux the exported pid names the client"
    );
    assert_eq!(scratch.hint(), None, "resume hints are native-only");
}

#[test]
fn a_version_two_record_is_continued_with_a_higher_revision() {
    let scratch = Scratch::new("v2");
    let states = scratch.root.join("states");
    fs::create_dir_all(&states).expect("states");
    fs::write(
        states.join(format!("{RUN}.state.json")),
        format!(
            r#"{{"schemaVersion":2,"paneId":"{PANE}","state":"running","detail":"","runStartedAt":"2026-09-13T00:00:00Z","updatedAt":"2026-09-13T00:00:00Z","lastHookEvent":"UserPromptSubmit","firstPrompt":"old","revision":7,"stateEpisodeToken":"7","runId":"{RUN}"}}"#
        ),
    )
    .expect("seed");
    let payloads = fixture_case("claude", "session-basic");
    let stop = payloads.iter().find(|payload| {
        serde_json::from_slice::<Value>(payload).expect("json")["hook_event_name"] == "Stop"
    });
    replay(
        &scratch,
        "claude",
        std::slice::from_ref(stop.expect("stop")),
    );
    let record = scratch.record().expect("record");
    assert_eq!(record.schema_version, 3);
    assert_eq!(record.revision, Some(8));
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.first_prompt.as_deref(), Some("old"));
    assert_eq!(record.run_started_at, None);
}

#[test]
fn missing_shim_environment_writes_nothing() {
    let scratch = Scratch::new("not-in-limpid");
    let env = HookEnv::from_pairs([
        ("LIMPID_PANE_ID", PANE),
        (
            "LIMPID_HOOK_LOG",
            scratch.root.join("hook.log").to_str().expect("path"),
        ),
    ]);
    let runtime = HookRuntime::new(&env, &NoSnapshots);
    let payloads = fixture_case("claude", "session-basic");
    assert_eq!(
        run_hook("claude", &payloads[0], &runtime),
        HookOutcome::NotInLimpid
    );
    assert!(!scratch.root.join("states").exists());
    assert!(
        scratch
            .log()
            .contains("not launched through the Limpid shim")
    );

    let env = HookEnv::from_pairs([(
        "LIMPID_AGENT_STATES_DIR",
        scratch.root.to_str().expect("path"),
    )]);
    let runtime = HookRuntime::new(&env, &NoSnapshots);
    assert_eq!(
        run_hook("claude", &payloads[0], &runtime),
        HookOutcome::NotInLimpid
    );
    assert_eq!(
        run_hook("gemini", &payloads[0], &runtime),
        HookOutcome::UnknownProvider
    );
}

#[test]
fn malformed_payloads_are_rejected_without_blocking_the_agent() {
    let scratch = Scratch::new("rejected");
    let env = scratch.env("claude");
    let runtime = HookRuntime::new(&env, &NoSnapshots);
    let outcome = run_hook("claude", b"[1,2]", &runtime);
    assert!(matches!(outcome, HookOutcome::Rejected(_)));
    assert_eq!(outcome.exit_code(), 0);
    assert_eq!(scratch.record(), None);
    assert!(scratch.log().contains("payload rejected"));
}

#[cfg(unix)]
#[test]
fn a_busy_record_lock_skips_the_write_and_logs() {
    use std::fs::OpenOptions;
    let scratch = Scratch::new("busy");
    let states = scratch.root.join("states");
    fs::create_dir_all(&states).expect("states");
    let sidecar = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(states.join(format!("{RUN}.state.json.flock")))
        .expect("sidecar");
    sidecar.try_lock().expect("hold the lock");
    let payloads = fixture_case("claude", "session-basic");
    let outcomes = replay(&scratch, "claude", &payloads[..1]);
    assert_eq!(outcomes, vec![HookOutcome::Applied]);
    assert_eq!(
        scratch.record(),
        None,
        "nothing is written while another writer holds the lock"
    );
    assert!(scratch.log().contains("record lock busy"));
    sidecar.unlock().expect("release");
}
