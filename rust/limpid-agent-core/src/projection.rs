//! Reducing run records into what the interface shows.
//!
//! One pass reads every record the host could find, decides which are current,
//! works out which panes each run occupies, picks the one badge each pane
//! shows, and names the tabs. It owns no file, no timer, and no provider
//! branch: capabilities come in with the descriptors, process liveness and
//! focus come in as facts the host already looked up, and anything that has to
//! change on disk leaves as a command.
//!
//! The pass is stateful in one direction only. `ProjectionState` carries what
//! cannot be recomputed from the records alone — which revisions were already
//! accepted, which attention episode each run is in — and the bridge's engine
//! keeps it for the next pass; the host never sees it.

use crate::title::{TitleCandidates, resolve_title};
use crate::turn_rules::conversation_of;
use limpid_agent_model::{
    AcceptedRun, AttachmentResolution, AttentionMarks, Badge, Capability, Command, CommandOp,
    ConversationKey, ConversationTurns, EpisodeStamp, Instants, Precondition, ProgramState,
    Projection, ProjectionInput, ProjectionState, ProviderDescriptor, ProviderId, RecordFile,
    RunRecord, RunState, RuntimePresentation, SessionInfo, SnapshotStatus, StopReason, Target,
    TurnRecord, TurnSummary, VIEWED_FINISHED_RETENTION_SECS, parse_utc_seconds, seconds_between,
};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

/// Priority of a finished run the user has already looked at: still visible,
/// but below anything that has not been seen.
const VIEWED_FINISHED_PRIORITY: i16 = 1;
/// Priority of an unseen finished run, above every non-attention state so a
/// completed turn is not buried by a running one in another pane. Taken from
/// `RunState::priority` so a change to that order cannot leave it behind.
const UNSEEN_FINISHED_PRIORITY: i16 = RunState::Finished.priority() as i16;
/// Priority of a finished run the user saw more than a day ago. Negative, so an
/// aged-out run loses to every state including the unknown one and the pane
/// really does clear.
///
/// There is deliberately no "no badge" priority. Every accepted record yields
/// a badge, because a state string this build does not know decodes as
/// unknown rather than failing and dropping the record.
const AGED_OUT_PRIORITY: i16 = -1;

/// Reduces the records the host found into the projection and the commands it
/// should apply, for a host that reads no provider transcript. No wait counts
/// as declined there, though a waiting run whose process died still ends in
/// error (`project_with`).
#[must_use]
pub fn project(
    previous: &ProjectionState,
    input: &ProjectionInput,
    now: &Instants,
) -> (ProjectionState, Projection, Vec<Command>) {
    project_with(previous, input, now, &mut |_, _| false)
}

/// Asks whether the transcript at a path shows that the person declined the
/// call a run of the provider waits on. The projection reads no file, so the
/// caller answers; the bridge's engine reads the transcript through the
/// provider's adapter and keeps what it read while the file is unchanged.
pub type DeclinedWait<'a> = dyn FnMut(&ProviderId, &str) -> bool + 'a;

/// This is `project`, with `declined` to ask about each run that waits inside
/// a turn and whose record names its transcript. Such a run whose wait the
/// person declined, and a run whose work in a turn the person stopped, shows
/// as its turn stopped (`stopped_badge`): Claude sends no hook for an Esc at
/// its question or permission prompt, nor for an Esc or Ctrl+C while it
/// works, so the record still says it waits or works until the host writes
/// the end the pass asks for (`CommandOp::EndStoppedTurn`).
#[must_use]
pub fn project_with(
    previous: &ProjectionState,
    input: &ProjectionInput,
    now: &Instants,
    declined: &mut DeclinedWait<'_>,
) -> (ProjectionState, Projection, Vec<Command>) {
    let mut state = ProjectionState {
        accepted: accept_records(previous, input),
        turns: carry_turns(&previous.turns, &input.turn_files),
        ..previous.clone()
    };

    let exited: BTreeSet<String> = crate::gc::retiring(&state.accepted, input, now)
        .into_iter()
        .filter(|id| crate::gc::died_at_work(&state.accepted[*id].record))
        .map(str::to_owned)
        .collect();
    let mut stopped_turns: Vec<(String, StoppedBy)> = Vec::new();
    let runtimes = build_runtimes(&mut state, input, &exited, declined, &mut stopped_turns);
    let pane_to_tab = pane_to_tab(input);
    let alive: BTreeSet<Uuid> = pane_to_tab.keys().copied().collect();
    let badges = dominant_badges(&runtimes, input, &pane_to_tab, now);
    let sessions = session_infos(input, &alive);
    let tab_titles = tab_titles(input, &badges);
    let marks_to_keep = surviving_marks(&input.marks, &runtimes);
    let mut commands = crate::gc::sweep(&state.accepted, input, &alive, now);
    commands.extend(crate::turn_retention::sweep(previous, &state, input, now));
    commands.extend(crate::events::route(&mut state, input, &alive));
    commands.extend(crate::notifications::observe(
        &mut state.outbox,
        &runtimes,
        input,
        &pane_to_tab,
        now,
    ));
    commands.extend(seen_where_the_user_is_looking(&runtimes, input));
    commands.extend(stopped_turns.iter().filter_map(|(storage_id, evidence)| {
        end_stopped_turn(storage_id, &state.accepted[storage_id], *evidence)
    }));
    let resume_candidates = resume_candidates(input, &sessions, &hints_retired(&commands, input));

    state.episodes = runtimes
        .iter()
        .map(|runtime| {
            (
                runtime.id.clone(),
                EpisodeStamp {
                    state: runtime.badge.state,
                    token: runtime.episode_token.clone(),
                },
            )
        })
        .collect();

    let projection = Projection {
        runtimes,
        badges,
        sessions,
        tab_titles,
        marks_to_keep,
        resume_candidates,
        // Recomputed when a turn changed or a run came or went, the two
        // things the reading depends on.
        conversations: (state.turns != previous.turns
            || previous.turns.is_empty()
            || live_runs(&state) != live_runs(previous))
        .then(|| conversations(input, &state.turns, &live_runs(&state))),
        next_pass_in_ms: crate::notifications::next_pass_in_ms(&state.outbox, now),
    };
    (state, projection, commands)
}

/// Decides which records are current.
///
/// A record is taken when it is newer than the copy already accepted, where
/// newer means a higher revision. Version 2 records predate revisions, so they
/// fall back to comparing the timestamp as text — sound only because the format
/// is fixed-width and UTC.
///
/// Entries survive a pass when their file is still there, whether or not it
/// could be read. A record that momentarily fails to read must keep its badge
/// rather than blink out and come back on the next scan.
fn accept_records(
    previous: &ProjectionState,
    input: &ProjectionInput,
) -> BTreeMap<String, AcceptedRun> {
    let present: BTreeSet<&str> = input
        .records
        .iter()
        .map(|file| file.name.as_str())
        .collect();
    let mut accepted: BTreeMap<String, AcceptedRun> = previous
        .accepted
        .iter()
        .filter(|(id, _)| present.contains(id.as_str()))
        .map(|(id, run)| (id.clone(), run.clone()))
        .collect();

    for file in &input.records {
        let Some(record) = decode(file) else { continue };
        let storage_id = storage_id(&record);
        // The file name is the only thing separating one run's record from
        // another's, so a record that disagrees with its own name is not
        // trustworthy enough to display.
        if storage_id != file.name {
            continue;
        }
        if let Some(current) = accepted.get(&storage_id)
            && !is_newer(&record, &current.record)
        {
            continue;
        }
        accepted.insert(
            storage_id,
            AcceptedRun {
                provider: file.provider.clone(),
                record,
            },
        );
    }
    accepted
}

fn decode(file: &RecordFile) -> Option<RunRecord> {
    let content = file.content.as_deref()?;
    let record = RunRecord::decode(content.as_bytes()).ok()?;
    Uuid::parse_str(&record.pane_id).ok()?;
    Some(record)
}

/// The record's file name: its run id when it has one, upper-cased, and its
/// pane id otherwise. Records from before run ids existed are keyed by pane.
fn storage_id(record: &RunRecord) -> String {
    match record.run_id.as_deref() {
        Some(run_id) if Uuid::parse_str(run_id).is_ok() => run_id.to_uppercase(),
        _ => record.pane_id.to_uppercase(),
    }
}

fn is_newer(candidate: &RunRecord, current: &RunRecord) -> bool {
    match (candidate.revision, current.revision) {
        (Some(candidate), Some(current)) => candidate > current,
        // A run that has started numbering never loses to one that has not:
        // the numbered record is the one a version 3 writer produced.
        (Some(_), None) => true,
        (None, Some(_)) => false,
        // Both predate revisions. The timestamp is fixed-width UTC, so
        // comparing it as text orders them correctly.
        (None, None) => candidate.updated_at > current.updated_at,
    }
}

/// Builds one presentation per accepted record and settles its attention
/// episode. A run in `exited` (storage ids) died at work and is retired this
/// pass; it shows as stopped (`exited_badge`). A run whose turn the person
/// stopped shows as its turn stopped (`stopped_badge`), and its storage id
/// goes into `stopped_turns`, for the command that writes the end.
fn build_runtimes(
    state: &mut ProjectionState,
    input: &ProjectionInput,
    exited: &BTreeSet<String>,
    declined: &mut DeclinedWait<'_>,
    stopped_turns: &mut Vec<(String, StoppedBy)>,
) -> Vec<RuntimePresentation> {
    let mut runtimes: Vec<RuntimePresentation> = state
        .accepted
        .iter()
        .map(|(storage_id, run)| {
            let capabilities = capabilities_of(input, &run.provider);
            let id = RuntimePresentation::identifier(
                &run.provider,
                run.record.run_id.as_deref().unwrap_or(&run.record.pane_id),
            );
            let (panes, attachment) = panes_for(&run.record, input);
            let event_token = event_token(&run.record);
            let episode_token = episode_token(state, &id, &run.record);
            let conversation = conversation_of(
                &run.provider,
                Some(&run.record),
                run.record.run_id.as_deref().unwrap_or(&run.record.pane_id),
            );
            let badge = badge_from(&run.record, capabilities);
            let badge = if exited.contains(storage_id) {
                exited_badge(badge)
            } else if let Some(evidence) = stopped_turn(run, input, declined) {
                stopped_turns.push((storage_id.clone(), evidence));
                stopped_badge(badge, run.record.state)
            } else {
                badge
            };
            RuntimePresentation {
                badge,
                provider: run.provider.clone(),
                run_id: run.record.run_id.clone(),
                revision: run.record.revision,
                panes,
                attachment,
                tmux_endpoint_key: endpoint_key(&run.record),
                event_token,
                episode_token,
                id,
                pid: run.record.pid.clone(),
                session_id: run.record.session_id.clone(),
                conversation,
                current_turn_id: run.record.current_turn_id.clone(),
            }
        })
        .collect();
    runtimes.sort_by(|left, right| left.id.cmp(&right.id));
    runtimes
}

/// What was read of each turn, after this pass's files. A file sent with
/// content is read again; one sent by name keeps what was read before, which
/// is also how the host says it could not read the file this time. Content
/// that does not decode is dropped rather than kept from before: its writer
/// replaces the file whole, so this is a lasting failure (a damaged file),
/// and keeping the old summary would show the turn until the next launch
/// and not after. A turn whose name is not sent is gone. A record that
/// disagrees with its own file name is not shown, as with run records.
fn carry_turns(
    previous: &BTreeMap<String, TurnSummary>,
    files: &[RecordFile],
) -> BTreeMap<String, TurnSummary> {
    files
        .iter()
        .filter_map(|file| {
            let summary = match file.content.as_deref() {
                Some(content) => TurnRecord::decode(content.as_bytes())
                    .ok()
                    .filter(|record| {
                        record.turn_id == file.name
                            && record.provider == file.provider
                            && record.conversation.provider == file.provider
                    })
                    .map(|record| TurnSummary::of(&record)),
                None => previous.get(&file.name).cloned(),
            };
            summary.map(|summary| (file.name.clone(), summary))
        })
        .collect()
}

/// Whether `path`, a directory a record of `provider` names, is one where the
/// provider runs an agent of its own (`internal_agent_directories`) under its
/// default configuration directory in `input.home`. The hook runtime keeps
/// such an agent out of the records as they are written, against the home
/// the agent's environment names (`CODEX_HOME` included); this is the
/// reading side's guard for records a build before that rule left behind,
/// and it knows only the default home, since the host's environment is not
/// the agent's. The default home is read both as written and as the host
/// resolved it (`resolved_homes`): a record of an agent that canonicalized a
/// symlinked home names the target. Only the provider's own records are read
/// this way: a person may well run another agent, or keep a project, under
/// such a path.
fn is_internal_agent_directory(input: &ProjectionInput, provider: &ProviderId, path: &str) -> bool {
    let (Some(descriptor), Some(home)) = (input.providers.get(provider), input.home.as_deref())
    else {
        return false;
    };
    let path = std::path::Path::new(path);
    descriptor
        .is_internal_agent_directory(&descriptor.default_home(std::path::Path::new(home)), path)
        || input.resolved_homes.get(provider).is_some_and(|resolved| {
            descriptor.is_internal_agent_directory(std::path::Path::new(resolved), path)
        })
}

/// Whether the turn was taken in its provider's internal agent directory:
/// its snapshots or its repository say where it ran.
fn is_internal_agent_turn(input: &ProjectionInput, turn: &TurnSummary) -> bool {
    let snapshot_root = |status: &SnapshotStatus| match status {
        SnapshotStatus::Captured { root, .. } => Some(root.clone()),
        _ => None,
    };
    snapshot_root(&turn.begin)
        .into_iter()
        .chain(snapshot_root(&turn.end))
        .chain(turn.repository.clone())
        .any(|root| is_internal_agent_directory(input, &turn.conversation.provider, &root))
}

/// The run ids with a current record: the runs whose turns can still end.
fn live_runs(state: &ProjectionState) -> BTreeSet<String> {
    state
        .accepted
        .values()
        .filter_map(|run| run.record.run_id.clone())
        .collect()
}

/// The turns grouped by conversation, each in display order. A turn still
/// started behind a later turn of its own run, or whose run is gone, is read
/// as overtaken: its end will not come. A later turn of another run does not
/// overtake it: the same conversation resumed in a second pane runs beside
/// it, and a turn that ends later would otherwise read as incomplete until
/// then.
fn conversations(
    input: &ProjectionInput,
    turns: &BTreeMap<String, TurnSummary>,
    live_runs: &BTreeSet<String>,
) -> Vec<ConversationTurns> {
    let mut grouped: BTreeMap<ConversationKey, Vec<TurnSummary>> = BTreeMap::new();
    for turn in turns.values() {
        // A turn a provider's internal agent began is not the person's work
        // to read; it stays in the state so retention still sees it.
        if is_internal_agent_turn(input, turn) {
            continue;
        }
        grouped
            .entry(turn.conversation.clone())
            .or_default()
            .push(turn.clone());
    }
    grouped
        .into_iter()
        .map(|(key, mut turns)| {
            turns.sort_by(|left, right| {
                (left.display_number, &left.turn_id).cmp(&(right.display_number, &right.turn_id))
            });
            // The highest number each run has reached in this conversation.
            let mut latest: BTreeMap<String, u32> = BTreeMap::new();
            for turn in &turns {
                let number = latest.entry(turn.run_id.clone()).or_default();
                *number = (*number).max(turn.display_number);
            }
            let turns = turns
                .into_iter()
                .map(|turn| {
                    let is_behind = latest
                        .get(&turn.run_id)
                        .is_some_and(|number| *number > turn.display_number);
                    if is_behind || !live_runs.contains(&turn.run_id) {
                        turn.overtaken()
                    } else {
                        turn
                    }
                })
                .collect();
            ConversationTurns { key, turns }
        })
        .collect()
}

fn capabilities_of<'a>(
    input: &'a ProjectionInput,
    provider: &ProviderId,
) -> Option<&'a ProviderDescriptor> {
    input.providers.get(provider)
}

/// Which panes show this run.
///
/// A run hosted in tmux belongs to whichever panes are attached to its
/// endpoint, which is why one record can light up several badges and why the
/// answer can be "cannot tell yet": the topology probe may not have reported.
/// Everything else belongs to the single pane it was launched in.
fn panes_for(record: &RunRecord, input: &ProjectionInput) -> (Vec<Uuid>, AttachmentResolution) {
    let Some(key) = endpoint_key(record) else {
        // A run that says it is hosted in tmux but names no endpoint is
        // somewhere we cannot work out. Falling back to the pane it was
        // launched from would show it where it very likely is not: the
        // point of tmux is that the run outlives that pane.
        if record.is_tmux_hosted == Some(true) {
            return (Vec::new(), AttachmentResolution::Unresolved);
        }
        let Ok(pane) = Uuid::parse_str(&record.pane_id) else {
            return (Vec::new(), AttachmentResolution::Detached);
        };
        return (vec![pane], AttachmentResolution::Attached);
    };
    match input.presence.attachments.get(&key) {
        Some(panes) if panes.is_empty() => (Vec::new(), AttachmentResolution::Detached),
        Some(panes) => (panes.clone(), AttachmentResolution::Attached),
        None => (Vec::new(), AttachmentResolution::Unresolved),
    }
}

/// The key the host indexes tmux attachments by: the socket, the tmux
/// server's identity (its pid and start time, as the record names them), and
/// the tmux pane.
///
/// The server is part of it because a tmux server started again on the same
/// socket numbers its panes from `%0` again, and a record of a run on the old
/// server can outlive it (a tmux run's record is not swept by its pid). With
/// the socket and pane alone, that record and a new run's share a key, and
/// whichever is read first decides where both show. The host's probe matches
/// a pane on the same three (`TmuxTopology.locations(for:)`), so the key
/// names exactly what it can answer for.
///
/// The host builds the same key from what its own topology probe reported, so
/// the shape is a contract between two codebases rather than something either
/// one owns. `AgentProjectionPresence.key(for:)` is the other half, and a
/// test there pins this spelling. A record that names no server identity
/// leaves those parts empty, as the host does.
///
/// No part is escaped: the socket path is the only free text in it and comes
/// first, and the other three hold digits and `%` only, so the key splits
/// from the right into one endpoint even when the path holds a `|`.
fn endpoint_key(record: &RunRecord) -> Option<String> {
    let socket = record.tmux_socket_path.as_deref()?;
    let pane = record.tmux_pane_id.as_deref()?;
    if socket.is_empty() || pane.is_empty() {
        return None;
    }
    let server_pid = record.tmux_server_pid.as_deref().unwrap_or_default();
    let server_started_at = record.tmux_server_started_at.as_deref().unwrap_or_default();
    Some(format!("{socket}|{server_pid}|{server_started_at}|{pane}"))
}

/// Identifies one record write. The revision when the writer numbered it, and
/// the timestamp otherwise, which is all a version 2 record offers.
fn event_token(record: &RunRecord) -> String {
    record.revision.map_or_else(
        || record.updated_at.clone(),
        |revision| revision.to_string(),
    )
}

/// The token a viewed mark is taken against.
///
/// The writer stamps one on every record, and that is authoritative. The
/// fallbacks matter only for records a previous release wrote: keep the token
/// while the state holds, mint a new one when it changes. Either way the
/// effect is the same — a run that finishes, is seen, and finishes again is
/// unseen the second time.
fn episode_token(state: &ProjectionState, id: &str, record: &RunRecord) -> String {
    if let Some(token) = record.state_episode_token.as_deref()
        && !token.is_empty()
    {
        return token.to_owned();
    }
    match state.episodes.get(id) {
        Some(previous) if previous.state == record.state => previous.token.clone(),
        _ => record.revision.map_or_else(
            || record.updated_at.clone(),
            |revision| revision.to_string(),
        ),
    }
}

/// Turns a record into what a badge shows. The session title fields only reach
/// the badge for providers that have session titles; carrying them for one that
/// does not would let a stale value name a tab. The cache window is gated the
/// same way, so the interface can trust that a window it is handed came from a
/// provider that declared it can describe one.
fn badge_from(record: &RunRecord, descriptor: Option<&ProviderDescriptor>) -> Badge {
    let titled = descriptor.is_some_and(|it| it.has(Capability::SessionTitle));
    let caches = descriptor.is_some_and(|it| it.has(Capability::CacheWindow));
    let present = |value: &Option<String>| value.clone().filter(|it| !it.is_empty());
    let waits = record.state == RunState::NeedsInput;
    Badge {
        state: record.state,
        detail: present(&record.detail),
        // A record says what its wait is only while it waits.
        wait_kind: record.wait_kind.filter(|_| waits),
        tool: waits.then(|| present(&record.tool)).flatten(),
        run_started_at: present(&record.run_started_at),
        context_tokens: record.context_tokens,
        is_tmux_hosted: record.is_tmux_hosted,
        updated_at: record.updated_at.clone(),
        last_prompt: present(&record.last_prompt),
        first_prompt: present(&record.first_prompt),
        turn_base_tree: present(&record.turn_base_tree),
        turn_root: present(&record.turn_root),
        worktree_root: present(&record.worktree_root),
        conversation_id: titled.then(|| present(&record.session_id)).flatten(),
        provider_session_title: titled
            .then(|| present(&record.provider_session_title))
            .flatten(),
        provider_generated_title: titled
            .then(|| present(&record.provider_generated_title))
            .flatten(),
        session_started_at: present(&record.session_started_at),
        cache_window: caches.then(|| record.cache_window.clone()).flatten(),
        // The record keeps the last failure's limit through what follows;
        // it is the run's only while the run still rests in that error.
        usage_limit: (record.state == RunState::Error)
            .then(|| record.usage_limit.clone())
            .flatten(),
        stop_reason: None,
        has_prompt: record.has_prompt,
    }
}

/// The badge of a run whose process died at work, on the pass that retires
/// its record: in error, saying why. The detail (the tool it was using) is
/// dropped: it is not why the run stopped. No failure is announced for it
/// (`notifications`).
fn exited_badge(badge: Badge) -> Badge {
    Badge {
        state: RunState::Error,
        detail: None,
        wait_kind: None,
        tool: None,
        stop_reason: Some(StopReason::ProcessExited),
        ..badge
    }
}

/// What says the person stopped a turn, which the writer weighs differently
/// (`CommandOp::EndStoppedTurn::by_program_status`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StoppedBy {
    Transcript,
    ProgramStatus,
}

/// Returns what shows that the person stopped the turn a run is in, if
/// anything does. Only a run at work or waiting inside a turn is asked
/// about, so a pass reads nothing for a run at rest. Work or a wait outside a
/// turn (a late tool, or its permission) is left as the record says, as the
/// idle prompt leaves a wait (`idle_outcome`): no turn holds it to stop.
///
/// The agent's own status report comes first: one that says it is idle
/// again, sent no earlier than the record last changed, means the turn
/// stopped however the person stopped it, and it costs no read. Claude
/// reports `done`, not `idle`, at a turn's own end, and `working` straight
/// after an answer at its prompt, so `idle` in a turn is the person's Esc,
/// Ctrl+C, or "No". Otherwise the transcript the record names is asked, for
/// a wait only: a declined wait leaves its interrupt line there. Work the
/// person stopped where no report comes (inside tmux) ends with the idle
/// prompt a minute later (`idle_outcome`), as before.
fn stopped_turn(
    run: &AcceptedRun,
    input: &ProjectionInput,
    declined: &mut DeclinedWait<'_>,
) -> Option<StoppedBy> {
    let record = &run.record;
    let is_in_a_turn = record.run_started_at.is_some();
    let is_waiting = match record.state {
        RunState::NeedsInput if is_in_a_turn => true,
        RunState::Running | RunState::Compacting if is_in_a_turn => false,
        _ => return None,
    };
    if program_status_shows_idle(run, input) {
        return Some(StoppedBy::ProgramStatus);
    }
    (is_waiting
        && record
            .transcript_path
            .as_deref()
            .is_some_and(|path| declined(&run.provider, path)))
    .then_some(StoppedBy::Transcript)
}

/// Returns whether the run's own pane last reported, under the name the
/// provider gives its agent (`ProviderDescriptor::program_status_app`), that
/// the agent is idle, and reported it no earlier than the second the record
/// last changed. Only the pane's latest report counts, so an idle from
/// before the turn is no evidence: Claude reports the turn's work as the
/// prompt is sent, before its hook writes the record, and the wait before
/// the record says the run waits. Reports carry no fraction of a second in
/// the record's timestamp, so the same second counts.
fn program_status_shows_idle(run: &AcceptedRun, input: &ProjectionInput) -> bool {
    let Some(app) = input
        .providers
        .get(&run.provider)
        .and_then(|descriptor| descriptor.program_status_app.as_deref())
    else {
        return false;
    };
    let Ok(pane) = Uuid::parse_str(&run.record.pane_id) else {
        return false;
    };
    let Some(status) = input.program_status.get(&pane) else {
        return false;
    };
    let (Some(reported), Some(changed)) = (
        parse_utc_seconds(&status.observed_at),
        parse_utc_seconds(&run.record.updated_at),
    ) else {
        return false;
    };
    status.app == app && status.state == ProgramState::Idle && reported >= changed
}

/// Returns the badge of a run whose turn the person stopped: the turn
/// stopped, as an interrupt ends it (`lifecycle`), which is what the person
/// did, and why. A wait (`state` is `NeedsInput`) was declined
/// (`StopReason::WaitDeclined`), so the interface says so rather than that
/// it was answered; the wait's words go with the wait. Work was interrupted
/// (`StopReason::Interrupted`). The badge is the answer until the record
/// says the same: the pass also asks the host to write that end
/// (`end_stopped_turn`), and until the write lands every pass asks again;
/// the engine answers from what it read while the file is unchanged. The
/// episode stays the one the person stopped, since they saw it, so a finish
/// straight after a wait announces nothing, and a finish of interrupted
/// work is not announced (`notifications`). The write keeps the episode too
/// (`lifecycle::end_stopped_turn`).
fn stopped_badge(badge: Badge, state: RunState) -> Badge {
    let stop_reason = if state == RunState::NeedsInput {
        StopReason::WaitDeclined
    } else {
        StopReason::Interrupted
    };
    Badge {
        state: RunState::Finished,
        detail: None,
        wait_kind: None,
        tool: None,
        run_started_at: None,
        stop_reason: Some(stop_reason),
        ..badge
    }
}

/// Returns the command that writes the end of a turn the person stopped into
/// the run record and its turn, which no hook will
/// (`CommandOp::EndStoppedTurn`). It names the turn as this pass read it,
/// which the writer checks again under the record lock. It is `None` for a
/// record without an episode token, which only a writer from before tokens
/// leaves, and for one that names no transcript: a record from before the
/// prompt kept it, whose turn the idle prompt ends instead.
fn end_stopped_turn(storage_id: &str, run: &AcceptedRun, evidence: StoppedBy) -> Option<Command> {
    let record = &run.record;
    Some(Command::new(
        CommandOp::EndStoppedTurn {
            episode_token: record
                .state_episode_token
                .clone()
                .filter(|token| !token.is_empty())?,
            turn_id: record.current_turn_id.clone(),
            transcript_path: record.transcript_path.clone()?,
            by_program_status: evidence == StoppedBy::ProgramStatus,
        },
        Target::Record {
            provider: run.provider.clone(),
            storage_id: storage_id.to_owned(),
        },
        Precondition::None,
    ))
}

fn pane_to_tab(input: &ProjectionInput) -> BTreeMap<Uuid, Uuid> {
    input
        .tabs
        .iter()
        .flat_map(|tab| tab.panes.iter().map(|pane| (*pane, tab.id)))
        .collect()
}

/// Picks the one badge each pane shows per provider.
///
/// Highest priority wins, then the most recent update, then the storage id so
/// the result does not depend on directory order. Revision is deliberately not
/// a tiebreaker: two runs in the same pane number their revisions
/// independently, so comparing them would be comparing unrelated counters.
fn dominant_badges(
    runtimes: &[RuntimePresentation],
    input: &ProjectionInput,
    pane_to_tab: &BTreeMap<Uuid, Uuid>,
    now: &Instants,
) -> BTreeMap<Uuid, BTreeMap<ProviderId, Badge>> {
    let mut best: BTreeMap<Uuid, BTreeMap<ProviderId, (i16, &RuntimePresentation)>> =
        BTreeMap::new();
    for runtime in runtimes {
        let priority = display_priority(runtime, &input.marks, now);
        for pane in &runtime.panes {
            // A pane the interface no longer has cannot show anything, and
            // keeping its entry would leak a badge into the next tab that
            // reuses the id.
            if !pane_to_tab.contains_key(pane) {
                continue;
            }
            let slot = best.entry(*pane).or_default();
            match slot.get(&runtime.provider) {
                Some(current) if !outranks(priority, runtime, current.0, current.1) => {}
                _ => {
                    slot.insert(runtime.provider.clone(), (priority, runtime));
                }
            }
        }
    }
    best.into_iter()
        .map(|(pane, providers)| {
            (
                pane,
                providers
                    .into_iter()
                    .map(|(provider, (_, runtime))| (provider, runtime.badge.clone()))
                    .collect(),
            )
        })
        .collect()
}

fn outranks(
    priority: i16,
    runtime: &RuntimePresentation,
    current_priority: i16,
    current: &RuntimePresentation,
) -> bool {
    (priority, &runtime.badge.updated_at, &runtime.id)
        > (current_priority, &current.badge.updated_at, &current.id)
}

/// How loudly a run competes for its pane's badge.
///
/// Only a finished run is affected by attention: every other state speaks for
/// itself. A finished run the user has seen drops below anything unseen, and
/// one that has sat seen for a day drops out of the running entirely.
fn display_priority(runtime: &RuntimePresentation, marks: &AttentionMarks, now: &Instants) -> i16 {
    if runtime.badge.state != RunState::Finished {
        return i16::from(runtime.badge.state.priority());
    }
    if has_aged_out(runtime, marks, now) {
        return AGED_OUT_PRIORITY;
    }
    if is_viewed(runtime, marks) {
        return VIEWED_FINISHED_PRIORITY;
    }
    UNSEEN_FINISHED_PRIORITY
}

/// Marks a finished run viewed when the user can see a pane it is in.
///
/// Attention otherwise only changes when a pane comes into sight, so a turn
/// that finishes in a pane the user is already looking at would sit in the
/// waiting list unread until they looked away and back. The host reports
/// what can be seen (`seen_panes`), which is empty while the application is
/// in the background: nobody saw anything then. The first pass after launch
/// marks nothing either: what it finds was finished before the window
/// existed. The host marks it once a window shows its pane, as focusing a
/// pane always has, so this only waits for the window rather than marking
/// on the restore's word. A tmux pane that is not its window's active one is
/// likewise out of sight even when the surface showing that window is.
fn seen_where_the_user_is_looking(
    runtimes: &[RuntimePresentation],
    input: &ProjectionInput,
) -> Vec<Command> {
    if input.is_bootstrap {
        return Vec::new();
    }
    // Read for each run: two runs of one tmux session reach the same pane,
    // and only the one whose tmux pane is in front there is in sight.
    let in_sight = |runtime: &RuntimePresentation| {
        runtime.panes.iter().any(|pane| {
            input.seen_panes.contains(pane)
                && input
                    .presence
                    .shows(runtime.tmux_endpoint_key.as_deref(), pane)
        })
    };
    runtimes
        .iter()
        .filter(|runtime| runtime.badge.state == RunState::Finished)
        .filter(|runtime| in_sight(runtime))
        .filter(|runtime| !is_viewed(runtime, &input.marks))
        .map(|runtime| {
            Command::new(
                CommandOp::MarkViewed {
                    runtime_id: runtime.id.clone(),
                    token: runtime.episode_token.clone(),
                },
                Target::Host,
                Precondition::None,
            )
        })
        .collect()
}

fn is_viewed(runtime: &RuntimePresentation, marks: &AttentionMarks) -> bool {
    marks.viewed.get(&runtime.id) == Some(&runtime.episode_token)
}

/// A finished run the user saw is not interesting forever. Aging it out keeps a
/// machine left running overnight from opening to a wall of badges.
fn has_aged_out(runtime: &RuntimePresentation, marks: &AttentionMarks, now: &Instants) -> bool {
    is_viewed(runtime, marks)
        && seconds_between(&runtime.badge.updated_at, &now.wall)
            .is_some_and(|elapsed| elapsed > VIEWED_FINISHED_RETENTION_SECS)
}

/// What each pane can resume, from the provider's own hint.
fn session_infos(
    input: &ProjectionInput,
    alive: &BTreeSet<Uuid>,
) -> BTreeMap<Uuid, BTreeMap<ProviderId, SessionInfo>> {
    let mut sessions: BTreeMap<Uuid, BTreeMap<ProviderId, SessionInfo>> = BTreeMap::new();
    for file in &input.session_records {
        let Some(content) = file.content.as_deref() else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(content) else {
            continue;
        };
        let Some(pane) = value
            .get("paneId")
            .and_then(serde_json::Value::as_str)
            .and_then(|it| Uuid::parse_str(it).ok())
        else {
            continue;
        };
        // A hint for a pane the interface no longer has is not offerable.
        if !alive.contains(&pane) {
            continue;
        }
        // Nor is one a provider's internal agent left: resuming it would
        // put the pane in the provider's own directory, on a thread that
        // has no transcript to resume.
        if value
            .get("cwd")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|cwd| is_internal_agent_directory(input, &file.provider, cwd))
        {
            continue;
        }
        let Some(session_id) = value
            .get("sessionId")
            .and_then(serde_json::Value::as_str)
            .filter(|it| !it.is_empty())
        else {
            continue;
        };
        sessions.entry(pane).or_default().insert(
            file.provider.clone(),
            SessionInfo {
                session_id: session_id.to_owned(),
                cwd: value
                    .get("cwd")
                    .and_then(serde_json::Value::as_str)
                    .filter(|it| !it.is_empty())
                    .map(str::to_owned),
            },
        );
    }
    sessions
}

/// Names each tab after the agent session that started most recently in it.
///
/// Without that rule an older pane typing a new turn would re-emit its own
/// opening prompt and overwrite a newer pane's label. A provider with session
/// titles must also carry a conversation id before its titles are used, so a
/// record left over from a session that has ended cannot name the tab.
fn tab_titles(
    input: &ProjectionInput,
    badges: &BTreeMap<Uuid, BTreeMap<ProviderId, Badge>>,
) -> BTreeMap<Uuid, String> {
    let mut resolved = BTreeMap::new();
    for tab in &input.tabs {
        let Some((provider, badge)) = latest_session_badge(tab.panes.iter().copied(), badges)
        else {
            continue;
        };
        let has_session_titles = input
            .providers
            .get(provider)
            .is_some_and(|it| it.has(Capability::SessionTitle));
        if has_session_titles && badge.conversation_id.is_none() {
            continue;
        }
        let candidates = if has_session_titles {
            TitleCandidates {
                provider_session: badge.provider_session_title.as_deref(),
                provider_generated: badge.provider_generated_title.as_deref(),
                first_prompt: badge.first_prompt.as_deref(),
            }
        } else {
            TitleCandidates {
                first_prompt: badge.first_prompt.as_deref(),
                ..TitleCandidates::default()
            }
        };
        if let Ok(Some(title)) = resolve_title(candidates) {
            resolved.insert(tab.id, title);
        }
    }
    resolved
}

fn latest_session_badge(
    panes: impl Iterator<Item = Uuid>,
    badges: &BTreeMap<Uuid, BTreeMap<ProviderId, Badge>>,
) -> Option<(&ProviderId, &Badge)> {
    let mut best: Option<(&ProviderId, &Badge)> = None;
    for pane in panes {
        for (provider, badge) in badges.get(&pane).into_iter().flatten() {
            let Some(started) = badge.session_started_at.as_deref() else {
                continue;
            };
            let newer = best.is_none_or(|(_, current)| {
                current
                    .session_started_at
                    .as_deref()
                    .is_none_or(|it| started > it)
            });
            if newer {
                best = Some((provider, badge));
            }
        }
    }
    best
}

/// Trims marks down to the runs that still exist. Without this every run the
/// user ever looked at would stay in the mark set for the life of the session.
fn surviving_marks(marks: &AttentionMarks, runtimes: &[RuntimePresentation]) -> AttentionMarks {
    let live: BTreeSet<&str> = runtimes.iter().map(|it| it.id.as_str()).collect();
    AttentionMarks {
        viewed: marks
            .viewed
            .iter()
            .filter(|(id, _)| live.contains(id.as_str()))
            .map(|(id, token)| (id.clone(), token.clone()))
            .collect(),
    }
}

/// The hints this pass's sweep deletes, read as the host will apply them: a
/// retirement takes the pane's hint only while the hint still names the run
/// being retired (`Precondition::HintOwner`), so a hint a newer run took
/// stays on disk, and stays offerable.
fn hints_retired(commands: &[Command], input: &ProjectionInput) -> BTreeSet<(ProviderId, Uuid)> {
    fn walk<'a>(
        commands: &'a [Command],
        out: &mut Vec<(&'a ProviderId, Uuid, &'a Option<String>)>,
    ) {
        for command in commands {
            if let (
                CommandOp::Delete,
                Target::SessionHint { provider, pane },
                Precondition::HintOwner { run_id },
            ) = (&command.op, &command.target, &command.expect)
            {
                out.push((provider, *pane, run_id));
            }
            walk(&command.then, out);
        }
    }
    let mut deletions = Vec::new();
    walk(commands, &mut deletions);
    deletions
        .into_iter()
        .filter(|(provider, pane, run_id)| {
            input.session_records.iter().any(|file| {
                file.provider == **provider
                    && file
                        .content
                        .as_deref()
                        .and_then(|content| serde_json::from_str::<serde_json::Value>(content).ok())
                        .is_some_and(|hint| {
                            hint.get("paneId")
                                .and_then(serde_json::Value::as_str)
                                .and_then(|it| Uuid::parse_str(it).ok())
                                == Some(*pane)
                                && hint
                                    .get("runId")
                                    .and_then(serde_json::Value::as_str)
                                    .map(str::to_owned)
                                    == **run_id
                        })
            })
        })
        .map(|(provider, pane, _)| (provider.clone(), pane))
        .collect()
}

/// Which panes are worth offering a resume for.
///
/// A provider that defers steps aside when another provider already has a
/// session on the same pane. Two agents resuming into one terminal would fight
/// over it, and the one that got there first keeps it.
///
/// A hint this pass retires (`retired`) is not offered either, though its
/// session is still handed over: the pass that retires a run that died at
/// work is the one that shows its stop, and the stop ledger takes the
/// conversation's folder from that session. The candidate is what a restored
/// pane types a resume from, and a run that nothing claimed is not to be
/// resumed at launch (`session_lifecycle`): its stop is the person's to
/// resume, not the relaunch's.
fn resume_candidates(
    input: &ProjectionInput,
    sessions: &BTreeMap<Uuid, BTreeMap<ProviderId, SessionInfo>>,
    retired: &BTreeSet<(ProviderId, Uuid)>,
) -> BTreeMap<Uuid, BTreeSet<ProviderId>> {
    let mut candidates: BTreeMap<Uuid, BTreeSet<ProviderId>> = BTreeMap::new();
    for (pane, providers) in sessions {
        for provider in providers.keys() {
            let Some(descriptor) = input.providers.get(provider) else {
                continue;
            };
            if !descriptor.has(Capability::Resume) {
                continue;
            }
            if retired.contains(&(provider.clone(), *pane)) {
                continue;
            }
            // Resolved hints are the test, not badges. A run that has already
            // exited still leaves a session worth resuming, and a pane that
            // has one is already spoken for.
            if descriptor.has(Capability::ResumeDefersToOtherLiveSession)
                && providers.keys().any(|other| other != provider)
            {
                continue;
            }
            candidates
                .entry(*pane)
                .or_default()
                .insert(provider.clone());
        }
    }
    candidates
}

#[cfg(test)]
#[path = "projection_tests/mod.rs"]
mod tests;
