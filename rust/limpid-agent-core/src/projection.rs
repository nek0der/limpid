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
//! accepted, which attention episode each run is in — and is handed back for
//! the next pass. The host stores it without reading it.

use crate::title::{TitleCandidates, resolve_title};
use limpid_agent_model::{
    AcceptedRun, AttachmentResolution, AttentionMarks, Badge, Capability, Command, CommandOp,
    EpisodeStamp, Instants, Precondition, Projection, ProjectionInput, ProjectionState,
    ProviderDescriptor, ProviderId, RecordFile, RunRecord, RunState, RuntimePresentation,
    SessionInfo, Target, VIEWED_FINISHED_RETENTION_SECS, seconds_between,
};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

/// Priority of a finished run the user has already looked at: still visible,
/// but below anything that has not been seen.
const VIEWED_FINISHED_PRIORITY: i16 = 1;
/// Priority of an unseen finished run, above every non-attention state so a
/// completed turn is not buried by a running one in another pane.
const UNSEEN_FINISHED_PRIORITY: i16 = 3;
/// Priority of a run the user has explicitly dismissed. Negative, so a
/// dismissed run loses to every state including the unknown one and the pane
/// really does clear.
///
/// There is deliberately no "no badge" priority. Every accepted record yields
/// a badge, because a state string this build does not know decodes as
/// unknown rather than failing and dropping the record.
const DISMISSED_PRIORITY: i16 = -1;

/// Reduces the records the host found into the projection and the commands it
/// should apply.
#[must_use]
pub fn project(
    previous: &ProjectionState,
    input: &ProjectionInput,
    now: &Instants,
) -> (ProjectionState, Projection, Vec<Command>) {
    let mut state = ProjectionState {
        accepted: accept_records(previous, input),
        ..previous.clone()
    };

    let runtimes = build_runtimes(&mut state, input);
    let pane_to_tab = pane_to_tab(input);
    let alive: BTreeSet<Uuid> = pane_to_tab.keys().copied().collect();
    let badges = dominant_badges(&runtimes, input, &pane_to_tab, now);
    let sessions = session_infos(input, &alive);
    let tab_titles = tab_titles(input, &badges);
    let marks_to_keep = surviving_marks(&input.marks, &runtimes);
    let mut commands = crate::gc::sweep(&state.accepted, input, &alive, now);
    commands.extend(crate::events::route(&mut state, input, &alive));
    commands.extend(crate::notifications::observe(
        &mut state.outbox,
        &runtimes,
        input,
        &pane_to_tab,
        now,
    ));
    commands.extend(seen_where_the_user_is_looking(&runtimes, input));
    let resume_candidates = resume_candidates(input, &sessions, &state.accepted);

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
/// episode.
fn build_runtimes(
    state: &mut ProjectionState,
    input: &ProjectionInput,
) -> Vec<RuntimePresentation> {
    let mut runtimes: Vec<RuntimePresentation> = state
        .accepted
        .values()
        .map(|run| {
            let capabilities = capabilities_of(input, &run.provider);
            let id = RuntimePresentation::identifier(
                &run.provider,
                run.record.run_id.as_deref().unwrap_or(&run.record.pane_id),
            );
            let (panes, attachment) = panes_for(&run.record, input);
            let event_token = event_token(&run.record);
            let episode_token = episode_token(state, &id, &run.record);
            RuntimePresentation {
                badge: badge_from(&run.record, capabilities),
                provider: run.provider.clone(),
                run_id: run.record.run_id.clone(),
                revision: run.record.revision,
                panes,
                attachment,
                event_token,
                episode_token,
                id,
            }
        })
        .collect();
    runtimes.sort_by(|left, right| left.id.cmp(&right.id));
    runtimes
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

/// The key the host indexes tmux attachments by.
///
/// The host builds the same key from what its own topology probe reported, so
/// the shape is a contract between two codebases rather than something either
/// one owns. `AgentProjectionPresence.key(socketPath:pane:)` is the other
/// half, and a test there pins this spelling.
fn endpoint_key(record: &RunRecord) -> Option<String> {
    let socket = record.tmux_socket_path.as_deref()?;
    let pane = record.tmux_pane_id.as_deref()?;
    if socket.is_empty() || pane.is_empty() {
        return None;
    }
    Some(format!("{socket}|{pane}"))
}

/// Identifies one record write. The revision when the writer numbered it, and
/// the timestamp otherwise, which is all a version 2 record offers.
fn event_token(record: &RunRecord) -> String {
    record.revision.map_or_else(
        || record.updated_at.clone(),
        |revision| revision.to_string(),
    )
}

/// The token a viewed or dismissed mark is taken against.
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
/// does not would let a stale value name a tab.
fn badge_from(record: &RunRecord, descriptor: Option<&ProviderDescriptor>) -> Badge {
    let titled = descriptor.is_some_and(|it| it.has(Capability::SessionTitle));
    let present = |value: &Option<String>| value.clone().filter(|it| !it.is_empty());
    Badge {
        state: record.state,
        detail: present(&record.detail),
        run_started_at: present(&record.run_started_at),
        context_tokens: record.context_tokens,
        is_tmux_hosted: record.is_tmux_hosted,
        updated_at: record.updated_at.clone(),
        last_prompt: present(&record.last_prompt),
        first_prompt: present(&record.first_prompt),
        turn_base_tree: present(&record.turn_base_tree),
        turn_root: present(&record.turn_root),
        conversation_id: titled.then(|| present(&record.session_id)).flatten(),
        provider_session_title: titled
            .then(|| present(&record.provider_session_title))
            .flatten(),
        provider_generated_title: titled
            .then(|| present(&record.provider_generated_title))
            .flatten(),
        session_started_at: present(&record.session_started_at),
    }
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
/// one that was dismissed — explicitly, or by sitting seen for a day — drops
/// out of the running entirely.
fn display_priority(runtime: &RuntimePresentation, marks: &AttentionMarks, now: &Instants) -> i16 {
    if runtime.badge.state != RunState::Finished {
        return i16::from(runtime.badge.state.priority());
    }
    if is_dismissed(runtime, marks, now) {
        return DISMISSED_PRIORITY;
    }
    if is_viewed(runtime, marks) {
        return VIEWED_FINISHED_PRIORITY;
    }
    UNSEEN_FINISHED_PRIORITY
}

/// Marks a finished run viewed when the user is watching the pane it is in.
///
/// Attention otherwise only changes when focus moves, so a turn that finishes
/// in the pane the user is already looking at would sit in the waiting list
/// unread until they looked away and back. Being the focused pane is not
/// enough on its own: a pane stays focused while the application is in the
/// background, and nobody saw anything then. Nor is the first pass after
/// launch: what it finds was finished before the window existed, and it is
/// for the user to look at, not for the restore to mark as looked at. A tmux
/// pane that is not its window's active one is likewise out of sight even
/// when the surface showing that window has focus.
fn seen_where_the_user_is_looking(
    runtimes: &[RuntimePresentation],
    input: &ProjectionInput,
) -> Vec<Command> {
    if input.is_bootstrap {
        return Vec::new();
    }
    let Some(focus) = input.focus else {
        return Vec::new();
    };
    if !focus.is_active {
        return Vec::new();
    }
    if input
        .presence
        .locations
        .get(&focus.pane)
        .is_some_and(|location| !location.is_active)
    {
        return Vec::new();
    }
    runtimes
        .iter()
        .filter(|runtime| runtime.badge.state == RunState::Finished)
        .filter(|runtime| runtime.panes.contains(&focus.pane))
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

fn is_dismissed(runtime: &RuntimePresentation, marks: &AttentionMarks, now: &Instants) -> bool {
    if marks.dismissed.get(&runtime.id) == Some(&runtime.episode_token) {
        return true;
    }
    // A finished run the user saw is not interesting forever. Aging it out
    // keeps a machine left running overnight from opening to a wall of badges.
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
    let keep = |source: &BTreeMap<String, String>| {
        source
            .iter()
            .filter(|(id, _)| live.contains(id.as_str()))
            .map(|(id, token)| (id.clone(), token.clone()))
            .collect()
    };
    AttentionMarks {
        viewed: keep(&marks.viewed),
        dismissed: keep(&marks.dismissed),
    }
}

/// Which panes are worth offering a resume for.
///
/// A provider that defers steps aside when another provider already has a
/// session on the same pane. Two agents resuming into one terminal would fight
/// over it, and the one that got there first keeps it.
///
/// A conversation a run in tmux is still holding is not offered anywhere.
/// tmux keeps that run alive across a relaunch, so resuming the same session
/// in a pane would run it twice. This covers the hint the hosted run wrote
/// itself and one a native run left before the conversation was reopened in
/// tmux.
fn resume_candidates(
    input: &ProjectionInput,
    sessions: &BTreeMap<Uuid, BTreeMap<ProviderId, SessionInfo>>,
    accepted: &BTreeMap<String, AcceptedRun>,
) -> BTreeMap<Uuid, BTreeSet<ProviderId>> {
    let held_in_tmux: BTreeSet<(&ProviderId, &str)> = accepted
        .values()
        .filter(|run| crate::lifecycle::is_live_tmux_run(&run.record))
        .filter_map(|run| Some((&run.provider, run.record.session_id.as_deref()?)))
        .collect();
    let mut candidates: BTreeMap<Uuid, BTreeSet<ProviderId>> = BTreeMap::new();
    for (pane, providers) in sessions {
        for (provider, session) in providers {
            if held_in_tmux.contains(&(provider, session.session_id.as_str())) {
                continue;
            }
            let Some(descriptor) = input.providers.get(provider) else {
                continue;
            };
            if !descriptor.has(Capability::Resume) {
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
mod tests {
    use super::*;
    use limpid_agent_model::{Focus, PaneLocation, ProjectionState, TabPanes};

    const PANE: &str = "11111111-1111-4111-8111-111111111111";
    const RUN: &str = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1";

    fn claude() -> ProviderId {
        ProviderId::new("claude").expect("provider id")
    }

    fn record(revision: Option<u64>, updated_at: &str, state: &str) -> String {
        let revision = revision.map_or("null".to_owned(), |it| it.to_string());
        format!(
            r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{RUN}","revision":{revision},
               "state":"{state}","updatedAt":"{updated_at}"}}"#
        )
    }

    fn file(content: Option<String>) -> RecordFile {
        RecordFile {
            provider: claude(),
            name: RUN.to_owned(),
            content,
        }
    }

    fn accept(previous: &ProjectionState, files: Vec<RecordFile>) -> BTreeMap<String, AcceptedRun> {
        accept_records(
            previous,
            &ProjectionInput {
                records: files,
                ..ProjectionInput::default()
            },
        )
    }

    fn state_with(accepted: BTreeMap<String, AcceptedRun>) -> ProjectionState {
        ProjectionState {
            accepted,
            ..ProjectionState::default()
        }
    }

    /// One finished run in one pane, with the panes the session holds.
    fn finished_input(focus: Option<Focus>) -> ProjectionInput {
        ProjectionInput {
            providers: [(claude(), descriptor())].into_iter().collect(),
            records: vec![file(Some(record(
                Some(4),
                "2026-09-14T12:03:00Z",
                "finished",
            )))],
            tabs: vec![TabPanes {
                id: Uuid::new_v4(),
                panes: vec![PANE.parse().expect("pane")],
            }],
            focus,
            ..ProjectionInput::default()
        }
    }

    fn descriptor() -> ProviderDescriptor {
        ProviderDescriptor {
            id: claude(),
            display_name: "Claude".to_owned(),
            capabilities: std::collections::BTreeSet::default(),
            pid_sweep_interval_ms: 30_000,
            state_directory: "agent-states".to_owned(),
            session_directory: "sessions".to_owned(),
            cwd_events_directory: None,
            process_names: Vec::new(),
            session_end_drop_reasons: Vec::new(),
        }
    }

    fn viewed_marks(commands: &[Command]) -> usize {
        commands
            .iter()
            .filter(|command| matches!(command.op, CommandOp::MarkViewed { .. }))
            .count()
    }

    #[test]
    fn a_turn_that_finishes_where_the_user_is_looking_is_marked_seen() {
        // Attention otherwise only changes when focus moves, so without this
        // the run sits in the waiting list unread until the user looks away
        // and back at the pane they were already watching.
        let pane: Uuid = PANE.parse().expect("pane");
        let now = Instants {
            wall: "2026-09-14T12:04:00Z".to_owned(),
            monotonic_ms: 0,
        };
        let input = finished_input(Some(Focus {
            tab: Uuid::new_v4(),
            pane,
            is_active: true,
        }));
        let (_, _, commands) = project(&ProjectionState::default(), &input, &now);
        assert_eq!(viewed_marks(&commands), 1);

        // Behind another application nobody saw it, even though the pane is
        // still the focused one.
        let background = finished_input(Some(Focus {
            tab: Uuid::new_v4(),
            pane,
            is_active: false,
        }));
        let (_, _, commands) = project(&ProjectionState::default(), &background, &now);
        assert_eq!(viewed_marks(&commands), 0);

        // And with no focused pane at all there is nothing to have seen.
        let (_, _, commands) = project(&ProjectionState::default(), &finished_input(None), &now);
        assert_eq!(viewed_marks(&commands), 0);
    }

    #[test]
    fn the_first_pass_after_launch_marks_nothing_seen() {
        // What the restore finds was finished before the window existed. The
        // user has not looked at it yet, whatever pane the session says is
        // focused.
        let pane: Uuid = PANE.parse().expect("pane");
        let now = Instants {
            wall: "2026-09-14T12:04:00Z".to_owned(),
            monotonic_ms: 0,
        };
        let mut input = finished_input(Some(Focus {
            tab: Uuid::new_v4(),
            pane,
            is_active: true,
        }));
        input.is_bootstrap = true;
        let (state, _, commands) = project(&ProjectionState::default(), &input, &now);
        assert_eq!(viewed_marks(&commands), 0);

        // The pass after it behaves as usual.
        input.is_bootstrap = false;
        let (_, _, commands) = project(&state, &input, &now);
        assert_eq!(viewed_marks(&commands), 1);
    }

    #[test]
    fn a_tmux_pane_that_is_not_its_windows_active_one_is_out_of_sight() {
        // Focusing the surface that shows a tmux window does not show every
        // pane in that window; only the active one is on screen.
        let pane: Uuid = PANE.parse().expect("pane");
        let now = Instants {
            wall: "2026-09-14T12:04:00Z".to_owned(),
            monotonic_ms: 0,
        };
        let mut input = finished_input(Some(Focus {
            tab: Uuid::new_v4(),
            pane,
            is_active: true,
        }));
        input
            .presence
            .locations
            .insert(pane, PaneLocation { is_active: false });
        let (_, _, commands) = project(&ProjectionState::default(), &input, &now);
        assert_eq!(viewed_marks(&commands), 0);

        input
            .presence
            .locations
            .insert(pane, PaneLocation { is_active: true });
        let (_, _, commands) = project(&ProjectionState::default(), &input, &now);
        assert_eq!(viewed_marks(&commands), 1);
    }

    #[test]
    fn a_lower_revision_never_replaces_a_higher_one() {
        // Two writers can race on the same run across a backend switch. The
        // revision is what orders them; a stale read must not roll the badge
        // back to a state the run has already left.
        let first = accept(
            &ProjectionState::default(),
            vec![file(Some(record(
                Some(4),
                "2026-09-14T12:03:00Z",
                "finished",
            )))],
        );
        assert_eq!(first[RUN].record.state, RunState::Finished);

        let second = accept(
            &state_with(first.clone()),
            vec![file(Some(record(
                Some(2),
                "2026-09-14T12:01:00Z",
                "running",
            )))],
        );
        assert_eq!(second[RUN].record.state, RunState::Finished);

        let third = accept(
            &state_with(first),
            vec![file(Some(record(
                Some(5),
                "2026-09-14T12:04:00Z",
                "unknown",
            )))],
        );
        assert_eq!(third[RUN].record.state, RunState::Unknown);
    }

    #[test]
    fn records_without_revisions_fall_back_to_the_timestamp() {
        // Version 2 records predate revisions. The format is fixed-width UTC,
        // so comparing the text orders them.
        let first = accept(
            &ProjectionState::default(),
            vec![file(Some(record(None, "2026-09-14T12:03:00Z", "finished")))],
        );
        let older = accept(
            &state_with(first.clone()),
            vec![file(Some(record(None, "2026-09-14T12:01:00Z", "running")))],
        );
        assert_eq!(older[RUN].record.state, RunState::Finished);

        // A numbered record is the one a version 3 writer produced, so it wins
        // over an unnumbered one whatever the timestamps say.
        let numbered = accept(
            &state_with(first),
            vec![file(Some(record(Some(1), "2026-09-14T12:00:00Z", "idle")))],
        );
        assert_eq!(numbered[RUN].record.state, RunState::Idle);
    }

    #[test]
    fn a_file_that_cannot_be_read_keeps_the_record_already_accepted() {
        // A read can fail while a hook is mid-write. Dropping the run would
        // make its badge blink out and come back on the next scan.
        let first = accept(
            &ProjectionState::default(),
            vec![file(Some(record(
                Some(4),
                "2026-09-14T12:03:00Z",
                "running",
            )))],
        );
        let unreadable = accept(&state_with(first.clone()), vec![file(None)]);
        assert_eq!(unreadable[RUN].record.state, RunState::Running);

        // A file that is gone is a different matter: the run was retired.
        let removed = accept(&state_with(first), Vec::new());
        assert!(removed.is_empty());
    }

    #[test]
    fn a_record_that_disagrees_with_its_file_name_is_ignored() {
        // The file name is the only thing separating one run's record from
        // another's, so a mismatch is not trustworthy enough to display.
        let mut misnamed = file(Some(record(Some(1), "2026-09-14T12:00:00Z", "running")));
        misnamed.name = "SOMETHING-ELSE".to_owned();
        assert!(accept(&ProjectionState::default(), vec![misnamed]).is_empty());
    }

    #[test]
    fn a_conversation_held_in_tmux_is_not_offered_for_resume() {
        let pane: Uuid = PANE.parse().expect("pane");
        let mut descriptor = descriptor();
        descriptor.capabilities.insert(Capability::Resume);
        let hint = format!(r#"{{"schemaVersion":1,"paneId":"{PANE}","sessionId":"S"}}"#);
        let sessions = session_infos(
            &ProjectionInput {
                session_records: vec![file(Some(hint))],
                ..ProjectionInput::default()
            },
            &[pane].into_iter().collect(),
        );
        let input = ProjectionInput {
            providers: [(claude(), descriptor)].into_iter().collect(),
            ..ProjectionInput::default()
        };
        let mut record =
            RunRecord::decode(record(Some(1), "2026-09-14T12:00:00Z", "running").as_bytes())
                .expect("record");
        record.session_id = Some("S".to_owned());
        record.tmux_socket_path = Some("/tmp/socket".to_owned());
        record.last_hook_event = Some("session_started".to_owned());
        let accepted = |record: &RunRecord| {
            [(
                RUN.to_owned(),
                AcceptedRun {
                    provider: claude(),
                    record: record.clone(),
                },
            )]
            .into_iter()
            .collect::<BTreeMap<_, _>>()
        };

        // Still running in tmux: resuming would start it a second time.
        assert!(resume_candidates(&input, &sessions, &accepted(&record)).is_empty());

        // Once its session has ended, the hint is an ordinary resume again.
        let mut ended = record.clone();
        ended.last_hook_event = Some("session_ended".to_owned());
        assert_eq!(
            resume_candidates(&input, &sessions, &accepted(&ended))[&pane].len(),
            1
        );

        // A different conversation, or one held outside tmux, is not held.
        let mut other = record.clone();
        other.session_id = Some("T".to_owned());
        assert_eq!(
            resume_candidates(&input, &sessions, &accepted(&other)).len(),
            1
        );
        let mut native = record;
        native.tmux_socket_path = None;
        assert_eq!(
            resume_candidates(&input, &sessions, &accepted(&native)).len(),
            1
        );
    }

    #[test]
    fn a_tmux_run_waits_rather_than_showing_nowhere() {
        // Until the topology probe reports, the panes a tmux-hosted run
        // occupies are unknown. Treating that as "no panes" would drop its
        // notification instead of holding it.
        let mut record =
            RunRecord::decode(record(Some(1), "2026-09-14T12:00:00Z", "running").as_bytes())
                .expect("record");
        record.tmux_socket_path = Some("/tmp/socket".to_owned());
        record.tmux_pane_id = Some("%3".to_owned());

        let input = ProjectionInput::default();
        let (panes, resolution) = panes_for(&record, &input);
        assert!(panes.is_empty());
        assert_eq!(resolution, AttachmentResolution::Unresolved);
    }
}
