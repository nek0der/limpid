//! What a run record keeps from each event: the conversation, prompts and
//! titles, waits, the cache window and usage limit, and the record's
//! revision and text bounds.

use super::*;

#[test]
fn a_session_holds_a_conversation_once_prompted_or_resumed() {
    let start = |source: Option<SessionSource>| AgentEvent::SessionStarted {
        compact: source == Some(SessionSource::Compact),
        source,
        session_id: Some("session-1".into()),
        session_title: None,
        cwd: None,
    };
    let run = |prev: Option<&RunRecord>, event: &AgentEvent| {
        apply(prev, event, &context(), &claude(), NOW)
            .run
            .expect("record")
    };

    // Started anew, nothing said yet: no transcript to resume.
    let fresh = run(None, &start(Some(SessionSource::Startup)));
    assert_eq!(fresh.has_prompt, Some(false));
    assert_eq!(
        run(None, &start(Some(SessionSource::Clear))).has_prompt,
        Some(false)
    );

    // A prompt gives it one, and a compaction keeps it.
    let prompted = run(Some(&fresh), &prompt("hello"));
    assert_eq!(prompted.has_prompt, Some(true));
    let compacted = run(Some(&prompted), &start(Some(SessionSource::Compact)));
    assert_eq!(compacted.has_prompt, Some(true));

    // A resume or a fork picked an existing conversation up, said or not
    // since: Limpid typing `codex resume` at launch and the person
    // quitting before a word is still a conversation to keep.
    for source in [SessionSource::Resume, SessionSource::Fork] {
        assert_eq!(run(None, &start(Some(source))).has_prompt, Some(true));
        assert_eq!(
            run(Some(&fresh), &start(Some(source))).has_prompt,
            Some(true)
        );
    }

    // A start that does not say where it came from says nothing.
    assert_eq!(run(None, &start(None)).has_prompt, None);
    assert_eq!(run(Some(&fresh), &start(None)).has_prompt, None);
}

#[test]
fn session_start_resets_the_run_and_remembers_the_session() {
    let writes = apply(None, &started(Some("Formal")), &context(), &claude(), NOW);
    let record = writes.run.expect("record");
    assert_eq!(record.schema_version, 3);
    assert_eq!(record.state, RunState::Idle);
    assert_eq!(record.revision, Some(1));
    assert_eq!(record.state_episode_token.as_deref(), Some("1"));
    assert_eq!(record.session_started_at.as_deref(), Some(NOW));
    assert_eq!(record.run_started_at, None);
    assert_eq!(record.session_id.as_deref(), Some("session-1"));
    assert_eq!(record.provider_session_title.as_deref(), Some("Formal"));
    assert_eq!(record.pid.as_deref(), Some("4242"));
    assert_eq!(record.run_id.as_deref(), Some(context().run_id.as_str()));
    assert_eq!(record.last_hook_event.as_deref(), Some("session_started"));
    assert_eq!(
        writes.side,
        vec![SideWrite::SessionHint {
            session_id: "session-1".into(),
            cwd: Some("/repo".into())
        }]
    );
    assert_eq!(writes.snapshot, None);
}

#[test]
fn a_wait_records_its_kind_and_the_tool_it_waits_to_use() {
    let tool = AgentEvent::ToolStarted {
        tool: "Write".into(),
        detail: Some("Write: /repo/notes.txt".into()),
    };
    let approval = AgentEvent::ApprovalRequested {
        detail: Some("Claude needs your permission to use Write".into()),
    };
    let (record, _, _) = run(
        &claude(),
        &[started(None), prompt("go"), tool.clone(), approval.clone()],
    );
    assert_eq!(record.wait_kind, Some(WaitKind::Approval));
    assert_eq!(record.tool.as_deref(), Some("Write"));
    assert_eq!(record.detail.as_deref(), Some("Write: /repo/notes.txt"));

    // Answered: the tool runs on, and the wait is gone with its kind.
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            tool,
            approval.clone(),
            AgentEvent::ToolFinished {
                tool: Some("Write".into()),
            },
        ],
    );
    assert_eq!(record.wait_kind, None);
    assert_eq!(record.tool, None);

    // A request with no tool event before it names no tool: the
    // provider's message is not one.
    let (record, _, _) = run(&claude(), &[started(None), prompt("go"), approval]);
    assert_eq!(record.wait_kind, Some(WaitKind::Approval));
    assert_eq!(record.tool, None);
    assert_eq!(
        record.detail.as_deref(),
        Some("Claude needs your permission to use Write")
    );

    // A question is one whatever its words look like.
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            AgentEvent::WaitingForInput {
                detail: Some("Read: which file first?".into()),
            },
        ],
    );
    assert_eq!(record.wait_kind, Some(WaitKind::Question));
    assert_eq!(record.tool, None);
    let encoded = String::from_utf8(record.encode().expect("encodes")).expect("utf8");
    assert!(encoded.contains(r#""waitKind":"question""#));
}

#[test]
fn a_permission_prompt_after_a_question_leaves_the_question_waiting() {
    let question = AgentEvent::WaitingForInput {
        detail: Some("Which color?".into()),
    };
    let prompt_shown = AgentEvent::ApprovalRequested {
        detail: Some("Claude needs your permission to use AskUserQuestion".into()),
    };
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            question.clone(),
            prompt_shown.clone(),
        ],
    );
    assert_eq!(record.state, RunState::NeedsInput);
    assert_eq!(record.wait_kind, Some(WaitKind::Question));
    assert_eq!(record.detail.as_deref(), Some("Which color?"));
    assert_eq!(record.tool, None);

    // A record from before `waitKind` says it by its last event.
    let (mut older, _, _) = run(&claude(), &[started(None), prompt("go"), question]);
    older.wait_kind = None;
    let record = apply(Some(&older), &prompt_shown, &context(), &claude(), NOW)
        .run
        .expect("record");
    assert_eq!(record.wait_kind, Some(WaitKind::Question));
    assert_eq!(record.detail.as_deref(), Some("Which color?"));
}

#[test]
fn a_turn_keeps_the_transcript_its_prompt_named_until_it_ends() {
    let named = ApplyContext {
        transcript_path: Some("/t/session.jsonl".into()),
        ..context()
    };
    let (session, _, _) = run(&claude(), &[started(None)]);
    let asked = apply(Some(&session), &prompt("go"), &named, &claude(), NOW)
        .run
        .expect("record");
    // Esc or Ctrl+C at work sends no hook, so the record names the turn's
    // transcript from its prompt on.
    assert_eq!(asked.state, RunState::Running);
    assert_eq!(asked.transcript_path.as_deref(), Some("/t/session.jsonl"));
    let waiting = apply(
        Some(&asked),
        &AgentEvent::WaitingForInput {
            detail: Some("Which color?".into()),
        },
        &named,
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(waiting.transcript_path.as_deref(), Some("/t/session.jsonl"));

    // The permission prompt after the question names no path of its own;
    // the wait keeps the question's.
    let prompt_shown = apply(
        Some(&waiting),
        &AgentEvent::ApprovalRequested { detail: None },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(
        prompt_shown.transcript_path.as_deref(),
        Some("/t/session.jsonl")
    );

    // The answer moves the run on in the same turn, which keeps the path,
    // and the turn's end lets it go.
    let answered = apply(
        Some(&prompt_shown),
        &AgentEvent::ToolFinished {
            tool: Some("AskUserQuestion".into()),
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(answered.state, RunState::Running);
    assert_eq!(
        answered.transcript_path.as_deref(),
        Some("/t/session.jsonl")
    );
    let ended = apply(
        Some(&answered),
        &AgentEvent::TurnFinished {
            continues_after_stop_hook: false,
            titles: None,
            cache: None,
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(ended.state, RunState::Finished);
    assert_eq!(ended.transcript_path, None);

    // A path no record text could hold is not cut down to another file's.
    let long = ApplyContext {
        transcript_path: Some(format!("/{}.jsonl", "a".repeat(MAX_RECORD_TEXT_BYTES))),
        ..context()
    };
    let record = apply(
        Some(&asked),
        &AgentEvent::WaitingForInput { detail: None },
        &long,
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    assert_eq!(record.transcript_path, None);
}

#[test]
fn a_permission_prompt_takes_only_a_tool_events_words() {
    // An error's words are not a request's.
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("go"),
            AgentEvent::Failed {
                error: "rate_limit".into(),
                usage_limit: None,
            },
            AgentEvent::ApprovalRequested {
                detail: Some("Claude needs your permission to use Bash".into()),
            },
        ],
    );
    assert_eq!(record.wait_kind, Some(WaitKind::Approval));
    assert_eq!(
        record.detail.as_deref(),
        Some("Claude needs your permission to use Bash")
    );
    assert_eq!(record.tool, None);
}

#[test]
fn a_turn_carries_prompts_and_ends_without_erasing_them() {
    let (record, sides, snapshots) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::ToolStarted {
                tool: "Bash".into(),
                detail: Some("Bash: ls".into()),
            },
            AgentEvent::ApprovalRequested {
                detail: Some("Claude needs your permission".into()),
            },
        ],
    );
    assert_eq!(record.state, RunState::NeedsInput);
    assert_eq!(record.detail.as_deref(), Some("Bash: ls"));
    assert_eq!(record.run_started_at.as_deref(), Some(NOW));
    assert_eq!(record.first_prompt.as_deref(), Some("first"));
    assert_eq!(record.last_prompt.as_deref(), Some("first"));
    assert_eq!(record.revision, Some(4));
    assert_eq!(sides.len(), 1);
    assert_eq!(
        snapshots,
        vec![TurnSnapshotOp::Capture {
            cwd: Some("/repo".into())
        }]
    );

    let finished = apply(
        Some(&record),
        &AgentEvent::TurnFinished {
            continues_after_stop_hook: false,
            titles: None,
            cache: None,
        },
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(finished.state, RunState::Finished);
    assert_eq!(finished.run_started_at, None);
    assert_eq!(finished.detail, None);
    assert_eq!(finished.last_prompt.as_deref(), Some("first"));
    assert_eq!(finished.updated_at, LATER);

    let second = apply(
        Some(&finished),
        &prompt("second"),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(second.first_prompt.as_deref(), Some("first"));
    assert_eq!(second.last_prompt.as_deref(), Some("second"));

    let failed = apply(
        Some(&second),
        &AgentEvent::Failed {
            error: "server_error".into(),
            usage_limit: None,
        },
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(failed.state, RunState::Error);
    assert_eq!(failed.detail.as_deref(), Some("server_error"));
    assert_eq!(failed.run_started_at, None);
    // Unified reset rule: an error keeps what the notification body needs.
    assert_eq!(failed.last_prompt.as_deref(), Some("second"));
    assert_eq!(failed.session_started_at.as_deref(), Some(NOW));
}

fn window(observed_at: &str) -> limpid_agent_model::CacheWindow {
    limpid_agent_model::CacheWindow {
        observed_at: observed_at.to_owned(),
        ttl_seconds: 3600,
        rewrite_tokens: Some(573_000),
        precision: limpid_agent_model::CachePrecision::Estimated,
    }
}

fn finished_with(observed_at: &str) -> AgentEvent {
    AgentEvent::TurnFinished {
        continues_after_stop_hook: false,
        titles: None,
        cache: Some(window(observed_at)),
    }
}

#[test]
fn a_finished_turn_records_its_cache_window_and_quiet_events_keep_it() {
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            finished_with(NOW),
            // A waiting-for-input event neither starts nor ends work, so
            // the window still describes the cache.
            AgentEvent::WaitingForInput { detail: None },
        ],
    );
    assert_eq!(record.cache_window, Some(window(NOW)));
    let encoded = String::from_utf8(record.encode().expect("encodes")).expect("utf8");
    assert!(encoded.contains("\"cacheWindow\":{"));

    // The next turn's window replaces it, and a turn that could not read
    // one leaves the cache unknown rather than reusing the old numbers.
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            finished_with(NOW),
            prompt("second"),
            finished_with(LATER),
        ],
    );
    assert_eq!(record.cache_window, Some(window(LATER)));
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            finished_with(NOW),
            AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: None,
                cache: None,
            },
        ],
    );
    assert_eq!(record.cache_window, None);
}

#[test]
fn a_failure_sets_the_usage_limit_and_the_next_failure_replaces_it() {
    let limit = limpid_agent_model::UsageLimit {
        resets_at: Some("2026-09-14T15:00:00Z".to_owned()),
        window: Some("five_hour".to_owned()),
    };
    let limited = AgentEvent::Failed {
        error: "rate_limit".into(),
        usage_limit: Some(limit.clone()),
    };
    let (record, _, _) = run(&claude(), &[started(None), prompt("go"), limited.clone()]);
    assert_eq!(record.state, RunState::Error);
    assert_eq!(record.usage_limit, Some(limit));
    let encoded = String::from_utf8(record.encode().expect("encodes")).expect("utf8");
    assert!(encoded.contains("\"usageLimit\":{"));

    let other = AgentEvent::Failed {
        error: "server_error".into(),
        usage_limit: None,
    };
    let (record, _, _) = run(&claude(), &[started(None), prompt("go"), limited, other]);
    assert_eq!(record.usage_limit, None);
}

#[test]
fn every_event_that_starts_or_ends_work_clears_the_cache_window() {
    let (finished, _, _) = run(&claude(), &[started(None), prompt("p"), finished_with(NOW)]);
    assert!(finished.cache_window.is_some());
    let clearing = [
        prompt("next"),
        started(None),
        AgentEvent::SessionStarted {
            compact: true,
            source: Some(SessionSource::Compact),
            session_id: Some("session-1".into()),
            session_title: None,
            cwd: None,
        },
        AgentEvent::SessionEnded {
            reason: Some("exit".into()),
            session_id: Some("session-1".into()),
        },
        AgentEvent::Compacting {
            context_tokens: Some(1),
        },
        AgentEvent::CompactionFinished,
        AgentEvent::Failed {
            error: "server_error".into(),
            usage_limit: None,
        },
        AgentEvent::Interrupted,
    ];
    for event in &clearing {
        let next = apply(Some(&finished), event, &context(), &claude(), LATER)
            .run
            .expect("record");
        assert_eq!(next.cache_window, None, "{event:?} must clear the window");
        assert_eq!(next.revision, finished.revision.map(|it| it + 1));
    }
}

#[test]
fn session_end_without_the_snapshot_capability_removes_nothing() {
    let (record, _, _) = run(&claude(), &[started(None), prompt("first")]);
    let writes = apply(
        Some(&record),
        &AgentEvent::SessionEnded {
            reason: Some("exit".into()),
            session_id: None,
        },
        &context(),
        &ProviderDescriptor::fixture("claude", [Capability::Resume]),
        LATER,
    );
    assert_eq!(writes.snapshot, None);
    assert_eq!(writes.run.expect("record").state, RunState::Unknown);
}

#[test]
fn session_end_keeps_prompts_drops_the_hint_and_removes_the_snapshot() {
    let (mut record, _, _) = run(&claude(), &[started(None), prompt("first")]);
    record.turn_base_tree = Some("abc".into());
    record.turn_root = Some("/repo".into());
    let writes = apply(
        Some(&record),
        &AgentEvent::SessionEnded {
            reason: Some("prompt_input_exit".into()),
            session_id: Some("session-1".into()),
        },
        &context(),
        &claude(),
        LATER,
    );
    let ended = writes.run.expect("record");
    assert_eq!(ended.state, RunState::Unknown);
    assert_eq!(ended.first_prompt.as_deref(), Some("first"));
    assert_eq!(ended.session_started_at.as_deref(), Some(NOW));
    assert_eq!(ended.turn_base_tree, None);
    assert_eq!(
        writes.snapshot,
        Some(TurnSnapshotOp::Remove {
            cwd: Some("/repo".into())
        })
    );
    assert_eq!(
        writes.side,
        vec![SideWrite::DeleteSessionHint {
            session_id: "session-1".into()
        }]
    );

    // A signal keeps the hint for auto-resume.
    let writes = apply(
        Some(&record),
        &AgentEvent::SessionEnded {
            reason: Some("other".into()),
            session_id: Some("session-1".into()),
        },
        &context(),
        &claude(),
        LATER,
    );
    assert!(writes.side.is_empty());

    // Codex never drops the hint because `/quit` reports `other`.
    let writes = apply(
        Some(&record),
        &AgentEvent::SessionEnded {
            reason: Some("exit".into()),
            session_id: Some("session-1".into()),
        },
        &context(),
        &codex(),
        LATER,
    );
    assert!(writes.side.is_empty());
}

#[test]
fn compaction_keeps_the_opening_prompt_and_generated_title() {
    let (record, _, _) = run(
        &claude(),
        &[
            started(Some("Formal")),
            AgentEvent::PromptSubmitted {
                prompt: "first".into(),
                titles: Some(Titles {
                    session_title: None,
                    generated_title: Some("Generated".into()),
                }),
                cwd: None,
            },
            AgentEvent::Compacting {
                context_tokens: Some(120_000),
            },
        ],
    );
    assert_eq!(record.state, RunState::Compacting);
    assert_eq!(record.context_tokens, Some(120_000));
    assert_eq!(record.run_started_at.as_deref(), Some(NOW));

    let restarted = apply(
        Some(&record),
        &AgentEvent::SessionStarted {
            compact: true,
            source: Some(SessionSource::Compact),
            session_id: Some("session-1".into()),
            session_title: None,
            cwd: None,
        },
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    // The compaction came mid-turn, so the turn goes on.
    assert_eq!(restarted.state, RunState::Running);
    assert_eq!(restarted.run_started_at.as_deref(), Some(NOW));
    assert_eq!(restarted.first_prompt.as_deref(), Some("first"));
    assert_eq!(restarted.last_prompt, None);
    assert_eq!(restarted.provider_session_title.as_deref(), Some("Formal"));
    assert_eq!(
        restarted.provider_generated_title.as_deref(),
        Some("Generated")
    );
    assert_eq!(restarted.session_started_at.as_deref(), Some(LATER));
    // The token count is not carried; only the event that reports it sets it.
    assert_eq!(restarted.context_tokens, None);

    let fresh = apply(
        Some(&restarted),
        &started(None),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(fresh.first_prompt, None);
    assert_eq!(fresh.provider_generated_title, None);
    assert_eq!(fresh.provider_session_title, None);
}

#[test]
fn codex_compaction_and_interrupt_return_to_a_settled_state() {
    let (record, _, _) = run(
        &codex(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::Compacting {
                context_tokens: None,
            },
            AgentEvent::CompactionFinished,
        ],
    );
    assert_eq!(record.state, RunState::Running);
    let interrupted = apply(
        Some(&record),
        &AgentEvent::Interrupted,
        &context(),
        &codex(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(interrupted.state, RunState::Finished);
    assert_eq!(interrupted.run_started_at, None);
    assert_eq!(interrupted.first_prompt.as_deref(), Some("first"));
}

#[test]
fn episode_token_survives_repeated_states_and_changes_with_the_state() {
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::WaitingForInput {
                detail: Some("Which color?".into()),
            },
            AgentEvent::WaitingForInput {
                detail: Some("Which color?".into()),
            },
        ],
    );
    assert_eq!(record.revision, Some(4));
    assert_eq!(record.state_episode_token.as_deref(), Some("3"));
    let finished = apply(
        Some(&record),
        &AgentEvent::TurnFinished {
            continues_after_stop_hook: false,
            titles: None,
            cache: None,
        },
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(finished.state_episode_token.as_deref(), Some("5"));
}

#[test]
fn tmux_hosting_marks_the_record_and_withholds_the_hint() {
    let context = ApplyContext {
        tmux: Some(TmuxEndpoint {
            socket_path: "/tmp/tmux-501/limpid".into(),
            pane: "%3".into(),
            server_pid: 777,
            server_started_at: Some(1_700_000_000),
        }),
        is_tmux_hosted: true,
        pid: None,
        ..self::context()
    };
    let writes = apply(None, &started(None), &context, &claude(), NOW);
    let record = writes.run.expect("record");
    assert_eq!(record.is_tmux_hosted, Some(true));
    assert_eq!(
        record.tmux_socket_path.as_deref(),
        Some("/tmp/tmux-501/limpid")
    );
    assert_eq!(record.tmux_pane_id.as_deref(), Some("%3"));
    assert_eq!(record.tmux_server_pid.as_deref(), Some("777"));
    assert_eq!(record.tmux_server_started_at.as_deref(), Some("1700000000"));
    assert_eq!(record.pid, None);
    assert!(writes.side.is_empty());
}

#[test]
fn side_only_events_write_no_record() {
    let cwd = AgentEvent::CwdChanged {
        new_cwd: "/repo/.git".into(),
        old_cwd: Some("/repo".into()),
    };
    let writes = apply(None, &cwd, &context(), &claude(), NOW);
    assert_eq!(writes.run, None);
    assert_eq!(
        writes.side,
        vec![SideWrite::CwdEvent {
            new_cwd: "/repo/.git".into(),
            old_cwd: Some("/repo".into())
        }]
    );
    assert_eq!(
        apply(None, &cwd, &context(), &codex(), NOW),
        RecordWrites::default()
    );
    let extension = AgentEvent::Extension {
        name: "Notification".into(),
        payload: serde_json::json!({}),
    };
    assert_eq!(
        apply(None, &extension, &context(), &claude(), NOW),
        RecordWrites::default()
    );
}

#[test]
fn titles_are_sanitized_and_absent_observations_keep_the_previous_value() {
    let (record, _, _) = run(
        &claude(),
        &[
            started(Some("  Safe\u{202e}\n\t title\u{200b}  ")),
            AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: None,
                cache: None,
            },
            AgentEvent::TurnFinished {
                continues_after_stop_hook: false,
                titles: Some(Titles {
                    session_title: None,
                    generated_title: Some("Gen\u{7}erated".into()),
                }),
                cache: None,
            },
        ],
    );
    assert_eq!(record.provider_session_title.as_deref(), Some("Safe title"));
    assert_eq!(
        record.provider_generated_title.as_deref(),
        Some("Generated")
    );
}

#[test]
fn prompts_keep_line_breaks_but_are_bounded_and_cleaned() {
    let long = format!(
        "line one\nline\u{202e} two{}",
        "x".repeat(MAX_RECORD_TEXT_BYTES)
    );
    let writes = apply(None, &prompt(&long), &context(), &claude(), NOW);
    let record = writes.run.expect("record");
    let stored = record.last_prompt.expect("prompt");
    assert!(stored.starts_with("line one\nline two"));
    assert_eq!(stored.len(), MAX_RECORD_TEXT_BYTES);
    assert_eq!(sanitize_text("\u{1F600}\u{9f}ok"), "\u{1F600}ok");
}

#[test]
fn detail_belongs_to_one_event_only() {
    let (record, _, _) = run(
        &claude(),
        &[
            started(None),
            prompt("first"),
            AgentEvent::Failed {
                error: "server_error".into(),
                usage_limit: None,
            },
            prompt("second"),
        ],
    );
    assert_eq!(
        record.detail, None,
        "a new prompt does not show the previous error"
    );
    let compacting = apply(
        Some(&record),
        &AgentEvent::Compacting {
            context_tokens: None,
        },
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(compacting.detail, None);
}

#[test]
fn hostile_session_ids_never_become_hints() {
    let event = AgentEvent::SessionStarted {
        compact: false,
        source: Some(SessionSource::Startup),
        session_id: Some("bad\"id".into()),
        session_title: None,
        cwd: None,
    };
    let writes = apply(None, &event, &context(), &claude(), NOW);
    assert!(writes.side.is_empty());
    assert_eq!(
        writes.run.expect("record").session_id.as_deref(),
        Some("bad\"id")
    );
}

#[test]
fn version_two_records_are_continued_with_a_higher_revision() {
    let previous = RunRecord::decode(
        br#"{"schemaVersion":2,"paneId":"P","state":"running","detail":"","runStartedAt":"2026-09-13T00:00:00Z","updatedAt":"2026-09-13T00:00:00Z","lastHookEvent":"UserPromptSubmit","lastPrompt":"old","firstPrompt":"old","revision":7,"stateEpisodeToken":"6","runId":"R","legacyField":1}"#,
    )
    .expect("decodes");
    let writes = apply(
        Some(&previous),
        &AgentEvent::TurnFinished {
            continues_after_stop_hook: false,
            titles: None,
            cache: None,
        },
        &context(),
        &claude(),
        NOW,
    );
    let record = writes.run.expect("record");
    assert_eq!(record.revision, Some(8));
    assert_eq!(record.state_episode_token.as_deref(), Some("8"));
    assert_eq!(record.first_prompt.as_deref(), Some("old"));
    assert_eq!(record.extra.get("legacyField"), Some(&serde_json::json!(1)));
    assert_eq!(record.run_id.as_deref(), Some(context().run_id.as_str()));
}

#[test]
fn version_two_text_is_cleaned_and_bounded_when_the_writer_changes() {
    let oversized_prompt = format!("old\u{202e}{}", "x".repeat(MAX_RECORD_TEXT_BYTES));
    let oversized_detail = format!("command\u{202e}{}", "y".repeat(MAX_RECORD_TEXT_BYTES));
    let previous = serde_json::json!({
        "schemaVersion": 2,
        "paneId": "P",
        "state": "running",
        "detail": oversized_detail,
        "runStartedAt": "2026-09-13T00:00:00Z",
        "updatedAt": "2026-09-13T00:00:00Z",
        "lastHookEvent": "PreToolUse",
        "lastPrompt": oversized_prompt,
        "firstPrompt": "opening\u{202e} prompt",
        "providerSessionTitle": "Title\nline\u{202e}",
        "providerGeneratedTitle": "Generated\u{7} title",
        "revision": 7,
        "runId": "R"
    });
    let previous =
        RunRecord::decode(&serde_json::to_vec(&previous).expect("encodes")).expect("decodes");
    let record = apply(
        Some(&previous),
        &AgentEvent::ApprovalRequested {
            detail: Some("generic approval".into()),
        },
        &context(),
        &claude(),
        NOW,
    )
    .run
    .expect("record");

    let last_prompt = record.last_prompt.expect("last prompt");
    assert_eq!(last_prompt.len(), MAX_RECORD_TEXT_BYTES);
    assert!(!last_prompt.contains('\u{202e}'));
    let detail = record.detail.expect("detail");
    assert_eq!(detail.len(), MAX_RECORD_TEXT_BYTES);
    assert!(!detail.contains('\u{202e}'));
    assert_eq!(record.first_prompt.as_deref(), Some("opening prompt"));
    assert_eq!(record.provider_session_title.as_deref(), Some("Title line"));
    assert_eq!(
        record.provider_generated_title.as_deref(),
        Some("Generated title")
    );
}

#[test]
fn a_first_prompt_the_harness_wrote_gives_way_to_the_persons() {
    let notification = "<task-notification>\n<task-id>b1</task-id>";
    let first = apply(None, &prompt(notification), &context(), &claude(), NOW)
        .run
        .expect("record");
    assert_eq!(first.first_prompt.as_deref(), Some(notification));
    let second = apply(
        Some(&first),
        &prompt("fix the login"),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(second.first_prompt.as_deref(), Some("fix the login"));
    // Once the person's words name it, a later prompt does not.
    let third = apply(
        Some(&second),
        &prompt(notification),
        &context(),
        &claude(),
        LATER,
    )
    .run
    .expect("record");
    assert_eq!(third.first_prompt.as_deref(), Some("fix the login"));
    assert_eq!(third.last_prompt.as_deref(), Some(notification));
}

#[test]
fn a_stopped_turn_ends_in_the_episode_the_person_stopped_and_keeps_the_rest() {
    let named = ApplyContext {
        transcript_path: Some("/t/session.jsonl".into()),
        ..context()
    };
    let (asked, _, _) = run(&claude(), &[started(None), prompt("go")]);
    let waiting = apply(
        Some(&asked),
        &AgentEvent::WaitingForInput {
            detail: Some("Which color?".into()),
        },
        &named,
        &claude(),
        NOW,
    )
    .run
    .expect("record");
    let ended = end_stopped_turn(&waiting, LATER).expect("a wait inside a turn ends");
    assert_eq!(ended.state, RunState::Finished);
    assert_eq!(ended.run_started_at, None);
    assert_eq!(ended.wait_kind, None);
    assert_eq!(ended.detail, None);
    assert_eq!(ended.transcript_path, None);
    assert_eq!(ended.cache_window, None);
    assert_eq!(ended.updated_at, LATER);
    assert_eq!(
        ended.revision,
        waiting.revision.map(|revision| revision + 1)
    );
    // The badge already showed this finish in the wait's episode.
    assert_eq!(ended.state_episode_token, waiting.state_episode_token);
    // No hook call is behind the write, so who the run is stays as it was.
    assert_eq!(ended.pid, waiting.pid);
    assert_eq!(ended.session_id, waiting.session_id);
    assert_eq!(ended.last_prompt, waiting.last_prompt);

    assert_eq!(ended.last_hook_event.as_deref(), Some("wait_declined"));

    // Work in a turn ends the same way, when the person stopped it with Esc
    // or Ctrl+C.
    assert_eq!(asked.state, RunState::Running);
    let interrupted = end_stopped_turn(&asked, LATER).expect("work inside a turn ends");
    assert_eq!(interrupted.state, RunState::Finished);
    assert_eq!(interrupted.run_started_at, None);
    assert_eq!(interrupted.tool, None);
    assert_eq!(interrupted.state_episode_token, asked.state_episode_token);
    assert_eq!(interrupted.last_hook_event.as_deref(), Some("interrupted"));

    // Only work or a wait inside a turn ends this way, since the projection
    // reads no other as stopped.
    assert_eq!(end_stopped_turn(&ended, LATER), None);
    let outside = RunRecord {
        run_started_at: None,
        ..waiting
    };
    assert_eq!(end_stopped_turn(&outside, LATER), None);
}
