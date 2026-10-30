//! Deciding which lifecycle changes are worth announcing.
//!
//! Separating the decision from the delivery is what makes the rule testable
//! and what lets an announcement wait. A run hosted in tmux may be attached to
//! no pane the moment it finishes, and firing at nothing would lose the event
//! while dropping it would lose it permanently. So a transition becomes a
//! pending entry, and the entry is released when the run has somewhere to be
//! seen, expired when it has waited too long, or discarded when the run moves
//! on to a different state. A finished turn's entry also waits a moment
//! (`FINISHED_NOTICE_HOLD_MS`) before it is released: an instruction queued
//! while the agent worked starts the next turn right after the `Stop`, which
//! discards the entry, so a turn with another one queued behind it says
//! nothing.
//!
//! Two tokens do different jobs here. The event token identifies one record
//! write and is what the host echoes back so a stale delivery cannot retire a
//! newer entry. The episode token identifies a stretch of the same state, and
//! is what decides that a run asking for input again is a new thing to say
//! rather than a repeat.

use limpid_agent_model::{
    AttachmentResolution, Badge, Command, CommandOp, CommandOutcome, FINISHED_NOTICE_HOLD_MS,
    Focus, Instants, NOTIFICATION_BODY_CHARS, NOTIFICATION_PENDING_LIFETIME_MS, NotificationKind,
    NotifyCommand, ObservedRuntime, OutboxState, PendingNotification, Precondition,
    ProjectionInput, PromptKind, RunState, RuntimePresentation, StopReason, Target,
    classify_prompt,
};
use std::collections::BTreeMap;
use uuid::Uuid;

/// Updates the outbox for this pass and returns what the host should deliver.
pub(crate) fn observe(
    outbox: &mut OutboxState,
    runtimes: &[RuntimePresentation],
    input: &ProjectionInput,
    pane_to_tab: &BTreeMap<Uuid, Uuid>,
    now: &Instants,
) -> Vec<Command> {
    retire_delivered(outbox, &input.acknowledged);
    prune(outbox, runtimes, now);

    if input.is_bootstrap {
        // Everything visible at launch would otherwise announce itself. Record
        // what is there and say nothing.
        outbox.previous = runtimes
            .iter()
            .filter(|runtime| notifiable_run(runtime).is_some())
            .map(|runtime| {
                let ended = is_end(runtime.badge.state).then(|| runtime.episode_token.clone());
                (runtime.id.clone(), observed(runtime, ended))
            })
            .collect();
        outbox.pending.clear();
        return Vec::new();
    }

    let mut commands = Vec::new();
    for runtime in runtimes {
        if notifiable_run(runtime).is_none() {
            continue;
        }
        let prior = outbox.previous.get(&runtime.id).cloned();
        queue(outbox, runtime, prior.as_ref(), now);
        let command = release(outbox, runtime, input, pane_to_tab, now);
        // An end is done with once it is announced or nothing waits to
        // announce it; one held for a pane is not, so a later pass that
        // finds the same episode finished can still announce it.
        let is_end_held = outbox
            .pending
            .values()
            .any(|entry| entry.runtime_id == runtime.id && entry.state == runtime.badge.state);
        let ended = if is_end(runtime.badge.state) && (command.is_some() || !is_end_held) {
            Some(runtime.episode_token.clone())
        } else {
            prior.as_ref().and_then(|it| it.ended_token.clone())
        };
        outbox
            .previous
            .insert(runtime.id.clone(), observed(runtime, ended));
        commands.extend(command);
    }
    commands.sort_by(|left, right| notify_key(left).cmp(notify_key(right)));
    commands
}

/// How soon a pass should run to release a finish whose hold ends then:
/// nothing else may happen in the meantime that would ask for one. `None`
/// when no finish is held.
pub(crate) fn next_pass_in_ms(outbox: &OutboxState, now: &Instants) -> Option<u64> {
    outbox
        .pending
        .values()
        .map(|entry| hold_left_ms_for(entry, now))
        .filter(|left| *left > 0)
        .min()
}

/// What remains of a finish's hold, zero once it is over.
fn hold_left_ms(entry: &PendingNotification, now: &Instants) -> u64 {
    (entry.created_at_ms + FINISHED_NOTICE_HOLD_MS).saturating_sub(now.monotonic_ms)
}

/// The hold that applies to an entry: a finish's, and none for anything
/// else, which is a wait or a failure the person should hear of at once.
fn hold_left_ms_for(entry: &PendingNotification, now: &Instants) -> u64 {
    if entry.state == RunState::Finished {
        hold_left_ms(entry, now)
    } else {
        0
    }
}

/// The run id a notification is keyed by. A run whose id is not an identifier
/// the host can route back to is never announced, because an acknowledgment
/// for it could not be matched.
fn notifiable_run(runtime: &RuntimePresentation) -> Option<Uuid> {
    Uuid::parse_str(runtime.run_id.as_deref()?).ok()
}

/// The states that end a turn's work, whose episode a later finish of work
/// outside a turn goes on in (`lifecycle`).
fn is_end(state: RunState) -> bool {
    matches!(state, RunState::Finished | RunState::Error)
}

fn observed(runtime: &RuntimePresentation, ended_token: Option<String>) -> ObservedRuntime {
    ObservedRuntime {
        state: runtime.badge.state,
        episode_token: Some(runtime.episode_token.clone()),
        ended_token,
    }
}

/// Clears entries the host reported delivering. Matching on both the token and
/// the state means a delivery for a state the run has already left cannot
/// retire the entry that replaced it.
fn retire_delivered(outbox: &mut OutboxState, acknowledged: &[CommandOutcome]) {
    for outcome in acknowledged {
        let CommandOutcome::Notified {
            runtime_id,
            event_token,
            state,
        } = outcome
        else {
            continue;
        };
        let key = dedup_key(runtime_id, event_token, *state);
        outbox.pending.remove(&key);
    }
}

/// Drops memory of runs that are gone and entries that have waited too long.
fn prune(outbox: &mut OutboxState, runtimes: &[RuntimePresentation], now: &Instants) {
    let live: std::collections::BTreeSet<&str> =
        runtimes.iter().map(|runtime| runtime.id.as_str()).collect();
    outbox.previous.retain(|id, _| live.contains(id.as_str()));
    outbox.pending.retain(|_, entry| {
        live.contains(entry.runtime_id.as_str())
            && now.monotonic_ms.saturating_sub(entry.created_at_ms)
                < NOTIFICATION_PENDING_LIFETIME_MS
    });
}

/// Decides whether this pass produced something to say.
fn queue(
    outbox: &mut OutboxState,
    runtime: &RuntimePresentation,
    prior: Option<&ObservedRuntime>,
    now: &Instants,
) {
    // An entry queued for a state the run has since left is stale. Drop it so
    // the current state gets its own turn rather than inheriting one.
    outbox
        .pending
        .retain(|_, entry| entry.runtime_id != runtime.id || entry.state == runtime.badge.state);
    // One still waiting in this state is filed under the record's latest
    // write, which is the token the release is looked up by and the host
    // acknowledges: a record written again while a finish is held (or waits
    // for a pane) would otherwise leave its entry where no release finds it.
    let key = dedup_key(&runtime.id, &runtime.event_token, runtime.badge.state);
    let earlier: Vec<String> = outbox
        .pending
        .iter()
        .filter(|(other, entry)| entry.runtime_id == runtime.id && **other != key)
        .map(|(other, _)| other.clone())
        .collect();
    for other in earlier {
        if let Some(mut entry) = outbox.pending.remove(&other) {
            entry.event_token.clone_from(&runtime.event_token);
            outbox.pending.entry(key.clone()).or_insert(entry);
        }
    }
    // A process found dead at work is a stop the list and the row keep, but
    // not announced as a failure: no hook said it failed, and a run that
    // reports no session end (Codex quit after an interrupt, or at an
    // approval prompt) looks the same as one that crashed.
    if runtime.badge.stop_reason == Some(StopReason::ProcessExited) {
        return;
    }
    // Work the person stopped with Esc or Ctrl+C ended where they were
    // looking, at their own key: its finish is no news. The record written
    // after it keeps the episode, so it is not announced later either.
    if runtime.badge.stop_reason == Some(StopReason::Interrupted) {
        return;
    }

    let is_new_episode =
        prior.and_then(|it| it.episode_token.as_deref()) != Some(runtime.episode_token.as_str());
    let begins_episode =
        matches!(runtime.badge.state, RunState::NeedsInput | RunState::Error) && is_new_episode;
    let is_end_done_with =
        prior.and_then(|it| it.ended_token.as_deref()) == Some(runtime.episode_token.as_str());
    if !begins_episode
        && !is_notifiable(
            prior.map(|it| it.state),
            runtime.badge.state,
            is_new_episode,
            is_end_done_with,
        )
    {
        return;
    }
    // One already waiting under this key keeps when it began: its hold and
    // its lifetime run from the first time it was queued, not the latest.
    outbox
        .pending
        .entry(dedup_key(
            &runtime.id,
            &runtime.event_token,
            runtime.badge.state,
        ))
        .or_insert_with(|| PendingNotification {
            runtime_id: runtime.id.clone(),
            state: runtime.badge.state,
            event_token: runtime.event_token.clone(),
            created_at_ms: now.monotonic_ms,
        });
}

/// Which badge changes are worth announcing at all. An error is included so
/// the failure reaches the history; whether it also interrupts is decided
/// later. A finish in an episode whose end the outbox is done with is the end
/// of work the run did outside a turn, after a `Stop` or a failure that
/// ended the turn (`lifecycle`) and was announced then, so it is not
/// announced again. Compared with that end rather than with the previous
/// pass: two writes inside one pass (a `Stop` and the late tool after it)
/// leave a pass that never saw the finish. A finish straight after a finish
/// is news when it begins an episode: only a `Stop` does that (`lifecycle`),
/// such as the real `Stop` of work the idle prompt settled first.
fn is_notifiable(
    previous: Option<RunState>,
    current: RunState,
    is_new_episode: bool,
    is_end_done_with: bool,
) -> bool {
    match current {
        RunState::NeedsInput => previous != Some(RunState::NeedsInput),
        RunState::Error => previous != Some(RunState::Error),
        RunState::Finished => {
            !is_end_done_with
                && match previous {
                    Some(RunState::Running | RunState::Compacting) => true,
                    Some(RunState::Finished) => is_new_episode,
                    _ => false,
                }
        }
        _ => false,
    }
}

/// Releases a pending entry once the run has a pane to be seen in.
fn release(
    outbox: &mut OutboxState,
    runtime: &RuntimePresentation,
    input: &ProjectionInput,
    pane_to_tab: &BTreeMap<Uuid, Uuid>,
    now: &Instants,
) -> Option<Command> {
    match runtime.attachment {
        // Nothing is attached, so there is nowhere to say it and nothing to
        // wait for.
        AttachmentResolution::Detached => {
            outbox
                .pending
                .retain(|_, entry| entry.runtime_id != runtime.id);
            return None;
        }
        // The topology probe has not reported. Hold the entry rather than
        // guessing.
        AttachmentResolution::Unresolved => return None,
        AttachmentResolution::Attached => {}
    }

    let key = dedup_key(&runtime.id, &runtime.event_token, runtime.badge.state);
    // Nothing pending under this key means nothing to release; a finish
    // still in its hold is not released yet.
    let entry = outbox.pending.get(&key)?;
    if hold_left_ms_for(entry, now) > 0 {
        return None;
    }
    let (tab, pane) = target(runtime, input.focus, pane_to_tab)?;

    Some(Command::new(
        CommandOp::Notify(NotifyCommand {
            provider: runtime.provider.clone(),
            kind: kind_of(runtime.badge.state)?,
            tab,
            pane,
            runtime_id: runtime.id.clone(),
            body: body_for(runtime.badge.state, &runtime.badge),
            // An error already has the agent's own dialog on screen, so the
            // history row is enough and a banner would only interrupt twice.
            presents_banner: runtime.badge.state != RunState::Error,
            // This run's own tmux pane: another run of the same tmux session
            // may be in front in that pane, or behind it.
            suppress_when_pane_focused: input
                .presence
                .shows(runtime.tmux_endpoint_key.as_deref(), &pane),
            episode_token: runtime.episode_token.clone(),
            event_token: runtime.event_token.clone(),
            state: runtime.badge.state,
        }),
        Target::Host,
        Precondition::None,
    ))
}

/// Where to announce. The pane the user is already looking at wins, so a
/// notification points at what is in front of them; otherwise the run's panes
/// are ordered so the choice does not depend on scan order.
fn target(
    runtime: &RuntimePresentation,
    focus: Option<Focus>,
    pane_to_tab: &BTreeMap<Uuid, Uuid>,
) -> Option<(Uuid, Uuid)> {
    let focused = focus
        .map(|it| it.pane)
        .filter(|pane| runtime.panes.contains(pane));
    let mut ordered: Vec<Uuid> = runtime.panes.clone();
    ordered.sort_by_key(ToString::to_string);
    let pane = focused.or_else(|| ordered.first().copied())?;
    // A pane no tab holds cannot be shown, so there is nothing to point at.
    let tab = pane_to_tab.get(&pane)?;
    Some((*tab, pane))
}

fn kind_of(state: RunState) -> Option<NotificationKind> {
    match state {
        RunState::Finished => Some(NotificationKind::Finished),
        RunState::NeedsInput => Some(NotificationKind::NeedsInput),
        RunState::Error => Some(NotificationKind::Failed),
        _ => None,
    }
}

/// What to quote under the title.
///
/// A finish quotes the prompt that produced it; anything waiting or failing
/// quotes its own detail first, because the reason is more use than the
/// request. `None` leaves the host to fall back to its generic wording.
fn body_for(state: RunState, badge: &Badge) -> Option<String> {
    let prompt = badge.last_prompt.as_deref().and_then(persons_words);
    let candidates = match state {
        RunState::Finished => [prompt, None],
        _ => [badge.detail.as_deref(), prompt],
    };
    candidates.into_iter().flatten().find_map(truncated)
}

/// The person's words in a prompt, without the harness blocks that led it;
/// `None` for a prompt the harness wrote, whose tags and ids are no
/// instruction to quote. The same judgment of the same prompt (the run's
/// `last_prompt`, which the turn record is begun from) as the turn's
/// `prompt_kind`, so the host words the turn by the kind it shows elsewhere.
/// A turn whose kind the provider named instead (a Codex goal's) begins
/// from the goal's objective, which is the person's words either way; the
/// host words it by that kind (`/goal …`).
fn persons_words(prompt: &str) -> Option<&str> {
    match classify_prompt(prompt) {
        (PromptKind::Text, words) => Some(words),
        _ => None,
    }
}

/// Collapses a prompt to one line and clips it to what a banner shows.
fn truncated(raw: &str) -> Option<String> {
    let collapsed = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        return None;
    }
    if collapsed.chars().count() <= NOTIFICATION_BODY_CHARS {
        return Some(collapsed);
    }
    let mut clipped: String = collapsed
        .chars()
        .take(NOTIFICATION_BODY_CHARS - 1)
        .collect();
    clipped.push('…');
    Some(clipped)
}

fn dedup_key(runtime_id: &str, event_token: &str, state: RunState) -> String {
    let state = serde_json::to_string(&state).unwrap_or_default();
    format!("{runtime_id}|{event_token}|{state}")
}

fn notify_key(command: &Command) -> &str {
    match &command.op {
        CommandOp::Notify(notify) => notify.runtime_id.as_str(),
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use limpid_agent_model::{PaneLocation, PanePresence, ProviderId, TabPanes};

    const RUN: &str = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1";

    fn pane() -> Uuid {
        Uuid::parse_str("11111111-1111-4111-8111-111111111111").expect("pane")
    }

    fn tab() -> Uuid {
        Uuid::parse_str("9F9F9F9F-0000-4000-8000-9F9F9F9F9F9F").expect("tab")
    }

    fn mapping() -> BTreeMap<Uuid, Uuid> {
        [(pane(), tab())].into_iter().collect()
    }

    fn runtime(state: RunState, event_token: &str, episode_token: &str) -> RuntimePresentation {
        RuntimePresentation {
            id: format!("claude:{RUN}"),
            provider: ProviderId::new("claude").expect("provider id"),
            run_id: Some(RUN.to_owned()),
            revision: None,
            badge: Badge {
                state,
                detail: None,
                wait_kind: None,
                tool: None,
                run_started_at: None,
                is_tmux_hosted: None,
                updated_at: "2026-09-14T12:00:00Z".to_owned(),
                last_prompt: Some("list the files".to_owned()),
                first_prompt: None,
                turn_base_tree: None,
                turn_root: None,
                worktree_root: None,
                conversation_id: None,
                provider_session_title: None,
                provider_generated_title: None,
                session_started_at: None,
                run_launch_order: None,
                parent_run_id: None,
                run_observed_order: None,
                cache_window: None,
                usage_limit: None,
                background_work: None,
                stop_reason: None,
                has_prompt: None,
                model: None,
                permission_mode: None,
            },
            panes: vec![pane()],
            attachment: AttachmentResolution::Attached,
            tmux_endpoint_key: None,
            event_token: event_token.to_owned(),
            episode_token: episode_token.to_owned(),
            pid: None,
            session_id: None,
            conversation: crate::turn_rules::conversation_of(
                &ProviderId::new("claude").expect("provider id"),
                None,
                RUN,
            ),
            current_turn_id: None,
        }
    }

    fn input() -> ProjectionInput {
        ProjectionInput {
            tabs: vec![TabPanes {
                id: tab(),
                panes: vec![pane()],
            }],
            ..ProjectionInput::default()
        }
    }

    fn at(monotonic_ms: u64) -> Instants {
        Instants {
            wall: "2026-09-14T12:00:00Z".to_owned(),
            monotonic_ms,
        }
    }

    fn pass(
        outbox: &mut OutboxState,
        runtime: &RuntimePresentation,
        input: &ProjectionInput,
        now: u64,
    ) -> Vec<Command> {
        observe(
            outbox,
            std::slice::from_ref(runtime),
            input,
            &mapping(),
            &at(now),
        )
    }

    /// A pass that queues a finish, which says nothing while the finish is
    /// held, then the pass at the end of the hold, which is what announces it.
    fn settled(
        outbox: &mut OutboxState,
        runtime: &RuntimePresentation,
        input: &ProjectionInput,
        now: u64,
    ) -> Vec<Command> {
        assert!(pass(outbox, runtime, input, now).is_empty(), "held");
        pass(outbox, runtime, input, now + FINISHED_NOTICE_HOLD_MS)
    }

    fn kinds(commands: &[Command]) -> Vec<NotificationKind> {
        commands
            .iter()
            .filter_map(|command| match &command.op {
                CommandOp::Notify(notify) => Some(notify.kind),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_finish_announces_only_when_the_run_was_seen_working() {
        // Arriving at a finished run says nothing: it may have been sitting
        // there since before Limpid opened, and announcing it would be noise.
        let mut outbox = OutboxState::default();
        let input = input();
        assert!(
            pass(
                &mut outbox,
                &runtime(RunState::Finished, "1", "1"),
                &input,
                0
            )
            .is_empty()
        );

        // Having watched it run, the finish is news.
        let mut outbox = OutboxState::default();
        assert!(
            pass(
                &mut outbox,
                &runtime(RunState::Running, "1", "1"),
                &input,
                0
            )
            .is_empty()
        );
        let commands = settled(
            &mut outbox,
            &runtime(RunState::Finished, "2", "2"),
            &input,
            10,
        );
        assert_eq!(kinds(&commands), vec![NotificationKind::Finished]);
    }

    /// How a table case reads one write: one pass, or a finish held and
    /// read again once its hold is over (`settled`).
    #[derive(Clone, Copy)]
    enum Read {
        Pass,
        Settled,
    }

    /// One write a table case reads: the run's state, event and episode
    /// tokens, the pass's time, how it is read, and what it announces.
    type Step = (
        RunState,
        &'static str,
        &'static str,
        u64,
        Read,
        &'static [NotificationKind],
    );

    const NOTHING: &[NotificationKind] = &[];
    const FINISH: &[NotificationKind] = &[NotificationKind::Finished];
    const FAILURE: &[NotificationKind] = &[NotificationKind::Failed];

    /// Work an agent goes on with after its turn ended runs in the episode
    /// of that end, and the idle prompt settles it there: an episode is
    /// announced once, and only a `Stop` that begins a new one is news again.
    #[test]
    fn work_outside_a_turn_is_announced_once_per_episode() {
        use Read::{Pass, Settled};
        use RunState::{Error, Finished, Running};
        let cases: [(&str, &[Step]); 5] = [
            (
                "the turn's stop announced episode 3; a tool after it runs \
                 there, and the idle prompt settles it there",
                &[
                    (Running, "2", "2", 0, Pass, NOTHING),
                    (Finished, "3", "3", 10, Settled, FINISH),
                    (Running, "4", "3", 2_000, Pass, NOTHING),
                    (Finished, "5", "3", 2_010, Settled, NOTHING),
                ],
            ),
            (
                "a stop that ends the stretch begins an episode",
                &[
                    (Running, "2", "2", 0, Pass, NOTHING),
                    (Finished, "3", "3", 10, Settled, FINISH),
                    (Running, "4", "3", 2_000, Pass, NOTHING),
                    (Finished, "5", "3", 2_010, Settled, NOTHING),
                    (Running, "6", "3", 4_000, Pass, NOTHING),
                    (Finished, "7", "7", 4_010, Settled, FINISH),
                ],
            ),
            (
                "the stop a stop hook held back comes right after the idle \
                 prompt settled the work, and begins an episode",
                &[
                    (Running, "2", "2", 0, Pass, NOTHING),
                    (Finished, "3", "3", 10, Settled, FINISH),
                    (Running, "4", "3", 2_000, Pass, NOTHING),
                    (Finished, "5", "3", 2_010, Settled, NOTHING),
                    (Finished, "7", "7", 4_000, Settled, FINISH),
                ],
            ),
            (
                "the stop and the late tool after it land between two \
                 passes, so the idle prompt's finish is the first chance",
                &[
                    (Running, "2", "2", 0, Pass, NOTHING),
                    (Running, "4", "3", 10, Pass, NOTHING),
                    (Finished, "5", "3", 20, Settled, FINISH),
                ],
            ),
            (
                "the failure announced episode 3; the work after it settles \
                 as finished in episode 3",
                &[
                    (Running, "2", "2", 0, Pass, NOTHING),
                    (Error, "3", "3", 10, Pass, FAILURE),
                    (Running, "4", "3", 20, Pass, NOTHING),
                    (Finished, "5", "3", 30, Settled, NOTHING),
                ],
            ),
        ];
        let input = input();
        for (case, steps) in cases {
            let mut outbox = OutboxState::default();
            for (index, &(state, event, episode, now, read, says)) in steps.iter().enumerate() {
                let runtime = runtime(state, event, episode);
                let commands = match read {
                    Pass => pass(&mut outbox, &runtime, &input, now),
                    Settled => settled(&mut outbox, &runtime, &input, now),
                };
                assert_eq!(kinds(&commands), says, "{case}: pass {index}");
            }
        }
    }

    #[test]
    fn a_finish_held_for_a_pane_is_announced_when_the_work_settles() {
        // The finish waited for the topology probe, and the late tool's
        // running dropped it before the run had a pane.
        let mut outbox = OutboxState::default();
        let input = input();
        assert!(
            pass(
                &mut outbox,
                &runtime(RunState::Running, "2", "2"),
                &input,
                0
            )
            .is_empty()
        );
        let mut held = runtime(RunState::Finished, "3", "3");
        held.attachment = AttachmentResolution::Unresolved;
        assert!(pass(&mut outbox, &held, &input, 10).is_empty());
        let mut late_tool = runtime(RunState::Running, "4", "3");
        late_tool.attachment = AttachmentResolution::Unresolved;
        assert!(pass(&mut outbox, &late_tool, &input, 20).is_empty());
        let commands = settled(
            &mut outbox,
            &runtime(RunState::Finished, "5", "3"),
            &input,
            30,
        );
        assert_eq!(kinds(&commands), vec![NotificationKind::Finished]);
    }

    #[test]
    fn a_finish_is_held_while_a_queued_instruction_may_start_the_next_turn() {
        // An instruction queued while the agent worked starts the next turn
        // within moments of the `Stop`. No hook says one was queued, so the
        // finish waits a moment, and a run back at work drops it.
        let mut outbox = OutboxState::default();
        let input = input();
        let quiet = |outbox: &mut OutboxState, state, event, episode, at| {
            pass(outbox, &runtime(state, event, episode), &input, at).is_empty()
        };
        assert!(quiet(&mut outbox, RunState::Running, "1", "1", 0));
        assert!(quiet(&mut outbox, RunState::Finished, "2", "2", 10));
        assert_eq!(outbox.pending.len(), 1);
        assert_eq!(
            next_pass_in_ms(&outbox, &at(10)),
            Some(FINISHED_NOTICE_HOLD_MS)
        );
        assert!(quiet(&mut outbox, RunState::Running, "3", "3", 1_010));
        assert!(outbox.pending.is_empty());
        assert_eq!(next_pass_in_ms(&outbox, &at(1_010)), None);

        // The queued turn's own finish, with nothing after it: announced once
        // the moment has passed, even though the record was written again
        // while it waited.
        assert!(quiet(&mut outbox, RunState::Finished, "4", "4", 2_000));
        assert!(quiet(&mut outbox, RunState::Finished, "5", "4", 2_500));
        assert_eq!(next_pass_in_ms(&outbox, &at(2_500)), Some(1_000));
        let commands = pass(
            &mut outbox,
            &runtime(RunState::Finished, "5", "4"),
            &input,
            2_000 + FINISHED_NOTICE_HOLD_MS,
        );
        assert_eq!(kinds(&commands), vec![NotificationKind::Finished]);
    }

    #[test]
    fn a_finish_queued_again_keeps_the_hold_it_began() {
        // A `Stop` that begins another episode while the first finish is
        // still held is the same notice: its hold does not start over.
        let mut outbox = OutboxState::default();
        let input = input();
        let quiet = |outbox: &mut OutboxState, state, event, episode, at| {
            pass(outbox, &runtime(state, event, episode), &input, at).is_empty()
        };
        assert!(quiet(&mut outbox, RunState::Running, "1", "1", 0));
        assert!(quiet(&mut outbox, RunState::Finished, "2", "2", 10));
        assert!(quiet(&mut outbox, RunState::Finished, "3", "3", 1_000));
        assert_eq!(outbox.pending.len(), 1);
        let commands = pass(
            &mut outbox,
            &runtime(RunState::Finished, "3", "3"),
            &input,
            10 + FINISHED_NOTICE_HOLD_MS,
        );
        assert_eq!(kinds(&commands), vec![NotificationKind::Finished]);
    }

    #[test]
    fn a_wait_or_a_failure_is_not_held() {
        let mut outbox = OutboxState::default();
        let input = input();
        assert!(
            pass(
                &mut outbox,
                &runtime(RunState::Running, "1", "1"),
                &input,
                0
            )
            .is_empty()
        );
        let commands = pass(
            &mut outbox,
            &runtime(RunState::NeedsInput, "2", "2"),
            &input,
            10,
        );
        assert_eq!(kinds(&commands), vec![NotificationKind::NeedsInput]);
        assert_eq!(next_pass_in_ms(&outbox, &at(10)), None);
    }

    #[test]
    fn a_run_waiting_for_input_announces_once_per_episode() {
        let mut outbox = OutboxState::default();
        let input = input();
        let waiting = runtime(RunState::NeedsInput, "1", "episode-1");
        let commands = pass(&mut outbox, &waiting, &input, 0);
        assert_eq!(kinds(&commands), vec![NotificationKind::NeedsInput]);

        // The host reports the delivery, and a later write inside the same
        // episode is the same ask rather than a new one.
        let mut delivered = input.clone();
        delivered.acknowledged = vec![CommandOutcome::Notified {
            runtime_id: format!("claude:{RUN}"),
            event_token: "1".to_owned(),
            state: RunState::NeedsInput,
        }];
        let repeat = runtime(RunState::NeedsInput, "2", "episode-1");
        assert!(pass(&mut outbox, &repeat, &delivered, 10).is_empty());

        // A new episode is a new ask, even though the state never changed.
        let again = runtime(RunState::NeedsInput, "3", "episode-2");
        let commands = pass(&mut outbox, &again, &input, 20);
        assert_eq!(kinds(&commands), vec![NotificationKind::NeedsInput]);
    }

    #[test]
    fn an_announcement_waits_while_the_panes_are_unknown() {
        // A tmux-hosted run can finish while the topology probe has not
        // reported. Firing at nothing would lose it; dropping it would lose it
        // for good.
        let mut outbox = OutboxState::default();
        let input = input();
        pass(
            &mut outbox,
            &runtime(RunState::Running, "1", "1"),
            &input,
            0,
        );

        let mut unresolved = runtime(RunState::Finished, "2", "2");
        unresolved.attachment = AttachmentResolution::Unresolved;
        unresolved.panes.clear();
        assert!(pass(&mut outbox, &unresolved, &input, 10).is_empty());
        assert_eq!(outbox.pending.len(), 1);

        // Its hold runs from when it was queued, not from when a pane came.
        let commands = pass(
            &mut outbox,
            &runtime(RunState::Finished, "2", "2"),
            &input,
            10 + FINISHED_NOTICE_HOLD_MS,
        );
        assert_eq!(kinds(&commands), vec![NotificationKind::Finished]);
    }

    #[test]
    fn a_detached_run_drops_what_it_was_going_to_say() {
        // Nobody is attached, so there is no pane to point at and nothing to
        // wait for.
        let mut outbox = OutboxState::default();
        let input = input();
        pass(
            &mut outbox,
            &runtime(RunState::Running, "1", "1"),
            &input,
            0,
        );

        let mut detached = runtime(RunState::Finished, "2", "2");
        detached.attachment = AttachmentResolution::Detached;
        detached.panes.clear();
        assert!(pass(&mut outbox, &detached, &input, 10).is_empty());
        assert!(outbox.pending.is_empty());
    }

    #[test]
    fn an_entry_that_waited_too_long_is_forgotten() {
        let mut outbox = OutboxState::default();
        let input = input();
        pass(
            &mut outbox,
            &runtime(RunState::Running, "1", "1"),
            &input,
            0,
        );

        let mut unresolved = runtime(RunState::Finished, "2", "2");
        unresolved.attachment = AttachmentResolution::Unresolved;
        pass(&mut outbox, &unresolved, &input, 10);
        assert_eq!(outbox.pending.len(), 1);

        // Well past the window, and the moment has gone.
        pass(
            &mut outbox,
            &unresolved,
            &input,
            NOTIFICATION_PENDING_LIFETIME_MS + 1_000,
        );
        assert!(outbox.pending.is_empty());
    }

    #[test]
    fn nothing_is_announced_on_the_first_pass_after_launch() {
        let mut outbox = OutboxState::default();
        let mut input = input();
        input.is_bootstrap = true;
        assert!(
            pass(
                &mut outbox,
                &runtime(RunState::NeedsInput, "1", "1"),
                &input,
                0
            )
            .is_empty()
        );

        // What was there is remembered, so the next change is measured
        // against it rather than announced from nothing.
        input.is_bootstrap = false;
        assert!(
            pass(
                &mut outbox,
                &runtime(RunState::NeedsInput, "1", "1"),
                &input,
                10
            )
            .is_empty()
        );
    }

    #[test]
    fn a_failure_reaches_the_history_without_interrupting() {
        let mut outbox = OutboxState::default();
        let input = input();
        let mut failed = runtime(RunState::Error, "1", "1");
        failed.badge.detail = Some("server_error".to_owned());
        let commands = pass(&mut outbox, &failed, &input, 0);
        let CommandOp::Notify(notify) = &commands[0].op else {
            panic!("expected a notification");
        };
        assert_eq!(notify.kind, NotificationKind::Failed);
        assert!(!notify.presents_banner);
        // The reason is more use than the request that led to it.
        assert_eq!(notify.body.as_deref(), Some("server_error"));
    }

    #[test]
    fn a_shared_tmux_pane_quiets_only_the_banner_of_the_run_in_front() {
        // Two runs of one tmux session wait in the same pane. The host may
        // hold back the banner of the one whose tmux pane is in front while the
        // pane has focus; the one behind it is not on screen there.
        let mut outbox = OutboxState::default();
        let mut input = input();
        let mut runs = Vec::new();
        for (run, tmux_pane, is_active) in [
            ("FFFFFFFF-1111-4111-8111-AAAAAAAAAAA1", "%3", true),
            ("00000000-1111-4111-8111-AAAAAAAAAAA1", "%4", false),
        ] {
            let key = format!("/tmp/socket|42|100|{tmux_pane}");
            input.presence.locations.insert(
                key.clone(),
                [(pane(), PaneLocation { is_active })].into_iter().collect(),
            );
            let mut waiting = runtime(RunState::NeedsInput, "1", "1");
            waiting.id = format!("claude:{run}");
            waiting.run_id = Some(run.to_owned());
            waiting.tmux_endpoint_key = Some(key);
            runs.push(waiting);
        }

        let commands = observe(&mut outbox, &runs, &input, &mapping(), &at(0));
        let quiet: BTreeMap<String, bool> = commands
            .iter()
            .filter_map(|command| match &command.op {
                CommandOp::Notify(notify) => {
                    Some((notify.runtime_id.clone(), notify.suppress_when_pane_focused))
                }
                _ => None,
            })
            .collect();
        assert_eq!(
            quiet,
            [
                (
                    "claude:00000000-1111-4111-8111-AAAAAAAAAAA1".to_owned(),
                    false
                ),
                (
                    "claude:FFFFFFFF-1111-4111-8111-AAAAAAAAAAA1".to_owned(),
                    true
                ),
            ]
            .into_iter()
            .collect()
        );
    }

    #[test]
    fn the_focused_pane_wins_when_the_run_reaches_several() {
        let second = Uuid::parse_str("22222222-2222-4222-8222-222222222222").expect("pane");
        let mut outbox = OutboxState::default();
        let mut input = input();
        input.tabs[0].panes.push(second);
        input.focus = Some(Focus {
            tab: tab(),
            pane: second,
        });
        input.presence = PanePresence {
            locations: [(
                "/tmp/socket|42|100|%3".to_owned(),
                [(second, PaneLocation { is_active: false })]
                    .into_iter()
                    .collect(),
            )]
            .into_iter()
            .collect(),
            ..PanePresence::default()
        };

        let mut waiting = runtime(RunState::NeedsInput, "1", "1");
        waiting.panes = vec![pane(), second];
        waiting.tmux_endpoint_key = Some("/tmp/socket|42|100|%3".to_owned());
        let mut mapping = mapping();
        mapping.insert(second, tab());
        let commands = observe(
            &mut outbox,
            std::slice::from_ref(&waiting),
            &input,
            &mapping,
            &at(0),
        );
        let CommandOp::Notify(notify) = &commands[0].op else {
            panic!("expected a notification");
        };
        assert_eq!(notify.pane, second);
        // The pane is not the active one in its tmux window, so the host is
        // told not to suppress the banner just because it has focus.
        assert!(!notify.suppress_when_pane_focused);
    }

    #[test]
    fn no_body_quotes_a_prompt_the_harness_wrote() {
        let mut badge = runtime(RunState::Finished, "1", "1").badge;
        badge.last_prompt = Some("<task-notification>\n<task-id>bmtysm2i6</task-id>".to_owned());
        assert_eq!(body_for(RunState::Finished, &badge), None);
        badge.detail = None;
        assert_eq!(body_for(RunState::NeedsInput, &badge), None);
    }

    #[test]
    fn a_finish_quotes_the_persons_words_after_a_reminder() {
        let mut badge = runtime(RunState::Finished, "1", "1").badge;
        badge.last_prompt =
            Some("<system-reminder>\nThe file changed.\n</system-reminder>\nadd tests".to_owned());
        assert_eq!(
            body_for(RunState::Finished, &badge).as_deref(),
            Some("add tests")
        );
    }

    #[test]
    fn a_long_prompt_is_clipped_to_what_a_banner_shows() {
        let raw = "  a\nvery   long\tprompt ".to_owned() + &"x".repeat(200);
        let clipped = truncated(&raw).expect("body");
        assert_eq!(clipped.chars().count(), NOTIFICATION_BODY_CHARS);
        assert!(clipped.starts_with("a very long prompt"), "{clipped}");
        assert!(clipped.ends_with('…'), "{clipped}");
        assert!(truncated("   \n ").is_none());
    }
}
