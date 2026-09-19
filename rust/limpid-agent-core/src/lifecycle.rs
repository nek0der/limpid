//! `apply`: one neutral event plus the previous run record gives the next
//! record and the side writes the hook runtime performs.
//!
//! This unifies the rule set previously carried by both `limpid-hook` shell
//! receivers. Every `SessionStarted` clears `lastPrompt` and `runStartedAt`
//! and refreshes `sessionStartedAt`. A non-compact start also clears
//! `firstPrompt` and replaces both title fields; a compact start retains those
//! fields unless it supplies a session title. The function owns no file,
//! clock, or provider branch. Directory names and the git operations behind
//! `SideWrite` and `TurnSnapshotOp` belong to the runtime.

use limpid_agent_model::{
    AgentEvent, Capability, MAX_RECORD_TEXT_BYTES, PanePresence, ProviderDescriptor, RunRecord,
    RunState, Titles, TmuxEndpoint,
};
use serde::{Deserialize, Serialize};

/// Everything the record needs that comes from the hook's environment
/// rather than from the payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApplyContext {
    /// Uppercase UUID string; the record's file name.
    pub run_id: String,
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
    /// Who put the agent in tmux, when it runs in tmux and the shim said so.
    /// `None` inside tmux is read the way `Manual` is.
    pub tmux_host_mode: Option<TmuxHostMode>,
}

/// Who put an agent in tmux, as the shim reports it in
/// `LIMPID_AGENT_TMUX_HOST_MODE`.
///
/// The difference decides what `LIMPID_PANE_ID` means. Limpid starts a hosted
/// agent in a session of its own, so the pane id names the pane that owns the
/// session. Inside the user's own tmux, the pane id names whichever Limpid pane
/// happens to show the tmux client, and resuming there would start the
/// session a second time next to the one tmux keeps alive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TmuxHostMode {
    /// Limpid started the agent in tmux (`limpidHosted`).
    LimpidHosted,
    /// The agent was started inside tmux the user runs (`manual`).
    Manual,
}

impl TmuxHostMode {
    /// Parses the shim's spelling. Anything else is not a mode this build
    /// knows, and the caller treats it as no mode at all.
    #[must_use]
    pub fn from_shim_value(value: &str) -> Option<Self> {
        match value {
            "limpidHosted" => Some(Self::LimpidHosted),
            "manual" => Some(Self::Manual),
            _ => None,
        }
    }
}

/// The `lastHookEvent` values a session end leaves on a record: this writer's
/// name and the raw hook name the shell receivers still write.
const SESSION_ENDED_EVENTS: [&str; 2] = ["session_ended", "SessionEnd"];

/// Whether the record's last hook call ended the agent.
///
/// For a run in tmux this is the only sign on disk that it is over: its record
/// carries no pid of ours to ask about, and the sweep never retires it. A tab
/// is closed on this answer, so it is about the agent and not only about the
/// conversation: Claude's `/clear` ends a session and keeps running, and
/// between that end and the start that follows it the tab is still showing a
/// live agent. The reasons that mean as much are the provider's to name
/// (`ProviderDescriptor::session_end_restart_reasons`).
///
/// A record with no reason — one an older build wrote, or an end that stated
/// none — reads as the agent having gone, which is how every session end read
/// before the reason was kept.
#[must_use]
pub(crate) fn has_session_ended(
    record: &RunRecord,
    descriptor: Option<&ProviderDescriptor>,
) -> bool {
    if !record
        .last_hook_event
        .as_deref()
        .is_some_and(|event| SESSION_ENDED_EVENTS.contains(&event))
    {
        return false;
    }
    let Some(reason) = record.session_end_reason.as_deref() else {
        return true;
    };
    !descriptor.is_some_and(|descriptor| {
        descriptor
            .session_end_restart_reasons
            .iter()
            .any(|it| it == reason)
    })
}

/// Whether the record describes a run in tmux whose session is still going.
///
/// Such a run outlives every pane, so the rules cannot ask a pane about it:
/// its side files are kept while it goes on, and its conversation is not
/// offered for resume anywhere, because tmux already holds it.
///
/// Two things can end it, and the record only carries one of them. The agent
/// ending its session leaves a session-end hook behind; a server that was
/// killed leaves nothing at all, so the host's evidence that the endpoint is
/// gone counts as the other. Without it a killed run would hold its
/// conversation out of resume for good, which is also why a record that names
/// no endpoint is not read as live: nothing could ever say it had ended.
#[must_use]
pub(crate) fn is_live_tmux_run(
    record: &RunRecord,
    descriptor: Option<&ProviderDescriptor>,
    presence: &PanePresence,
) -> bool {
    if record.tmux_socket_path.is_none() || has_session_ended(record, descriptor) {
        return false;
    }
    // No endpoint, no way of ever being told it is gone: such a record would
    // hold its conversation out of resume for the rest of the install. A run
    // we cannot place is not one we can call live.
    let Some(key) = endpoint_key(record) else {
        return false;
    };
    !presence.gone_endpoints.contains(&key)
}

/// The key the host indexes tmux endpoints by, for the attachments it reports
/// and the endpoints it reports gone.
///
/// The server run is part of it, not only the socket and the pane. Pane ids
/// start again with every server, so a record an earlier server run left on
/// the same socket can name the same pane as a run going now; keyed by socket
/// and pane alone, the two shared whatever the host reported about either,
/// and the earlier endpoint being gone ended the later run for the rules. A
/// record that could not read its server's start time keys with an empty
/// one, and the host builds its key from the same record fields, so the two
/// sides still meet.
///
/// The host builds the same key from the record's own fields, so the shape is
/// a contract between two codebases rather than something either one owns.
/// `AgentProjectionPresence.key(for:)` is the other half, and a test there
/// pins this spelling.
#[must_use]
pub(crate) fn endpoint_key(record: &RunRecord) -> Option<String> {
    let socket = record.tmux_socket_path.as_deref()?;
    let pane = record.tmux_pane_id.as_deref()?;
    if socket.is_empty() || pane.is_empty() {
        return None;
    }
    let pid = record.tmux_server_pid.as_deref().unwrap_or_default();
    let started = record.tmux_server_started_at.as_deref().unwrap_or_default();
    Some(format!("{socket}|{pid}|{started}|{pane}"))
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
    /// outside tmux and for agents Limpid hosts in tmux. Inside the user's own
    /// tmux the pane is only showing a client, not the pane that owns the
    /// session.
    ///
    /// `hosted_in_tmux` decides where the runtime keeps it, and the reason is
    /// version skew rather than tidiness: a build from before mirror tabs
    /// existed shows a converted tab as a plain shell, and a hint it can read
    /// would have it resume, in that shell, the conversation the agent is
    /// still having in tmux. Such a hint therefore goes somewhere that build
    /// does not look, and this build reads both places.
    SessionHint {
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        hosted_in_tmux: bool,
    },
    /// Forget the resume hint when the session ended on the user's terms.
    /// The runtime deletes only when the stored hint names this session and
    /// this run.
    DeleteSessionHint {
        session_id: String,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        hosted_in_tmux: bool,
    },
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
    /// Remove the snapshot ref and index files at session end. `cwd` is the
    /// previous turn root when known.
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
    next.state_episode_token = match (prev.map(|record| record.state), previous_token) {
        (Some(previous), Some(token)) if previous == next.state => Some(token),
        _ => next.revision.map(|revision| revision.to_string()),
    };
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
            session_id,
            session_title,
            cwd,
        } => {
            next.state = RunState::Idle;
            next.run_started_at = None;
            next.last_prompt = None;
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
            if let Some(session_id) = hint.filter(|_| owns_resume_hint(context)) {
                writes.side.push(SideWrite::SessionHint {
                    session_id: session_id.to_owned(),
                    cwd: cwd.clone(),
                    hosted_in_tmux: is_hosted_in_tmux(context),
                });
            }
        }
        AgentEvent::SessionEnded { reason, session_id } => {
            next.state = RunState::Unknown;
            next.run_started_at = None;
            next.session_end_reason = reason.as_deref().and_then(text_field);
            // Only a provider that takes snapshots has one to remove; the
            // removal runs git, so it is not issued for the others.
            if descriptor.has(Capability::TurnSnapshot) {
                writes.snapshot = Some(TurnSnapshotOp::Remove {
                    cwd: prev.and_then(|record| record.turn_root.clone()),
                });
            }
            next.turn_base_tree = None;
            next.turn_root = None;
            let drops = descriptor.has(Capability::SessionEndDropsSession)
                && owns_resume_hint(context)
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
                    hosted_in_tmux: is_hosted_in_tmux(context),
                });
            }
        }
        _ => {}
    }
}

/// Whether the launching pane owns this run's session, and so its resume hint.
///
/// A hosted run follows the same drop rule as a native one on purpose: a
/// session end the user did not ask for (tmux losing its server is one) keeps
/// the hint, because resuming is how such a run comes back.
fn owns_resume_hint(context: &ApplyContext) -> bool {
    !context.is_tmux_hosted || context.tmux_host_mode == Some(TmuxHostMode::LimpidHosted)
}

/// Whether the run this hint belongs to is one Limpid put in tmux, which is
/// what decides where the hint is kept (`SideWrite::SessionHint`).
fn is_hosted_in_tmux(context: &ApplyContext) -> bool {
    context.is_tmux_hosted && context.tmux_host_mode == Some(TmuxHostMode::LimpidHosted)
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
            let prompt = text_field(prompt);
            if next.first_prompt.is_none() {
                next.first_prompt.clone_from(&prompt);
            }
            next.last_prompt = prompt;
            observe_titles(next, titles.as_ref());
            if let Some(cwd) = turn_snapshot_cwd(event, descriptor) {
                writes.snapshot = Some(TurnSnapshotOp::Capture {
                    cwd: cwd.map(str::to_owned),
                });
            }
        }
        AgentEvent::ToolStarted { detail, .. } => {
            next.state = RunState::Running;
            next.detail = detail.as_deref().and_then(text_field);
        }
        AgentEvent::WaitingForInput { detail } => {
            next.state = RunState::NeedsInput;
            next.detail = detail.as_deref().and_then(text_field);
        }
        AgentEvent::ApprovalRequested { detail } => {
            next.state = RunState::NeedsInput;
            // The preceding tool event stored what needs approval (the
            // command or question); keep it over the provider's generic
            // "needs your permission" message.
            next.detail = prev
                .and_then(|record| record.detail.as_deref())
                .and_then(text_field)
                .or_else(|| detail.as_deref().and_then(text_field))
                .or_else(|| Some("permission".to_owned()));
        }
        AgentEvent::Compacting { context_tokens } => {
            next.state = RunState::Compacting;
            next.context_tokens = *context_tokens;
        }
        AgentEvent::ToolFinished { .. } | AgentEvent::CompactionFinished => {
            next.state = RunState::Running;
        }
        AgentEvent::TurnFinished { titles } => {
            next.state = RunState::Finished;
            next.run_started_at = None;
            observe_titles(next, titles.as_ref());
        }
        AgentEvent::Failed { error } => {
            next.state = RunState::Error;
            next.run_started_at = None;
            next.detail = text_field(error);
        }
        AgentEvent::Interrupted => {
            next.state = RunState::Finished;
            next.run_started_at = None;
        }
        AgentEvent::TitleChanged { titles } => observe_titles(next, Some(titles)),
        _ => {}
    }
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
        // rule reads the previous one, and it does so explicitly.
        detail: None,
        run_started_at: prev.and_then(|record| record.run_started_at.clone()),
        updated_at: now.to_owned(),
        last_hook_event: None,
        // Written by the session-end rule alone, so every other event clears
        // the reason along with the end it described.
        session_end_reason: None,
        // The shell wrote the token count only on the event that carried it.
        context_tokens: None,
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
        session_id: prev.and_then(|record| record.session_id.clone()),
        provider_session_title: prev
            .and_then(|record| record.provider_session_title.as_deref())
            .and_then(title_field),
        provider_generated_title: prev
            .and_then(|record| record.provider_generated_title.as_deref())
            .and_then(title_field),
        session_started_at: prev.and_then(|record| record.session_started_at.clone()),
        turn_base_tree: prev.and_then(|record| record.turn_base_tree.clone()),
        turn_root: prev.and_then(|record| record.turn_root.clone()),
        killed_by_limpid_at: prev.and_then(|record| record.killed_by_limpid_at.clone()),
        resume_attempted_at: prev.and_then(|record| record.resume_attempted_at.clone()),
        tmux_socket_path: context.tmux.as_ref().map(|tmux| tmux.socket_path.clone()),
        tmux_session_id: None,
        tmux_pane_id: context.tmux.as_ref().map(|tmux| tmux.pane.clone()),
        tmux_server_pid: context
            .tmux
            .as_ref()
            .map(|tmux| tmux.server_pid.to_string()),
        tmux_server_started_at: context
            .tmux
            .as_ref()
            .map(|tmux| server_started_at(prev, tmux)),
        extra: prev.map(|record| record.extra.clone()).unwrap_or_default(),
    }
}

/// The start time of the server the run is in, as the record should carry it.
///
/// Read afresh on every event, because the socket can come to be served by
/// another server run. It cannot be read once the server is gone, and a
/// killed server takes its agent with it, so the agent's last hook runs just
/// after that: the time the record already holds for the same server stays,
/// or the host could never again tell that server's panes from a later one's
/// (`endpoint_key`). A different pid is a different server run, and what was
/// known about the earlier one says nothing about it.
fn server_started_at(prev: Option<&RunRecord>, tmux: &TmuxEndpoint) -> String {
    if let Some(started) = tmux.server_started_at {
        return started.to_string();
    }
    prev.filter(|record| {
        record.tmux_socket_path.as_deref() == Some(tmux.socket_path.as_str())
            && record.tmux_server_pid.as_deref() == Some(tmux.server_pid.to_string().as_str())
    })
    .and_then(|record| record.tmux_server_started_at.clone())
    .unwrap_or_default()
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
        AgentEvent::Compacting { .. } => "compacting",
        AgentEvent::CompactionFinished => "compaction_finished",
        AgentEvent::TurnFinished { .. } => "turn_finished",
        AgentEvent::Failed { .. } => "failed",
        AgentEvent::Interrupted => "interrupted",
        AgentEvent::CwdChanged { .. } => "cwd_changed",
        AgentEvent::WorktreeCreated { .. } => "worktree_created",
        AgentEvent::TitleChanged { .. } => "title_changed",
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
mod tests {
    use super::*;
    use limpid_agent_model::ProviderId;
    use std::collections::BTreeSet;

    const NOW: &str = "2026-09-14T00:00:00Z";
    const LATER: &str = "2026-09-14T00:00:05Z";

    fn context() -> ApplyContext {
        ApplyContext {
            run_id: "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11".into(),
            pane_id: "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10".into(),
            pid: Some(4242),
            tmux: None,
            is_tmux_hosted: false,
            tmux_host_mode: None,
        }
    }

    fn descriptor(name: &str, capabilities: BTreeSet<Capability>) -> ProviderDescriptor {
        let id = ProviderId::new(name).expect("provider id");
        ProviderDescriptor {
            display_name: name.to_owned(),
            capabilities,
            pid_sweep_interval_ms: 3_000,
            state_directory: "states".to_owned(),
            session_directory: "sessions".to_owned(),
            cwd_events_directory: None,
            process_names: Vec::new(),
            session_end_drop_reasons: Vec::new(),
            session_end_restart_reasons: Vec::new(),
            id,
        }
    }

    fn claude() -> ProviderDescriptor {
        let mut claude = descriptor(
            "claude",
            BTreeSet::from([
                Capability::SessionTitle,
                Capability::SessionEndDropsSession,
                Capability::Resume,
                Capability::CwdEvents,
                Capability::TurnSnapshot,
            ]),
        );
        claude.session_end_drop_reasons = ["clear", "logout", "exit", "prompt_input_exit", "quit"]
            .into_iter()
            .map(str::to_owned)
            .collect();
        claude.session_end_restart_reasons = vec!["clear".to_owned()];
        claude
    }

    fn codex() -> ProviderDescriptor {
        descriptor(
            "codex",
            BTreeSet::from([Capability::Resume, Capability::TurnSnapshot]),
        )
    }

    fn started(title: Option<&str>) -> AgentEvent {
        AgentEvent::SessionStarted {
            compact: false,
            session_id: Some("session-1".into()),
            session_title: title.map(str::to_owned),
            cwd: Some("/repo".into()),
        }
    }

    fn prompt(text: &str) -> AgentEvent {
        AgentEvent::PromptSubmitted {
            prompt: text.into(),
            titles: None,
            cwd: Some("/repo".into()),
        }
    }

    /// Applies `events` in order and returns the final record plus every
    /// side write and snapshot op, the way the runtime would see them.
    fn run(
        descriptor: &ProviderDescriptor,
        events: &[AgentEvent],
    ) -> (RunRecord, Vec<SideWrite>, Vec<TurnSnapshotOp>) {
        let mut record: Option<RunRecord> = None;
        let mut sides = Vec::new();
        let mut snapshots = Vec::new();
        for event in events {
            let writes = apply(record.as_ref(), event, &context(), descriptor, NOW);
            sides.extend(writes.side);
            snapshots.extend(writes.snapshot);
            if let Some(next) = writes.run {
                record = Some(next);
            }
        }
        (
            record.expect("at least one event writes a record"),
            sides,
            snapshots,
        )
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
                cwd: Some("/repo".into()),
                hosted_in_tmux: false,
            }]
        );
        assert_eq!(writes.snapshot, None);
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
            &AgentEvent::TurnFinished { titles: None },
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
            &descriptor("claude", BTreeSet::from([Capability::Resume])),
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
                session_id: "session-1".into(),
                hosted_in_tmux: false,
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
        assert_eq!(restarted.state, RunState::Idle);
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
            &AgentEvent::TurnFinished { titles: None },
            &context(),
            &claude(),
            LATER,
        )
        .run
        .expect("record");
        assert_eq!(finished.state_episode_token.as_deref(), Some("5"));
    }

    fn tmux_context(mode: Option<TmuxHostMode>) -> ApplyContext {
        ApplyContext {
            tmux: Some(TmuxEndpoint {
                socket_path: "/tmp/tmux-501/limpid".into(),
                pane: "%3".into(),
                server_pid: 777,
                server_started_at: Some(1_700_000_000),
            }),
            is_tmux_hosted: true,
            tmux_host_mode: mode,
            pid: None,
            ..self::context()
        }
    }

    fn ended(reason: &str) -> AgentEvent {
        AgentEvent::SessionEnded {
            reason: Some(reason.into()),
            session_id: Some("session-1".into()),
        }
    }

    #[test]
    fn tmux_hosting_marks_the_record_and_withholds_the_hint_in_the_users_tmux() {
        // Inside the user's own tmux the pane only shows a client, and a mode
        // this build cannot read is treated the same way.
        for mode in [Some(TmuxHostMode::Manual), None] {
            let context = tmux_context(mode);
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
            assert!(writes.side.is_empty(), "{mode:?}");

            let ending = ended("prompt_input_exit");
            let writes = apply(Some(&record), &ending, &context, &claude(), LATER);
            assert!(writes.side.is_empty(), "{mode:?}");
        }
    }

    /// A killed server takes its agent with it, and the agent's last hook
    /// runs after the server is gone: its start time can no longer be read.
    /// The run is still the one the record named, so what the record knew
    /// about its server stays, or the host could never again tell that
    /// server's panes from a later one's.
    #[test]
    fn a_server_that_can_no_longer_be_read_keeps_the_start_time_already_recorded() {
        let context = tmux_context(Some(TmuxHostMode::LimpidHosted));
        let record = apply(None, &started(None), &context, &claude(), NOW)
            .run
            .expect("record");

        let mut gone = context.clone();
        if let Some(tmux) = gone.tmux.as_mut() {
            tmux.server_started_at = None;
        }
        let after = apply(Some(&record), &ended("other"), &gone, &claude(), LATER)
            .run
            .expect("record");
        assert_eq!(after.tmux_server_started_at.as_deref(), Some("1700000000"));

        // A different server on the same socket is a different run of it,
        // and what was known about the first one says nothing about it.
        let mut other = gone;
        if let Some(tmux) = other.tmux.as_mut() {
            tmux.server_pid = 778;
        }
        let moved = apply(Some(&record), &ended("other"), &other, &claude(), LATER)
            .run
            .expect("record");
        assert_eq!(moved.tmux_server_started_at.as_deref(), Some(""));
    }

    #[test]
    fn a_run_limpid_hosts_in_tmux_keeps_a_hint_like_a_native_one() {
        // Limpid gave the agent a session of its own, so the pane id names the
        // pane that owns it and resuming there cannot start it twice.
        let context = tmux_context(Some(TmuxHostMode::LimpidHosted));
        let writes = apply(None, &started(None), &context, &claude(), NOW);
        assert_eq!(
            writes.side,
            vec![SideWrite::SessionHint {
                session_id: "session-1".into(),
                cwd: Some("/repo".into()),
                // Somewhere a build from before mirror tabs does not read,
                // or it would resume this conversation in a plain shell
                // while the agent is still having it in tmux.
                hosted_in_tmux: true,
            }]
        );
        let record = writes.run.expect("record");
        assert_eq!(record.is_tmux_hosted, Some(true));

        // The user ending the session drops it.
        let ending = ended("prompt_input_exit");
        let writes = apply(Some(&record), &ending, &context, &claude(), LATER);
        assert_eq!(
            writes.side,
            vec![SideWrite::DeleteSessionHint {
                session_id: "session-1".into(),
                hosted_in_tmux: true,
            }]
        );
        assert!(has_session_ended(
            &writes.run.expect("record"),
            Some(&claude())
        ));

        // An end the user did not ask for keeps it, so the run can come back.
        let writes = apply(Some(&record), &ended("other"), &context, &claude(), LATER);
        assert!(writes.side.is_empty());
    }

    #[test]
    fn a_session_end_is_recognized_from_either_writer() {
        let (mut record, _, _) = run(&claude(), &[started(None)]);
        assert!(!has_session_ended(&record, Some(&claude())));
        record.last_hook_event = Some("SessionEnd".into());
        assert!(has_session_ended(&record, Some(&claude())));
        record.last_hook_event = Some("session_ended".into());
        assert!(has_session_ended(&record, Some(&claude())));
        record.last_hook_event = None;
        assert!(!has_session_ended(&record, Some(&claude())));
    }

    /// `/clear` ends the conversation and keeps the agent, so the window
    /// between that end and the start that follows it must not read as an
    /// agent that has gone: a tab is closed on that answer.
    #[test]
    fn a_session_end_the_agent_survives_is_not_an_ended_agent() {
        let (record, _, _) = run(&claude(), &[started(None), ended("clear")]);
        assert_eq!(record.session_end_reason.as_deref(), Some("clear"));
        assert!(!has_session_ended(&record, Some(&claude())));
        // The same end from a provider that never restarts in place, and the
        // same record read without a descriptor, are both an agent that left.
        assert!(has_session_ended(&record, Some(&codex_like())));
        assert!(has_session_ended(&record, None));

        // Every other reason Claude gives is Claude on its way out.
        let (leaving, _, _) = run(&claude(), &[started(None), ended("prompt_input_exit")]);
        assert!(has_session_ended(&leaving, Some(&claude())));

        // And the start that follows clears the reason with the end.
        let (restarted, _, _) = run(
            &claude(),
            &[started(None), ended("clear"), started(Some("session-2"))],
        );
        assert_eq!(restarted.session_end_reason, None);
        assert!(!has_session_ended(&restarted, Some(&claude())));
    }

    /// A provider that states no reason it survives, which is every provider
    /// but Claude today.
    fn codex_like() -> ProviderDescriptor {
        let mut descriptor = claude();
        descriptor.session_end_restart_reasons = Vec::new();
        descriptor
    }

    #[test]
    fn host_modes_parse_only_the_shims_spelling() {
        assert_eq!(
            TmuxHostMode::from_shim_value("limpidHosted"),
            Some(TmuxHostMode::LimpidHosted)
        );
        assert_eq!(
            TmuxHostMode::from_shim_value("manual"),
            Some(TmuxHostMode::Manual)
        );
        assert_eq!(TmuxHostMode::from_shim_value("LimpidHosted"), None);
        assert_eq!(TmuxHostMode::from_shim_value(""), None);
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
                AgentEvent::TurnFinished { titles: None },
                AgentEvent::TitleChanged {
                    titles: Titles {
                        session_title: None,
                        generated_title: Some("Gen\u{7}erated".into()),
                    },
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
            &AgentEvent::TurnFinished { titles: None },
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
            "lastHookEvent": "UserPromptSubmit",
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
}
