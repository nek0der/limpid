//! Maps Claude Code hook payloads to neutral events.
//!
//! The mapping mirrors what `claude-shim/limpid-hook` did and is checked
//! against the recorded fixtures under `rust/fixtures/claude`. Titles come
//! from two places. `SessionStart` and `UserPromptSubmit` carry
//! `session_title` once the session has a name of the person's (`/rename`,
//! recorded in `fixtures/claude/2026-10/rename`). The transcript's
//! `custom-title` and `ai-title` lines carry that name and the one Claude
//! generates, which this adapter reads on prompt submit and stop, because
//! no hook reports a title as it changes. Stop also reads the transcript for
//! the prompt cache window the turn left behind (see `cache`), and the idle
//! prompt for whether the tool call the run waited on has ended (see
//! `awaited`).

use limpid_agent_model::{
    AgentEvent, BackgroundWork, CommandRun, EventId, HookContext, MAX_HOOK_INPUT_BYTES,
    NormalizeError, ProviderId, RawHookInput, SessionSource, Titles, UsageLimit, parse_object,
    transcript_path_for_events,
};
use serde_json::{Map, Value};

pub(crate) fn normalize(input: RawHookInput<'_>) -> Result<Vec<AgentEvent>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let event_name = string(&object, "hook_event_name")
        .unwrap_or("unknown")
        .to_owned();
    let cwd = string(&object, "cwd").map(str::to_owned);
    let event = match event_name.as_str() {
        "SessionStart" => AgentEvent::SessionStarted {
            compact: string(&object, "source") == Some("compact"),
            source: SessionSource::parse(string(&object, "source")),
            session_id: string(&object, "session_id").map(str::to_owned),
            session_title: string(&object, "session_title").map(str::to_owned),
            cwd,
        },
        "SessionEnd" => AgentEvent::SessionEnded {
            reason: string(&object, "reason").map(str::to_owned),
            session_id: string(&object, "session_id").map(str::to_owned),
        },
        "UserPromptSubmit" => AgentEvent::PromptSubmitted {
            prompt: string(&object, "prompt").unwrap_or_default().to_owned(),
            titles: prompt_titles(&object, input.transcript),
            cwd,
        },
        "PreToolUse" => pre_tool_use(&object),
        "PostToolUse" | "PostToolUseFailure"
            if string(&object, "tool_name") == Some(crate::approval::QUESTION_TOOL) =>
        {
            AgentEvent::ToolFinished {
                tool: Some(crate::approval::QUESTION_TOOL.to_owned()),
                by_subagent: is_by_subagent(&object),
            }
        }
        "Notification" => match string(&object, "notification_type") {
            Some("permission_prompt") => AgentEvent::ApprovalRequested {
                detail: string(&object, "message").map(str::to_owned),
            },
            Some("idle_prompt") => AgentEvent::AwaitingPrompt {
                awaited_call_ended: input
                    .transcript
                    .is_some_and(crate::awaited::transcript_awaited_call_ended),
            },
            _ => extension(&event_name, object),
        },
        "PreCompact" => AgentEvent::Compacting {
            context_tokens: object.get("current_token_count").and_then(Value::as_u64),
        },
        "Stop" => AgentEvent::TurnFinished {
            continues_after_stop_hook: object
                .get("stop_hook_active")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            titles: input.transcript.and_then(transcript_titles),
            cache: input
                .transcript
                .and_then(crate::cache::transcript_cache_window),
            reply: string(&object, "last_assistant_message")
                .filter(|reply| !reply.is_empty())
                .map(str::to_owned),
            background_work: background_work(&object),
        },
        "StopFailure" => {
            // Recorded payloads carry the reason under `error`; the shell
            // receiver expected `error_type`, kept as a fallback.
            let error = string(&object, "error")
                .or_else(|| string(&object, "error_type"))
                .unwrap_or("error");
            AgentEvent::Failed {
                usage_limit: if error == "rate_limit" {
                    usage_limit(&object, input.transcript)
                } else {
                    None
                },
                error: error.to_owned(),
            }
        }
        "CwdChanged" => {
            let new_cwd = ["new_cwd", "newCwd", "cwd"]
                .iter()
                .find_map(|key| string(&object, key))
                .unwrap_or_default()
                .to_owned();
            AgentEvent::CwdChanged {
                new_cwd,
                old_cwd: ["old_cwd", "oldCwd", "previous_cwd"]
                    .iter()
                    .find_map(|key| string(&object, key))
                    .map(str::to_owned),
            }
        }
        _ => extension(&event_name, object),
    };
    Ok(vec![event])
}

/// The background tasks `Stop` lists as still running
/// (`background_tasks`), counted by kind, or `None` when it lists none. A
/// task with no status is counted, since the list holds only tasks Claude
/// still tracks; one in any status but `running` is not. Recorded in
/// `fixtures/claude/2026-10/background-task` (2.1.312), which also carries
/// the `<task-notification>` turn whose stop lists the task no more.
fn background_work(object: &Map<String, Value>) -> Option<BackgroundWork> {
    let mut work = BackgroundWork::default();
    for task in object.get("background_tasks")?.as_array()? {
        let Some(task) = task.as_object() else {
            continue;
        };
        if string(task, "status").is_some_and(|status| status != "running") {
            continue;
        }
        let count = match string(task, "type") {
            Some("shell") => &mut work.shells,
            Some("subagent") => &mut work.subagents,
            _ => &mut work.others,
        };
        *count = count.saturating_add(1);
    }
    (!work.is_empty()).then_some(work)
}

/// The plan's usage limit a `rate_limit` failure is, if it is one. The
/// transcript's API error line says so when it is there; when it is not, the
/// failure's own words do; with neither, a subscriber's limit is the likely
/// one (Claude Code retries a subscriber's passing 429s itself since 2.1.199),
/// so it stands with no time.
fn usage_limit(object: &Map<String, Value>, transcript: Option<&[u8]>) -> Option<UsageLimit> {
    use crate::usage::{Finding, message_names_a_limit, transcript_usage_limit};
    match transcript.map_or(Finding::NotFound, transcript_usage_limit) {
        Finding::Limit(limit) => Some(limit),
        Finding::NotALimit => None,
        Finding::NotFound => match string(object, "last_assistant_message") {
            Some(message) if !message_names_a_limit(message) => None,
            _ => Some(UsageLimit::default()),
        },
    }
}

/// Titles are read from the transcript on prompt submit and stop, since no
/// hook reports a title as it changes. Stop reads it for the cache window too,
/// which needs no extra file read, and a failed stop for the usage limit it
/// hit. The idle prompt reads it for whether the call the run waited on has
/// ended; the other notifications do not, since each one named costs a file
/// read.
pub(crate) fn transcript_path(input: RawHookInput<'_>) -> Result<Option<String>, NormalizeError> {
    let path = transcript_path_for_events(input, &["UserPromptSubmit", "Stop", "StopFailure"])?;
    if path.is_some() {
        return Ok(path);
    }
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    if string(&object, "notification_type") != Some("idle_prompt") {
        return Ok(None);
    }
    transcript_path_for_events(input, &["Notification"])
}

/// Returns the transcript of a call that begins a turn (`UserPromptSubmit`)
/// or puts the run in a wait (the question tool's `PreToolUse` and the
/// permission prompt's `Notification`). Esc at a wait, and Esc or Ctrl+C at
/// work, send no hook, so the app reads this transcript for the interrupt
/// line while the run waits (`awaited`) and for what a turn the person
/// stopped used. Only the path is named; nothing is read.
pub(crate) fn turn_transcript_path(
    input: RawHookInput<'_>,
) -> Result<Option<String>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let names_it = match string(&object, "hook_event_name") {
        Some("UserPromptSubmit") => true,
        Some("PreToolUse") => string(&object, "tool_name") == Some(crate::approval::QUESTION_TOOL),
        Some("Notification") => string(&object, "notification_type") == Some("permission_prompt"),
        _ => false,
    };
    if !names_it {
        return Ok(None);
    }
    transcript_path_for_events(input, &["UserPromptSubmit", "PreToolUse", "Notification"])
}

fn pre_tool_use(object: &Map<String, Value>) -> AgentEvent {
    let tool = string(object, "tool_name").unwrap_or_default();
    let tool_input = object.get("tool_input");
    if tool == "AskUserQuestion" {
        // The question text is what the attention card shows. A payload
        // that is not the documented shape has none, and the wait's kind
        // already says it is a question, so the tool's name would add
        // nothing a person could read.
        let question = tool_input
            .and_then(|input| input.get("questions"))
            .and_then(|questions| questions.get(0))
            .and_then(|question| question.get("question"))
            .and_then(Value::as_str)
            .or_else(|| {
                tool_input
                    .and_then(|input| input.get("question"))
                    .and_then(Value::as_str)
            })
            .filter(|question| !question.trim().is_empty());
        return AgentEvent::WaitingForInput {
            detail: question.map(str::to_owned),
        };
    }
    // Prefer the concrete argument over the bare tool name so a permission
    // prompt that follows can show what needs approval.
    let argument = tool_input
        .and_then(|input| input.get("command").or_else(|| input.get("file_path")))
        .and_then(Value::as_str);
    let detail = match argument {
        Some(argument) if !argument.is_empty() => format!("{tool}: {argument}"),
        _ => tool.to_owned(),
    };
    AgentEvent::ToolStarted {
        tool: tool.to_owned(),
        detail: Some(detail),
        by_subagent: is_by_subagent(object),
    }
}

/// Whether a tool hook is a subagent's. Recorded in 2.1.312: a subagent's
/// tool call carries `agent_id` and `agent_type`; the agent's own, a stop
/// hook's continuation included, carries neither.
fn is_by_subagent(object: &Map<String, Value>) -> bool {
    string(object, "agent_id").is_some_and(|id| !id.is_empty())
}

/// The titles a transcript holds: the latest `custom-title` line, which
/// `/rename` writes, and the latest `ai-title` line, which Claude writes as it
/// names the session. Claude Code 2.1.312 writes each on its own line, and
/// writes `ai-title` only where it sets the terminal's title, so not inside
/// tmux.
fn transcript_titles(transcript: &[u8]) -> Option<Titles> {
    let mut titles = Titles::default();
    for line in transcript.split(|byte| *byte == b'\n').rev() {
        // Most lines are conversation records; a substring check keeps the
        // JSON parse for the few that can carry a title.
        if !contains(line, br#"-title""#) {
            continue;
        }
        let Ok(Value::Object(record)) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        let (field, key) = match string(&record, "type") {
            Some("custom-title") => (&mut titles.session_title, "customTitle"),
            Some("ai-title") => (&mut titles.generated_title, "aiTitle"),
            _ => continue,
        };
        if field.is_none() {
            *field = string(&record, key).map(str::to_owned);
        }
        if titles.session_title.is_some() && titles.generated_title.is_some() {
            break;
        }
    }
    (titles.session_title.is_some() || titles.generated_title.is_some()).then_some(titles)
}

/// A prompt's titles: the session's name as the payload carries it, which
/// a transcript Claude does not keep cannot give, else the transcript's.
fn prompt_titles(object: &Map<String, Value>, transcript: Option<&[u8]>) -> Option<Titles> {
    let mut titles = transcript.and_then(transcript_titles);
    if let Some(name) = string(object, "session_title").filter(|it| !it.trim().is_empty()) {
        titles.get_or_insert_with(Titles::default).session_title = Some(name.to_owned());
    }
    titles
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn extension(name: &str, object: Map<String, Value>) -> AgentEvent {
    AgentEvent::Extension {
        name: name.to_owned(),
        payload: Value::Object(object),
    }
}

/// The hook call's identity. Claude's tool hooks name the tool use they are
/// about, which stays the same however the call is retried; every other hook
/// falls back to the shim's invocation id.
pub(crate) fn event_id(
    input: RawHookInput<'_>,
    context: &HookContext,
    provider: &ProviderId,
) -> Result<Option<EventId>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let hook = string(&object, "hook_event_name");
    if let (Some(hook @ ("PreToolUse" | "PostToolUse" | "PostToolUseFailure")), Some(tool_use_id)) = (
        hook,
        string(&object, "tool_use_id").filter(|id| !id.is_empty()),
    ) {
        return Ok(Some(EventId::tool(provider, tool_use_id, hook)));
    }
    Ok(context
        .invocation_id
        .map(|id| EventId::invocation(provider, id)))
}

/// A Bash command Claude ran, from the hook that follows it. Claude reports
/// a non-zero exit as a failed tool call (`PostToolUseFailure`) whose `error`
/// begins `Exit code N`; a call that succeeded exited with 0. An interrupted
/// run (`interrupted`, `is_interrupt`) has no exit status worth showing.
/// <https://code.claude.com/docs/en/hooks>
pub(crate) fn command_run(input: RawHookInput<'_>) -> Result<Option<CommandRun>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    if string(&object, "tool_name") != Some("Bash") {
        return Ok(None);
    }
    let Some(command) = object
        .get("tool_input")
        .and_then(|input| input.get("command"))
        .and_then(Value::as_str)
        .filter(|command| !command.trim().is_empty())
    else {
        return Ok(None);
    };
    // A command sent to the background reports when it starts, not when it
    // ends: what came back says nothing about how it exited. It is still the
    // turn's last check, shown without a ✓ or ✗, so an earlier run's ✓ does
    // not stand for it.
    let is_background = object
        .get("tool_input")
        .and_then(|input| input.get("run_in_background"))
        .and_then(Value::as_bool)
        == Some(true)
        || object
            .get("tool_response")
            .and_then(|response| response.get("backgroundTaskId"))
            .is_some();
    let exit_code = match string(&object, "hook_event_name") {
        _ if is_background => None,
        Some("PostToolUse") => {
            let interrupted = object
                .get("tool_response")
                .and_then(|response| response.get("interrupted"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            (!interrupted).then_some(0)
        }
        Some("PostToolUseFailure") => {
            if object.get("is_interrupt").and_then(Value::as_bool) == Some(true) {
                None
            } else {
                string(&object, "error").and_then(exit_code_of)
            }
        }
        _ => return Ok(None),
    };
    Ok(Some(CommandRun {
        command: command.to_owned(),
        exit_code,
        cwd: string(&object, "cwd").map(str::to_owned),
    }))
}

/// The status in a failed Bash call's `error`, whose first line is
/// `Exit code N`.
fn exit_code_of(error: &str) -> Option<i32> {
    error
        .lines()
        .next()?
        .trim()
        .strip_prefix("Exit code ")?
        .trim()
        .parse()
        .ok()
}

fn string<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ClaudeAdapter;
    use limpid_agent_model::ProviderAdapter;

    fn event_id_of(payload: &str, invocation: Option<uuid::Uuid>) -> Option<String> {
        let context = HookContext {
            invocation_id: invocation,
            ..HookContext::fixture()
        };
        ClaudeAdapter
            .event_id(
                RawHookInput {
                    bytes: payload.as_bytes(),
                    transcript: None,
                },
                &context,
            )
            .expect("an object")
            .map(|id| id.as_str().to_owned())
    }

    #[test]
    fn event_id_uses_tool_use_id_for_claude_tool_events() {
        let invocation = Some(uuid::Uuid::from_u128(9));
        let before = event_id_of(
            r#"{"hook_event_name":"PreToolUse","tool_use_id":"toolu_01"}"#,
            invocation,
        );
        let after = event_id_of(
            r#"{"hook_event_name":"PostToolUse","tool_use_id":"toolu_01"}"#,
            invocation,
        );
        assert_eq!(before.as_deref(), Some("claude:tool:toolu_01:PreToolUse"));
        assert_eq!(after.as_deref(), Some("claude:tool:toolu_01:PostToolUse"));
        // A retry under a new invocation id is still the same tool hook.
        assert_eq!(
            event_id_of(
                r#"{"hook_event_name":"PreToolUse","tool_use_id":"toolu_01"}"#,
                Some(uuid::Uuid::from_u128(10))
            ),
            before
        );
    }

    #[test]
    fn event_id_uses_invocation_id_otherwise() {
        let invocation = Some(uuid::Uuid::from_u128(9));
        assert_eq!(
            event_id_of(
                r#"{"hook_event_name":"UserPromptSubmit","prompt":"hi"}"#,
                invocation
            )
            .as_deref(),
            Some("claude:invocation:00000000-0000-0000-0000-000000000009")
        );
        // A tool hook without its id falls back too.
        assert_eq!(
            event_id_of(r#"{"hook_event_name":"PreToolUse"}"#, invocation).as_deref(),
            Some("claude:invocation:00000000-0000-0000-0000-000000000009")
        );
        assert_eq!(event_id_of(r#"{"hook_event_name":"Stop"}"#, None), None);
        // The same prompt sent twice is two events; one call retried is one.
        let prompt = r#"{"hook_event_name":"UserPromptSubmit","prompt":"hi"}"#;
        assert_ne!(
            event_id_of(prompt, Some(uuid::Uuid::from_u128(1))),
            event_id_of(prompt, Some(uuid::Uuid::from_u128(2)))
        );
        assert_eq!(
            event_id_of(prompt, Some(uuid::Uuid::from_u128(1))),
            event_id_of(prompt, Some(uuid::Uuid::from_u128(1)))
        );
    }

    fn events(payload: &str, transcript: Option<&str>) -> Vec<AgentEvent> {
        normalize(RawHookInput {
            bytes: payload.as_bytes(),
            transcript: transcript.map(str::as_bytes),
        })
        .expect("normalizes")
    }

    #[test]
    fn a_stop_after_a_stop_hook_says_so() {
        assert_eq!(
            events(
                r#"{"hook_event_name":"Stop","stop_hook_active":true}"#,
                None
            ),
            vec![AgentEvent::TurnFinished {
                continues_after_stop_hook: true,
                titles: None,
                cache: None,
                reply: None,
                background_work: None,
            }]
        );
    }

    #[test]
    fn transcript_titles_take_the_latest_line_of_each_kind() {
        let transcript = concat!(
            "{\"type\":\"custom-title\",\"customTitle\":\"old name\"}\n",
            "{\"type\":\"ai-title\",\"aiTitle\":\"first\"}\n",
            "not json\n",
            "{\"type\":\"custom-title\",\"customTitle\":\"mine\"}\n",
            "{\"type\":\"ai-title\",\"aiTitle\":\"second\"}\n",
        );
        let actual = events(r#"{"hook_event_name":"Stop"}"#, Some(transcript));
        assert_eq!(
            actual,
            vec![AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: Some(Titles {
                    session_title: Some("mine".into()),
                    generated_title: Some("second".into()),
                }),
                cache: None,
                reply: None,
                background_work: None,
            }]
        );
        assert_eq!(
            events(
                r#"{"hook_event_name":"Stop"}"#,
                Some("{\"type\":\"custom-title\",\"customTitle\":\"mine\"}\n")
            ),
            vec![AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: Some(Titles {
                    session_title: Some("mine".into()),
                    generated_title: None,
                }),
                cache: None,
                reply: None,
                background_work: None,
            }]
        );
        assert_eq!(
            events(
                r#"{"hook_event_name":"Stop"}"#,
                Some("{\"type\":\"user\"}\n")
            ),
            vec![AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: None,
                cache: None,
                reply: None,
                background_work: None,
            }]
        );
    }

    #[test]
    fn a_prompt_takes_the_sessions_name_from_its_payload_before_the_transcript() {
        let renamed =
            r#"{"hook_event_name":"UserPromptSubmit","prompt":"p","session_title":"Payload name"}"#;
        let titles = |transcript: Option<&str>| match events(renamed, transcript).as_slice() {
            [AgentEvent::PromptSubmitted { titles, .. }] => titles.clone(),
            other => panic!("{other:?}"),
        };
        // A Claude that keeps no transcript still names its session.
        assert_eq!(
            titles(None),
            Some(Titles {
                session_title: Some("Payload name".into()),
                generated_title: None,
            })
        );
        assert_eq!(
            titles(Some(concat!(
                "{\"type\":\"custom-title\",\"customTitle\":\"Older name\"}\n",
                "{\"type\":\"ai-title\",\"aiTitle\":\"Generated\"}\n",
            ))),
            Some(Titles {
                session_title: Some("Payload name".into()),
                generated_title: Some("Generated".into()),
            })
        );
        let blank = r#"{"hook_event_name":"UserPromptSubmit","prompt":"p","session_title":"  "}"#;
        assert!(matches!(
            events(blank, None).as_slice(),
            [AgentEvent::PromptSubmitted { titles: None, .. }]
        ));
    }

    /// Every background task `Stop` lists as running counts, by kind; one
    /// that is no longer running, or an entry that is not a task, does not.
    #[test]
    fn stop_counts_the_background_tasks_still_running() {
        let payload = r#"{"hook_event_name":"Stop","background_tasks":[
            {"id":"b1","type":"shell","status":"running","command":"sleep 40"},
            {"id":"b2","type":"shell","status":"completed","command":"ls"},
            {"id":"a1","type":"subagent","status":"running","agent_type":"general-purpose"},
            {"id":"m1","type":"monitor"},
            "not a task"
        ]}"#;
        let [
            AgentEvent::TurnFinished {
                background_work, ..
            },
        ] = &events(payload, None)[..]
        else {
            panic!("one turn_finished");
        };
        assert_eq!(
            *background_work,
            Some(BackgroundWork {
                shells: 1,
                subagents: 1,
                others: 1,
            })
        );
        for payload in [
            r#"{"hook_event_name":"Stop","background_tasks":[]}"#,
            r#"{"hook_event_name":"Stop","background_tasks":[{"type":"shell","status":"killed"}]}"#,
            r#"{"hook_event_name":"Stop","background_tasks":"shell"}"#,
            r#"{"hook_event_name":"Stop"}"#,
        ] {
            let [
                AgentEvent::TurnFinished {
                    background_work, ..
                },
            ] = &events(payload, None)[..]
            else {
                panic!("one turn_finished");
            };
            assert_eq!(*background_work, None, "{payload}");
        }
    }

    #[test]
    fn stop_reads_the_cache_window_beside_the_title() {
        let transcript = concat!(
            "{\"type\":\"assistant\",\"isSidechain\":false,\"requestId\":\"req_1\",",
            "\"timestamp\":\"2026-10-07T12:00:00.250Z\",\"message\":{\"id\":\"msg_1\",\"usage\":",
            "{\"input_tokens\":1,\"cache_read_input_tokens\":10,\"cache_creation_input_tokens\":5,",
            "\"output_tokens\":4,\"cache_creation\":{\"ephemeral_1h_input_tokens\":5,",
            "\"ephemeral_5m_input_tokens\":0}}}}\n",
            "{\"type\":\"ai-title\",\"aiTitle\":\"named\"}\n",
        );
        let actual = events(r#"{"hook_event_name":"Stop"}"#, Some(transcript));
        assert_eq!(
            actual,
            vec![AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: Some(Titles {
                    session_title: None,
                    generated_title: Some("named".into()),
                }),
                cache: Some(limpid_agent_model::CacheWindow {
                    observed_at: "2026-10-07T12:00:00Z".into(),
                    ttl_seconds: 3600,
                    rewrite_tokens: Some(20),
                    precision: limpid_agent_model::CachePrecision::Estimated,
                }),
                reply: None,
                background_work: None,
            }]
        );
        // Prompt submit reads the transcript for titles only: the window it
        // would find belongs to the turn this prompt is about to replace.
        let actual = events(
            r#"{"hook_event_name":"UserPromptSubmit","prompt":"p"}"#,
            Some(transcript),
        );
        assert!(matches!(
            actual.as_slice(),
            [AgentEvent::PromptSubmitted {
                titles: Some(_),
                ..
            }]
        ));
    }

    #[test]
    fn ask_user_question_reports_the_question_text_and_nothing_without_one() {
        let payload = r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?"}]}}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::WaitingForInput {
                detail: Some("Which color?".into())
            }]
        );
        let payload =
            r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::WaitingForInput { detail: None }]
        );
    }

    #[test]
    fn question_completion_resumes_without_finishing_other_pending_tools() {
        for name in ["PostToolUse", "PostToolUseFailure"] {
            let payload =
                format!(r#"{{"hook_event_name":"{name}","tool_name":"AskUserQuestion"}}"#);
            assert_eq!(
                events(&payload, None),
                vec![AgentEvent::ToolFinished {
                    tool: Some("AskUserQuestion".into()),
                    by_subagent: false,
                }]
            );
            let payload = format!(
                r#"{{"hook_event_name":"{name}","tool_name":"AskUserQuestion","agent_id":"a1","agent_type":"Explore"}}"#
            );
            assert_eq!(
                events(&payload, None),
                vec![AgentEvent::ToolFinished {
                    tool: Some("AskUserQuestion".into()),
                    by_subagent: true,
                }]
            );
            let payload = format!(r#"{{"hook_event_name":"{name}","tool_name":"Bash"}}"#);
            assert!(matches!(
                events(&payload, None).as_slice(),
                [AgentEvent::Extension { .. }]
            ));
        }
    }

    #[test]
    fn tool_detail_prefers_the_command_then_the_path_then_the_name() {
        let payload = r#"{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/a.txt"}}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::ToolStarted {
                tool: "Edit".into(),
                detail: Some("Edit: /a.txt".into()),
                by_subagent: false,
            }]
        );
        let payload = r#"{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{}}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::ToolStarted {
                tool: "Read".into(),
                detail: Some("Read".into()),
                by_subagent: false,
            }]
        );
        // A `command` that is there but empty says what the tool runs is
        // nothing, so the detail is the bare tool: `file_path` is read only
        // when the input has no `command` at all.
        // `scripts/derive-expected-events.py` mirrors this, so a re-recorded
        // case with both keys derives the golden the adapter gives.
        let payload = r#"{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"command":"","file_path":"/a.txt"}}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::ToolStarted {
                tool: "Edit".into(),
                detail: Some("Edit".into()),
                by_subagent: false,
            }]
        );
    }

    #[test]
    fn an_idle_notification_says_the_agent_awaits_its_prompt() {
        let payload =
            r#"{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"m"}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::AwaitingPrompt {
                awaited_call_ended: false
            }]
        );
        // This is a question the person declined with Esc: its result and the
        // interrupt line follow the call, and no hook said so.
        let declined = concat!(
            r#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{}}]}}"#,
            "\n",
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"User rejected tool use"}]},"toolUseResult":"User rejected tool use","toolDenialKind":"user-rejected"}"#,
            "\n",
            r#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
        );
        assert_eq!(
            events(payload, Some(declined)),
            vec![AgentEvent::AwaitingPrompt {
                awaited_call_ended: true
            }]
        );
    }

    #[test]
    fn only_the_idle_notification_asks_for_the_transcript() {
        let path = |payload: &str| {
            transcript_path(RawHookInput {
                bytes: payload.as_bytes(),
                transcript: None,
            })
            .expect("ok")
        };
        assert_eq!(
            path(
                r#"{"hook_event_name":"Notification","notification_type":"idle_prompt","transcript_path":"/t/x.jsonl"}"#
            ),
            Some("/t/x.jsonl".into())
        );
        assert_eq!(
            path(
                r#"{"hook_event_name":"Notification","notification_type":"permission_prompt","transcript_path":"/t/x.jsonl"}"#
            ),
            None
        );
        assert_eq!(
            path(
                r#"{"hook_event_name":"PreToolUse","notification_type":"idle_prompt","transcript_path":"/t/x.jsonl"}"#
            ),
            None
        );
    }

    #[test]
    fn only_a_prompt_or_a_call_that_waits_names_its_transcript() {
        let path = |payload: &str| {
            turn_transcript_path(RawHookInput {
                bytes: payload.as_bytes(),
                transcript: None,
            })
            .expect("ok")
        };
        let named = Some("/t/x.jsonl".to_owned());
        assert_eq!(
            path(
                r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","transcript_path":"/t/x.jsonl"}"#
            ),
            named
        );
        assert_eq!(
            path(
                r#"{"hook_event_name":"Notification","notification_type":"permission_prompt","transcript_path":"/t/x.jsonl"}"#
            ),
            named
        );
        // A prompt names it for the turn it begins, which Esc or Ctrl+C
        // can end with no hook.
        assert_eq!(
            path(
                r#"{"hook_event_name":"UserPromptSubmit","prompt":"go","transcript_path":"/t/x.jsonl"}"#
            ),
            named
        );
        for payload in [
            r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","transcript_path":"/t/x.jsonl"}"#,
            r#"{"hook_event_name":"Notification","notification_type":"idle_prompt","transcript_path":"/t/x.jsonl"}"#,
            r#"{"hook_event_name":"Stop","transcript_path":"/t/x.jsonl"}"#,
            r#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","transcript_path":"/t/x.txt"}"#,
        ] {
            assert_eq!(path(payload), None, "{payload}");
        }
    }

    #[test]
    fn other_notifications_and_unknown_events_pass_through_as_extensions() {
        let payload = r#"{"hook_event_name":"Notification","notification_type":"auth_success","message":"m"}"#;
        assert!(matches!(
            events(payload, None).as_slice(),
            [AgentEvent::Extension { name, .. }] if name == "Notification"
        ));
        let payload = r#"{"hook_event_name":"SubagentStart"}"#;
        assert!(matches!(
            events(payload, None).as_slice(),
            [AgentEvent::Extension { name, .. }] if name == "SubagentStart"
        ));
        assert!(matches!(
            events(r#"{"cwd":"/x"}"#, None).as_slice(),
            [AgentEvent::Extension { name, .. }] if name == "unknown"
        ));
    }

    #[test]
    fn stop_failure_reads_error_then_error_type() {
        let payload = r#"{"hook_event_name":"StopFailure","error":"server_error"}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::Failed {
                error: "server_error".into(),
                usage_limit: None,
            }]
        );
        let payload = r#"{"hook_event_name":"StopFailure","error_type":"rate_limit"}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::Failed {
                error: "rate_limit".into(),
                usage_limit: Some(UsageLimit::default()),
            }]
        );
    }

    #[test]
    fn a_rate_limit_failure_reads_the_reset_from_the_transcript() {
        let payload = r#"{"hook_event_name":"StopFailure","error":"rate_limit"}"#;
        let transcript = r#"{"type":"user","message":{"content":"go"}}
{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","quotaLimits":{"status":"rejected","resetsAt":1791352800,"rateLimitType":"five_hour"}}
{"type":"system","subtype":"turn_duration"}"#;
        assert_eq!(
            events(payload, Some(transcript)),
            vec![AgentEvent::Failed {
                error: "rate_limit".into(),
                usage_limit: Some(UsageLimit {
                    resets_at: Some("2026-10-07T06:00:00Z".into()),
                    window: Some("five_hour".into()),
                }),
            }]
        );
    }

    #[test]
    fn a_rate_limit_that_is_not_the_plans_limit_stays_an_error() {
        let payload = r#"{"hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"API Error: Request rejected (429)"}"#;
        assert_eq!(
            events(payload, None),
            vec![AgentEvent::Failed {
                error: "rate_limit".into(),
                usage_limit: None,
            }]
        );
        let allowed = r#"{"type":"user","message":{"content":"go"}}
{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","quotaLimits":{"status":"allowed"}}"#;
        assert_eq!(
            events(
                r#"{"hook_event_name":"StopFailure","error":"rate_limit"}"#,
                Some(allowed)
            ),
            vec![AgentEvent::Failed {
                error: "rate_limit".into(),
                usage_limit: None,
            }]
        );
    }

    #[test]
    fn a_failed_stop_asks_for_the_transcript() {
        let payload = br#"{"hook_event_name":"StopFailure","error":"rate_limit","transcript_path":"/tmp/t.jsonl"}"#;
        assert_eq!(
            transcript_path(RawHookInput {
                bytes: payload,
                transcript: None,
            })
            .unwrap()
            .as_deref(),
            Some("/tmp/t.jsonl")
        );
    }

    #[test]
    fn transcript_is_requested_only_for_prompt_and_stop() {
        let stop = r#"{"hook_event_name":"Stop","transcript_path":"/t/x.jsonl"}"#;
        assert_eq!(
            transcript_path(RawHookInput {
                bytes: stop.as_bytes(),
                transcript: None
            })
            .expect("ok"),
            Some("/t/x.jsonl".into())
        );
        let tool = r#"{"hook_event_name":"PreToolUse","transcript_path":"/t/x.jsonl"}"#;
        assert_eq!(
            transcript_path(RawHookInput {
                bytes: tool.as_bytes(),
                transcript: None
            })
            .expect("ok"),
            None
        );
        let other = r#"{"hook_event_name":"Stop","transcript_path":"/etc/passwd"}"#;
        assert_eq!(
            transcript_path(RawHookInput {
                bytes: other.as_bytes(),
                transcript: None
            })
            .expect("ok"),
            None
        );
    }

    #[test]
    fn worktree_intent_only_comes_from_a_bash_pre_tool_use() {
        let payload = r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/r","tool_input":{"command":"git worktree add -b demo ../demo"}}"#;
        let intent = ClaudeAdapter
            .worktree_intent(RawHookInput {
                bytes: payload.as_bytes(),
                transcript: None,
            })
            .expect("ok")
            .expect("intent");
        assert_eq!(intent.branch, "demo");
        assert_eq!(intent.cwd.as_deref(), Some("/r"));
        let payload = r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"git worktree add -b demo ../demo"}}"#;
        assert_eq!(
            ClaudeAdapter
                .worktree_intent(RawHookInput {
                    bytes: payload.as_bytes(),
                    transcript: None
                })
                .expect("ok"),
            None
        );
    }

    fn run(payload: &str) -> Option<CommandRun> {
        command_run(RawHookInput {
            bytes: payload.as_bytes(),
            transcript: None,
        })
        .expect("payload")
    }

    #[test]
    fn a_bash_call_reports_its_command_and_exit() {
        let ok = run(
            r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/r",
                "tool_input":{"command":"cargo test"},
                "tool_response":{"stdout":"ok","stderr":"","interrupted":false,"isImage":false}}"#,
        )
        .expect("a run");
        assert_eq!(ok.command, "cargo test");
        assert_eq!(ok.exit_code, Some(0));
        assert_eq!(ok.cwd.as_deref(), Some("/r"));

        let failed = run(
            r#"{"hook_event_name":"PostToolUseFailure","tool_name":"Bash",
                "tool_input":{"command":"npm test"},
                "error":"Exit code 1\nError: Cannot find module 'express'","is_interrupt":false}"#,
        )
        .expect("a run");
        assert_eq!(failed.exit_code, Some(1));

        let interrupted = run(
            r#"{"hook_event_name":"PostToolUseFailure","tool_name":"Bash",
                "tool_input":{"command":"npm test"},"error":"Interrupted","is_interrupt":true}"#,
        )
        .expect("a run");
        assert_eq!(interrupted.exit_code, None);
    }

    #[test]
    fn a_run_that_did_not_end_has_no_exit() {
        let interrupted = run(
            r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cargo test"},
                "tool_response":{"stdout":"","stderr":"","interrupted":true,"isImage":false}}"#,
        )
        .expect("a run");
        assert_eq!(interrupted.exit_code, None);
        let unexplained = run(
            r#"{"hook_event_name":"PostToolUseFailure","tool_name":"Bash",
                "tool_input":{"command":"cargo test"},"error":"Command timed out"}"#,
        )
        .expect("a run");
        assert_eq!(
            unexplained.exit_code, None,
            "no `Exit code` line, no status"
        );
        let background = run(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash",
                    "tool_input":{"command":"cargo test","run_in_background":true},
                    "tool_response":{"stdout":"","stderr":"","interrupted":false,"isImage":false}}"#)
        .expect("a run");
        assert_eq!(
            background.exit_code, None,
            "a background command has not ended"
        );
    }

    #[test]
    fn other_tools_and_hooks_report_no_run() {
        assert_eq!(
            run(
                r#"{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"a"}}"#
            ),
            None
        );
        assert_eq!(
            run(
                r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#
            ),
            None,
            "before it ran, it has no result"
        );
        assert_eq!(
            run(r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}"#),
            None
        );
    }

    #[test]
    fn a_bash_result_leaves_a_waiting_question_alone() {
        // The question stays until its own tool answers: a command that
        // finished meanwhile is not an answer.
        let events = events(
            r#"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"cargo test"}}"#,
            None,
        );
        assert!(
            !events
                .iter()
                .any(|event| matches!(event, AgentEvent::ToolFinished { .. })),
            "{events:?}"
        );
    }
}
