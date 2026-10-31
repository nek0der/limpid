//! `apply`: one neutral event plus the previous run record gives the next
//! record and the side writes the hook runtime performs.
//!
//! This unifies the rule set previously carried by both `limpid-hook` shell
//! receivers. Every `SessionStarted` clears `lastPrompt` and refreshes
//! `sessionStartedAt`. A non-compact start also clears `runStartedAt` and
//! `firstPrompt` and replaces both title fields; a compact start retains those
//! fields unless it supplies a session title, and keeps the turn it happened
//! in open. A finished turn records the
//! prompt cache window it left behind, and every event that starts or ends
//! work clears it again, because that window no longer describes the cache.
//! A stop also records what it left running in the background, which stays
//! through work outside the turn and goes with the next turn, failure,
//! interrupt, or session start or end. The session's model and permission
//! mode come with the call rather than with an event (`ApplyContext`), and
//! are kept from the last call that said them, even on a call whose events
//! change nothing else. The function owns no file,
//! clock, or provider branch. Directory names and the git operations behind
//! `SideWrite` and `TurnSnapshotOp` belong to the runtime.

use limpid_agent_model::{
    AgentEvent, BackgroundWork, CacheWindow, Capability, MAX_RECORD_TEXT_BYTES, PromptKind,
    ProviderDescriptor, RunRecord, RunState, SessionSettings, SessionSource, Titles, TmuxEndpoint,
    WaitKind, classify_prompt, seconds_between,
};
use serde::{Deserialize, Serialize};

/// Everything the record needs that comes from the hook's environment
/// rather than from the payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApplyContext {
    /// Uppercase UUID string; the record's file name.
    pub run_id: String,
    /// The launching shim's immutable monotonic stamp, absent on older shims.
    pub run_launch_order: Option<u64>,
    /// The enclosing shim invocation, absent outside a nested agent launch.
    pub parent_run_id: Option<String>,
    /// The latest observation of this run's own settings, not a subagent's.
    pub run_observed_order: Option<u64>,
    /// Uppercase UUID string of the launching pane.
    pub pane_id: String,
    /// The agent process, when the shim exported it and tmux did not make it
    /// meaningless.
    pub pid: Option<u32>,
    /// The tmux server and pane hosting the agent, when both were readable.
    pub tmux: Option<TmuxEndpoint>,
    /// Whether the agent runs inside any tmux, hosted or manual. Set even
    /// when the endpoint could not be parsed.
    pub is_tmux_hosted: bool,
    /// This is the provider's transcript, when this call begins a turn or
    /// opens a wait the provider may end without a hook
    /// (`ProviderAdapter::turn_transcript_path`). It is kept on the record
    /// while the run is in that turn or waits, so the app can read whether
    /// the person declined the call, and what a turn the person stopped
    /// used.
    pub transcript_path: Option<String>,
    /// What this call says of the session's model and permission mode
    /// (`ProviderAdapter::session_settings`).
    pub settings: SessionSettings,
}

/// What the runtime must write after one event.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct RecordWrites {
    /// The next run record, or `None` when the event changes no run state.
    pub run: Option<RunRecord>,
    /// Pane-scoped records to write or delete, each checked against its
    /// owner by the runtime.
    pub side: Vec<SideWrite>,
    /// A turn snapshot to capture or remove. The runtime fills
    /// `turn_base_tree` and `turn_root` of `run` from a successful capture.
    pub snapshot: Option<TurnSnapshotOp>,
}

/// A pane-scoped side record.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SideWrite {
    /// Remember the provider session for resume. Written on session start
    /// outside tmux only, because a tmux client is not the pane that owns
    /// the session.
    SessionHint {
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    /// Forget the resume hint when the session ended on the user's terms.
    /// The runtime deletes only when the stored hint names this session and
    /// this run.
    DeleteSessionHint { session_id: String },
    /// The agent changed its working directory.
    CwdEvent {
        new_cwd: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        old_cwd: Option<String>,
    },
    /// A worktree was created on the agent's behalf.
    WorktreeEvent {
        repo_root: String,
        worktree_path: String,
        branch: String,
    },
}

/// Git work the runtime performs around a turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum TurnSnapshotOp {
    /// Snapshot the working tree at prompt submit, from `cwd` (or the
    /// process working directory when absent).
    Capture {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    /// Remove the scratch index files, and the per-pane ref earlier builds
    /// wrote, at session end. `cwd` is the previous turn root when known.
    Remove {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
}

/// The directory `apply` asks a turn snapshot of for `event`, so a runtime
/// can capture it before taking the record lock. `Some(None)` means a
/// snapshot of the process's current directory; `None` means no snapshot.
#[must_use]
pub fn turn_snapshot_cwd<'a>(
    event: &'a AgentEvent,
    descriptor: &ProviderDescriptor,
) -> Option<Option<&'a str>> {
    match event {
        AgentEvent::PromptSubmitted { cwd, .. } if descriptor.has(Capability::TurnSnapshot) => {
            Some(cwd.as_deref())
        }
        _ => None,
    }
}

/// Applies `event` to `prev` under the provider's descriptor.
///
/// The descriptor rather than a bare capability set, because some rules need
/// the provider's own vocabulary as well: which session-end reasons count as
/// the user ending the session is the provider's to say, not the rules'.
///
/// `now` is one ISO-8601 UTC timestamp with second precision, used for every
/// time field the event sets, so one hook call never straddles two seconds.
#[must_use]
pub fn apply(
    prev: Option<&RunRecord>,
    event: &AgentEvent,
    context: &ApplyContext,
    descriptor: &ProviderDescriptor,
    now: &str,
) -> RecordWrites {
    let mut writes = apply_event(prev, event, context, descriptor, now);
    // An event that changes no run state still brings what the call said of
    // the session's settings: Claude's model switch is such a call, and so
    // is the idle prompt of a run that already rests. Only an existing
    // record takes it, since one the event did not create has nothing for it
    // to describe yet. The revision moves, so the write orders after the
    // last; `updated_at` does not, because the projection reads it as when
    // the run last changed (the newest run in a pane, a viewed finish's age,
    // whether an agent's status report is newer than the record), and a
    // setting changes none of that.
    if writes.run.is_none()
        && let Some(prev) = prev
    {
        let mut next = prev.clone();
        observe_settings(&mut next, &context.settings);
        next.run_observed_order = next.run_observed_order.max(context.run_observed_order);
        if next.model != prev.model
            || next.effort != prev.effort
            || next.permission_mode != prev.permission_mode
            || next.run_observed_order != prev.run_observed_order
        {
            next.revision = Some(prev.revision.unwrap_or(0) + 1);
            writes.run = Some(next);
        }
    }
    writes
}

/// `apply` for the event alone; the call's settings reach only the record it
/// writes.
fn apply_event(
    prev: Option<&RunRecord>,
    event: &AgentEvent,
    context: &ApplyContext,
    descriptor: &ProviderDescriptor,
    now: &str,
) -> RecordWrites {
    let mut writes = RecordWrites::default();
    match event {
        AgentEvent::CwdChanged { new_cwd, old_cwd } => {
            if descriptor.has(Capability::CwdEvents) {
                writes.side.push(SideWrite::CwdEvent {
                    new_cwd: new_cwd.clone(),
                    old_cwd: old_cwd.clone(),
                });
            }
            return writes;
        }
        AgentEvent::WorktreeCreated {
            repo_root,
            worktree_path,
            branch,
        } => {
            writes.side.push(SideWrite::WorktreeEvent {
                repo_root: repo_root.clone(),
                worktree_path: worktree_path.clone(),
                branch: branch.clone(),
            });
            return writes;
        }
        AgentEvent::Extension { .. } => return writes,
        // The agent at its prompt says something only about a run shown at
        // work, or waiting on a call the transcript shows ended
        // (`idle_outcome`); any other run already rests where it should, and
        // a wait still open is not ended by the agent being idle.
        AgentEvent::AwaitingPrompt { awaited_call_ended }
            if idle_outcome(prev, *awaited_call_ended, now).is_none() =>
        {
            return writes;
        }
        // A background subagent's tool after the turn ended, its start or its
        // end, is work the stop already counted (`background_work`); the run
        // stays at its rest rather than reading as a turn at work. Only the
        // finished rest. At `idle` and `error` no stop counted the subagent
        // (a session start and a failure clear the count), so its tools are
        // the one sign that work goes on, and they still show the run
        // working until the subagent ends: its end starts a turn of Claude's,
        // whose stop settles the run, and Claude holds the idle prompt back
        // while a subagent runs. A wait the subagent's permission prompt
        // opened is ended by its next tool as any wait is.
        AgentEvent::ToolStarted {
            by_subagent: true, ..
        }
        | AgentEvent::ToolFinished {
            by_subagent: true, ..
        } if prev
            .is_some_and(|record| record.state == RunState::Finished && !is_in_a_turn(record)) =>
        {
            return writes;
        }
        _ => {}
    }

    let mut next = carried(prev, context, now);
    match event {
        AgentEvent::SessionStarted { .. } | AgentEvent::SessionEnded { .. } => {
            session_transition(
                prev,
                event,
                context,
                descriptor,
                now,
                &mut next,
                &mut writes,
            );
        }
        _ => turn_transition(prev, event, descriptor, now, &mut next, &mut writes),
    }

    next.last_hook_event = Some(event_name(event).to_owned());
    let previous_token = prev.and_then(|record| record.state_episode_token.clone());
    let continues_episode = leaves_or_rejoins_a_rest(prev, event, now);
    // A `Stop` is the end of work every time, so it always begins an
    // episode, even from `finished`: the run the idle prompt settled after a
    // late tool, then a real `Stop`, has finished again.
    let begins_episode = matches!(event, AgentEvent::TurnFinished { .. });
    next.state_episode_token = match (prev.map(|record| record.state), previous_token) {
        (Some(previous), Some(token))
            if !begins_episode && (previous == next.state || continues_episode) =>
        {
            Some(token)
        }
        _ => next.revision.map(|revision| revision.to_string()),
    };
    next.transcript_path = turn_transcript(prev, context, &next);
    observe_settings(&mut next, &context.settings);
    let works_outside_a_turn = !is_in_a_turn(&next) && next.state.is_at_work();
    if !works_outside_a_turn {
        next.outside_turn_rest = None;
    }
    writes.run = Some(next);
    writes
}

/// Applies the session-boundary fields and resume-hint operations. Compact
/// starts retain the long-lived prompt and title observations.
fn session_transition(
    prev: Option<&RunRecord>,
    event: &AgentEvent,
    context: &ApplyContext,
    descriptor: &ProviderDescriptor,
    now: &str,
    next: &mut RunRecord,
    writes: &mut RecordWrites,
) {
    match event {
        AgentEvent::SessionStarted {
            compact,
            source,
            session_id,
            session_title,
            cwd,
        } => {
            // A compaction in the middle of a turn restarts the session while
            // the turn goes on, so the turn stays open and running; one the
            // person asked for after the turn ended rests at the prompt.
            let continues_turn = *compact && prev.is_some_and(is_in_a_turn);
            // A fresh start has no conversation yet; a resume or a fork has
            // the one it picked up; a compaction keeps this run's. A source
            // this build does not know says nothing either way, so only a
            // start the provider names as fresh can retire a run quietly at
            // launch (`session_lifecycle`).
            next.has_prompt = match source {
                Some(SessionSource::Startup | SessionSource::Clear) => Some(false),
                Some(SessionSource::Resume | SessionSource::Fork) => Some(true),
                Some(SessionSource::Compact) => prev.and_then(|record| record.has_prompt),
                None => None,
            };
            next.state = if continues_turn {
                RunState::Running
            } else {
                RunState::Idle
            };
            if !continues_turn {
                next.run_started_at = None;
            }
            next.last_prompt = None;
            // A new session, a `/clear`, a resume, and a compaction restart all
            // begin a different prefix, so the previous window describes a
            // cache the next message will not read.
            next.cache_window = None;
            // A compaction leaves the background tasks running, but the run
            // rests idle or in a turn after any start, and the badge shows
            // the count only while it rests finished; a later stop says
            // again what is still running.
            next.background_work = None;
            next.session_started_at = Some(now.to_owned());
            if *compact {
                if let Some(title) = session_title {
                    next.provider_session_title = title_field(title);
                }
            } else {
                next.first_prompt = None;
                next.provider_generated_title = None;
                next.provider_session_title = session_title.as_deref().and_then(title_field);
            }
            if let Some(session_id) = session_id {
                next.session_id = Some(session_id.clone());
            }
            let hint = session_id.as_deref().filter(|id| is_hint_safe(id));
            if let Some(session_id) = hint.filter(|_| !context.is_tmux_hosted) {
                writes.side.push(SideWrite::SessionHint {
                    session_id: session_id.to_owned(),
                    cwd: cwd.clone(),
                });
            }
        }
        AgentEvent::SessionEnded { reason, session_id } => {
            next.state = RunState::Unknown;
            next.run_started_at = None;
            next.cache_window = None;
            next.background_work = None;
            // Only a provider that takes snapshots has one to remove; the
            // removal runs git, so it is not issued for the others.
            if descriptor.has(Capability::TurnSnapshot) {
                writes.snapshot = Some(TurnSnapshotOp::Remove {
                    cwd: prev.and_then(|record| record.turn_root.clone()),
                });
            }
            next.turn_base_tree = None;
            next.turn_root = None;
            next.worktree_root = None;
            let drops = descriptor.has(Capability::SessionEndDropsSession)
                && !context.is_tmux_hosted
                && reason.as_deref().is_some_and(|reason| {
                    descriptor
                        .session_end_drop_reasons
                        .iter()
                        .any(|it| it == reason)
                });
            let hint = session_id.as_deref().filter(|id| is_hint_safe(id));
            if let Some(session_id) = hint.filter(|_| drops) {
                writes.side.push(SideWrite::DeleteSessionHint {
                    session_id: session_id.to_owned(),
                });
            }
        }
        _ => {}
    }
}

/// Everything between session start and end: the state machine of one turn.
fn turn_transition(
    prev: Option<&RunRecord>,
    event: &AgentEvent,
    descriptor: &ProviderDescriptor,
    now: &str,
    next: &mut RunRecord,
    writes: &mut RecordWrites,
) {
    match event {
        AgentEvent::PromptSubmitted { prompt, titles, .. } => {
            next.state = RunState::Running;
            next.run_started_at = Some(now.to_owned());
            // The request this prompt starts refreshes the cache, so the
            // window is warm by definition until the turn reports a new one.
            next.cache_window = None;
            // The turn's own stop says again what is still running.
            next.background_work = None;
            let prompt = text_field(prompt);
            // The first prompt names the tab, so it is the first one with
            // the person's words: a prompt the harness wrote (a background
            // task's end, a subagent's hand-back) gives way to the next.
            let names_nothing = next
                .first_prompt
                .as_deref()
                .is_none_or(|first| classify_prompt(first).0 != PromptKind::Text);
            if names_nothing && prompt.is_some() {
                next.first_prompt.clone_from(&prompt);
            }
            // A prompt, whatever it says, gives the session a conversation
            // its transcript can resume.
            next.has_prompt = Some(true);
            next.last_prompt = prompt;
            observe_titles(next, titles.as_ref());
            if let Some(cwd) = turn_snapshot_cwd(event, descriptor) {
                writes.snapshot = Some(TurnSnapshotOp::Capture {
                    cwd: cwd.map(str::to_owned),
                });
            }
        }
        // A tool outside a turn runs too: the run is shown working, and its
        // `runStartedAt` stays empty, which is what records that no turn
        // holds the work (`idle_outcome`).
        AgentEvent::ToolStarted { tool, detail, .. } => {
            next.state = RunState::Running;
            next.detail = detail.as_deref().and_then(text_field);
            next.tool = text_field(tool);
            note_rest_left(prev, event, next);
        }
        AgentEvent::WaitingForInput { detail } => {
            next.state = RunState::NeedsInput;
            next.detail = detail.as_deref().and_then(text_field);
            next.wait_kind = Some(WaitKind::Question);
        }
        AgentEvent::ApprovalRequested { detail } => {
            next.state = RunState::NeedsInput;
            // Claude's permission prompt also follows its question tool: the
            // question is still what waits, in its own words.
            if is_question_wait(prev) {
                carry_wait(prev, next);
                next.wait_kind = Some(WaitKind::Question);
            } else {
                approval_wait(prev, detail.as_deref(), next);
            }
        }
        AgentEvent::Compacting => {
            next.state = RunState::Compacting;
            next.cache_window = None;
        }
        AgentEvent::ToolFinished { .. } => {
            next.state = RunState::Running;
            note_rest_left(prev, event, next);
        }
        AgentEvent::CompactionFinished => {
            // Codex compacts at the person's `/compact` after a turn as well
            // as within one, and only a turn goes on afterwards.
            next.state = if prev.is_some_and(is_in_a_turn) {
                RunState::Running
            } else {
                RunState::Idle
            };
            // Compaction replaces the prefix the window was measured on.
            next.cache_window = None;
        }
        AgentEvent::TurnFinished {
            titles,
            cache,
            background_work,
            ..
        } => finish_turn(next, titles.as_ref(), cache.as_ref(), *background_work),
        AgentEvent::Failed { error, usage_limit } => {
            next.state = RunState::Error;
            next.run_started_at = None;
            next.detail = text_field(error);
            // Set or cleared by every failure, so it always describes the
            // error the run rests in; the badge reads it only then.
            next.usage_limit.clone_from(usage_limit);
            // A failed request may or may not have refreshed the cache; an
            // unknown window is shown as nothing rather than as a guess.
            next.cache_window = None;
            // No stop listed what the failed turn left running, and a count
            // an earlier stop left would describe a different turn.
            next.background_work = None;
        }
        AgentEvent::Interrupted => {
            next.state = RunState::Finished;
            next.run_started_at = None;
            next.cache_window = None;
            next.background_work = None;
        }
        // Reached only when it ends something (`apply`). Work outside a turn
        // is over and returns to the rest it left, in the episode it left
        // (`leaves_or_rejoins_a_rest`), so the end its `Stop` or failure
        // already announced is not announced again. A turn open long enough
        // to have sat idle stopped without saying so (an Esc, then the
        // person's `/compact`, or an Esc that declined the question or
        // permission the turn waited on), and ends as an interrupt does.
        // Either way the requests made since refreshed the cache after the
        // window was read.
        AgentEvent::AwaitingPrompt { awaited_call_ended } => {
            next.cache_window = None;
            match idle_outcome(prev, *awaited_call_ended, now) {
                Some(IdleOutcome::EndsOutsideWork) => {
                    // Only the two rests are places to return to; any other
                    // value, from a newer writer or none at all, is a turn's.
                    next.state = match prev.and_then(|record| record.outside_turn_rest) {
                        Some(RunState::Idle) => RunState::Idle,
                        _ => RunState::Finished,
                    };
                }
                Some(IdleOutcome::EndsStoppedTurn) | None => {
                    next.state = RunState::Finished;
                    next.run_started_at = None;
                }
            }
        }
        _ => {}
    }
}

/// The record a stop leaves: the turn ended, with what the stop observed.
fn finish_turn(
    next: &mut RunRecord,
    titles: Option<&Titles>,
    cache: Option<&CacheWindow>,
    background_work: Option<BackgroundWork>,
) {
    next.state = RunState::Finished;
    next.run_started_at = None;
    observe_titles(next, titles);
    // Stored as observed, including `None`: a turn whose window could not be
    // read leaves the cache unknown rather than describing it with the
    // previous turn's numbers.
    next.cache_window = cache.cloned();
    // Each stop lists everything still running, so it replaces what an
    // earlier stop listed, and a stop that lists nothing clears it.
    next.background_work = background_work.filter(|work| !work.is_empty());
}

/// Whether a prompt opened a turn that has not ended. `runStartedAt` is the
/// mark: a prompt sets it, every end of a turn clears it, and so does a
/// session start other than a compaction.
fn is_in_a_turn(record: &RunRecord) -> bool {
    record.run_started_at.is_some()
}

/// How long a turn must have been open before the idle prompt can end it.
/// Claude sends that notification after its TUI has sat at the prompt for a
/// minute (the default idle threshold, 60 s), so an idle prompt that arrives
/// sooner after a prompt is the previous stretch's, delivered late, and
/// ending the turn just begun would be wrong. Five seconds under the minute
/// absorb the record's whole-second clock and the hook's own delay.
pub const STOPPED_TURN_IDLE_SECS: u64 = 55;

/// What the agent idle at its prompt ends, for a run shown at work.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IdleOutcome {
    /// Work no turn holds: Claude's TUI has sent a turn's `Stop` before the
    /// `PreToolUse` of a tool the turn still ran, with no `Stop` after it,
    /// or a turn another stop hook holds open has gone on after its first
    /// `Stop`. The turn's end is taken again, with that work in it, and the
    /// turn keeps how it ended.
    EndsOutsideWork,
    /// A turn is still open: it stopped without a `Stop`, which an Esc does,
    /// including the Esc that declines the question or permission prompt
    /// the turn waited on.
    EndsStoppedTurn,
}

/// What `AwaitingPrompt` at `now` ends for `prev`, or `None` when it ends
/// nothing: the run rests already, waits on the person, or is in a turn too
/// young to have sat idle (`STOPPED_TURN_IDLE_SECS`).
///
/// `awaited_call_ended` is the event's word that the call the run last made
/// has a result or an interrupt after it. A turn waiting on the person ends
/// only with it. Claude sends no hook when a question or permission prompt
/// is declined with Esc, so this is the one sign that the wait is over; a
/// minute idle without it is a person who has not answered yet.
///
/// Shared with the turn rules, so the record and the turn record end the
/// same thing, and with the hook runtime, which judges it again under the
/// record lock.
#[must_use]
pub fn idle_outcome(
    prev: Option<&RunRecord>,
    awaited_call_ended: bool,
    now: &str,
) -> Option<IdleOutcome> {
    let record = prev?;
    let has_sat_idle = || {
        record
            .run_started_at
            .as_deref()
            .and_then(|started| seconds_between(started, now))
            .is_some_and(|open| open >= STOPPED_TURN_IDLE_SECS)
    };
    match record.state {
        RunState::Running if !is_in_a_turn(record) => Some(IdleOutcome::EndsOutsideWork),
        RunState::Running | RunState::Compacting => {
            has_sat_idle().then_some(IdleOutcome::EndsStoppedTurn)
        }
        // A wait outside a turn is a late tool's, which no turn holds; it
        // keeps resting on the person as before.
        RunState::NeedsInput if awaited_call_ended && is_in_a_turn(record) => {
            has_sat_idle().then_some(IdleOutcome::EndsStoppedTurn)
        }
        _ => None,
    }
}

/// Returns the record after the person stopped the turn `prev` is in, which
/// no hook reports, as the app's writer applies it once the projection read
/// it: Esc or "No" at Claude's question or permission prompt, or Esc or
/// Ctrl+C while it works. It is `None` unless `prev` is at work or waits
/// inside a turn, the only runs the projection reads as stopped.
///
/// It ends the turn as the idle prompt ends a stopped turn
/// (`IdleOutcome::EndsStoppedTurn`): finished, out of the turn, with the
/// wait's words, its kind, its tool, its transcript, and the cache window
/// gone. Two things differ, both because the projection has already shown
/// this end before the record says it (`stopped_badge`). The episode stays
/// the one the person stopped: the badge showed the finish in it, and a new
/// one would read as a second finish and be announced. And the record is
/// otherwise carried as it is, identity and unknown fields included, since
/// no hook call supplies them: the writer is the app, not the agent.
#[must_use]
pub fn end_stopped_turn(prev: &RunRecord, now: &str) -> Option<RunRecord> {
    let last_hook_event = match prev.state {
        RunState::NeedsInput => "wait_declined",
        RunState::Running | RunState::Compacting => "interrupted",
        _ => return None,
    };
    if !is_in_a_turn(prev) {
        return None;
    }
    let mut next = prev.clone();
    next.schema_version = RunRecord::SCHEMA_VERSION;
    next.revision = Some(prev.revision.unwrap_or(0) + 1);
    next.state = RunState::Finished;
    next.run_started_at = None;
    next.detail = None;
    next.tool = None;
    next.wait_kind = None;
    next.transcript_path = None;
    next.cache_window = None;
    next.outside_turn_rest = None;
    // As `Interrupted` does: no stop listed what the stopped turn left
    // running. The turn's prompt already cleared it.
    next.background_work = None;
    now.clone_into(&mut next.updated_at);
    next.last_hook_event = Some(last_hook_event.to_owned());
    Some(next)
}

/// Records the rest a tool event outside a turn takes the run from, for the
/// idle prompt to return it to. A failure's work settles as finished: the
/// agent went on after it, and that work did not fail.
fn note_rest_left(prev: Option<&RunRecord>, event: &AgentEvent, next: &mut RunRecord) {
    // A tool event's judgment does not read the clock.
    let Some(record) = prev.filter(|_| leaves_or_rejoins_a_rest(prev, event, "")) else {
        return;
    };
    next.outside_turn_rest = Some(match record.state {
        RunState::Idle => RunState::Idle,
        _ => RunState::Finished,
    });
}

/// Whether `event` takes the run out of a rest, or back to one, without a
/// turn: a tool after the turn ended, or the agent idle after that tool.
/// The stretch belongs to the episode the run rested in, so it raises no
/// notification of its own and leaves a finish the person saw seen. A `Stop`
/// that ends the stretch is the turn's real end and begins a new one.
fn leaves_or_rejoins_a_rest(prev: Option<&RunRecord>, event: &AgentEvent, now: &str) -> bool {
    let Some(record) = prev.filter(|record| !is_in_a_turn(record)) else {
        return false;
    };
    match event {
        AgentEvent::ToolStarted { .. } | AgentEvent::ToolFinished { .. } => matches!(
            record.state,
            RunState::Finished | RunState::Error | RunState::Idle
        ),
        AgentEvent::AwaitingPrompt { awaited_call_ended } => {
            idle_outcome(prev, *awaited_call_ended, now) == Some(IdleOutcome::EndsOutsideWork)
        }
        _ => false,
    }
}

/// Whether the run already waits on its own question: the record says so,
/// or, for a record from before `waitKind`, its last event was the question.
fn is_question_wait(prev: Option<&RunRecord>) -> bool {
    prev.is_some_and(|record| {
        record.state == RunState::NeedsInput
            && (record.wait_kind == Some(WaitKind::Question)
                || (record.wait_kind.is_none()
                    && record.last_hook_event.as_deref() == Some("waiting_for_input")))
    })
}

/// A permission request's wait. Only the tool event just before it says
/// what needs approval, and which tool; any earlier detail (an error, say)
/// is not a request's words, and the provider's own message stands instead.
fn approval_wait(prev: Option<&RunRecord>, detail: Option<&str>, next: &mut RunRecord) {
    next.wait_kind = Some(WaitKind::Approval);
    // `tool` is written only by a tool event and kept only with its words;
    // a record from before the field says it by its last event, which the
    // shell receivers named after the hook.
    let has_tool_context = prev.is_some_and(|record| {
        record.tool.is_some()
            || matches!(
                record.last_hook_event.as_deref(),
                Some("tool_started" | "PreToolUse")
            )
    });
    let tool_detail = prev
        .filter(|_| has_tool_context)
        .and_then(|record| record.detail.as_deref())
        .and_then(text_field);
    if tool_detail.is_some() {
        next.tool = prev
            .and_then(|record| record.tool.as_deref())
            .and_then(text_field);
    }
    next.detail = tool_detail
        .or_else(|| detail.and_then(text_field))
        .or_else(|| Some("permission".to_owned()));
}

/// Returns the transcript the record names: the one the call that began the
/// turn or opened or renewed the wait named, else the one the record already
/// had (a tool's hook, or Claude's permission prompt after its question
/// tool, whose path the question already gave). Only a run in a turn or in
/// `NeedsInput` keeps one: a wait is read from it, and so is what a turn the
/// person stopped used, which no hook brings. A path longer than any record
/// text is dropped rather than cut, because a cut path names another file.
fn turn_transcript(
    prev: Option<&RunRecord>,
    context: &ApplyContext,
    next: &RunRecord,
) -> Option<String> {
    if next.state != RunState::NeedsInput && !is_in_a_turn(next) {
        return None;
    }
    context
        .transcript_path
        .clone()
        .or_else(|| prev.and_then(|record| record.transcript_path.clone()))
        .filter(|path| !path.is_empty() && path.len() <= MAX_RECORD_TEXT_BYTES)
}

/// Keeps what the run's wait is about through an event that leaves its
/// state as it was.
fn carry_wait(prev: Option<&RunRecord>, next: &mut RunRecord) {
    next.detail = prev
        .and_then(|record| record.detail.as_deref())
        .and_then(text_field);
    next.tool = prev
        .and_then(|record| record.tool.as_deref())
        .and_then(text_field);
    next.wait_kind = prev.and_then(|record| record.wait_kind);
}

/// The next record with every field the event does not touch carried over
/// from `prev`, and the identity fields set from the context.
fn carried(prev: Option<&RunRecord>, context: &ApplyContext, now: &str) -> RunRecord {
    let revision = prev.and_then(|record| record.revision).unwrap_or(0) + 1;
    RunRecord {
        schema_version: RunRecord::SCHEMA_VERSION,
        pane_id: context.pane_id.clone(),
        run_id: Some(context.run_id.clone()),
        revision: Some(revision),
        state_episode_token: None,
        state: prev.map_or(RunState::Unknown, |record| record.state),
        // The shell wrote `detail` fresh on every event; only the approval
        // rule reads the previous one, and it does so explicitly. The tool
        // `detail` names and the kind of wait go with it.
        detail: None,
        tool: None,
        wait_kind: None,
        // `apply` sets it again while the run is in a turn or waits
        // (`turn_transcript`).
        transcript_path: None,
        run_started_at: prev.and_then(|record| record.run_started_at.clone()),
        updated_at: now.to_owned(),
        last_hook_event: None,
        pid: context.pid.map(|pid| pid.to_string()),
        is_tmux_hosted: context.is_tmux_hosted.then_some(true),
        // A previous record may come from the unbounded shell writer. Apply
        // the v3 text contract again at the writer boundary so switching
        // backends cannot carry hostile or oversized values forward.
        last_prompt: prev
            .and_then(|record| record.last_prompt.as_deref())
            .and_then(text_field),
        first_prompt: prev
            .and_then(|record| record.first_prompt.as_deref())
            .and_then(text_field),
        has_prompt: prev.and_then(|record| record.has_prompt),
        session_id: prev.and_then(|record| record.session_id.clone()),
        provider_session_title: prev
            .and_then(|record| record.provider_session_title.as_deref())
            .and_then(title_field),
        provider_generated_title: prev
            .and_then(|record| record.provider_generated_title.as_deref())
            .and_then(title_field),
        session_started_at: prev.and_then(|record| record.session_started_at.clone()),
        run_launch_order: prev
            .and_then(|record| record.run_launch_order)
            .or(context.run_launch_order),
        parent_run_id: prev
            .and_then(|record| record.parent_run_id.clone())
            .or_else(|| context.parent_run_id.clone()),
        run_observed_order: prev
            .and_then(|record| record.run_observed_order)
            .max(context.run_observed_order),
        turn_base_tree: prev.and_then(|record| record.turn_base_tree.clone()),
        turn_root: prev.and_then(|record| record.turn_root.clone()),
        worktree_root: prev.and_then(|record| record.worktree_root.clone()),
        current_turn_id: prev.and_then(|record| record.current_turn_id.clone()),
        killed_by_limpid_at: prev.and_then(|record| record.killed_by_limpid_at.clone()),
        resume_attempted_at: prev.and_then(|record| record.resume_attempted_at.clone()),
        tmux_socket_path: context.tmux.as_ref().map(|tmux| tmux.socket_path.clone()),
        tmux_session_id: None,
        tmux_pane_id: context.tmux.as_ref().map(|tmux| tmux.pane.clone()),
        tmux_server_pid: context
            .tmux
            .as_ref()
            .map(|tmux| tmux.server_pid.to_string()),
        tmux_server_started_at: context.tmux.as_ref().map(|tmux| {
            tmux.server_started_at
                .map(|started| started.to_string())
                .unwrap_or_default()
        }),
        // Carried through the events that neither start nor end work, such
        // as a question asked after the turn ended. The idle prompt reaches
        // here only when it ends work, which clears it.
        cache_window: prev.and_then(|record| record.cache_window.clone()),
        usage_limit: prev.and_then(|record| record.usage_limit.clone()),
        // Kept while the work outside a turn lasts; `apply` drops it once the
        // run is in a turn or at rest.
        outside_turn_rest: prev.and_then(|record| record.outside_turn_rest),
        // Unlike the cache window, which the idle prompt that ends work
        // outside a turn clears, kept through that prompt: it returns the run
        // to the rest the stop described. What the stop left running stays
        // until the next prompt, failure, interrupt, or session start or end.
        background_work: prev.and_then(|record| record.background_work),
        // Kept until a call says otherwise (`observe_settings`): most calls
        // do not say, and a session start does not reset them.
        model: prev.and_then(|record| record.model.clone()),
        effort: prev.and_then(|record| record.effort.clone()),
        permission_mode: prev.and_then(|record| record.permission_mode),
        extra: prev.map(|record| record.extra.clone()).unwrap_or_default(),
    }
}

/// As with titles, a setting the call did not say is kept, never cleared. The
/// effort is the exception: it belongs to the model it was said of, so a new
/// model drops it until a call says the new one's.
fn observe_settings(record: &mut RunRecord, settings: &SessionSettings) {
    if let Some(model) = settings.model.as_deref().and_then(title_field) {
        if record.model.as_ref() != Some(&model) {
            record.effort = None;
        }
        record.model = Some(model);
    }
    if record.model.is_none() {
        record.model = settings.answered_model.as_deref().and_then(title_field);
    }
    if let Some(effort) = settings.effort.as_deref().and_then(title_field) {
        record.effort = Some(effort);
    }
    if let Some(mode) = settings.permission_mode {
        record.permission_mode = Some(mode);
    }
}

/// A title observation of `None` means "nothing seen", never "cleared", so
/// only present values replace what the record holds.
fn observe_titles(record: &mut RunRecord, titles: Option<&Titles>) {
    let Some(titles) = titles else { return };
    if let Some(title) = titles.session_title.as_deref().and_then(title_field) {
        record.provider_session_title = Some(title);
    }
    if let Some(title) = titles.generated_title.as_deref().and_then(title_field) {
        record.provider_generated_title = Some(title);
    }
}

/// The record's `lastHookEvent`, kept for diagnostics: the neutral event's
/// wire name rather than the provider's, because the record no longer knows
/// which provider produced it.
fn event_name(event: &AgentEvent) -> &'static str {
    match event {
        AgentEvent::SessionStarted { .. } => "session_started",
        AgentEvent::SessionEnded { .. } => "session_ended",
        AgentEvent::PromptSubmitted { .. } => "prompt_submitted",
        AgentEvent::ToolStarted { .. } => "tool_started",
        AgentEvent::ToolFinished { .. } => "tool_finished",
        AgentEvent::WaitingForInput { .. } => "waiting_for_input",
        AgentEvent::ApprovalRequested { .. } => "approval_requested",
        AgentEvent::Compacting => "compacting",
        AgentEvent::CompactionFinished => "compaction_finished",
        AgentEvent::AwaitingPrompt { .. } => "awaiting_prompt",
        AgentEvent::TurnFinished { .. } => "turn_finished",
        AgentEvent::Failed { .. } => "failed",
        AgentEvent::Interrupted => "interrupted",
        AgentEvent::CwdChanged { .. } => "cwd_changed",
        AgentEvent::WorktreeCreated { .. } => "worktree_created",
        AgentEvent::Extension { .. } => "extension",
    }
}

/// The shell refused to store a session id containing a quote or backslash
/// because it built JSON by hand; the runtime no longer does, but such an id
/// still cannot come from a real provider and is treated as hostile.
fn is_hint_safe(session_id: &str) -> bool {
    !session_id.is_empty() && !session_id.contains(['"', '\\'])
}

/// A prompt or detail value: control characters and direction overrides
/// removed, line breaks kept, bounded to the record text limit. Empty after
/// cleaning means absent.
fn text_field(value: &str) -> Option<String> {
    let cleaned = sanitize_text(value);
    (!cleaned.is_empty()).then_some(cleaned)
}

/// A title value: additionally collapsed to one line.
fn title_field(value: &str) -> Option<String> {
    let cleaned = sanitize_title(value);
    (!cleaned.is_empty()).then_some(cleaned)
}

/// Removes terminal controls and invisible direction modifiers, keeps line
/// breaks and tabs, and truncates to `MAX_RECORD_TEXT_BYTES` at a character
/// boundary.
#[must_use]
pub fn sanitize_text(value: &str) -> String {
    let mut visible = String::with_capacity(value.len().min(MAX_RECORD_TEXT_BYTES));
    for character in value.chars() {
        if is_dropped(character) {
            continue;
        }
        if visible.len() + character.len_utf8() > MAX_RECORD_TEXT_BYTES {
            break;
        }
        visible.push(character);
    }
    visible
}

/// Removes the same characters as `sanitize_text`, then collapses every run
/// of whitespace into one space so the result fits a single-line UI; the
/// same rule the title resolver applies.
#[must_use]
pub fn sanitize_title(value: &str) -> String {
    let cleaned = sanitize_text(value);
    cleaned.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn is_dropped(character: char) -> bool {
    if matches!(character, '\n' | '\t' | '\r') {
        return false;
    }
    let scalar = character as u32;
    scalar < 0x20
        || (0x7f..=0x9f).contains(&scalar)
        || (0x202a..=0x202e).contains(&scalar)
        || (0x2066..=0x2069).contains(&scalar)
        || matches!(scalar, 0x200b..=0x200f | 0xfeff)
}

#[cfg(test)]
#[path = "lifecycle_tests/mod.rs"]
mod tests;
