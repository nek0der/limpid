//! Replays recorded fixtures through the hook runtime against a scratch
//! state directory and checks what lands on disk.

use limpid_agent_hook::{
    HookEnv, HookOutcome, HookRuntime, NoSnapshots, TURNS_DIRECTORY, run_hook,
};
use limpid_agent_model::{
    ChangeSummary, DeniedAction, LOCK_FILE_SUFFIX, PermissionMode, PromptKind, RecordedPromptKind,
    RunRecord, RunState, SnapshotStatus, TurnPhase, TurnRecord, TurnUsage, cwd_event_file_name,
    run_record_file_name, session_hint_file_name,
};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use support::{PANE, RUN};

mod support;

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
        let bytes = fs::read(self.root.join("states").join(run_record_file_name(RUN))).ok()?;
        Some(RunRecord::decode(&bytes).expect("record decodes"))
    }

    fn hint(&self) -> Option<Value> {
        let bytes = fs::read(
            self.root
                .join("sessions")
                .join(session_hint_file_name(PANE)),
        )
        .ok()?;
        Some(serde_json::from_slice(&bytes).expect("hint decodes"))
    }

    fn log(&self) -> String {
        fs::read_to_string(self.root.join("hook.log")).unwrap_or_default()
    }

    /// One Claude hook call of run `run`, carrying the invocation id `call`
    /// the way the shim exports it (`None`: a shim that exports none).
    fn call(&self, run: &str, call: Option<&str>, payload: &[u8]) -> HookOutcome {
        self.call_as("claude", run, call, payload)
    }

    /// Does what `call` does, for `provider`.
    fn call_as(
        &self,
        provider: &str,
        run: &str,
        call: Option<&str>,
        payload: &[u8],
    ) -> HookOutcome {
        let mut pairs = self.pairs(provider);
        pairs.retain(|(name, _)| name != "LIMPID_AGENT_RUN_ID");
        pairs.push(("LIMPID_AGENT_RUN_ID".to_owned(), run.to_owned()));
        if let Some(call) = call {
            pairs.push(("LIMPID_HOOK_INVOCATION_ID".to_owned(), call.to_owned()));
        }
        let env = HookEnv::from_pairs(pairs);
        run_hook(provider, payload, &HookRuntime::new(&env, &NoSnapshots))
    }

    /// Every turn on disk, in display order.
    fn turns(&self) -> Vec<TurnRecord> {
        // A prompt with no turn id of its own makes no turn, so a missing
        // turns directory means no turns here; a record that does not decode
        // still fails the test.
        let mut turns = match support::read_turns(&self.root.join("states")) {
            Ok(turns) => turns,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(error) => panic!("turns: {error}"),
        };
        turns.sort_by_key(|turn| turn.display_number);
        turns
    }
}

const SESSION_START: &[u8] =
    br#"{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}"#;
const PROMPT: &[u8] =
    br#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"add tests"}"#;
const STOP: &[u8] = br#"{"hook_event_name":"Stop","session_id":"s1"}"#;
const OTHER_RUN: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F12";

fn new_call() -> String {
    uuid::Uuid::new_v4().to_string()
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn fixture_case(provider: &str, case: &str) -> Vec<Vec<u8>> {
    dated_fixture_case(provider, "2026-09", case)
}

fn dated_fixture_case(provider: &str, date: &str, case: &str) -> Vec<Vec<u8>> {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures")
        .join(provider)
        .join(date)
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

/// Each payload is its own hook call, with the invocation id the shim mints
/// for every call.
fn replay(scratch: &Scratch, provider: &str, payloads: &[Vec<u8>]) -> Vec<HookOutcome> {
    payloads
        .iter()
        .map(|payload| {
            let mut pairs = scratch.pairs(provider);
            pairs.push(("LIMPID_HOOK_INVOCATION_ID".to_owned(), new_call()));
            let env = HookEnv::from_pairs(pairs);
            run_hook(provider, payload, &HookRuntime::new(&env, &NoSnapshots))
        })
        .collect()
}

/// A refusal lands on the turn under way, leaves the run working, and is
/// applied once when its hook is retried; with no turn running it is no
/// turn's.
#[test]
fn a_refused_action_lands_on_the_turn_under_way_once() {
    let scratch = Scratch::new("claude-denied");
    let denied = br#"{"hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"git push --force"},"tool_use_id":"toolu_1","reason":"Rewrites history"}"#.to_vec();
    replay(&scratch, "claude", std::slice::from_ref(&denied));
    assert!(scratch.turns().is_empty());

    replay(
        &scratch,
        "claude",
        &[
            br#"{"hook_event_name":"UserPromptSubmit","prompt":"ship it"}"#.to_vec(),
            denied.clone(),
            denied,
        ],
    );
    assert_eq!(scratch.record().expect("record").state, RunState::Running);
    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].denied_count, 1);
    assert_eq!(
        turns[0].denied_actions,
        vec![DeniedAction {
            action: "git push --force".to_owned(),
            reason: "Rewrites history".to_owned(),
        }]
    );
}

/// The case's refusal, whose payload is written by hand around a real session
/// (`rust/fixtures/README.md`), reaches the turn the session's prompt began.
#[test]
fn the_fixture_cases_refusal_stays_on_its_turn_through_the_stop() {
    let scratch = Scratch::new("claude-denied-case");
    let payloads = dated_fixture_case("claude", "2026-10", "permission-denied");
    replay(&scratch, "claude", &payloads);
    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].phase, TurnPhase::Finished);
    assert_eq!(turns[0].denied_count, 1);
    assert_eq!(
        turns[0].denied_actions[0].action,
        "git push --force origin main"
    );
    assert_eq!(scratch.record().expect("record").state, RunState::Finished);
}

/// A Claude session switched with `/model haiku`, then prompted once: the
/// switch's call, which changes no state, still writes the model, and the
/// prompt the mode, each kept through the calls after it.
#[test]
fn a_recorded_model_switch_reaches_the_record_and_stays() {
    let scratch = Scratch::new("claude-model-switch");
    let payloads = dated_fixture_case("claude", "2026-10", "model-switch");
    let outcomes = replay(&scratch, "claude", &payloads[..2]);
    assert!(
        outcomes
            .iter()
            .all(|outcome| *outcome == HookOutcome::Applied)
    );
    let switched = scratch.record().expect("record after the switch");
    assert_eq!(switched.model.as_deref(), Some("Haiku 5.5"));
    assert_eq!(switched.permission_mode, None);
    assert_eq!(switched.last_hook_event.as_deref(), Some("session_started"));

    replay(&scratch, "claude", &payloads[2..4]);
    let stopped = scratch.record().expect("record after the stop");
    assert_eq!(stopped.state, RunState::Finished);
    assert_eq!(stopped.model.as_deref(), Some("Haiku 5.5"));
    assert_eq!(stopped.permission_mode, Some(PermissionMode::Default));
}

#[test]
fn answered_claude_question_resumes_before_the_next_tool_or_stop() {
    for event in ["PostToolUse", "PostToolUseFailure"] {
        let scratch = Scratch::new("claude-question-answer");
        replay(&scratch, "claude", &[
            br#"{"hook_event_name":"UserPromptSubmit","prompt":"Ask a question"}"#.to_vec(),
            br#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?"}]}}"#.to_vec(),
        ]);
        assert_eq!(
            scratch.record().expect("waiting record").state,
            RunState::NeedsInput
        );
        replay(
            &scratch,
            "claude",
            &[format!(r#"{{"hook_event_name":"{event}","tool_name":"Bash"}}"#).into_bytes()],
        );
        assert_eq!(
            scratch.record().expect("unrelated tool").state,
            RunState::NeedsInput
        );
        replay(
            &scratch,
            "claude",
            &[
                format!(r#"{{"hook_event_name":"{event}","tool_name":"AskUserQuestion"}}"#)
                    .into_bytes(),
            ],
        );
        assert_eq!(
            scratch.record().expect("answered record").state,
            RunState::Running
        );
    }
}

/// An MCP server's request for input waits as a question in the server's
/// words, and its result, whatever the person chose, puts the turn back to
/// work until its stop.
#[test]
fn an_mcp_elicitation_waits_in_its_words_until_its_result() {
    for case in ["mcp-elicitation-form", "mcp-elicitation-url-dismissed"] {
        let scratch = Scratch::new(case);
        let payloads = dated_fixture_case("claude", "2026-10", case);
        let named = |name: &str| {
            payloads
                .iter()
                .position(|payload| {
                    serde_json::from_slice::<Value>(payload).expect("payload")["hook_event_name"]
                        == name
                })
                .expect("recorded event")
        };
        let (asked, answered) = (named("Elicitation"), named("ElicitationResult"));
        let message =
            serde_json::from_slice::<Value>(&payloads[asked]).expect("payload")["message"]
                .as_str()
                .expect("message")
                .to_owned();

        replay(&scratch, "claude", &payloads[..=asked]);
        let waiting = scratch.record().expect("waiting record");
        assert_eq!(waiting.state, RunState::NeedsInput, "{case}");
        assert_eq!(
            waiting.wait_kind,
            Some(limpid_agent_model::WaitKind::Question)
        );
        assert_eq!(waiting.detail.as_deref(), Some(message.as_str()));

        replay(&scratch, "claude", &payloads[asked + 1..=answered]);
        let answered = scratch.record().expect("answered record");
        assert_eq!(answered.state, RunState::Running, "{case}");
        assert_eq!(answered.wait_kind, None);

        replay(&scratch, "claude", &payloads[named("Stop")..=named("Stop")]);
        assert_eq!(scratch.record().expect("record").state, RunState::Finished);
    }
}

/// A background subagent's request for input comes after the turn that
/// launched it has stopped, and without `agent_id`: the finished run waits
/// on the person all the same.
#[test]
fn a_background_subagents_mcp_elicitation_waits_after_the_stop() {
    let scratch = Scratch::new("claude-elicitation-subagent");
    let payloads = dated_fixture_case("claude", "2026-10", "mcp-elicitation-background-subagent");
    replay(&scratch, "claude", &payloads[..5]);
    assert_eq!(
        scratch.record().expect("record").state,
        RunState::Finished,
        "the subagent's own tool leaves the run at its rest"
    );
    replay(&scratch, "claude", &payloads[5..6]);
    let waiting = scratch.record().expect("waiting record");
    assert_eq!(waiting.state, RunState::NeedsInput);
    assert_eq!(
        waiting.detail.as_deref(),
        Some("Pick a color for the probe")
    );
    replay(&scratch, "claude", &payloads[6..]);
    assert_eq!(scratch.record().expect("record").state, RunState::Finished);
}

/// A question declined with Esc sends no hook after the permission prompt;
/// the idle prompt a minute later reads the transcript, which shows the
/// call rejected and interrupted, and ends the wait and the turn with it.
#[test]
fn a_declined_claude_question_ends_the_turn_at_the_idle_prompt() {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures/claude/2026-10/ask-user-question-declined");
    let payloads = dated_fixture_case("claude", "2026-10", "ask-user-question-declined");
    let transcript = directory.join("0004-Notification.transcript.jsonl");
    // The recorded path names the recording machine's transcript; the
    // replay reads the one beside the payload.
    let mut idle: Value = serde_json::from_slice(&payloads[4]).expect("payload");
    idle["transcript_path"] = Value::from(transcript.display().to_string());
    let idle = serde_json::to_vec(&idle).expect("payload");
    let open: Value = serde_json::json!({
        "hook_event_name": "Notification",
        "notification_type": "idle_prompt",
    });
    let open = serde_json::to_vec(&open).expect("payload");

    let scratch = Scratch::new("claude-question-declined");
    let call = |payload: &[u8], now: &str| {
        let mut pairs = scratch.pairs("claude");
        pairs.push(("LIMPID_HOOK_INVOCATION_ID".to_owned(), new_call()));
        let env = HookEnv::from_pairs(pairs);
        let mut runtime = HookRuntime::new(&env, &NoSnapshots);
        now.clone_into(&mut runtime.now);
        assert_eq!(run_hook("claude", payload, &runtime), HookOutcome::Applied);
    };
    call(&payloads[0], "2026-10-01T12:00:00Z");
    call(&payloads[1], "2026-10-01T12:00:01Z");
    call(&payloads[2], "2026-10-01T12:00:05Z");
    call(&payloads[3], "2026-10-01T12:00:05Z");
    let waiting = scratch.record().expect("waiting record");
    assert_eq!(waiting.state, RunState::NeedsInput);
    // The question's call names its transcript, which the app reads while
    // the run waits, since the Esc that declines it sends no hook.
    let named: Value = serde_json::from_slice(&payloads[2]).expect("payload");
    assert_eq!(
        waiting.transcript_path.as_deref(),
        named["transcript_path"].as_str()
    );

    // An idle prompt with no transcript to read writes nothing, since the
    // question may still be open.
    call(&open, "2026-10-01T12:01:05Z");
    assert_eq!(
        scratch.record().expect("record"),
        waiting,
        "nothing written"
    );

    call(&idle, "2026-10-01T12:02:05Z");
    let record = scratch.record().expect("record");
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.run_started_at, None);
    assert_eq!(record.wait_kind, None);
    assert_eq!(record.transcript_path, None, "the path goes with the wait");
    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].phase, TurnPhase::Interrupted);
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
            .join(format!("{}{LOCK_FILE_SUFFIX}", run_record_file_name(RUN)))
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
        &fs::read(scratch.root.join("cwd").join(cwd_event_file_name(PANE))).expect("cwd event"),
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

/// Codex's memory agent runs in the same process after the person's turn
/// ends, with its own `session_id` and the memories directory under Codex's
/// home as `cwd`, and its `Stop` reaches no user hook. Its calls must not
/// become the pane's session, turn, or resume hint, nor take back that the
/// session holds a conversation: its `SessionStart(startup)` read as the
/// pane's would set `has_prompt` to `false`, and a relaunch would then
/// retire the person's conversation instead of resuming it.
#[test]
fn codex_memory_agent_hooks_leave_the_persons_session_alone() {
    let payloads = dated_fixture_case("codex", "2026-10", "memory-agent");
    let person_session = "00000000-0000-4000-8000-000000000001";
    // The runtime takes Codex's home from the agent's environment: the
    // variable when set, else the default under `HOME`.
    for home in [
        ("CODEX_HOME", "/Users/example/.codex"),
        ("HOME", "/Users/example"),
    ] {
        let scratch = Scratch::new("codex-memory-agent");
        let replay_with_home = |payload: &[u8]| {
            let mut pairs = scratch.pairs("codex");
            pairs.push((home.0.to_owned(), home.1.to_owned()));
            pairs.push(("LIMPID_HOOK_INVOCATION_ID".to_owned(), new_call()));
            let env = HookEnv::from_pairs(pairs);
            run_hook("codex", payload, &HookRuntime::new(&env, &NoSnapshots))
        };
        let (before_quit, quit) = payloads.split_at(payloads.len() - 1);
        for payload in before_quit {
            assert_eq!(replay_with_home(payload), HookOutcome::Applied);
        }
        // The person's turn finished and nothing began after it: the memory
        // agent's start, prompt, tools, and end changed no record.
        let record = scratch.record().expect("record");
        assert_eq!(record.state, RunState::Finished, "{}", home.0);
        assert_eq!(record.run_started_at, None);
        assert_eq!(record.last_hook_event.as_deref(), Some("turn_finished"));
        assert_eq!(record.session_id.as_deref(), Some(person_session));
        assert_eq!(record.has_prompt, Some(true), "{}", home.0);
        let hint = scratch.hint().expect("hint");
        assert_eq!(hint["sessionId"], person_session);
        assert_eq!(hint["cwd"], "/tmp/example");
        let turns = scratch.turns();
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].phase, TurnPhase::Finished);
        assert_eq!(turns[0].conversation.conversation_id, person_session);
        // The person's own `/quit` still ends the session.
        assert_eq!(replay_with_home(&quit[0]), HookOutcome::Applied);
        assert_eq!(scratch.record().expect("record").state, RunState::Unknown);
    }
}

/// Codex keeps a session's name in `session_index.jsonl` under its home,
/// apart from the payloads, and the runtime reads it beside each prompt and
/// stop. The first turn ended before Codex named the thread, so the run has
/// no name until the next prompt, which finds the one `/rename` gave.
#[test]
fn codex_takes_its_session_name_from_its_title_index() {
    let scratch = Scratch::new("codex-thread-name");
    let home = scratch.root.join("codex-home");
    fs::create_dir_all(&home).expect("home");
    let case = Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures/codex/2026-10/thread-name");
    // One call with `payload`, beside the index the case recorded at
    // `index_at`, or with no index at all.
    let call_with = |payload: &[u8], index_at: Option<&str>| {
        let index = home.join("session_index.jsonl");
        match index_at.map(|stem| fs::read(case.join(format!("{stem}.title-index.jsonl")))) {
            Some(Ok(bytes)) => fs::write(&index, bytes).expect("index"),
            _ => drop(fs::remove_file(&index)),
        }
        let mut pairs = scratch.pairs("codex");
        pairs.push(("CODEX_HOME".to_owned(), home.display().to_string()));
        pairs.push(("LIMPID_HOOK_INVOCATION_ID".to_owned(), new_call()));
        let env = HookEnv::from_pairs(pairs);
        assert_eq!(
            run_hook("codex", payload, &HookRuntime::new(&env, &NoSnapshots)),
            HookOutcome::Applied
        );
    };
    let payload = |stem: &str| fs::read(case.join(format!("{stem}.json"))).expect("payload");
    let call = |stem: &str| call_with(&payload(stem), Some(stem));
    let title = || scratch.record().expect("record").provider_session_title;
    for stem in ["0000-SessionStart", "0001-UserPromptSubmit", "0002-Stop"] {
        call(stem);
    }
    assert_eq!(title(), None);
    // Each turn's title as the run knew it when the turn was written.
    let titles = || {
        scratch
            .turns()
            .into_iter()
            .map(|turn| turn.conversation_title)
            .collect::<Vec<_>>()
    };
    call("0015-UserPromptSubmit");
    assert_eq!(title().as_deref(), Some("Fixture thread name"));
    // The turn begun before the index named the thread records no title;
    // the one begun at the prompt that read it records it at once, from
    // the run that prompt wrote, not the one before it.
    let named = [None, Some("Fixture thread name".to_owned())];
    assert_eq!(titles(), named, "at the prompt that read the name");
    call("0019-Stop");
    assert_eq!(titles(), named, "kept at its stop");
    // The session's end reads no index, and keeps the name without one.
    call_with(&payload("0022-SessionEnd"), None);
    assert_eq!(title().as_deref(), Some("Fixture thread name"));

    // A resume starts the session again, and a start replaces the titles:
    // the name a resumed session has is the one the index gives it.
    let mut start: Value = serde_json::from_slice(&payload("0000-SessionStart")).expect("start");
    start["source"] = Value::from("resume");
    let resume = serde_json::to_vec(&start).expect("resume");
    call_with(&resume, None);
    assert_eq!(title(), None);
    call_with(&resume, Some("0019-Stop"));
    assert_eq!(title().as_deref(), Some("Fixture thread name"));
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
        states.join(run_record_file_name(RUN)),
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
        .open(states.join(format!("{}{LOCK_FILE_SUFFIX}", run_record_file_name(RUN))))
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

#[test]
fn resent_event_is_applied_once() {
    let scratch = Scratch::new("turn-resent");
    let prompt = new_call();
    let stop = new_call();
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    // The shim retries a call with the id it minted for it.
    scratch.call(RUN, Some(&prompt), PROMPT);
    scratch.call(RUN, Some(&prompt), PROMPT);
    scratch.call(RUN, Some(&stop), STOP);
    scratch.call(RUN, Some(&stop), STOP);

    let turns = scratch.turns();
    assert_eq!(turns.len(), 1, "a retried prompt starts no second turn");
    let turn = &turns[0];
    assert_eq!(turn.phase, TurnPhase::Finished);
    assert_eq!(turn.applied_events.len(), 2);
    assert_eq!(turn.begin, SnapshotStatus::Disabled);
    assert_eq!(
        turn.changes,
        ChangeSummary::Unavailable {
            reason: "disabled".into()
        }
    );
    assert_eq!(turn.prompt_head.as_deref(), Some("add tests"));
    assert_eq!(
        scratch
            .record()
            .and_then(|record| record.current_turn_id)
            .as_deref(),
        Some(turn.turn_id.as_str())
    );
}

/// A Codex subagent inherits the parent's environment, so its hooks reach
/// the parent's run; its prompt is not the parent's turn.
#[test]
fn a_codex_subagents_prompt_leaves_the_parents_turn_current() {
    let scratch = Scratch::new("turn-codex-subagent");
    let codex = |payload: &str| {
        scratch.call_as("codex", RUN, Some(&new_call()), payload.as_bytes());
    };
    codex(r#"{"hook_event_name":"SessionStart","session_id":"p","source":"startup"}"#);
    codex(r#"{"hook_event_name":"UserPromptSubmit","session_id":"p","prompt":"fix it"}"#);
    let parent_turn = scratch.record().and_then(|record| record.current_turn_id);
    assert!(parent_turn.is_some(), "the parent's prompt began a turn");
    codex(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"c","prompt":"look around",
            "agent_id":"019a0000-0000-7000-8000-000000000001","agent_type":"explorer"}"#,
    );
    assert_eq!(
        scratch.record().and_then(|record| record.current_turn_id),
        parent_turn,
        "the subagent began no turn"
    );
    codex(r#"{"hook_event_name":"Stop","session_id":"p"}"#);

    let turns = scratch.turns();
    assert_eq!(turns.len(), 1, "only the parent's turn");
    assert_eq!(turns[0].phase, TurnPhase::Finished);
    assert_eq!(turns[0].prompt_head.as_deref(), Some("fix it"));
}

/// The Codex helper's watcher reports a limit for the rollout of the
/// session it watched; `/new` within its interval has moved the run on.
#[test]
fn a_codex_usage_limit_applies_only_to_the_session_it_watched() {
    let scratch = Scratch::new("codex-limit-session");
    let rollout = scratch.root.join("rollout.jsonl");
    fs::write(
        &rollout,
        r#"{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"event_msg","payload":{"type":"task_complete","error":{"codex_error_info":"usage_limit_exceeded"}}}
"#,
    )
    .expect("rollout");
    let codex = |payload: &str| {
        scratch.call_as("codex", RUN, Some(&new_call()), payload.as_bytes());
    };
    let report = serde_json::json!({
        "hook_event_name": "LimpidTurnFailed",
        "transcript_path": rollout,
        "session_id": "a",
        "limpid_failed_at": u64::MAX / 2,
    })
    .to_string();
    codex(r#"{"hook_event_name":"SessionStart","session_id":"a","source":"startup"}"#);
    codex(r#"{"hook_event_name":"UserPromptSubmit","session_id":"a","prompt":"first"}"#);
    // The person runs `/new` and sends the first prompt of the new
    // conversation.
    codex(r#"{"hook_event_name":"SessionStart","session_id":"b","source":"startup"}"#);
    codex(r#"{"hook_event_name":"UserPromptSubmit","session_id":"b","prompt":"second"}"#);
    codex(&report);
    let record = scratch.record().expect("record");
    assert_eq!(record.state, RunState::Running, "b goes on");
    assert_eq!(record.usage_limit, None);
    assert!(record.run_started_at.is_some());

    // Reported for the session the run is in, it ends that turn.
    let scratch = Scratch::new("codex-limit-same-session");
    let codex = |payload: &str| {
        scratch.call_as("codex", RUN, Some(&new_call()), payload.as_bytes());
    };
    codex(r#"{"hook_event_name":"SessionStart","session_id":"a","source":"startup"}"#);
    codex(r#"{"hook_event_name":"UserPromptSubmit","session_id":"a","prompt":"first"}"#);
    codex(&report);
    let record = scratch.record().expect("record");
    assert_eq!(record.state, RunState::Error);
    assert!(record.usage_limit.is_some());
}

/// Codex runs no hook when a turn fails for any reason, not only at its
/// usage limit. The watcher reports the failure, and the turn ends failed
/// with the kind its rollout names, as a hook would end it. The rollout is
/// taken from what Codex CLI 0.165.0 wrote for a model it does not have.
#[test]
fn a_failed_codex_turn_ends_with_the_kind_its_rollout_names() {
    let scratch = Scratch::new("codex-failed-turn");
    let rollout = scratch.root.join("rollout.jsonl");
    fs::write(
        &rollout,
        r#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":null,"error":{"message":"The 'no-such-model' model is not supported when using Codex with a ChatGPT account.","codex_error_info":"model_not_found"}}}
"#,
    )
    .expect("rollout");
    let codex = |payload: &str| {
        scratch.call_as("codex", RUN, Some(&new_call()), payload.as_bytes());
    };
    codex(r#"{"hook_event_name":"SessionStart","session_id":"a","source":"startup"}"#);
    codex(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"a","turn_id":"t1","prompt":"Say hello."}"#,
    );
    codex(
        &serde_json::json!({
            "hook_event_name": "LimpidTurnFailed",
            "transcript_path": rollout,
            "session_id": "a",
            "limpid_error_kind": "model_not_found",
            "limpid_failed_at": u64::MAX / 2,
        })
        .to_string(),
    );
    let record = scratch.record().expect("record");
    assert_eq!(record.state, RunState::Error);
    assert_eq!(record.detail.as_deref(), Some("model_not_found"));
    assert_eq!(record.usage_limit, None);
    assert_eq!(record.run_started_at, None);
    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].phase, TurnPhase::Failed);
}

/// The stop's reply names what came of the turn, kept as the first
/// paragraph on one line; a later end with no reply of its own leaves it.
/// The reply is taken from what Claude Code 2.1.312 sent for a turn that
/// left a shell running.
#[test]
fn a_turn_keeps_the_first_paragraph_of_its_reply() {
    let scratch = Scratch::new("turn-reply");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    scratch.call(
        RUN,
        Some(&new_call()),
        br#"{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"Lighthouses have guided sailors safely\nthrough dark and stormy nights.\n\n- one\n- two"}"#,
    );
    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(
        turns[0].reply_head.as_deref(),
        Some("Lighthouses have guided sailors safely through dark and stormy nights.")
    );

    // The idle prompt after the stop takes the end again, with no reply.
    scratch.call(
        RUN,
        Some(&new_call()),
        br#"{"hook_event_name":"Notification","session_id":"s1","notification_type":"idle_prompt"}"#,
    );
    assert_eq!(
        scratch.turns()[0].reply_head.as_deref(),
        Some("Lighthouses have guided sailors safely through dark and stormy nights.")
    );

    // A stop that sends no reply records none.
    scratch.call(RUN, Some(&new_call()), PROMPT);
    scratch.call(RUN, Some(&new_call()), STOP);
    let turns = scratch.turns();
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[1].reply_head, None);
}

#[test]
fn the_same_prompt_sent_twice_is_two_turns() {
    let scratch = Scratch::new("turn-twice");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    scratch.call(RUN, Some(&new_call()), PROMPT);

    let turns = scratch.turns();
    assert_eq!(
        turns
            .iter()
            .map(|turn| turn.display_number)
            .collect::<Vec<_>>(),
        vec![1, 2]
    );
    // The first was overtaken; it stays as it was rather than being guessed at.
    assert_eq!(turns[0].phase, TurnPhase::Started);
}

#[test]
fn display_number_continues_across_runs_of_one_conversation() {
    let scratch = Scratch::new("turn-runs");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    // The same session resumed as another run, as after a restore.
    scratch.call(OTHER_RUN, Some(&new_call()), SESSION_START);
    scratch.call(OTHER_RUN, Some(&new_call()), PROMPT);

    let turns = scratch.turns();
    assert_eq!(
        turns
            .iter()
            .map(|turn| turn.display_number)
            .collect::<Vec<_>>(),
        vec![1, 2]
    );
    assert_eq!(turns[1].run_id, OTHER_RUN);
    assert!(
        turns
            .iter()
            .all(|turn| turn.conversation.conversation_id == "s1")
    );
    assert!(turns.iter().all(|turn| !turn.conversation.is_fallback));
}

#[test]
fn display_number_is_never_reused_after_deletion() {
    let scratch = Scratch::new("turn-deleted");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    let first = scratch.turns().remove(0);
    fs::remove_file(
        scratch
            .root
            .join("states")
            .join(TURNS_DIRECTORY)
            .join(format!("{}.turn.json", first.turn_id)),
    )
    .expect("delete the turn");

    scratch.call(RUN, Some(&new_call()), PROMPT);

    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(
        turns[0].display_number, 2,
        "T1 still means the deleted turn"
    );
}

#[test]
fn a_call_without_an_id_records_no_turn() {
    let scratch = Scratch::new("turn-no-id");
    scratch.call(RUN, None, SESSION_START);
    assert_eq!(scratch.call(RUN, None, PROMPT), HookOutcome::Applied);

    assert!(scratch.turns().is_empty());
    assert!(scratch.log().contains("prompt without an id"));
    // The run itself is still recorded.
    assert_eq!(scratch.record().expect("record").state, RunState::Running);
}

#[test]
fn an_end_without_a_turn_is_recorded_as_incomplete() {
    let scratch = Scratch::new("turn-end-only");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), STOP);

    let turns = scratch.turns();
    assert_eq!(turns.len(), 1, "the end is not lost");
    assert_eq!(turns[0].phase, TurnPhase::Finished);
    assert_eq!(
        turns[0].changes,
        ChangeSummary::Unavailable {
            reason: "beginMissing".into()
        }
    );
    assert_eq!(turns[0].duration_seconds, None);
}

#[test]
fn a_failed_begin_leaves_no_turn_for_the_next_end_to_close() {
    let scratch = Scratch::new("turn-failed-begin");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    scratch.call(RUN, Some(&new_call()), STOP);
    let first = scratch.turns().remove(0);
    // The conversation's counter is unreadable, so the next prompt cannot
    // number a turn.
    let counter = scratch
        .root
        .join("states")
        .join(TURNS_DIRECTORY)
        .join(first.conversation.counter_file_name());
    let intact = fs::read(&counter).expect("counter");
    fs::write(&counter, b"not a counter").expect("break the counter");
    scratch.call(RUN, Some(&new_call()), PROMPT);
    fs::write(&counter, intact).expect("mend the counter");
    scratch.call(RUN, Some(&new_call()), STOP);

    let turns = scratch.turns();
    assert_eq!(turns[0].turn_id, first.turn_id);
    assert_eq!(
        turns[0].applied_events, first.applied_events,
        "the finished turn is not ended again by the next turn's stop"
    );
    assert_eq!(
        turns.last().map(|turn| turn.changes.clone()),
        Some(ChangeSummary::Unavailable {
            reason: "beginMissing".into()
        })
    );
    assert!(scratch.log().contains("read counter"));
}

#[test]
fn a_turn_a_newer_build_wrote_is_left_as_it_is() {
    let scratch = Scratch::new("turn-newer");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    let turn = scratch.turns().remove(0);
    let path = scratch
        .root
        .join("states")
        .join(TURNS_DIRECTORY)
        .join(format!("{}.turn.json", turn.turn_id));
    let mut value: Value = serde_json::from_slice(&fs::read(&path).expect("read")).expect("json");
    value["schemaVersion"] = Value::from(2);
    value["fromTheFuture"] = Value::from(true);
    let newer = serde_json::to_vec(&value).expect("encode");
    fs::write(&path, &newer).expect("write");

    scratch.call(RUN, Some(&new_call()), STOP);

    assert_eq!(fs::read(&path).expect("read"), newer, "not a byte changed");
    assert!(scratch.log().contains("a newer build wrote"));
}

// Numbers are handed out under the run record's lock, and off Unix the
// hook opens no lock file (`records::open_lock_file`).
#[cfg(unix)]
#[test]
fn concurrent_prompts_of_one_conversation_get_distinct_numbers() {
    let scratch = std::sync::Arc::new(Scratch::new("turn-concurrent"));
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(OTHER_RUN, Some(&new_call()), SESSION_START);
    let threads: Vec<_> = [RUN, OTHER_RUN]
        .into_iter()
        .map(|run| {
            let scratch = std::sync::Arc::clone(&scratch);
            std::thread::spawn(move || {
                for _ in 0..5 {
                    scratch.call(run, Some(&new_call()), PROMPT);
                }
            })
        })
        .collect();
    for thread in threads {
        thread.join().expect("thread");
    }

    let numbers: Vec<u32> = scratch
        .turns()
        .iter()
        .map(|turn| turn.display_number)
        .collect();
    assert_eq!(
        numbers,
        (1..=10).collect::<Vec<_>>(),
        "no number twice, none skipped"
    );
}

/// Rewrites the current turn's file with `edit`, and returns the run's
/// current turn id and the bytes now on disk.
fn rewrite_current_turn(scratch: &Scratch, edit: impl FnOnce(&mut Value)) -> (String, Vec<u8>) {
    let turn = scratch.turns().remove(0);
    let path = scratch
        .root
        .join("states")
        .join(TURNS_DIRECTORY)
        .join(format!("{}.turn.json", turn.turn_id));
    let mut value: Value = serde_json::from_slice(&fs::read(&path).expect("read")).expect("json");
    edit(&mut value);
    let bytes = serde_json::to_vec(&value).expect("encode");
    fs::write(&path, &bytes).expect("write");
    (turn.turn_id, bytes)
}

#[test]
fn an_unreadable_current_turn_is_neither_ended_nor_replaced() {
    for (name, edit) in [
        (
            "newer shape",
            Box::new(|value: &mut Value| {
                value["schemaVersion"] = Value::from(9);
                value["phase"] = Value::from(42);
            }) as Box<dyn FnOnce(&mut Value)>,
        ),
        (
            "another turn's id",
            Box::new(|value: &mut Value| {
                value["turnId"] = Value::from("00000000-0000-4000-8000-000000000000");
            }),
        ),
    ] {
        let scratch = Scratch::new("turn-unreadable");
        scratch.call(RUN, Some(&new_call()), SESSION_START);
        scratch.call(RUN, Some(&new_call()), PROMPT);
        let (turn_id, bytes) = rewrite_current_turn(&scratch, edit);

        scratch.call(RUN, Some(&new_call()), STOP);

        let directory = scratch.root.join("states").join(TURNS_DIRECTORY);
        let records = fs::read_dir(&directory)
            .expect("turns")
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".turn.json"))
            .count();
        assert_eq!(records, 1, "{name}: no end-only record in its place");
        assert_eq!(
            fs::read(directory.join(format!("{turn_id}.turn.json"))).expect("read"),
            bytes,
            "{name}: not a byte changed"
        );
        assert_eq!(
            scratch.record().and_then(|record| record.current_turn_id),
            Some(turn_id),
            "{name}: the run still names it"
        );
    }
}

#[test]
fn an_end_only_turn_ended_again_still_has_no_duration() {
    // A stop hook held the stop that wrote the end-only record; the time
    // until the real stop is not how long a turn took.
    let scratch = Scratch::new("turn-end-only-again");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    scratch.call(RUN, Some(&new_call()), STOP);
    scratch.call(RUN, Some(&new_call()), STOP);
    scratch.call(
        RUN,
        Some(&new_call()),
        br#"{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":true}"#,
    );

    let turns = scratch.turns();
    assert_eq!(turns.len(), 2);
    let end_only = &turns[1];
    assert_eq!(end_only.applied_events.len(), 2, "ended, then ended again");
    assert_eq!(end_only.duration_seconds, None);
    assert_eq!(
        end_only.changes,
        ChangeSummary::Unavailable {
            reason: "beginMissing".into()
        }
    );
}

fn bash(hook: &str, command: &str, tail: &str) -> Vec<u8> {
    format!(
        r#"{{"hook_event_name":"{hook}","session_id":"s1","tool_name":"Bash",
           "tool_use_id":"toolu_{}","tool_input":{{"command":"{command}"}}{tail}}}"#,
        uuid::Uuid::new_v4().simple()
    )
    .into_bytes()
}

#[test]
fn a_turn_keeps_its_last_check() {
    let scratch = Scratch::new("turn-check");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    scratch.call(
        RUN,
        Some(&new_call()),
        &bash("PostToolUse", "cargo test", ""),
    );
    scratch.call(
        RUN,
        Some(&new_call()),
        &bash(
            "PostToolUseFailure",
            "make test-swift FILTER=TurnTests",
            r#","error":"Exit code 2\nfailed","is_interrupt":false"#,
        ),
    );
    // Not a check: it leaves the last one as it was.
    scratch.call(
        RUN,
        Some(&new_call()),
        &bash("PostToolUse", "git status", ""),
    );

    let turn = scratch.turns().remove(0);
    let check = turn.last_check.expect("a check");
    assert_eq!(check.command, "make test-swift FILTER=TurnTests");
    assert_eq!(check.exit_code, Some(2));
    assert!(check.is_filtered);
    // And the run itself was not moved by the commands.
    assert_eq!(scratch.record().expect("record").state, RunState::Running);
}

#[test]
fn a_command_after_the_turn_ended_is_not_its_check() {
    let scratch = Scratch::new("turn-check-after");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    scratch.call(RUN, Some(&new_call()), STOP);
    scratch.call(
        RUN,
        Some(&new_call()),
        &bash("PostToolUse", "cargo test", ""),
    );

    assert_eq!(scratch.turns().remove(0).last_check, None);
    assert_eq!(
        scratch.record().expect("record").state,
        RunState::Finished,
        "a finished run stays finished"
    );
}

#[test]
fn a_project_names_its_own_checks() {
    let scratch = Scratch::new("turn-check-project");
    let project = scratch.root.join("project");
    fs::create_dir_all(&project).expect("project");
    // The routing file sits beside the state directories.
    fs::write(
        scratch.root.join("worktree-routing.json"),
        serde_json::json!({
            "schemaVersion": 1,
            "projects": [{
                "root": "/elsewhere",
                "worktrees": [project],
                "placement": {"kind": "siblingPrefixed"},
                "bootstrap": [],
                "routing": {},
                "checks": ["just check"],
            }],
        })
        .to_string(),
    )
    .expect("routing");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    let cwd = format!(r#","cwd":{}"#, serde_json::json!(project));
    scratch.call(
        RUN,
        Some(&new_call()),
        &bash("PostToolUse", "cargo test", &cwd),
    );
    assert_eq!(
        scratch.turns().remove(0).last_check,
        None,
        "the project replaced the defaults"
    );
    scratch.call(
        RUN,
        Some(&new_call()),
        &bash("PostToolUse", "just check", &cwd),
    );
    assert_eq!(
        scratch
            .turns()
            .remove(0)
            .last_check
            .map(|check| check.command),
        Some("just check".to_owned())
    );
}

#[test]
fn a_check_piped_on_has_no_exit_of_its_own() {
    let scratch = Scratch::new("turn-check-piped");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    // The call succeeded because `tail` did; the tests may have failed.
    scratch.call(
        RUN,
        Some(&new_call()),
        &bash("PostToolUse", "cargo test 2>&1 | tail -20", ""),
    );

    let check = scratch.turns().remove(0).last_check.expect("a check");
    assert_eq!(check.exit_code, None);
    assert!(!check.is_filtered, "the redirection is not an argument");
}

#[test]
fn a_check_that_may_not_have_run_has_no_exit_of_its_own() {
    for command in [
        "if false; then make test; fi",
        "while false; do make test; done",
    ] {
        let scratch = Scratch::new("turn-check-conditional");
        scratch.call(RUN, Some(&new_call()), SESSION_START);
        scratch.call(RUN, Some(&new_call()), PROMPT);
        // The call exited 0 without running the tests.
        scratch.call(RUN, Some(&new_call()), &bash("PostToolUse", command, ""));

        let check = scratch.turns().remove(0).last_check.expect("a check");
        assert_eq!(check.exit_code, None, "{command}");
    }
}

fn routing_with(scratch: &Scratch, projects: &str) {
    fs::write(scratch.root.join("worktree-routing.json"), projects).expect("routing");
}

#[test]
fn the_defaults_apply_where_no_project_names_checks() {
    for routing in [
        // A project without its own list.
        r#"{"schemaVersion":1,"projects":[{"root":"/tmp","placement":{"kind":"siblingPrefixed"},"bootstrap":[],"routing":{}}]}"#,
        // A version this build does not know: not guessed at.
        r#"{"schemaVersion":2,"projects":[{"root":"/tmp","checks":["just check"]}]}"#,
    ] {
        let scratch = Scratch::new("turn-check-defaults");
        routing_with(&scratch, routing);
        scratch.call(RUN, Some(&new_call()), SESSION_START);
        scratch.call(RUN, Some(&new_call()), PROMPT);
        scratch.call(
            RUN,
            Some(&new_call()),
            &bash("PostToolUse", "cargo test", r#","cwd":"/tmp""#),
        );
        assert!(scratch.turns().remove(0).last_check.is_some(), "{routing}");
    }
}

#[test]
fn a_nested_project_keeps_its_own_checks() {
    let scratch = Scratch::new("turn-check-nested");
    routing_with(
        &scratch,
        r#"{"schemaVersion":1,"projects":[
            {"root":"/work","checks":["cargo test"]},
            {"root":"/work/app","checks":["just check"]}]}"#,
    );
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    scratch.call(
        RUN,
        Some(&new_call()),
        &bash("PostToolUse", "cargo test", r#","cwd":"/work/app/src""#),
    );
    assert_eq!(
        scratch.turns().remove(0).last_check,
        None,
        "the inner project's list applies"
    );
}

#[test]
fn a_turn_keeps_its_checks_in_order_and_counts_them() {
    let scratch = Scratch::new("turn-checks");
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(RUN, Some(&new_call()), PROMPT);
    for _ in 0..2 {
        scratch.call(
            RUN,
            Some(&new_call()),
            &bash(
                "PostToolUseFailure",
                "cargo test",
                r#","error":"Exit code 101\nfailed","is_interrupt":false"#,
            ),
        );
    }
    scratch.call(
        RUN,
        Some(&new_call()),
        &bash("PostToolUse", "cargo test", ""),
    );

    let turn = scratch.turns().remove(0);
    let exits: Vec<_> = turn.checks.iter().map(|mark| mark.exit_code).collect();
    assert_eq!(exits, vec![Some(101), Some(101), Some(0)]);
    assert_eq!((turn.check_count, turn.failure_count), (3, 2));
    assert_eq!(turn.last_check.expect("a check").exit_code, Some(0));
}

/// One line of a Claude transcript, in the shape Claude Code writes it.
fn transcript_line(line: &str) -> String {
    format!("{line}\n")
}

/// `path` as it goes between a JSON string's quotes, so that a Windows
/// path's backslashes reach the hook as backslashes.
fn json_text(path: &Path) -> String {
    let quoted = serde_json::to_string(&path.display().to_string()).expect("path");
    quoted[1..quoted.len() - 1].to_owned()
}

/// A title Claude first writes during a turn reaches that turn at its
/// stop: the record ends with the name the run learned from the same
/// event, not the one the run had before it.
#[test]
fn a_claude_turn_records_the_title_its_stop_reads() {
    let scratch = Scratch::new("turn-title-claude");
    let session = scratch.root.join("session.jsonl");
    let prompt =
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":"add tests"}}"#;
    fs::write(&session, transcript_line(prompt)).expect("transcript");
    let path = json_text(&session);
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"add tests","prompt_id":"p1","transcript_path":"{path}"}}"#
        )
        .as_bytes(),
    );
    assert_eq!(scratch.turns()[0].conversation_title, None, "no title yet");

    let titled = [
        prompt,
        r#"{"type":"ai-title","aiTitle":"Add the missing tests","sessionId":"s1"}"#,
    ];
    fs::write(&session, titled.map(transcript_line).concat()).expect("transcript");
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(r#"{{"hook_event_name":"Stop","session_id":"s1","transcript_path":"{path}"}}"#)
            .as_bytes(),
    );

    assert_eq!(
        scratch.turns()[0].conversation_title.as_deref(),
        Some("Add the missing tests")
    );
}

#[test]
fn a_claude_turn_reads_what_it_and_its_subagents_used_at_its_stop() {
    let scratch = Scratch::new("turn-usage-claude");
    let session = scratch.root.join("session.jsonl");
    let subagents = scratch.root.join("session").join("subagents");
    fs::create_dir_all(&subagents).expect("subagents");
    let lines = [
        r#"{"type":"user","isSidechain":false,"promptId":"p0","message":{"content":"earlier"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"r0","message":{"usage":{"input_tokens":50,"output_tokens":50}}}"#,
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":"add tests"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"r1","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":10}}}"#,
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":[{"type":"tool_result"}]},"toolUseResult":{"status":"completed","agentId":"a1"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"r2","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":20,"cache_read_input_tokens":1100,"output_tokens":5}}}"#,
    ];
    fs::write(&session, lines.map(transcript_line).concat()).expect("transcript");
    fs::write(
        subagents.join("agent-a1.jsonl"),
        transcript_line(
            r#"{"type":"assistant","isSidechain":true,"requestId":"s1","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":7,"cache_read_input_tokens":0,"output_tokens":3}}}"#,
        ),
    )
    .expect("subagent");
    let path = json_text(&session);
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"add tests","prompt_id":"p1","transcript_path":"{path}"}}"#
        )
        .as_bytes(),
    );
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(r#"{{"hook_event_name":"Stop","session_id":"s1","transcript_path":"{path}"}}"#)
            .as_bytes(),
    );

    let turn = scratch.turns().remove(0);
    assert_eq!(turn.provider_turn_id.as_deref(), Some("p1"));
    assert_eq!(
        turn.usage,
        Some(TurnUsage {
            input_tokens: 5,
            cache_write_tokens: 127,
            cache_read_tokens: 2100,
            output_tokens: 18,
            is_partial: false,
        })
    );
}

/// Codex runs `Interrupt` when the person stops a turn with Esc, and has
/// written what the turn used by then (`fixtures/codex/2026-10/
/// interrupted-turn`, with its rollout reduced in `fixtures/transcripts/
/// codex-0.164.0-interrupted-turn.jsonl`). The turn stopped while its
/// command ran had made two requests; the one stopped while Codex was still
/// reasoning had made none. The command never finished, so no check counts.
#[test]
fn an_interrupted_codex_turn_reads_what_it_used_from_the_rollout() {
    let scratch = Scratch::new("codex-interrupted-turn");
    let rollout = scratch.root.join("rollout.jsonl");
    fs::write(
        &rollout,
        include_bytes!("../../fixtures/transcripts/codex-0.164.0-interrupted-turn.jsonl"),
    )
    .expect("rollout");
    for payload in dated_fixture_case("codex", "2026-10", "interrupted-turn") {
        let mut payload: Value = serde_json::from_slice(&payload).expect("payload");
        payload["transcript_path"] = Value::from(rollout.display().to_string());
        let payload = serde_json::to_vec(&payload).expect("payload");
        assert_eq!(
            scratch.call_as("codex", RUN, Some(&new_call()), &payload),
            HookOutcome::Applied
        );
    }

    let turns = scratch.turns();
    assert_eq!(turns.len(), 2);
    assert!(
        turns
            .iter()
            .all(|turn| turn.phase == TurnPhase::Interrupted)
    );
    assert_eq!(
        turns[0].usage,
        Some(TurnUsage {
            input_tokens: 25_514,
            cache_write_tokens: 0,
            cache_read_tokens: 25_216,
            output_tokens: 97,
            is_partial: false,
        })
    );
    assert_eq!(turns[0].check_count, 0);
    assert_eq!(turns[1].usage, None);
}

/// Codex begins the turns of a `/goal` itself, with no `UserPromptSubmit`
/// (`fixtures/codex/2026-10/goal`, with its rollout reduced in
/// `fixtures/transcripts/codex-0.165.0-goal.jsonl`). Each turn begins at its
/// first hook, before its tool runs, and shows the goal's objective; before,
/// each was an end with no beginning, and showed nothing it changed.
#[test]
fn a_codex_goal_begins_each_of_its_turns_at_the_turns_first_hook() {
    let scratch = Scratch::new("codex-goal");
    let rollout = scratch.root.join("rollout.jsonl");
    fs::write(
        &rollout,
        include_bytes!("../../fixtures/transcripts/codex-0.165.0-goal.jsonl"),
    )
    .expect("rollout");
    let payloads: Vec<Vec<u8>> = dated_fixture_case("codex", "2026-10", "goal")
        .into_iter()
        .map(|payload| {
            let mut payload: Value = serde_json::from_slice(&payload).expect("payload");
            payload["transcript_path"] = Value::from(rollout.display().to_string());
            serde_json::to_vec(&payload).expect("payload")
        })
        .collect();
    let calls: Vec<String> = payloads.iter().map(|_| new_call()).collect();
    for (index, (payload, call)) in payloads.iter().zip(&calls).enumerate() {
        assert_eq!(
            scratch.call_as("codex", RUN, Some(call), payload),
            HookOutcome::Applied
        );
        // The first tool of each turn finds the run at work in a turn.
        if index == 1 || index == 4 {
            assert!(
                scratch
                    .record()
                    .is_some_and(|record| record.run_started_at.is_some()),
                "payload {index} began a turn"
            );
            // The shim retries a call with the id it minted for it; the turn
            // the call began is not begun again.
            scratch.call_as("codex", RUN, Some(call), payload);
        }
    }
    let turns = scratch.turns();
    assert_eq!(turns.len(), 2);
    let objective = "Create a.txt containing \"a\", then b.txt containing \"b\". Create only a.txt in your first turn and end that turn; create b.txt in the next turn, then mark the goal complete.";
    for turn in &turns {
        assert_eq!(turn.phase, TurnPhase::Finished);
        assert_eq!(
            turn.prompt_kind.as_ref().map(RecordedPromptKind::kind),
            Some(PromptKind::Goal)
        );
        assert_eq!(
            turn.prompt_head.as_deref(),
            Some(objective.chars().take(80).collect::<String>().as_str())
        );
        // A begin was taken (the runtime takes none here), not missed.
        assert_eq!(turn.begin, SnapshotStatus::Disabled);
        assert!(turn.usage.is_some(), "what the turn used is read");
    }
    assert_eq!(
        turns[0].provider_turn_id.as_deref(),
        Some("00000000-0000-4000-8000-000000000003")
    );
    assert_eq!(
        turns[1].provider_turn_id.as_deref(),
        Some("00000000-0000-4000-8000-000000000013")
    );
    let record = scratch.record().expect("record");
    assert_eq!(record.state, RunState::Finished);
    assert_eq!(record.first_prompt.as_deref(), Some(objective));
}

/// A tool call of the turn the run last had, after that turn's `Stop`, is
/// that turn's late work; it begins no turn of its own.
#[test]
fn a_codex_tool_after_its_turns_stop_begins_no_turn() {
    let scratch = Scratch::new("codex-late-tool");
    let codex = |payload: &str| {
        scratch.call_as("codex", RUN, Some(&new_call()), payload.as_bytes());
    };
    codex(r#"{"hook_event_name":"SessionStart","session_id":"p","source":"startup"}"#);
    codex(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"p","turn_id":"t1","prompt":"fix it"}"#,
    );
    codex(r#"{"hook_event_name":"Stop","session_id":"p","turn_id":"t1"}"#);
    codex(
        r#"{"hook_event_name":"PreToolUse","session_id":"p","turn_id":"t1","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
    );

    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].prompt_head.as_deref(), Some("fix it"));
    assert!(
        scratch
            .record()
            .is_some_and(|record| record.run_started_at.is_none()),
        "the run is in no turn"
    );
}

/// A subagent the turn spawned can still work after the parent's `Stop`;
/// its tool names the subagent's own turn, which is no turn of the pane's.
#[test]
fn a_codex_subagents_tool_after_the_parents_stop_begins_no_turn() {
    let scratch = Scratch::new("codex-subagent-after-stop");
    let codex = |payload: &str| {
        scratch.call_as("codex", RUN, Some(&new_call()), payload.as_bytes());
    };
    codex(r#"{"hook_event_name":"SessionStart","session_id":"p","source":"startup"}"#);
    codex(
        r#"{"hook_event_name":"UserPromptSubmit","session_id":"p","turn_id":"t1","prompt":"fix it"}"#,
    );
    codex(r#"{"hook_event_name":"Stop","session_id":"p","turn_id":"t1"}"#);
    codex(
        r#"{"hook_event_name":"PreToolUse","session_id":"c","turn_id":"t2","agent_id":"019a0000-0000-7000-8000-000000000001","agent_type":"explorer","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
    );

    assert_eq!(scratch.turns().len(), 1);
    assert!(
        scratch
            .record()
            .is_some_and(|record| record.run_started_at.is_none()),
        "the run is in no turn"
    );
}

/// A goal turn that ran no hooked tool is first seen at its `Stop`. It
/// changed whatever it changed before that hook, so its begin is missing,
/// not taken then and shown changing nothing; it still shows the goal.
#[test]
fn a_codex_goal_turn_first_seen_at_its_stop_shows_its_begin_missing() {
    let scratch = Scratch::new("codex-goal-stop-first");
    let rollout = scratch.root.join("rollout.jsonl");
    fs::write(
        &rollout,
        include_bytes!("../../fixtures/transcripts/codex-0.165.0-goal.jsonl"),
    )
    .expect("rollout");
    let path = json_text(&rollout);
    let codex = |payload: String| {
        scratch.call_as("codex", RUN, Some(&new_call()), payload.as_bytes());
    };
    codex(format!(
        r#"{{"hook_event_name":"SessionStart","session_id":"p","source":"startup","transcript_path":"{path}"}}"#
    ));
    codex(format!(
        r#"{{"hook_event_name":"Stop","session_id":"p","turn_id":"00000000-0000-4000-8000-000000000003","transcript_path":"{path}"}}"#
    ));

    let turns = scratch.turns();
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].phase, TurnPhase::Finished);
    assert_eq!(
        turns[0].prompt_kind.as_ref().map(RecordedPromptKind::kind),
        Some(PromptKind::Goal)
    );
    assert_eq!(turns[0].begin, SnapshotStatus::Pending);
    assert_eq!(
        turns[0].changes,
        ChangeSummary::Unavailable {
            reason: "beginMissing".into()
        }
    );
}

/// Codex records a subagent's work in a rollout of its own and names only
/// its thread in the parent's (`fixtures/codex/2026-10/subagent`, with
/// both rollouts reduced in `fixtures/transcripts/codex-0.165.0-subagent-
/// *.jsonl`). The parent's `Stop` finds the subagent's rollout under the
/// sessions folder by its thread and adds what it used for this turn.
#[test]
fn a_codex_turn_counts_its_subagents_from_their_own_rollouts() {
    // Replays the case with the subagent's rollout in place or gone, and
    // returns what the turn used.
    let replay_with_child = |has_child: bool| {
        let scratch = Scratch::new("codex-subagent");
        let day = scratch.root.join("codex-home/sessions/2026/10/28");
        fs::create_dir_all(&day).expect("day");
        let parent =
            day.join("rollout-2026-10-28T14-55-55-00000000-0000-4000-8000-000000000001.jsonl");
        let child =
            day.join("rollout-2026-10-28T14-56-11-00000000-0000-4000-8000-000000000021.jsonl");
        fs::write(
            &parent,
            include_bytes!("../../fixtures/transcripts/codex-0.165.0-subagent-parent.jsonl"),
        )
        .expect("parent");
        if has_child {
            fs::write(
                &child,
                include_bytes!("../../fixtures/transcripts/codex-0.165.0-subagent-child.jsonl"),
            )
            .expect("child");
        }
        for payload in dated_fixture_case("codex", "2026-10", "subagent") {
            let mut payload: Value = serde_json::from_slice(&payload).expect("payload");
            // The subagent's own tool calls name its rollout, the rest the
            // parent's.
            let rollout = if payload.get("agent_id").is_some() {
                &child
            } else {
                &parent
            };
            payload["transcript_path"] = Value::from(rollout.display().to_string());
            let payload = serde_json::to_vec(&payload).expect("payload");
            assert_eq!(
                scratch.call_as("codex", RUN, Some(&new_call()), &payload),
                HookOutcome::Applied
            );
        }
        let turns = scratch.turns();
        assert_eq!(turns.len(), 1);
        turns[0].usage.expect("usage")
    };

    // The parent's three requests, then the subagent's two.
    let parent = TurnUsage {
        input_tokens: 76_369 - 57_472,
        cache_write_tokens: 0,
        cache_read_tokens: 57_472,
        output_tokens: 429,
        is_partial: false,
    };
    let child = TurnUsage {
        input_tokens: 24_878 + (24_972 - 24_704),
        cache_write_tokens: 0,
        cache_read_tokens: 24_704,
        output_tokens: 68 + 18,
        is_partial: false,
    };
    assert_eq!(replay_with_child(true), parent.plus(child));
    // A subagent whose rollout is not found leaves the count short.
    assert_eq!(
        replay_with_child(false),
        TurnUsage {
            is_partial: true,
            ..parent
        }
    );
}

#[test]
fn a_codex_turn_reads_its_usage_and_checks_from_the_rollout_at_its_stop() {
    let scratch = Scratch::new("turn-usage-codex");
    let rollout = scratch.root.join("rollout.jsonl");
    let command = |script: &str, status: &str, exit: i32| {
        format!(
            r#"{{"type":"event_msg","payload":{{"type":"item_completed","turn_id":"t1","item":{{"type":"CommandExecution","command":["/bin/zsh","-lc","{script}"],"status":"{status}","exit_code":{exit}}}}}}}"#
        )
    };
    let lines = [
        command("cargo test", "failed", 101),
        command("ls", "completed", 0),
        command("cargo test", "completed", 0),
        r#"{"type":"token_usage_record","payload":{"turn_id":"t1","turn_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"cache_write_input_tokens":0,"output_tokens":40}}}"#.to_owned(),
    ];
    fs::write(&rollout, lines.map(|line| line + "\n").concat()).expect("rollout");
    let path = json_text(&rollout);
    let codex = |payload: String| {
        scratch.call_as("codex", RUN, Some(&new_call()), payload.as_bytes());
    };
    codex(
        r#"{"hook_event_name":"SessionStart","session_id":"s1","source":"startup","cwd":"/tmp"}"#
            .to_owned(),
    );
    codex(format!(
        r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"fix it","turn_id":"t1","cwd":"/tmp","transcript_path":"{path}"}}"#
    ));
    codex(format!(
        r#"{{"hook_event_name":"Stop","session_id":"s1","turn_id":"t1","stop_hook_active":false,"cwd":"/tmp","transcript_path":"{path}"}}"#
    ));

    let turn = scratch.turns().remove(0);
    assert_eq!(turn.provider_turn_id.as_deref(), Some("t1"));
    assert_eq!(
        turn.usage,
        Some(TurnUsage {
            input_tokens: 100,
            cache_write_tokens: 0,
            cache_read_tokens: 900,
            output_tokens: 40,
            is_partial: false,
        })
    );
    let exits: Vec<_> = turn.checks.iter().map(|mark| mark.exit_code).collect();
    assert_eq!(exits, vec![Some(101), Some(0)]);
    assert_eq!((turn.check_count, turn.failure_count), (2, 1));
    assert_eq!(turn.last_check.expect("a check").command, "cargo test");
}

#[test]
fn a_subagent_transcript_past_the_limit_leaves_the_usage_partial() {
    let scratch = Scratch::new("turn-usage-large-subagent");
    let session = scratch.root.join("session.jsonl");
    let subagents = scratch.root.join("session").join("subagents");
    fs::create_dir_all(&subagents).expect("subagents");
    let lines = [
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":"explore"}}"#,
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":[{"type":"tool_result"}]},"toolUseResult":{"status":"completed","agentId":"a1"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"r1","message":{"usage":{"input_tokens":2,"output_tokens":5}}}"#,
    ];
    fs::write(&session, lines.map(transcript_line).concat()).expect("transcript");
    // Padding the size of the hook's limit, then the subagent's last
    // request: the tail holds the request, but not the start of the file.
    let mut large = vec![b' '; limpid_agent_hook::MAX_TRANSCRIPT_BYTES];
    large.extend(transcript_line(
        r#"{"type":"assistant","isSidechain":true,"requestId":"s1","message":{"usage":{"input_tokens":1,"output_tokens":3}}}"#,
    ).bytes());
    fs::write(subagents.join("agent-a1.jsonl"), large).expect("subagent");
    let path = json_text(&session);
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"explore","prompt_id":"p1","transcript_path":"{path}"}}"#
        )
        .as_bytes(),
    );
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(r#"{{"hook_event_name":"Stop","session_id":"s1","transcript_path":"{path}"}}"#)
            .as_bytes(),
    );

    assert_eq!(
        scratch.turns().remove(0).usage,
        Some(TurnUsage {
            input_tokens: 3,
            cache_write_tokens: 0,
            cache_read_tokens: 0,
            output_tokens: 8,
            is_partial: true,
        })
    );
}

#[test]
fn a_stop_nobody_prompted_reads_the_turn_from_the_last_prompt() {
    let scratch = Scratch::new("turn-usage-end-only");
    let session = scratch.root.join("session.jsonl");
    let lines = [
        r#"{"type":"user","isSidechain":false,"promptId":"p0","message":{"content":"earlier"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"r0","message":{"usage":{"input_tokens":50,"output_tokens":50}}}"#,
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":"go on"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"r1","message":{"usage":{"input_tokens":2,"output_tokens":5}}}"#,
    ];
    fs::write(&session, lines.map(transcript_line).concat()).expect("transcript");
    let path = json_text(&session);
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(r#"{{"hook_event_name":"Stop","session_id":"s1","transcript_path":"{path}"}}"#)
            .as_bytes(),
    );

    let turn = scratch.turns().remove(0);
    assert_eq!(turn.provider_turn_id, None);
    assert_eq!(
        turn.usage,
        Some(TurnUsage {
            input_tokens: 2,
            cache_write_tokens: 0,
            cache_read_tokens: 0,
            output_tokens: 5,
            is_partial: false,
        })
    );
}

#[test]
fn a_second_stop_of_an_ended_turn_does_not_count_it_again() {
    let scratch = Scratch::new("turn-usage-second-stop");
    let session = scratch.root.join("session.jsonl");
    let lines = [
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":"go"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"r1","message":{"usage":{"input_tokens":2,"output_tokens":5}}}"#,
    ];
    fs::write(&session, lines.map(transcript_line).concat()).expect("transcript");
    let path = json_text(&session);
    let stop =
        format!(r#"{{"hook_event_name":"Stop","session_id":"s1","transcript_path":"{path}"}}"#);
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"go","prompt_id":"p1","transcript_path":"{path}"}}"#
        )
        .as_bytes(),
    );
    scratch.call(RUN, Some(&new_call()), stop.as_bytes());
    // Background work ends with a stop nobody prompted; the transcript's
    // last prompt is still the ended turn's.
    scratch.call(RUN, Some(&new_call()), stop.as_bytes());

    let turns = scratch.turns();
    assert_eq!(turns.len(), 2, "the second stop is an end-only record");
    let usages: Vec<_> = turns.iter().map(|turn| turn.usage).collect();
    assert!(
        usages.contains(&None),
        "the end-only record counts nothing: {usages:?}"
    );
    assert_eq!(usages.iter().flatten().count(), 1);
}

#[test]
fn a_stop_waits_for_the_last_response_to_reach_the_transcript() {
    let scratch = Scratch::new("turn-usage-late-response");
    let session = scratch.root.join("session.jsonl");
    let lines = [
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":"go"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"r1","message":{"usage":{"input_tokens":2,"output_tokens":5}}}"#,
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":[{"type":"tool_result"}]}}"#,
    ];
    fs::write(&session, lines.map(transcript_line).concat()).expect("transcript");
    let path = json_text(&session);
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"go","prompt_id":"p1","transcript_path":"{path}"}}"#
        )
        .as_bytes(),
    );
    // The last response lands a moment after Stop begins, as an interactive
    // Claude Code writes it.
    let late = session.clone();
    let writer = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(200));
        let mut file = fs::OpenOptions::new()
            .append(true)
            .open(late)
            .expect("open");
        std::io::Write::write_all(
            &mut file,
            transcript_line(
                r#"{"type":"assistant","isSidechain":false,"requestId":"r2","message":{"usage":{"input_tokens":3,"output_tokens":7}}}"#,
            )
            .as_bytes(),
        )
        .expect("append");
    });
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(r#"{{"hook_event_name":"Stop","session_id":"s1","transcript_path":"{path}"}}"#)
            .as_bytes(),
    );
    writer.join().expect("writer");

    assert_eq!(
        scratch.turns().remove(0).usage,
        Some(TurnUsage {
            input_tokens: 5,
            cache_write_tokens: 0,
            cache_read_tokens: 0,
            output_tokens: 12,
            is_partial: false,
        })
    );
}

#[test]
fn a_stop_waits_for_a_turns_only_response() {
    let scratch = Scratch::new("turn-usage-only-response");
    let session = scratch.root.join("session.jsonl");
    fs::write(
        &session,
        transcript_line(
            r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":"what is 2 + 2?"}}"#,
        ),
    )
    .expect("transcript");
    let path = json_text(&session);
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"what is 2 + 2?","prompt_id":"p1","transcript_path":"{path}"}}"#
        )
        .as_bytes(),
    );
    let late = session.clone();
    let writer = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(200));
        let mut file = fs::OpenOptions::new()
            .append(true)
            .open(late)
            .expect("open");
        std::io::Write::write_all(
            &mut file,
            transcript_line(
                r#"{"type":"assistant","isSidechain":false,"requestId":"r1","message":{"usage":{"input_tokens":3,"output_tokens":7}}}"#,
            )
            .as_bytes(),
        )
        .expect("append");
    });
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(r#"{{"hook_event_name":"Stop","session_id":"s1","transcript_path":"{path}"}}"#)
            .as_bytes(),
    );
    writer.join().expect("writer");

    assert_eq!(
        scratch.turns().remove(0).usage,
        Some(TurnUsage {
            input_tokens: 3,
            cache_write_tokens: 0,
            cache_read_tokens: 0,
            output_tokens: 7,
            is_partial: false,
        })
    );
}

#[test]
fn a_continued_stop_of_an_end_only_record_does_not_count_the_turn_before() {
    let scratch = Scratch::new("turn-usage-end-only-continued");
    let session = scratch.root.join("session.jsonl");
    let lines = [
        r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":"go"}}"#,
        r#"{"type":"assistant","isSidechain":false,"requestId":"r1","message":{"usage":{"input_tokens":2,"output_tokens":5}}}"#,
    ];
    fs::write(&session, lines.map(transcript_line).concat()).expect("transcript");
    let path = json_text(&session);
    let stop = |active: bool| {
        format!(
            r#"{{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":{active},"transcript_path":"{path}"}}"#
        )
    };
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"go","prompt_id":"p1","transcript_path":"{path}"}}"#
        )
        .as_bytes(),
    );
    scratch.call(RUN, Some(&new_call()), stop(false).as_bytes());
    // A stop nobody prompted, then the stop a hook's feedback continued.
    scratch.call(RUN, Some(&new_call()), stop(false).as_bytes());
    scratch.call(RUN, Some(&new_call()), stop(true).as_bytes());

    let usages: Vec<_> = scratch.turns().iter().map(|turn| turn.usage).collect();
    assert_eq!(usages.iter().flatten().count(), 1, "{usages:?}");
}

#[test]
fn a_response_that_never_comes_leaves_the_turn_without_usage() {
    let scratch = Scratch::new("turn-usage-no-response");
    let session = scratch.root.join("session.jsonl");
    fs::write(
        &session,
        transcript_line(
            r#"{"type":"user","isSidechain":false,"promptId":"p1","message":{"content":"hi"}}"#,
        ),
    )
    .expect("transcript");
    let path = json_text(&session);
    scratch.call(RUN, Some(&new_call()), SESSION_START);
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hi","prompt_id":"p1","transcript_path":"{path}"}}"#
        )
        .as_bytes(),
    );
    let started = std::time::Instant::now();
    scratch.call(
        RUN,
        Some(&new_call()),
        format!(r#"{{"hook_event_name":"Stop","session_id":"s1","transcript_path":"{path}"}}"#)
            .as_bytes(),
    );
    assert!(
        started.elapsed() < std::time::Duration::from_secs(3),
        "the wait is bounded"
    );
    assert_eq!(scratch.turns().remove(0).usage, None);
}
