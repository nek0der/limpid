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

/// Longest reply head kept on a turn record, in characters: longer than the
/// prompt's, since a reply's first paragraph says what came of the turn and
/// is shown whole where there is room for it.
pub const REPLY_HEAD_CHARS: usize = 400;

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

/// The first paragraph of the agent's last reply that has words, on one
/// line, without the Markdown that marks it up. The stop carries only the
/// message the agent ended on, after the tools it ran, which tends to open
/// with what came of the turn; a heading over it, a code block, or a rule
/// says nothing on its own and is passed over. A list reads as its items,
/// joined with " · ". A paragraph that ends in a colon only leads into the
/// next ("Three problems, most serious first:"), so the next follows it.
/// `None` when no paragraph has words (a reply of code alone).
#[must_use]
pub fn reply_head(reply: &str) -> Option<String> {
    let mut paragraph: Vec<String> = Vec::new();
    let mut is_list = false;
    let mut fence: Option<&str> = None;
    // A paragraph that ends in a colon, waiting for the one it leads into.
    let mut lead: Option<String> = None;
    for line in reply.lines().chain(std::iter::once("")) {
        let trimmed = line.trim();
        if let Some(marker) = fence {
            if trimmed.starts_with(marker) {
                fence = None;
            }
            continue;
        }
        if let Some(marker) = ["```", "~~~"]
            .into_iter()
            .find(|marker| trimmed.starts_with(marker))
        {
            fence = Some(marker);
            // A code block ends the paragraph before it, as a blank line does.
            if let Some(head) = joined(&paragraph, is_list) {
                match lead.take() {
                    None if head.ends_with([':', '：']) => lead = Some(head),
                    None => return Some(head),
                    Some(lead) => return Some(capped(&format!("{lead} {head}"))),
                }
            }
            paragraph.clear();
            is_list = false;
            continue;
        }
        if trimmed.is_empty() {
            if let Some(head) = joined(&paragraph, is_list) {
                match lead.take() {
                    None if head.ends_with([':', '：']) => lead = Some(head),
                    None => return Some(head),
                    Some(lead) => return Some(capped(&format!("{lead} {head}"))),
                }
            }
            paragraph.clear();
            is_list = false;
            continue;
        }
        if is_heading(trimmed) || is_rule(trimmed) || trimmed.starts_with('|') {
            continue;
        }
        let quoted = trimmed.trim_start_matches('>').trim_start();
        match list_item(quoted) {
            Some(item) => {
                is_list = true;
                paragraph.push(item.to_owned());
            }
            // A line under an item goes on with that item.
            None if is_list => {
                if let Some(last) = paragraph.last_mut() {
                    last.push(' ');
                    last.push_str(quoted);
                }
            }
            None => paragraph.push(quoted.to_owned()),
        }
    }
    lead
}

/// The paragraph's lines as one line, or its items joined; `None` when no
/// words are left once the markup is taken out.
fn joined(paragraph: &[String], is_list: bool) -> Option<String> {
    let lines: Vec<String> = paragraph
        .iter()
        .map(|line| plain(line))
        .filter(|line| !line.is_empty())
        .collect();
    if lines.is_empty() {
        return None;
    }
    Some(capped(&lines.join(if is_list { " · " } else { " " })))
}

/// `text` cut to what a record keeps (`REPLY_HEAD_CHARS`).
fn capped(text: &str) -> String {
    text.chars().take(REPLY_HEAD_CHARS).collect()
}

/// A line's words without inline markup: strong emphasis, code spans, and a
/// link's or image's address, which leave their text. A single `_` or `*`
/// stays, since it is as often part of a name (`model_not_found`) as a mark.
fn plain(line: &str) -> String {
    let mut text = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(open) = rest.find('[') {
        let label_start = if rest[..open].ends_with('!') {
            open - 1
        } else {
            open
        };
        text.push_str(&rest[..label_start]);
        let after = &rest[open + 1..];
        // `[text](address)`: the text stays. A `[` that opens no link is
        // only a character.
        let target = after.find("](").and_then(|close| {
            after[close + 2..]
                .find(')')
                .map(|end| (close, close + 2 + end))
        });
        if let Some((close, end)) = target {
            text.push_str(&after[..close]);
            rest = &after[end + 1..];
        } else {
            text.push_str(&rest[label_start..=open]);
            rest = after;
        }
    }
    text.push_str(rest);
    let text = text.replace("**", "").replace("__", "").replace('`', "");
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A list item's text without its marker (`-`, `*`, `+`, `1.`, `1)`).
fn list_item(line: &str) -> Option<&str> {
    if let Some(item) = ["- ", "* ", "+ "]
        .into_iter()
        .find_map(|marker| line.strip_prefix(marker))
    {
        return Some(item.trim_start());
    }
    let digits = line.chars().take_while(char::is_ascii_digit).count();
    if digits == 0 {
        return None;
    }
    line[digits..]
        .strip_prefix(". ")
        .or_else(|| line[digits..].strip_prefix(") "))
        .map(str::trim_start)
}

/// An ATX heading: `#` to `######`, then a space or nothing. `#123` alone
/// is words.
fn is_heading(line: &str) -> bool {
    let marks = line.chars().take_while(|c| *c == '#').count();
    (1..=6).contains(&marks) && line[marks..].chars().next().is_none_or(char::is_whitespace)
}

/// A thematic break: three or more of one of `-`, `*`, `_`, spaces aside.
fn is_rule(line: &str) -> bool {
    let marks: Vec<char> = line.chars().filter(|c| !c.is_whitespace()).collect();
    marks.len() >= 3
        && ['-', '*', '_']
            .into_iter()
            .any(|mark| marks.iter().all(|c| *c == mark))
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
    /// The conversation's title as the run knows it (the session title, else
    /// the generated one); `None` when the provider has not named it.
    pub title: Option<&'a str>,
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
        reply_head: None,
        conversation_title: start.title.map(str::to_owned),
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
    /// The reply the stop that ended the turn sent, whole, which the record
    /// keeps the head of (`reply_head`); empty for a stop that sent none,
    /// which leaves the turn with no reply. `None` for an end that is no
    /// stop (a failure, an interrupt, a retake), which has nothing to say
    /// over what the record held.
    pub reply: Option<&'a str>,
    /// The conversation's title as the run knows it by now; `None` keeps the
    /// title the record held, since a title the provider has given is not
    /// taken back.
    pub title: Option<&'a str>,
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
    if let Some(title) = end.title {
        record.conversation_title = Some(title.to_owned());
    }
    if let Some(reply) = end.reply {
        record.reply_head = reply_head(reply);
    }
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
            title: None,
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
                    reply: None,
                    background_work: None,
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
                reply: None,
                title: None,
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

    #[test]
    fn the_reply_head_is_the_first_paragraph_with_words() {
        // Recorded from Codex CLI 0.165.0.
        assert_eq!(
            reply_head("Lighthouses guide ships safely through the night.").as_deref(),
            Some("Lighthouses guide ships safely through the night.")
        );
        assert_eq!(
            reply_head(
                "## Summary\n\nFixed the off-by-one in `add()`;\n**make test** passes.\n\n- calc.py\n- tests\n\nI did not touch divide()."
            )
            .as_deref(),
            Some("Fixed the off-by-one in add(); make test passes.")
        );
        assert_eq!(
            reply_head("- Renamed the watcher\n- Updated the\n  docs\n1. Tests pass").as_deref(),
            Some("Renamed the watcher · Updated the docs · Tests pass")
        );
        assert_eq!(
            reply_head("```bash\nmake test\n```\nThe [test](https://example.com/t) passes.\n")
                .as_deref(),
            Some("The test passes.")
        );
        assert_eq!(
            reply_head("> Note: model_not_found stays as *is*\n---\n").as_deref(),
            Some("Note: model_not_found stays as *is*")
        );
        assert_eq!(
            reply_head("#\n#123 is fixed.").as_deref(),
            Some("#123 is fixed.")
        );
        // Taken from the demo's pull request review.
        assert_eq!(
            reply_head("Three problems, most serious first:\n\n1. Major: credits apply twice.\n2. Nit: two tests share a name.").as_deref(),
            Some("Three problems, most serious first: Major: credits apply twice. · Nit: two tests share a name.")
        );
        assert_eq!(
            reply_head("修正しました：").as_deref(),
            Some("修正しました："),
            "a colon with nothing after it stands alone"
        );
        assert_eq!(reply_head("```\nonly code\n```"), None);
        assert_eq!(reply_head(" \n\n---\n"), None);
    }

    #[test]
    fn the_reply_head_keeps_at_most_four_hundred_characters() {
        let long = "あ".repeat(REPLY_HEAD_CHARS + 10);
        assert_eq!(
            reply_head(&long).map(|head| head.chars().count()),
            Some(REPLY_HEAD_CHARS)
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
                    reply: None,
                    title: None,
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
    /// A stop says what the turn ended on, even when it says nothing: the
    /// stop that ends a turn after a stop hook replaces the earlier stop's
    /// reply. An end that is no stop keeps the reply it found.
    #[test]
    fn the_last_stop_says_the_reply_and_another_end_keeps_it() {
        let event =
            EventId::invocation(&ProviderId::new("claude").expect("id"), Uuid::from_u128(1));
        let end = |reply| TurnEnd {
            phase: TurnPhase::Finished,
            now: "2026-10-12T00:00:10Z",
            end: captured("b"),
            diff: None,
            usage: None,
            checks: None,
            are_checks_partial: false,
            reply,
            title: None,
        };
        let stopped = end_record(
            &start(captured("a"), &event),
            end(Some("## Done\n\nAll set.")),
        );
        assert_eq!(stopped.reply_head.as_deref(), Some("All set."));
        let retaken = end_record(&stopped, end(None));
        assert_eq!(retaken.reply_head.as_deref(), Some("All set."));
        let continued = end_record(&stopped, end(Some("```\nonly code\n```")));
        assert_eq!(continued.reply_head, None);
    }

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
            reply: None,
            title: None,
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

    fn titled_start(title: Option<&'static str>, event: &EventId) -> TurnRecord {
        begin_record(TurnStart {
            turn_id: "T".to_owned(),
            conversation: ConversationKey {
                provider: ProviderId::new("claude").expect("id"),
                conversation_id: "s".to_owned(),
                is_fallback: false,
            },
            run_id: "R",
            pane_id: "P",
            display_number: 1,
            prompt: "go",
            now: "2026-10-12T00:00:00Z",
            begin: captured("a"),
            event,
            provider_turn_id: None,
            title,
        })
    }

    fn titled_end(title: Option<&str>) -> TurnEnd<'_> {
        TurnEnd {
            phase: TurnPhase::Finished,
            now: "2026-10-12T00:00:10Z",
            end: captured("b"),
            diff: None,
            usage: None,
            checks: None,
            are_checks_partial: false,
            reply: None,
            title,
        }
    }

    fn title_event() -> EventId {
        EventId::invocation(&ProviderId::new("claude").expect("id"), Uuid::from_u128(7))
    }

    #[test]
    fn begin_record_keeps_the_conversation_title() {
        let record = titled_start(Some("Review the fork"), &title_event());
        assert_eq!(
            record.conversation_title,
            Some("Review the fork".to_owned())
        );
    }

    #[test]
    fn end_record_takes_the_latest_title() {
        let previous = titled_start(Some("old"), &title_event());
        let ended = end_record(&previous, titled_end(Some("new")));
        assert_eq!(ended.conversation_title, Some("new".to_owned()));
    }

    #[test]
    fn end_record_keeps_the_title_when_none_is_known() {
        let previous = titled_start(Some("old"), &title_event());
        let ended = end_record(&previous, titled_end(None));
        assert_eq!(ended.conversation_title, Some("old".to_owned()));
    }
}
