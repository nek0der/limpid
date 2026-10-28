//! Maps Codex CLI hook payloads to neutral events.
//!
//! The mapping mirrors what `codex-shim/limpid-hook` did and is checked
//! against the recorded fixtures under `rust/fixtures/codex`. The payloads
//! carry no session title; the runtime adds the one Codex keeps apart from
//! them (see `titles`).
//!
//! Not every hook call is the person's agent. Codex's memory feature runs a
//! "Memory Writing Agent" in the same process after a session starts, and
//! that thread runs the user's `SessionStart`, `UserPromptSubmit`, and tool
//! hooks with its own `session_id` and no marker (`agent_id` and
//! `agent_type` are set only for thread-spawned subagents), while its `Stop`
//! goes to no user hook at all (recorded in `fixtures/codex/2026-10/
//! memory-agent`). Taken as the pane's agent it would begin a turn no
//! `Stop` ends, retitle the tab with its prompt, and leave the resume hint
//! naming its thread. What tells it apart is where it runs: Codex sets the
//! consolidation agent's `cwd` to the memories directory under its own home
//! (`codex-rs/memories/write/src/phase2.rs`), so a payload from there is
//! the provider's internal work and yields no event (`is_internal_agent`).
//!
//! A subagent the person's agent spawns is marked, and only its tool calls
//! and permission requests count as the pane's (`is_subagents_own`).

use crate::failure::{RolloutFailure, USAGE_LIMIT_KIND, rollout_failure};
use crate::json::string;
use limpid_agent_model::{
    AgentEvent, HookContext, MAX_HOOK_INPUT_BYTES, NormalizeError, RawHookInput, RunRecord,
    SessionSource, UsageLimit, format_utc_seconds, parse_object, parse_utc_seconds,
    transcript_path_for_events,
};
use serde_json::{Map, Value};
use std::borrow::Cow;
use std::path::Path;
use std::time::{Duration, UNIX_EPOCH};

/// The variable that moves Codex's configuration directory from `~/.codex`.
pub(crate) const HOME_DIRECTORY_VARIABLE: &str = "CODEX_HOME";

/// The tool Codex asks the person a question with and waits on until it is
/// answered, interrupted, or (outside Plan mode) resolved by the TUI's own
/// countdown; its `PostToolUse` or `Interrupt` ends the wait. Codex's other
/// question tool, `request_user_input_async`, returns at once and the turn
/// goes on, so it is an ordinary tool call (recorded in `fixtures/codex/
/// 2026-10/request-user-input-async`). No hook can answer either: a
/// `PreToolUse` hook may only block the call or rewrite its input.
const QUESTION_TOOL: &str = "request_user_input";

/// The hooks that end a turn. Each names the turn (`turn_id`) and the rollout
/// that holds what it used, which Codex has written by the time either runs
/// (`Interrupt`'s recorded in `fixtures/codex/2026-10/interrupted-turn`).
pub(crate) const TURN_END_EVENTS: [&str; 2] = ["Stop", "Interrupt"];

pub(crate) fn normalize(
    input: RawHookInput<'_>,
    context: &HookContext,
) -> Result<Vec<AgentEvent>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let event_name = string(&object, "hook_event_name")
        .unwrap_or("unknown")
        .to_owned();
    if is_internal_agent(&object, context) || is_subagents_own(&object, &event_name) {
        return Ok(Vec::new());
    }
    let cwd = string(&object, "cwd").map(str::to_owned);
    let event = match event_name.as_str() {
        "SessionStart" => AgentEvent::SessionStarted {
            compact: false,
            // Codex spells `source` as Claude does; whether the session has
            // a conversation behind it is what a relaunch reads from it.
            source: SessionSource::parse(string(&object, "source")),
            session_id: string(&object, "session_id").map(str::to_owned),
            session_title: None,
            cwd,
        },
        "SessionEnd" => AgentEvent::SessionEnded {
            reason: string(&object, "reason").map(str::to_owned),
            session_id: string(&object, "session_id").map(str::to_owned),
        },
        "UserPromptSubmit" => AgentEvent::PromptSubmitted {
            prompt: string(&object, "prompt").unwrap_or_default().to_owned(),
            titles: None,
            cwd,
        },
        "PreToolUse" => pre_tool_use(&object),
        "PostToolUse" => AgentEvent::ToolFinished {
            tool: string(&object, "tool_name").map(str::to_owned),
        },
        "PermissionRequest" => AgentEvent::ApprovalRequested {
            detail: string(&object, "message").map(str::to_owned),
        },
        "PreCompact" => AgentEvent::Compacting {
            context_tokens: object.get("current_token_count").and_then(Value::as_u64),
        },
        "PostCompact" => AgentEvent::CompactionFinished,
        "Interrupt" => AgentEvent::Interrupted,
        // Not Codex's own event: the helper's watcher reports it when the
        // rollout shows a turn failed, since Codex runs no hook then
        // (`crate::failure`). What the rollout says of the failure is read
        // here; for a usage limit, the reset the watcher read from Codex's
        // message (in Codex's time zone) times it when the rate limits did
        // not.
        LIMPID_TURN_FAILED_EVENT => {
            let failure = match input.transcript {
                // The rollout says what the turn ended in. A turn that did
                // not fail (one the person began meanwhile) is no failure at
                // all.
                Some(rollout) => match rollout_failure(rollout) {
                    Some(failure) => failure,
                    None => {
                        return Ok(vec![AgentEvent::Extension {
                            name: event_name.clone(),
                            payload: Value::Object(object),
                        }]);
                    }
                },
                // Unread, the kind the watcher read stands; a limit has no
                // time of its own.
                None => watched_failure(&object),
            };
            let message_reset = object
                .get(MESSAGE_RESET_KEY)
                .and_then(Value::as_u64)
                .and_then(|seconds| UNIX_EPOCH.checked_add(Duration::from_secs(seconds)))
                .map(format_utc_seconds);
            AgentEvent::Failed {
                error: failure.error,
                usage_limit: failure.usage_limit.map(|mut limit| {
                    if limit.resets_at.is_none() {
                        limit.resets_at = message_reset;
                    }
                    limit
                }),
            }
        }
        // Codex's Stop schema carries no error today; the branch stays for a
        // future schema that does, matching the receiver it replaces.
        "Stop" => match string(&object, "error_type") {
            Some(error) if !error.is_empty() => AgentEvent::Failed {
                error: error.to_owned(),
                usage_limit: None,
            },
            _ => AgentEvent::TurnFinished {
                continues_after_stop_hook: object
                    .get("stop_hook_active")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                titles: None,
                cache: None,
            },
        },
        _ => AgentEvent::Extension {
            name: event_name.clone(),
            payload: Value::Object(object),
        },
    };
    Ok(vec![event])
}

/// The event the helper's watcher reports for a turn the rollout shows
/// failed (see the arm in `normalize`).
pub(crate) const LIMPID_TURN_FAILED_EVENT: &str = "LimpidTurnFailed";
/// This key holds the kind of failure the watcher read (Codex's
/// `codex_error_info`), for a report whose rollout cannot be read again.
const ERROR_KIND_KEY: &str = "limpid_error_kind";
/// For a usage limit, the watcher's reading of Codex's message, in Unix
/// seconds.
const MESSAGE_RESET_KEY: &str = "limpid_message_resets_at";
/// This key names the session whose rollout the watcher reads, from the
/// `SessionStart` it began on.
const WATCHED_SESSION_KEY: &str = "session_id";
/// This key holds when the rollout says the turn failed, in Unix seconds.
const FAILED_AT_KEY: &str = "limpid_failed_at";

/// The failure the watcher read, for a report whose rollout could not be
/// read again: its kind, and a usage limit with no time when that is the
/// kind.
fn watched_failure(object: &Map<String, Value>) -> RolloutFailure {
    let error = string(object, ERROR_KIND_KEY)
        .filter(|kind| !kind.is_empty())
        .unwrap_or("error")
        .to_owned();
    let usage_limit = (error == USAGE_LIMIT_KIND).then(UsageLimit::default);
    RolloutFailure { error, usage_limit }
}

/// Returns whether the watcher's report is about the run as `record` shows it
/// now. The watcher reads every ten seconds and the hook runtime prepares the
/// turn's end before it takes the record lock, so by the time the report is
/// applied the person may have started another conversation (`/new`) or the
/// next prompt in this one; applied there, the old failure would put the new
/// work in error and end it. So the report applies only to the session it
/// watched, and only while the run is still in a turn that began no later
/// than the failure ended it. Codex's own hooks are always current.
pub(crate) fn applies_to(input: RawHookInput<'_>, record: Option<&RunRecord>) -> bool {
    let Ok(object) = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES) else {
        return true;
    };
    if string(&object, "hook_event_name") != Some(LIMPID_TURN_FAILED_EVENT) {
        return true;
    }
    let Some(record) = record else {
        return false;
    };
    if let (Some(watched), Some(current)) = (
        string(&object, WATCHED_SESSION_KEY),
        record.session_id.as_deref(),
    ) && watched != current
    {
        return false;
    }
    // A run in no turn has no turn for the failure to have ended: a new
    // session clears the start, and so does every other end.
    let Some(started) = record.run_started_at.as_deref().and_then(parse_utc_seconds) else {
        return false;
    };
    // Both are whole seconds, and a request that fails can end its turn in
    // the second it began, so a failure in the start's own second counts.
    // Nothing tells a turn the person began later in that same second from
    // the one that failed, so that turn would count too.
    object
        .get(FAILED_AT_KEY)
        .and_then(Value::as_u64)
        .is_none_or(|failed| started <= failed)
}

/// The watcher's event reads the rollout for the failure, and the events that
/// end a turn for what the turn used and the commands it ran (`tokens`).
pub(crate) fn transcript_path(input: RawHookInput<'_>) -> Result<Option<String>, NormalizeError> {
    let path = transcript_path_for_events(input, &TURN_END_EVENTS)?;
    if path.is_some() {
        return Ok(path);
    }
    transcript_path_for_events(input, &[LIMPID_TURN_FAILED_EVENT])
}

/// Whether the payload comes from Codex's own memory agent rather than the
/// person's thread: its `cwd` is one of the descriptor's
/// `internal_agent_directories` under the provider's home
/// (`ProviderDescriptor::is_internal_agent_directory`, which compares by
/// components). A home the environment did not name, or named relative,
/// leaves nothing to compare against, and the payload counts as the
/// person's: the shim makes a relative `CODEX_HOME` absolute before Codex
/// starts, so a hook Limpid installed never sees one.
///
/// Codex canonicalizes a `CODEX_HOME` the environment sets and leaves the
/// default `~/.codex` as written, so the `cwd` it reports may be the real
/// path of a home the environment names through a symlink (or `/tmp` for
/// `/private/tmp`). Both sides are resolved the same way when they exist on
/// disk, and compared as written when they do not (the fixtures' paths).
fn is_internal_agent(object: &Map<String, Value>, context: &HookContext) -> bool {
    let (Some(home), Some(cwd)) = (context.provider_home.as_deref(), string(object, "cwd")) else {
        return false;
    };
    crate::descriptor::descriptor()
        .is_internal_agent_directory(&resolved(home), &resolved(Path::new(cwd)))
}

/// Returns whether the payload is a subagent's own event, which is not the
/// pane's. Codex sets `agent_id` only on the hooks of a thread the agent
/// spawned (`spawn_agent`). The child inherits the parent's environment, so
/// its hooks reach the parent's run record: its prompt would begin a turn
/// that replaces the parent's (which the parent's `Stop` then ends, leaving
/// the parent's own turn with no end), and its session, compaction, and
/// interrupt would be taken for the parent's. Its tools still run, and its
/// permission requests still wait on the person, in the pane's process, so
/// those stay the pane's.
fn is_subagents_own(object: &Map<String, Value>, event_name: &str) -> bool {
    string(object, "agent_id").is_some_and(|id| !id.is_empty())
        && !matches!(
            event_name,
            "PreToolUse" | "PostToolUse" | "PermissionRequest"
        )
}

/// `path` with its symlinks resolved when it exists, else as written. Only
/// an absolute path is resolved: a relative one would be taken against the
/// hook's own working directory, which for the memory agent is the memories
/// directory itself.
fn resolved(path: &Path) -> Cow<'_, Path> {
    if !path.is_absolute() {
        return Cow::Borrowed(path);
    }
    std::fs::canonicalize(path).map_or(Cow::Borrowed(path), Cow::Owned)
}

fn pre_tool_use(object: &Map<String, Value>) -> AgentEvent {
    let tool = string(object, "tool_name").unwrap_or_default().to_owned();
    if tool == QUESTION_TOOL {
        return AgentEvent::WaitingForInput {
            detail: question_text(object),
        };
    }
    // The concrete argument over the bare tool name, as the Claude adapter
    // words it: a permission request that follows takes its words from this
    // event, and every summary of the wait (the session row, the Needs
    // Attention row) names what the tool runs rather than the tool.
    let argument = object
        .get("tool_input")
        .and_then(Value::as_object)
        .and_then(|input| input.get("command").or_else(|| input.get("file_path")))
        .and_then(argument_text)
        .filter(|argument| !argument.is_empty());
    let detail = match argument {
        Some(argument) => format!("{tool}: {argument}"),
        None => tool.clone(),
    };
    AgentEvent::ToolStarted {
        detail: Some(detail),
        tool,
    }
}

/// The first question's text, which the attention card shows. Any further
/// questions of the call stay in the terminal, as do the options. A payload
/// not of the recorded shape has none, and the wait's kind already says it
/// is a question.
fn question_text(object: &Map<String, Value>) -> Option<String> {
    object
        .get("tool_input")
        .and_then(|input| input.get("questions"))
        .and_then(|questions| questions.get(0))
        .and_then(|question| question.get("question"))
        .and_then(Value::as_str)
        .filter(|question| !question.trim().is_empty())
        .map(str::to_owned)
}

/// A tool's argument as one line: the string it is, or an argv array
/// (`["bash", "-lc", "ls"]`) joined with spaces, as a shell would show it.
fn argument_text(value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Array(words) => {
            let words: Vec<&str> = words.iter().filter_map(Value::as_str).collect();
            (!words.is_empty()).then(|| words.join(" "))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_id_uses_invocation_id_for_every_codex_event() {
        use limpid_agent_model::{HookContext, ProviderAdapter};
        // `turn_id` is per turn, not per hook call, so it is never the id.
        let payload = r#"{"hook_event_name":"PermissionRequest","turn_id":"turn-1"}"#;
        let id = |invocation| {
            crate::CodexAdapter
                .event_id(
                    RawHookInput {
                        bytes: payload.as_bytes(),
                        transcript: None,
                    },
                    &HookContext {
                        invocation_id: invocation,
                        ..HookContext::fixture()
                    },
                )
                .expect("an object")
                .map(|id| id.as_str().to_owned())
        };
        assert_eq!(
            id(Some(uuid::Uuid::from_u128(9))).as_deref(),
            Some("codex:invocation:00000000-0000-0000-0000-000000000009")
        );
        assert_eq!(id(None), None);
    }

    fn events(payload: &str) -> Vec<AgentEvent> {
        events_under(None, payload)
    }

    fn events_under(home: Option<&str>, payload: &str) -> Vec<AgentEvent> {
        let context = HookContext {
            provider_home: home.map(std::path::PathBuf::from),
            ..HookContext::fixture()
        };
        normalize(
            RawHookInput {
                bytes: payload.as_bytes(),
                transcript: None,
            },
            &context,
        )
        .expect("normalizes")
    }

    /// The payloads Codex's memory agent sends, as recorded: its own
    /// `session_id`, no transcript, no subagent marker, and the memories
    /// directory under Codex's home as `cwd`.
    fn memory_agent_payloads(cwd: &str) -> [String; 4] {
        [
            format!(
                r#"{{"hook_event_name":"SessionStart","session_id":"m","transcript_path":null,"cwd":"{cwd}","source":"startup"}}"#
            ),
            format!(
                r###"{{"hook_event_name":"UserPromptSubmit","session_id":"m","turn_id":"t","transcript_path":null,"cwd":"{cwd}","prompt":"## Memory Writing Agent: Phase 2 (Consolidation)"}}"###
            ),
            format!(
                r#"{{"hook_event_name":"PreToolUse","session_id":"m","turn_id":"t","transcript_path":null,"cwd":"{cwd}","tool_name":"Bash","tool_input":{{"command":"pwd"}},"tool_use_id":"exec-1"}}"#
            ),
            format!(
                r#"{{"hook_event_name":"SessionEnd","session_id":"m","transcript_path":null,"cwd":"{cwd}","reason":"other"}}"#
            ),
        ]
    }

    /// The memory agent's hooks, run in a memories directory under Codex's
    /// home, are not the pane's events; the person's thread is, wherever it
    /// runs. Which paths are under the home is `is_internal_agent_directory`'s
    /// rule, tested with it; here, that Codex declares both of its memories
    /// directories and reads them under the home it is given.
    #[test]
    fn only_the_memory_agents_hooks_are_kept_from_the_pane() {
        let home = Some("/Users/example/.codex");
        for (home, cwd, is_memory_agent) in [
            (home, "/Users/example/.codex/memories", true),
            (home, "/Users/example/.codex/memories_v2/skills", true),
            (home, "/Users/example/work/.codex/memories", false),
            // Without a home there is nothing to compare against, and the
            // payload is the person's: the runtime always names one when
            // the environment has a `HOME`, so this is the conservative side
            // of a missing environment.
            (None, "/Users/example/.codex/memories", false),
        ] {
            let expected = usize::from(!is_memory_agent);
            for payload in memory_agent_payloads(cwd) {
                assert_eq!(
                    events_under(home, &payload).len(),
                    expected,
                    "{home:?}, {cwd}: {payload}"
                );
            }
        }
    }

    /// Codex canonicalizes a set `CODEX_HOME`, so the `cwd` it reports is
    /// the real path even when the environment names the home through a
    /// symlink; the default home is not canonicalized, so the opposite
    /// shape (a real home, a `cwd` through a link) is covered as well.
    #[cfg(unix)]
    #[test]
    fn a_home_named_through_a_symlink_still_finds_the_memory_agent() {
        let scratch_dir = tempfile::tempdir().expect("scratch");
        let scratch = scratch_dir.path().to_path_buf();
        let real_home = scratch.join("real").join("codex");
        std::fs::create_dir_all(real_home.join("memories")).expect("memories directory");
        let linked_home = scratch.join("codex-link");
        std::os::unix::fs::symlink(&real_home, &linked_home).expect("symlink");
        let real_memories = std::fs::canonicalize(real_home.join("memories"))
            .expect("canonical memories")
            .display()
            .to_string();
        let linked_memories = linked_home.join("memories").display().to_string();

        for (home, cwd) in [
            (linked_home.display().to_string(), real_memories.clone()),
            (real_home.display().to_string(), linked_memories.clone()),
            (linked_home.display().to_string(), linked_memories.clone()),
        ] {
            for payload in memory_agent_payloads(&cwd) {
                assert_eq!(
                    events_under(Some(&home), &payload),
                    Vec::new(),
                    "home {home}, cwd {cwd}: {payload}"
                );
            }
        }
        // A sibling of the home, reached through the same link prefix, is
        // still the person's.
        let other = scratch.join("real").join("other").join("memories");
        std::fs::create_dir_all(&other).expect("other directory");
        for payload in memory_agent_payloads(&other.display().to_string()) {
            assert_eq!(
                events_under(Some(&linked_home.display().to_string()), &payload).len(),
                1,
                "{payload}"
            );
        }
    }

    /// Codex resolves a relative `CODEX_HOME` against the directory it
    /// starts in, which the hook cannot know: it runs in the session's
    /// `cwd`, and for the memory agent that is the memories directory. So
    /// the shim makes the value absolute before Codex starts, the way Codex
    /// would, and a home that reaches the hook relative is compared with
    /// nothing.
    #[test]
    fn a_relative_home_made_absolute_by_the_shim_finds_the_memory_agent() {
        // What the shim exports for `CODEX_HOME=.codex-work` started in
        // `/Users/example/project` when the directory does not exist.
        let home = Some("/Users/example/project/./.codex-work");
        for payload in memory_agent_payloads("/Users/example/project/.codex-work/memories") {
            assert_eq!(events_under(home, &payload), Vec::new(), "{payload}");
        }
        // Left relative, it names no directory, and the payload is the
        // person's rather than a guess at which project it was relative to.
        for payload in memory_agent_payloads("/Users/example/project/.codex-work/memories") {
            assert_eq!(
                events_under(Some(".codex-work"), &payload).len(),
                1,
                "{payload}"
            );
        }
    }

    /// A subagent's hooks carry `agent_id` and `agent_type` (Codex 0.163.0,
    /// `hooks/src/events/user_prompt_submit.rs`). Its prompt, session,
    /// compaction, and interrupt are its own and leave the parent's turn
    /// alone; its tools and permission requests are work in the pane.
    #[test]
    fn a_subagent_neither_begins_nor_ends_the_parents_turn() {
        let marker = r#""agent_id":"019a0000-0000-7000-8000-000000000001","agent_type":"explorer""#;
        for own in [
            format!(r#"{{"hook_event_name":"SessionStart","session_id":"c",{marker}}}"#),
            format!(r#"{{"hook_event_name":"SessionEnd","session_id":"c",{marker}}}"#),
            format!(r#"{{"hook_event_name":"UserPromptSubmit","prompt":"look",{marker}}}"#),
            format!(r#"{{"hook_event_name":"Stop",{marker}}}"#),
            format!(r#"{{"hook_event_name":"PreCompact",{marker}}}"#),
            format!(r#"{{"hook_event_name":"PostCompact",{marker}}}"#),
            format!(r#"{{"hook_event_name":"Interrupt",{marker}}}"#),
        ] {
            assert_eq!(events(&own), Vec::new(), "{own}");
        }
        assert_eq!(
            events(&format!(
                r#"{{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{{"command":"ls"}},{marker}}}"#
            )),
            vec![AgentEvent::ToolStarted {
                tool: "Bash".into(),
                detail: Some("Bash: ls".into())
            }]
        );
        assert!(matches!(
            events(&format!(
                r#"{{"hook_event_name":"PermissionRequest","message":"run ls",{marker}}}"#
            ))
            .as_slice(),
            [AgentEvent::ApprovalRequested { .. }]
        ));
        // The parent's own prompt, with no marker or an empty one, is a turn.
        for parent in [
            r#"{"hook_event_name":"UserPromptSubmit","prompt":"fix it"}"#,
            r#"{"hook_event_name":"UserPromptSubmit","prompt":"fix it","agent_id":""}"#,
        ] {
            assert!(
                matches!(
                    events(parent).as_slice(),
                    [AgentEvent::PromptSubmitted { .. }]
                ),
                "{parent}"
            );
        }
    }

    #[test]
    fn the_watchers_report_of_a_usage_limit_is_read_from_the_rollout() {
        let rollout = br#"{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1791352800}}}}
{"type":"event_msg","payload":{"type":"task_complete","error":{"message":"Try again at 10:29 AM.","codex_error_info":"usage_limit_exceeded"}}}"#;
        let payload =
            br#"{"hook_event_name":"LimpidTurnFailed","transcript_path":"/tmp/rollout.jsonl"}"#;
        let input = RawHookInput {
            bytes: payload,
            transcript: Some(rollout),
        };
        assert_eq!(
            normalize(input, &HookContext::fixture()).unwrap(),
            vec![AgentEvent::Failed {
                error: "Try again at 10:29 AM.".into(),
                usage_limit: Some(limpid_agent_model::UsageLimit {
                    resets_at: Some("2026-10-07T06:00:00Z".into()),
                    window: Some("five_hour".into()),
                }),
            }]
        );
        assert_eq!(
            transcript_path(input).unwrap().as_deref(),
            Some("/tmp/rollout.jsonl")
        );
        // Without the rollout the limit still stands, timed by the message.
        assert_eq!(
            events(
                r#"{"hook_event_name":"LimpidTurnFailed","limpid_error_kind":"usage_limit_exceeded","limpid_message_resets_at":1791352800}"#
            ),
            vec![AgentEvent::Failed {
                error: "usage_limit_exceeded".into(),
                usage_limit: Some(limpid_agent_model::UsageLimit {
                    resets_at: Some("2026-10-07T06:00:00Z".into()),
                    window: None,
                }),
            }]
        );
    }

    #[test]
    fn the_watchers_report_of_any_other_failure_names_its_kind() {
        // Taken from what Codex CLI 0.165.0 wrote for a model it does not have.
        let rollout = br#"{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":null,"error":{"message":"The 'no-such-model' model is not supported when using Codex with a ChatGPT account.","codex_error_info":"model_not_found"}}}"#;
        let payload =
            br#"{"hook_event_name":"LimpidTurnFailed","transcript_path":"/tmp/rollout.jsonl"}"#;
        assert_eq!(
            normalize(
                RawHookInput {
                    bytes: payload,
                    transcript: Some(rollout),
                },
                &HookContext::fixture()
            )
            .unwrap(),
            vec![AgentEvent::Failed {
                error: "model_not_found".into(),
                usage_limit: None,
            }]
        );
        // Without the rollout the watcher's word stands.
        assert_eq!(
            events(
                r#"{"hook_event_name":"LimpidTurnFailed","limpid_error_kind":"server_overloaded"}"#
            ),
            vec![AgentEvent::Failed {
                error: "server_overloaded".into(),
                usage_limit: None,
            }]
        );
        assert_eq!(
            events(r#"{"hook_event_name":"LimpidTurnFailed"}"#),
            vec![AgentEvent::Failed {
                error: "error".into(),
                usage_limit: None,
            }]
        );
    }

    #[test]
    fn a_report_applies_only_to_the_session_and_turn_it_observed() {
        let record = |session: &str, started: Option<&str>| {
            let started = started.map_or(String::new(), |started| {
                format!(r#","runStartedAt":"{started}""#)
            });
            RunRecord::decode(
                format!(
                    r#"{{"schemaVersion":3,"paneId":"p","state":"running","updatedAt":"2026-10-07T06:00:00Z","sessionId":"{session}"{started}}}"#
                )
                .as_bytes(),
            )
            .expect("record")
        };
        // The turn failed at 2026-10-07T06:00:00Z.
        let report = |session: &str| {
            format!(
                r#"{{"hook_event_name":"LimpidTurnFailed","session_id":"{session}","limpid_failed_at":1791352800}}"#
            )
        };
        let applies = |payload: &str, record: Option<&RunRecord>| {
            applies_to(
                RawHookInput {
                    bytes: payload.as_bytes(),
                    transcript: None,
                },
                record,
            )
        };
        let in_turn = record("a", Some("2026-10-07T05:59:00Z"));
        assert!(applies(&report("a"), Some(&in_turn)));
        assert!(
            applies(
                &report("a"),
                Some(&record("a", Some("2026-10-07T06:00:00Z")))
            ),
            "a turn that failed in the second it began"
        );
        assert!(
            !applies(&report("b"), Some(&in_turn)),
            "another conversation"
        );
        assert!(
            !applies(
                &report("a"),
                Some(&record("a", Some("2026-10-07T06:00:01Z")))
            ),
            "the next turn"
        );
        assert!(
            !applies(&report("a"), Some(&record("a", None))),
            "no turn at all"
        );
        assert!(!applies(&report("a"), None));
        // Codex's own hooks are always about the run as it is.
        assert!(applies(r#"{"hook_event_name":"Stop"}"#, None));
    }

    #[test]
    fn a_report_for_a_turn_that_did_not_fail_is_no_failure() {
        // The person began another turn before the watcher read the line.
        let rollout = br#"{"type":"event_msg","payload":{"type":"task_complete","error":{"codex_error_info":"usage_limit_exceeded"}}}
{"type":"event_msg","payload":{"type":"task_started"}}"#;
        let payload =
            br#"{"hook_event_name":"LimpidTurnFailed","transcript_path":"/tmp/rollout.jsonl"}"#;
        let events = normalize(
            RawHookInput {
                bytes: payload,
                transcript: Some(rollout),
            },
            &HookContext::fixture(),
        )
        .unwrap();
        assert!(matches!(events.as_slice(), [AgentEvent::Extension { .. }]));
    }

    #[test]
    fn the_messages_reset_times_a_limit_the_rate_limits_did_not() {
        let rollout = br#"{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"event_msg","payload":{"type":"task_complete","error":{"message":"Try again at 10:29 AM.","codex_error_info":"usage_limit_exceeded"}}}"#;
        let payload =
            br#"{"hook_event_name":"LimpidTurnFailed","limpid_message_resets_at":1791352800}"#;
        let events = normalize(
            RawHookInput {
                bytes: payload,
                transcript: Some(rollout),
            },
            &HookContext::fixture(),
        )
        .unwrap();
        assert_eq!(
            events,
            vec![AgentEvent::Failed {
                error: "Try again at 10:29 AM.".into(),
                usage_limit: Some(limpid_agent_model::UsageLimit {
                    resets_at: Some("2026-10-07T06:00:00Z".into()),
                    window: None,
                }),
            }]
        );
    }

    #[test]
    fn only_a_stop_among_codex_events_reads_the_rollout() {
        let path = |event: &str| {
            let payload = format!(
                r#"{{"hook_event_name":"{event}","transcript_path":"/tmp/rollout.jsonl"}}"#
            );
            transcript_path(RawHookInput {
                bytes: payload.as_bytes(),
                transcript: None,
            })
            .unwrap()
        };
        assert_eq!(path("Stop"), Some("/tmp/rollout.jsonl".into()));
        for event in [
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "SessionStart",
        ] {
            assert_eq!(path(event), None, "{event}");
        }
    }

    #[test]
    fn a_stop_after_a_stop_hook_says_so() {
        assert_eq!(
            events(r#"{"hook_event_name":"Stop","stop_hook_active":true}"#),
            vec![AgentEvent::TurnFinished {
                continues_after_stop_hook: true,
                titles: None,
                cache: None
            }]
        );
    }

    #[test]
    fn stop_with_an_error_type_fails_and_without_one_finishes() {
        assert_eq!(
            events(r#"{"hook_event_name":"Stop","error_type":"timeout"}"#),
            vec![AgentEvent::Failed {
                error: "timeout".into(),
                usage_limit: None,
            }]
        );
        assert_eq!(
            events(r#"{"hook_event_name":"Stop","error_type":""}"#),
            vec![AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: None,
                cache: None
            }]
        );
    }

    #[test]
    fn a_question_waits_with_its_first_question_and_nothing_without_one() {
        assert_eq!(
            events(
                r#"{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_input":{"questions":[{"id":"a","header":"A","question":"Which license?","options":[]},{"id":"b","header":"B","question":"Who holds it?","options":[]}]}}"#
            ),
            vec![AgentEvent::WaitingForInput {
                detail: Some("Which license?".into())
            }]
        );
        for input in [r"{}", r#"{"questions":[{"question":"  "}]}"#] {
            let payload = format!(
                r#"{{"hook_event_name":"PreToolUse","tool_name":"request_user_input","tool_input":{input}}}"#
            );
            assert_eq!(
                events(&payload),
                vec![AgentEvent::WaitingForInput { detail: None }],
                "{input}"
            );
        }
    }

    #[test]
    fn a_question_codex_does_not_wait_on_is_an_ordinary_tool_call() {
        assert_eq!(
            events(
                r#"{"hook_event_name":"PreToolUse","tool_name":"request_user_input_async","tool_input":{"questions":[{"title":"Which license?","options":["MIT"]}]}}"#
            ),
            vec![AgentEvent::ToolStarted {
                tool: "request_user_input_async".into(),
                detail: Some("request_user_input_async".into())
            }]
        );
    }

    #[test]
    fn tool_detail_prefers_the_command_then_the_path_then_the_name() {
        assert_eq!(
            events(
                r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo out > out-long.txt"}}"#
            ),
            vec![AgentEvent::ToolStarted {
                tool: "Bash".into(),
                detail: Some("Bash: echo out > out-long.txt".into())
            }]
        );
        assert_eq!(
            events(
                r#"{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"file_path":"/a.txt"}}"#
            ),
            vec![AgentEvent::ToolStarted {
                tool: "apply_patch".into(),
                detail: Some("apply_patch: /a.txt".into())
            }]
        );
        assert_eq!(
            events(
                r#"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"command":""}}"#
            ),
            vec![AgentEvent::ToolStarted {
                tool: "Read".into(),
                detail: Some("Read".into())
            }]
        );
        // A `command` that is there but empty says what the tool runs is
        // nothing, so the detail is the bare tool: `file_path` is read only
        // when the input has no `command` at all.
        // `scripts/derive-expected-events.py` mirrors this, so a re-recorded
        // case with both keys derives the golden the adapter gives.
        assert_eq!(
            events(
                r#"{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"","file_path":"/a.txt"}}"#
            ),
            vec![AgentEvent::ToolStarted {
                tool: "apply_patch".into(),
                detail: Some("apply_patch".into())
            }]
        );
        assert_eq!(
            events(
                r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":["bash","-lc","ls -la"]}}"#
            ),
            vec![AgentEvent::ToolStarted {
                tool: "Bash".into(),
                detail: Some("Bash: bash -lc ls -la".into())
            }]
        );
        assert_eq!(
            events(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#),
            vec![AgentEvent::ToolFinished {
                tool: Some("Bash".into())
            }]
        );
    }

    #[test]
    fn unsubscribed_events_pass_through_as_extensions() {
        for payload in [
            r#"{"hook_event_name":"CwdChanged","new_cwd":"/x"}"#,
            r#"{"hook_event_name":"Notification","notification_type":"permission_prompt"}"#,
            r#"{"hook_event_name":"StopFailure","error":"x"}"#,
        ] {
            assert!(
                matches!(events(payload).as_slice(), [AgentEvent::Extension { .. }]),
                "{payload}"
            );
        }
    }
}
