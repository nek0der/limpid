//! Deciding which lifecycle changes are worth announcing.
//!
//! Separating the decision from the delivery is what makes the rule testable
//! and what lets an announcement wait. A run hosted in tmux may be attached to
//! no pane the moment it finishes, and firing at nothing would lose the event
//! while dropping it would lose it permanently. So a transition becomes a
//! pending entry, and the entry is released when the run has somewhere to be
//! seen, expired when it has waited too long, or discarded when the run moves
//! on to a different state.
//!
//! Two tokens do different jobs here. The event token identifies one record
//! write and is what the host echoes back so a stale delivery cannot retire a
//! newer entry. The episode token identifies a stretch of the same state, and
//! is what decides that a run asking for input again is a new thing to say
//! rather than a repeat.

use limpid_agent_model::{
    AttachmentResolution, Badge, Command, CommandOp, CommandOutcome, Focus, Instants,
    NOTIFICATION_BODY_CHARS, NOTIFICATION_PENDING_LIFETIME_MS, NotificationKind, NotifyCommand,
    ObservedRuntime, OutboxState, PendingNotification, Precondition, ProjectionInput, RunState,
    RuntimePresentation, Target,
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
            .map(|runtime| (runtime.id.clone(), observed(runtime)))
            .collect();
        outbox.pending.clear();
        return Vec::new();
    }

    let mut commands = Vec::new();
    for runtime in runtimes {
        if notifiable_run(runtime).is_none() {
            continue;
        }
        let prior = outbox
            .previous
            .insert(runtime.id.clone(), observed(runtime));
        queue(outbox, runtime, prior.as_ref(), now);
        if let Some(command) = release(outbox, runtime, input, pane_to_tab) {
            commands.push(command);
        }
    }
    commands.sort_by(|left, right| notify_key(left).cmp(notify_key(right)));
    commands
}

/// The run id a notification is keyed by. A run whose id is not a identifier
/// the host can route back to is never announced, because an acknowledgement
/// for it could not be matched.
fn notifiable_run(runtime: &RuntimePresentation) -> Option<Uuid> {
    Uuid::parse_str(runtime.run_id.as_deref()?).ok()
}

fn observed(runtime: &RuntimePresentation) -> ObservedRuntime {
    ObservedRuntime {
        state: runtime.badge.state,
        episode_token: Some(runtime.episode_token.clone()),
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

    let begins_episode = matches!(runtime.badge.state, RunState::NeedsInput | RunState::Error)
        && prior.and_then(|it| it.episode_token.as_deref()) != Some(runtime.episode_token.as_str());
    if !begins_episode && !is_notifiable(prior.map(|it| it.state), runtime.badge.state) {
        return;
    }
    outbox.pending.insert(
        dedup_key(&runtime.id, &runtime.event_token, runtime.badge.state),
        PendingNotification {
            runtime_id: runtime.id.clone(),
            state: runtime.badge.state,
            event_token: runtime.event_token.clone(),
            created_at_ms: now.monotonic_ms,
        },
    );
}

/// Which badge changes are worth announcing at all. An error is included so
/// the failure reaches the history; whether it also interrupts is decided
/// later.
fn is_notifiable(previous: Option<RunState>, current: RunState) -> bool {
    match current {
        RunState::NeedsInput => previous != Some(RunState::NeedsInput),
        RunState::Error => previous != Some(RunState::Error),
        RunState::Finished => matches!(previous, Some(RunState::Running | RunState::Compacting)),
        _ => false,
    }
}

/// Releases a pending entry once the run has a pane to be seen in.
fn release(
    outbox: &mut OutboxState,
    runtime: &RuntimePresentation,
    input: &ProjectionInput,
    pane_to_tab: &BTreeMap<Uuid, Uuid>,
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
    // Nothing pending under this key means nothing to release; the lookup
    // is the guard, not a value we need.
    outbox.pending.get(&key)?;
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
            suppress_when_pane_focused: input
                .presence
                .locations
                .get(&pane)
                .is_none_or(|location| location.is_active),
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
    let candidates = match state {
        RunState::Finished => [badge.last_prompt.as_deref(), None],
        _ => [badge.detail.as_deref(), badge.last_prompt.as_deref()],
    };
    candidates.into_iter().flatten().find_map(truncated)
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
                run_started_at: None,
                context_tokens: None,
                is_tmux_hosted: None,
                updated_at: "2026-09-14T12:00:00Z".to_owned(),
                last_prompt: Some("list the files".to_owned()),
                first_prompt: None,
                turn_base_tree: None,
                turn_root: None,
                conversation_id: None,
                provider_session_title: None,
                provider_generated_title: None,
                session_started_at: None,
            },
            panes: vec![pane()],
            attachment: AttachmentResolution::Attached,
            event_token: event_token.to_owned(),
            episode_token: episode_token.to_owned(),
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
        let commands = pass(
            &mut outbox,
            &runtime(RunState::Finished, "2", "2"),
            &input,
            10,
        );
        assert_eq!(kinds(&commands), vec![NotificationKind::Finished]);
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

        let commands = pass(
            &mut outbox,
            &runtime(RunState::Finished, "2", "2"),
            &input,
            20,
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
            locations: [(second, PaneLocation { is_active: false })]
                .into_iter()
                .collect(),
            ..PanePresence::default()
        };

        let mut waiting = runtime(RunState::NeedsInput, "1", "1");
        waiting.panes = vec![pane(), second];
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
    fn a_long_prompt_is_clipped_to_what_a_banner_shows() {
        let raw = "  a\nvery   long\tprompt ".to_owned() + &"x".repeat(200);
        let clipped = truncated(&raw).expect("body");
        assert_eq!(clipped.chars().count(), NOTIFICATION_BODY_CHARS);
        assert!(clipped.starts_with("a very long prompt"), "{clipped}");
        assert!(clipped.ends_with('…'), "{clipped}");
        assert!(truncated("   \n ").is_none());
    }
}
