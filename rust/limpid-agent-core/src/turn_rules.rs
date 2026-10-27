//! Turn records: which events open and close a turn, and the record each one
//! writes. The rules are pure; the runtime runs git, takes the counter lock,
//! and writes the files (`limpid-agent-hook`'s `turn` module).

use crate::lifecycle::IdleOutcome;
use limpid_agent_model::{
    AgentEvent, Capability, ChangeSummary, CheckResult, ConversationKey, DiffStat, EventId,
    GitContext, PromptKind, ProviderDescriptor, ProviderId, RecordedPromptKind, RunRecord,
    RunState, SkippedFile, SnapshotStatus, TurnPhase, TurnRecord, TurnUsage, classify_prompt,
    seconds_between,
};
use std::collections::BTreeMap;

/// Longest prompt head kept on a turn record, in characters: enough to name
/// the turn in a list, short enough that a pasted file is not copied.
pub const PROMPT_HEAD_CHARS: usize = 80;

/// What an event does to the run's turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TurnStep {
    /// A prompt was submitted: a new turn begins.
    Begin,
    /// The turn ended this way. Every ending takes the end snapshot, so a
    /// failed or interrupted turn still says what it changed.
    /// `continues_ended_turn` is set when the provider says the turn went on
    /// after another stop hook held it (`stop_hook_active`): this end then
    /// replaces the earlier one.
    End {
        phase: TurnPhase,
        continues_ended_turn: bool,
    },
    /// The ended turn went on without saying so (work after its `Stop`):
    /// its end snapshot and difference are taken again, and the way it
    /// ended (finished, failed, interrupted) stays as it was.
    Retake,
}

/// The step `event` takes, for a provider that records turns (the same
/// capability that takes snapshots); `None` for every other event. `prev`
/// is the run record before the event and `now` its time: the agent idle at
/// its prompt ends what the record shows at work (`lifecycle::idle_outcome`),
/// so the turn record ends the same thing the run record does.
#[must_use]
pub fn turn_step(
    event: &AgentEvent,
    descriptor: &ProviderDescriptor,
    prev: Option<&RunRecord>,
    now: &str,
) -> Option<TurnStep> {
    if !descriptor.has(Capability::TurnSnapshot) {
        return None;
    }
    match event {
        AgentEvent::AwaitingPrompt { awaited_call_ended } => {
            match crate::lifecycle::idle_outcome(prev, *awaited_call_ended, now)? {
                // Work after the turn's `Stop` is the turn's: its end snapshot is
                // taken again, and it keeps how it ended. Work that began
                // at the prompt after a session start has no turn of its own.
                IdleOutcome::EndsOutsideWork => {
                    (prev?.outside_turn_rest != Some(RunState::Idle)).then_some(TurnStep::Retake)
                }
                IdleOutcome::EndsStoppedTurn => Some(end(TurnPhase::Interrupted)),
            }
        }
        AgentEvent::PromptSubmitted { .. } => Some(TurnStep::Begin),
        AgentEvent::TurnFinished {
            continues_after_stop_hook,
            ..
        } => Some(TurnStep::End {
            phase: TurnPhase::Finished,
            continues_ended_turn: *continues_after_stop_hook,
        }),
        AgentEvent::Failed { .. } => Some(end(TurnPhase::Failed)),
        AgentEvent::Interrupted => Some(end(TurnPhase::Interrupted)),
        _ => None,
    }
}

fn end(phase: TurnPhase) -> TurnStep {
    TurnStep::End {
        phase,
        continues_ended_turn: false,
    }
}

/// The identity a turn records for event `index` of one hook call. The call
/// is what the shim retries, so its id is the base; a call that yields more
/// than one event gives each after the first its own suffix, so the second is
/// not taken for a repeat of the first.
#[must_use]
pub fn event_id_for(call: Option<&EventId>, index: usize) -> Option<EventId> {
    let call = call?;
    if index == 0 {
        Some(call.clone())
    } else {
        Some(EventId::indexed(call, index))
    }
}

/// The conversation a run's turns belong to: the provider's session when the
/// run has reported one, else the run itself, marked as a fallback.
#[must_use]
pub fn conversation_of(
    provider: &ProviderId,
    record: Option<&RunRecord>,
    run_id: &str,
) -> ConversationKey {
    match record
        .and_then(|record| record.session_id.as_deref())
        .filter(|id| !id.is_empty())
    {
        Some(session_id) => ConversationKey {
            provider: provider.clone(),
            conversation_id: session_id.to_owned(),
            is_fallback: false,
        },
        None => ConversationKey {
            provider: provider.clone(),
            conversation_id: run_id.to_owned(),
            is_fallback: true,
        },
    }
}

/// Who wrote the prompt, judged from the whole of it (`classify_prompt`),
/// and its first characters on one line: the person's words without the
/// harness blocks that led them, however long those were, or a prompt the
/// harness wrote as it came. Judged here rather than from the head, which a
/// long reminder would fill before the person's words begin. `None` for the
/// head, and so for the kind, when the prompt has no words.
#[must_use]
pub fn prompt_head(prompt: &str) -> (Option<PromptKind>, Option<String>) {
    let (kind, words) = classify_prompt(prompt);
    let shown = if kind == PromptKind::Text {
        words
    } else {
        prompt
    };
    let line = shown.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.is_empty() {
        return (None, None);
    }
    (
        Some(kind),
        Some(line.chars().take(PROMPT_HEAD_CHARS).collect()),
    )
}

/// A snapshot as the runtime took it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SnapshotTaken {
    pub status: SnapshotStatus,
    pub skipped: Vec<SkippedFile>,
    pub git_context: Option<GitContext>,
}

/// What a new turn starts from.
pub struct TurnStart<'a> {
    pub turn_id: String,
    pub conversation: ConversationKey,
    pub run_id: &'a str,
    pub pane_id: &'a str,
    pub display_number: u32,
    pub prompt: &'a str,
    pub now: &'a str,
    pub begin: SnapshotTaken,
    pub event: &'a EventId,
    /// The provider's own id for the turn (`TurnRecord::provider_turn_id`).
    pub provider_turn_id: Option<String>,
}

/// The record a submitted prompt writes.
#[must_use]
pub fn begin_record(start: TurnStart<'_>) -> TurnRecord {
    let (prompt_kind, prompt_head) = prompt_head(start.prompt);
    let mut record = TurnRecord {
        schema_version: TurnRecord::SCHEMA_VERSION,
        turn_id: start.turn_id,
        provider: start.conversation.provider.clone(),
        conversation: start.conversation,
        run_id: start.run_id.to_owned(),
        pane_id: start.pane_id.to_owned(),
        display_number: start.display_number,
        prompt_head,
        prompt_kind: prompt_kind.map(RecordedPromptKind::Known),
        started_at: start.now.to_owned(),
        finished_at: None,
        phase: TurnPhase::Started,
        git_context: start.begin.git_context,
        begin: start.begin.status,
        end: SnapshotStatus::Pending,
        skipped_begin: start.begin.skipped,
        skipped_end: Vec::new(),
        changes: ChangeSummary::Pending,
        duration_seconds: None,
        added_bytes: None,
        applied_events: Vec::new(),
        last_check: None,
        checks: Vec::new(),
        check_count: 0,
        failure_count: 0,
        are_checks_partial: false,
        provider_turn_id: start.provider_turn_id,
        usage: None,
        extra: BTreeMap::new(),
        was_decoded_lossily: false,
    };
    // A new record has applied nothing yet; the result is always `Applied`.
    let _ = record.apply_event(Some(start.event));
    record
}

/// The record an end writes when the run has no turn to end: the hook
/// missed the prompt, or the run began before this build recorded turns. The
/// begin is `Pending`, so the turn reads as incomplete (`beginMissing`)
/// rather than as one that changed nothing, and it has no duration.
#[must_use]
pub fn end_only_record(start: TurnStart<'_>, end: TurnEnd<'_>) -> TurnRecord {
    end_record(&begin_record(start), end)
}

/// How a turn ended.
pub struct TurnEnd<'a> {
    pub phase: TurnPhase,
    pub now: &'a str,
    pub end: SnapshotTaken,
    /// The difference between the begin and end trees; `None` when it could
    /// not be taken.
    pub diff: Option<DiffStat>,
    /// What the turn used, read from the transcript as it ended; `None`
    /// keeps what the record held.
    pub usage: Option<TurnUsage>,
    /// Every check the turn ran, for a provider that reports them only at
    /// the end; `None` keeps the checks recorded as they ran.
    pub checks: Option<Vec<CheckResult>>,
    /// Whether `checks` may leave out the turn's first runs, the turn's
    /// start gone from the part of the transcript read.
    pub are_checks_partial: bool,
}

/// The record with its ending filled in, judged from both snapshots.
#[must_use]
pub fn end_record(previous: &TurnRecord, end: TurnEnd<'_>) -> TurnRecord {
    let mut record = previous.clone();
    record.phase = end.phase;
    record.finished_at = Some(end.now.to_owned());
    record.end = end.end.status;
    record.skipped_end = end.end.skipped;
    // A turn with no begin started when its first end was written, so the
    // time since then is not how long it took, however often it ends again.
    record.duration_seconds = if record.begin == SnapshotStatus::Pending {
        None
    } else {
        seconds_between(&record.started_at, end.now)
    };
    record.added_bytes = end.diff.and_then(|diff| diff.added_bytes);
    // A later end of the same turn reads again from where the turn began,
    // so a whole reading holds the earlier one. A partial one may hold
    // less: the turn went on past the first end, and its start left the
    // part of the transcript read. Each count is then the larger of the
    // two, and both readings short of the whole, so it says so.
    if let Some(usage) = end.usage {
        record.usage = Some(match record.usage {
            Some(known) if usage.is_partial => known.fuller(usage),
            _ => usage,
        });
    }
    // A partial list of checks never replaces a longer one; the turn then
    // ran more than either says.
    if let Some(checks) = end.checks {
        let is_longer = u32::try_from(checks.len()).is_ok_and(|count| count >= record.check_count);
        if !end.are_checks_partial {
            record.set_checks(checks);
        } else if is_longer {
            // The failures the start of the turn held, which the partial
            // list no longer does, are still the turn's.
            let failures = record.failure_count;
            record.set_checks(checks);
            record.failure_count = record.failure_count.max(failures);
        }
        record.are_checks_partial = end.are_checks_partial;
    }
    record.changes = ChangeSummary::judge(
        record.phase,
        &record.begin,
        &record.end,
        &record.skipped_begin,
        &record.skipped_end,
        end.diff,
    );
    record
}

#[cfg(test)]
mod tests {
    use super::*;
    use limpid_agent_model::ProviderId;
    use uuid::Uuid;

    fn descriptor(capabilities: &[Capability]) -> ProviderDescriptor {
        ProviderDescriptor::fixture("claude", capabilities.iter().copied())
    }

    fn captured(tree: &str) -> SnapshotTaken {
        SnapshotTaken {
            status: SnapshotStatus::Captured {
                tree: tree.to_owned(),
                root: "/repo".to_owned(),
            },
            skipped: Vec::new(),
            git_context: None,
        }
    }

    fn start(begin: SnapshotTaken, event: &EventId) -> TurnRecord {
        begin_record(TurnStart {
            turn_id: "T".to_owned(),
            conversation: ConversationKey {
                provider: ProviderId::new("claude").expect("id"),
                conversation_id: "s".to_owned(),
                is_fallback: false,
            },
            run_id: "R",
            pane_id: "P",
            display_number: 3,
            prompt: "  add   the\n\ttests  ",
            now: "2026-10-12T00:00:00Z",
            begin,
            event,
            provider_turn_id: None,
        })
    }

    #[test]
    fn every_ending_is_a_step_and_only_for_a_provider_that_records_turns() {
        let records = descriptor(&[Capability::TurnSnapshot]);
        assert_eq!(
            turn_step(&AgentEvent::Interrupted, &records, None, NOW),
            Some(end(TurnPhase::Interrupted))
        );
        assert_eq!(
            turn_step(
                &AgentEvent::Failed {
                    error: "x".into(),
                    usage_limit: None
                },
                &records,
                None,
                NOW
            ),
            Some(end(TurnPhase::Failed))
        );
        assert_eq!(
            turn_step(
                &AgentEvent::TurnFinished {
                    continues_after_stop_hook: true,
                    titles: None,
                    cache: None,
                },
                &records,
                None,
                NOW
            ),
            Some(TurnStep::End {
                phase: TurnPhase::Finished,
                continues_ended_turn: true
            }),
            "a stop after a stop hook says it continues the turn"
        );
        assert_eq!(
            turn_step(&AgentEvent::CompactionFinished, &records, None, NOW),
            None
        );
        assert_eq!(
            turn_step(&AgentEvent::Interrupted, &descriptor(&[]), None, NOW),
            None
        );
    }

    const NOW: &str = "2026-09-14T00:01:00Z";

    fn record(json: &str) -> RunRecord {
        RunRecord::decode(json.as_bytes()).expect("record")
    }

    #[test]
    fn the_idle_prompt_ends_what_the_run_record_shows_at_work() {
        let records = descriptor(&[Capability::TurnSnapshot]);
        let idle_with = |prev: &RunRecord, awaited_call_ended: bool| {
            turn_step(
                &AgentEvent::AwaitingPrompt { awaited_call_ended },
                &records,
                Some(prev),
                NOW,
            )
        };
        let idle = |prev: &RunRecord| idle_with(prev, false);
        // Work after the turn's `Stop` takes that turn's end again, keeping
        // how it ended.
        let after_stop = record(
            r#"{"schemaVersion":3,"paneId":"P","state":"running","updatedAt":"t","outsideTurnRest":"finished"}"#,
        );
        assert_eq!(idle(&after_stop), Some(TurnStep::Retake));
        // Work from the prompt after a session start has no turn.
        let from_idle = record(
            r#"{"schemaVersion":3,"paneId":"P","state":"running","updatedAt":"t","outsideTurnRest":"idle"}"#,
        );
        assert_eq!(idle(&from_idle), None);
        // A turn open for a minute stopped without a `Stop`; one just begun
        // has not sat idle yet.
        let open = record(
            r#"{"schemaVersion":3,"paneId":"P","state":"compacting","updatedAt":"t","runStartedAt":"2026-09-14T00:00:00Z"}"#,
        );
        assert_eq!(idle(&open), Some(end(TurnPhase::Interrupted)));
        let young = record(
            r#"{"schemaVersion":3,"paneId":"P","state":"running","updatedAt":"t","runStartedAt":"2026-09-14T00:00:30Z"}"#,
        );
        assert_eq!(idle(&young), None);
        // A run at rest has nothing for it to end.
        let finished =
            record(r#"{"schemaVersion":3,"paneId":"P","state":"finished","updatedAt":"t"}"#);
        assert_eq!(idle(&finished), None);
        assert_eq!(idle_with(&finished, true), None);
        // A wait whose call the transcript shows declined ended the turn
        // with the Esc; one still open is a person yet to answer.
        let waiting = record(
            r#"{"schemaVersion":3,"paneId":"P","state":"needsInput","updatedAt":"t","waitKind":"question","runStartedAt":"2026-09-14T00:00:00Z"}"#,
        );
        assert_eq!(idle_with(&waiting, true), Some(end(TurnPhase::Interrupted)));
        assert_eq!(idle_with(&waiting, false), None);
        assert_eq!(
            turn_step(
                &AgentEvent::AwaitingPrompt {
                    awaited_call_ended: false
                },
                &records,
                None,
                NOW
            ),
            None
        );
    }

    #[test]
    fn the_second_event_of_one_call_has_an_id_of_its_own() {
        let call = EventId::invocation(&ProviderId::new("claude").expect("id"), Uuid::from_u128(1));
        let first = event_id_for(Some(&call), 0).expect("id");
        let second = event_id_for(Some(&call), 1).expect("id");
        assert_eq!(first, call);
        assert_ne!(second, first);
        assert_eq!(
            event_id_for(Some(&call), 1),
            Some(second),
            "and the same on a retry"
        );
        assert_eq!(event_id_for(None, 0), None);
    }

    #[test]
    fn a_run_without_a_session_is_its_own_conversation() {
        let provider = descriptor(&[]);
        let fallback = conversation_of(&provider.id, None, "R1");
        assert!(fallback.is_fallback);
        assert_eq!(fallback.conversation_id, "R1");
        let mut record = RunRecord::decode(
            br#"{"schemaVersion":3,"paneId":"P","runId":"R1","state":"running","updatedAt":"2026-10-12T00:00:00Z","sessionId":"s1"}"#,
        )
        .expect("record");
        assert_eq!(record.state, RunState::Running);
        assert_eq!(
            conversation_of(&provider.id, Some(&record), "R1").conversation_id,
            "s1"
        );
        record.session_id = Some(String::new());
        assert!(conversation_of(&provider.id, Some(&record), "R1").is_fallback);
    }

    #[test]
    fn a_turn_ends_judged_with_its_duration() {
        let event =
            EventId::invocation(&ProviderId::new("claude").expect("id"), Uuid::from_u128(1));
        let begun = start(captured("a"), &event);
        assert_eq!(begun.prompt_head.as_deref(), Some("add the tests"));
        assert_eq!(
            begun.prompt_kind,
            Some(RecordedPromptKind::Known(PromptKind::Text))
        );
        assert_eq!(begun.applied_events, vec![event.as_str().to_owned()]);
        assert_eq!(begun.changes, ChangeSummary::Pending);

        let ended = end_record(
            &begun,
            TurnEnd {
                phase: TurnPhase::Interrupted,
                now: "2026-10-12T00:01:30Z",
                end: captured("b"),
                diff: Some(DiffStat {
                    files: 1,
                    added: 2,
                    removed: 0,
                    has_shell_changes: false,
                    added_bytes: Some(10),
                }),
                usage: None,
                checks: None,
                are_checks_partial: false,
            },
        );
        assert_eq!(ended.phase, TurnPhase::Interrupted);
        assert_eq!(ended.duration_seconds, Some(90));
        assert!(
            matches!(ended.changes, ChangeSummary::Changed { files: 1, .. }),
            "an interrupted turn still says what it changed"
        );
    }

    #[test]
    fn the_prompt_head_is_one_line_of_at_most_eighty_characters() {
        let long = "あ".repeat(PROMPT_HEAD_CHARS + 5);
        let (kind, head) = prompt_head(&long);
        let head = head.expect("head");
        assert_eq!(kind, Some(PromptKind::Text));
        assert_eq!(
            head.chars().count(),
            PROMPT_HEAD_CHARS,
            "counted in characters, not bytes"
        );
        assert_eq!(prompt_head(" \n\t "), (None, None));
    }

    #[test]
    fn the_head_after_a_long_reminder_is_the_persons_words() {
        let reminder = format!(
            "<system-reminder>\n{}\n</system-reminder>\n",
            "The user opened a file in the IDE. ".repeat(10)
        );
        let (kind, head) = prompt_head(&(reminder.clone() + "add  the\ntests"));
        assert_eq!(kind, Some(PromptKind::Text));
        assert_eq!(head.as_deref(), Some("add the tests"));
        // A reminder with nothing after it is the harness's, kept as it came.
        let (kind, head) = prompt_head(&reminder);
        assert_eq!(kind, Some(PromptKind::Injected));
        assert!(
            head.expect("head")
                .starts_with("<system-reminder> The user")
        );
    }

    #[test]
    fn a_prompt_the_harness_wrote_keeps_its_head_as_it_came() {
        let (kind, head) = prompt_head("<task-notification>\n<task-id>b1</task-id>");
        assert_eq!(kind, Some(PromptKind::BackgroundTask));
        assert_eq!(
            head.as_deref(),
            Some("<task-notification> <task-id>b1</task-id>")
        );
    }

    /// A turn whose begin left nothing to diff against still finishes, and
    /// says why its changes are unknown: the begin never landed
    /// (`beginMissing`), or the turn ran outside a repository (`notGit`).
    #[test]
    fn a_turn_with_no_begin_to_diff_finishes_with_the_reason() {
        let event =
            EventId::invocation(&ProviderId::new("claude").expect("id"), Uuid::from_u128(1));
        let taken = |status| SnapshotTaken {
            status,
            skipped: Vec::new(),
            git_context: None,
        };
        for (begin, end, reason) in [
            (SnapshotStatus::Pending, captured("b"), "beginMissing"),
            (
                SnapshotStatus::NotGit,
                taken(SnapshotStatus::NotGit),
                "notGit",
            ),
        ] {
            let begun = start(taken(begin), &event);
            let ended = end_record(
                &begun,
                TurnEnd {
                    phase: TurnPhase::Finished,
                    now: "2026-10-12T00:00:10Z",
                    end,
                    diff: None,
                    usage: None,
                    checks: None,
                    are_checks_partial: false,
                },
            );
            assert_eq!(ended.phase, TurnPhase::Finished, "{reason}");
            assert_eq!(
                ended.changes,
                ChangeSummary::Unavailable {
                    reason: reason.into()
                }
            );
        }
    }

    /// A continued stop reads the turn again: a whole reading replaces what
    /// the turn held; a partial one keeps the larger of each count and says
    /// it is short; a partial list of checks does not replace a longer one.
    #[test]
    fn a_later_end_keeps_the_fuller_reading() {
        let event =
            EventId::invocation(&ProviderId::new("claude").expect("id"), Uuid::from_u128(1));
        let usage = |input, output, is_partial| TurnUsage {
            input_tokens: input,
            output_tokens: output,
            is_partial,
            ..TurnUsage::default()
        };
        let check = |exit_code| CheckResult {
            command: "cargo test".into(),
            exit_code: Some(exit_code),
            is_filtered: false,
        };
        let end = |usage, checks, are_checks_partial| TurnEnd {
            phase: TurnPhase::Finished,
            now: "2026-10-12T00:00:10Z",
            end: captured("b"),
            diff: None,
            usage,
            checks,
            are_checks_partial,
        };
        let begun = start(captured("a"), &event);
        let first = end_record(
            &begun,
            end(
                Some(usage(5, 10, false)),
                Some(vec![check(1), check(0)]),
                false,
            ),
        );
        assert_eq!((first.check_count, first.failure_count), (2, 1));

        let partial = end_record(
            &first,
            end(Some(usage(3, 20, true)), Some(vec![check(0)]), true),
        );
        assert_eq!(partial.usage, Some(usage(5, 20, true)));
        assert_eq!(partial.check_count, 2);
        assert!(
            partial.are_checks_partial,
            "more ran than the record counts"
        );

        let longer = end_record(
            &first,
            end(None, Some(vec![check(0), check(0), check(0)]), true),
        );
        assert_eq!(
            (longer.check_count, longer.failure_count),
            (3, 1),
            "a failure the partial list lost is still counted"
        );

        let whole = end_record(
            &partial,
            end(
                Some(usage(9, 30, false)),
                Some(vec![check(1), check(0), check(0)]),
                false,
            ),
        );
        assert_eq!(whole.usage, Some(usage(9, 30, false)));
        assert_eq!((whole.check_count, whole.failure_count), (3, 1));
        assert!(!whole.are_checks_partial);

        let unread = end_record(&whole, end(None, None, false));
        assert_eq!(unread.usage, whole.usage);
        assert_eq!(unread.checks, whole.checks);
    }
}
