//! Which turns the retention limits take: a turn started longer ago
//! than the host's limit, or past the newest so many of its conversation,
//! goes, its record and refs together (`CommandOp::DeleteTurn`); while a
//! repository's turns hold more snapshot bytes than its limit, the oldest
//! that may go, go too; and past the most turns kept at all, the oldest go
//! even unread, since every pass carries a summary of each and past the
//! bridge's limit no pass runs.
//!
//! Deleting is the one thing here no later pass can take back, so a turn
//! stays whenever anything says a person may still need it. The host names
//! the turns it protects: unread ones whose session is open, which the age
//! limit spares but the count limits do not, and those a review or a draft
//! comment holds a range of. The rules add what only they can see: a turn
//! still running, the turn a run is on, a record this version may not
//! delete, the latest turns of a conversation shown in a pane, and a turn
//! first read in this pass, which the host has not yet had a pass to judge.
//! A run that left in this pass still protects its turns for this pass, for
//! the same reason. Until the host has said what it protects, nothing is
//! deleted at all.
//!
//! While a turn is held for the moment (a review's range, a read a moment
//! ago, one running or just read in), no later turn of its worktree goes:
//! taking one from the middle would join the gaps around it, and what it
//! changed would read as changed outside every turn. A turn kept
//! for good (unread, or a record this version may not delete) holds back
//! nothing, or one unread turn would stop the limits for its whole worktree;
//! the gaps a deletion opens there are the reader's to leave out
//! (`OutsideTurnsPlan`).

use limpid_agent_model::{
    Command, CommandOp, ConversationKey, Instants, MAX_TURN_DELETIONS_PER_PASS, Precondition,
    ProjectionInput, ProjectionState, SnapshotStatus, TURNS_KEPT_PER_SHOWN_CONVERSATION, Target,
    TurnPhase, TurnSummary, TurnSweepInput, seconds_between,
};
use std::collections::{BTreeMap, BTreeSet};

/// The turns this pass deletes, oldest first, at most
/// `MAX_TURN_DELETIONS_PER_PASS`.
pub(crate) fn sweep(
    previous: &ProjectionState,
    state: &ProjectionState,
    input: &ProjectionInput,
    now: &Instants,
) -> Vec<Command> {
    let Some(limits) = &input.turn_sweep else {
        return Vec::new();
    };
    taken(previous, state, limits, now)
        .into_iter()
        .take(MAX_TURN_DELETIONS_PER_PASS)
        .map(|turn| {
            Command::new(
                CommandOp::DeleteTurn {
                    turn_id: turn.turn_id.clone(),
                },
                Target::Turn {
                    provider: turn.conversation.provider.clone(),
                    turn_id: turn.turn_id.clone(),
                },
                Precondition::None,
            )
        })
        .collect()
}

/// How many turns of `state` the sweep takes under `to` that it keeps under
/// `from`, chosen as a pass made now would choose them and before a pass's
/// share caps them: what a change of the limits deletes, for the host to say
/// before it saves the change. It is `sweep`'s own choice with the
/// deletion left out, so what the host says and what a pass deletes cannot
/// drift apart. `state` stands for both passes, since what was committed is
/// what the next pass starts from.
#[must_use]
pub fn turns_taken_by_change(
    state: &ProjectionState,
    from: &TurnSweepInput,
    to: &TurnSweepInput,
    now: &Instants,
) -> usize {
    let taken_anyway: BTreeSet<&str> = taken(state, state, from, now)
        .into_iter()
        .map(|turn| turn.turn_id.as_str())
        .collect();
    taken(state, state, to, now)
        .into_iter()
        .filter(|turn| !taken_anyway.contains(turn.turn_id.as_str()))
        .count()
}

/// Every turn `limits` take now, oldest first, however many passes deleting
/// them takes.
fn taken<'a>(
    previous: &ProjectionState,
    state: &'a ProjectionState,
    limits: &TurnSweepInput,
    now: &Instants,
) -> Vec<&'a TurnSummary> {
    // Both passes' runs: one retired in this pass protected its turns
    // when the host last judged them.
    let runs = || previous.accepted.values().chain(state.accepted.values());
    let live_runs: BTreeSet<&str> = runs()
        .filter_map(|run| run.record.run_id.as_deref())
        .collect();
    let current: BTreeSet<&str> = runs()
        .filter_map(|run| run.record.current_turn_id.as_deref())
        .collect();
    // The age of the oldest turn held in each worktree; `None` when one
    // held has no age that reads, which holds every turn of that worktree.
    let mut oldest_held: BTreeMap<&str, Option<u64>> = BTreeMap::new();
    let age = |turn: &TurnSummary| seconds_between(&turn.started_at, &now.wall);
    let mut by_conversation: BTreeMap<&ConversationKey, Vec<&TurnSummary>> = BTreeMap::new();
    for turn in state.turns.values() {
        by_conversation
            .entry(&turn.conversation)
            .or_default()
            .push(turn);
    }
    let mut chosen: Vec<&TurnSummary> = Vec::new();
    // Turns that may go but are within the age and count limits: what the
    // size limit takes from, oldest first.
    let mut spare: Vec<&TurnSummary> = Vec::new();
    // Unread turns within the count limit: what only the cap on all turns
    // takes from, oldest first.
    let mut unread: Vec<&TurnSummary> = Vec::new();
    for (conversation, mut turns) in by_conversation {
        // Newest first: a turn's place counts from the latest.
        turns.sort_by(|left, right| {
            (right.display_number, &right.turn_id).cmp(&(left.display_number, &left.turn_id))
        });
        let is_shown = limits.shown_conversations.contains(conversation);
        for (place, turn) in turns.into_iter().enumerate() {
            let is_held = limits.held_turn_ids.contains(&turn.turn_id)
                || !previous.turns.contains_key(&turn.turn_id)
                || current.contains(turn.turn_id.as_str())
                // Still under way: its end has yet to be written.
                || (turn.phase == TurnPhase::Started && live_runs.contains(turn.run_id.as_str()));
            // The latest turns of a shown conversation are kept without
            // holding: in a conversation used now and then, the twentieth
            // may be months old, and holding would stop the limits for
            // every later turn of its worktree while the pane is open.
            let is_kept = is_held
                || !turn.is_deletable
                || (is_shown && place < TURNS_KEPT_PER_SHOWN_CONVERSATION);
            let is_unread = limits.protected_turn_ids.contains(&turn.turn_id);
            let is_past_count =
                place >= usize::try_from(limits.max_per_conversation).unwrap_or(usize::MAX);
            // A start time that does not read is no evidence of age.
            let is_past_age = age(turn).is_some_and(|age| age > limits.max_age_secs);
            if !is_kept && (is_past_count || (is_past_age && !is_unread)) {
                chosen.push(turn);
            } else if !is_kept && is_unread {
                unread.push(turn);
            } else if !is_kept {
                spare.push(turn);
            } else if is_held && let Some(root) = root(turn) {
                let oldest = oldest_held.entry(root).or_insert(Some(0));
                *oldest = match (*oldest, age(turn)) {
                    (Some(known), Some(this)) => Some(known.max(this)),
                    _ => None,
                };
            }
        }
    }
    if let Some(limit) = limits.max_repository_bytes {
        let more = past_size(state, &chosen, spare.clone(), limit);
        let taken: BTreeSet<&str> = more.iter().map(|turn| turn.turn_id.as_str()).collect();
        spare.retain(|turn| !taken.contains(turn.turn_id.as_str()));
        chosen.extend(more);
    }
    if let Some(cap) = limits.max_turns {
        let more = past_cap(state.turns.len() - chosen.len(), cap, spare, unread);
        chosen.extend(more);
    }
    chosen.retain(|turn| {
        root(turn).is_none_or(|root| match oldest_held.get(root) {
            None => true,
            Some(None) => false,
            Some(Some(oldest)) => age(turn).is_some_and(|this| this > *oldest),
        })
    });
    chosen.sort_by(|left, right| {
        (&left.started_at, &left.turn_id).cmp(&(&right.started_at, &right.turn_id))
    });
    chosen
}

/// The turns of `spare` that bring each repository back within
/// `max_repository_bytes`, oldest first, after `chosen` goes. A turn whose
/// bytes are not known counts as none: it neither makes the limit go over
/// nor brings it back.
fn past_size<'a>(
    state: &'a ProjectionState,
    chosen: &[&'a TurnSummary],
    mut spare: Vec<&'a TurnSummary>,
    max_repository_bytes: u64,
) -> Vec<&'a TurnSummary> {
    let mut bytes_by_repository: BTreeMap<&str, u64> = BTreeMap::new();
    for turn in state.turns.values() {
        if let Some(repository) = repository(turn) {
            *bytes_by_repository.entry(repository).or_default() += turn.added_bytes.unwrap_or(0);
        }
    }
    // Taken as gone, though a held turn may keep some of them this pass:
    // the limit is reached a pass later then, not missed.
    for turn in chosen {
        if let Some(repository) = repository(turn) {
            let total = bytes_by_repository.entry(repository).or_default();
            *total = total.saturating_sub(turn.added_bytes.unwrap_or(0));
        }
    }
    spare.sort_by(|left, right| {
        (&left.started_at, &left.turn_id).cmp(&(&right.started_at, &right.turn_id))
    });
    let mut more = Vec::new();
    for turn in spare {
        let (Some(repository), Some(bytes)) = (repository(turn), turn.added_bytes) else {
            continue;
        };
        let total = bytes_by_repository.entry(repository).or_default();
        if *total > max_repository_bytes && bytes > 0 {
            *total = total.saturating_sub(bytes);
            more.push(turn);
        }
    }
    more
}

/// The turns that bring the count of all turns kept, `left` after what is
/// already chosen goes, back to `cap`: read ones before unread ones, each
/// oldest first. One held stops those after it in its worktree, so the cap
/// may stay exceeded a little while a review keeps a range open.
fn past_cap<'a>(
    left: usize,
    cap: u64,
    mut spare: Vec<&'a TurnSummary>,
    mut unread: Vec<&'a TurnSummary>,
) -> Vec<&'a TurnSummary> {
    let over = left.saturating_sub(usize::try_from(cap).unwrap_or(usize::MAX));
    if over == 0 {
        return Vec::new();
    }
    let by_age = |turns: &mut Vec<&TurnSummary>| {
        turns.sort_by(|left, right| {
            (&left.started_at, &left.turn_id).cmp(&(&right.started_at, &right.turn_id))
        });
    };
    by_age(&mut spare);
    by_age(&mut unread);
    spare.into_iter().chain(unread).take(over).collect()
}

/// The repository a turn's refs live in: its common git directory, else the
/// worktree its snapshots were taken in.
fn repository(turn: &TurnSummary) -> Option<&str> {
    turn.repository.as_deref().or_else(|| root(turn))
}

/// The worktree a turn's snapshots were taken in, if either was.
fn root(turn: &TurnSummary) -> Option<&str> {
    [&turn.end, &turn.begin]
        .into_iter()
        .find_map(|status| match status {
            SnapshotStatus::Captured { root, .. } => Some(root.as_str()),
            _ => None,
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use limpid_agent_model::{
        AcceptedRun, ChangeSummary, ProviderId, RunRecord, SnapshotStatus, TurnSweepInput,
    };

    const NOW: &str = "2026-10-12T00:00:00Z";
    const DAY: u64 = 24 * 60 * 60;

    fn conversation(id: &str) -> ConversationKey {
        ConversationKey {
            provider: ProviderId::new("claude").expect("provider id"),
            conversation_id: id.to_owned(),
            is_fallback: false,
        }
    }

    /// Turn `number` of conversation `id`, started `days_ago` days before
    /// now, by run `RUN`.
    fn turn(id: &str, number: u32, days_ago: u64) -> TurnSummary {
        TurnSummary {
            turn_id: format!("{id}-{number}"),
            conversation: conversation(id),
            run_id: "RUN".to_owned(),
            pane_id: "PANE".to_owned(),
            display_number: number,
            prompt_head: Some("p".to_owned()),
            prompt_kind: limpid_agent_model::PromptKind::Text,
            reply_head: None,
            conversation_title: None,
            started_at: limpid_agent_model::format_utc_seconds(
                std::time::UNIX_EPOCH
                    + std::time::Duration::from_secs(1_791_763_200 - days_ago * DAY),
            ),
            finished_at: None,
            phase: TurnPhase::Finished,
            begin: SnapshotStatus::Pending,
            end: SnapshotStatus::Pending,
            changes: ChangeSummary::Pending,
            duration_seconds: None,
            added_bytes: None,
            repository: None,
            last_check: None,
            checks: Vec::new(),
            check_count: 0,
            failure_count: 0,
            are_checks_partial: false,
            denied_actions: Vec::new(),
            denied_count: 0,
            usage: None,
            has_prompt: true,
            is_deletable: true,
        }
    }

    fn state(turns: Vec<TurnSummary>) -> ProjectionState {
        ProjectionState {
            turns: turns
                .into_iter()
                .map(|turn| (turn.turn_id.clone(), turn))
                .collect(),
            ..ProjectionState::default()
        }
    }

    fn limits() -> TurnSweepInput {
        TurnSweepInput {
            max_age_secs: 14 * DAY,
            max_per_conversation: 200,
            ..TurnSweepInput::default()
        }
    }

    fn deleted(state: &ProjectionState, limits: Option<TurnSweepInput>) -> Vec<String> {
        let input = ProjectionInput {
            turn_sweep: limits,
            ..ProjectionInput::default()
        };
        let now = Instants {
            wall: NOW.to_owned(),
            monotonic_ms: 0,
        };
        let gone: Vec<String> = sweep(state, state, &input, &now)
            .into_iter()
            .map(|command| match command.op {
                CommandOp::DeleteTurn { turn_id } => turn_id,
                other => panic!("not a deletion: {other:?}"),
            })
            .collect();
        // Every case the sweep is tested on also checks the count the host
        // shows before a change: from limits that take nothing, it is what
        // the sweep deletes, up to a pass's share.
        if let Some(limits) = &input.turn_sweep {
            let counted = turns_taken_by_change(state, &takes_nothing(limits), limits, &now);
            if gone.len() < MAX_TURN_DELETIONS_PER_PASS {
                assert_eq!(counted, gone.len(), "the count and the sweep agree");
            } else {
                assert!(counted >= gone.len(), "a pass deletes at most its share");
            }
        }
        gone
    }

    /// `limits`' protection, with limits that take no turn.
    fn takes_nothing(limits: &TurnSweepInput) -> TurnSweepInput {
        TurnSweepInput {
            max_age_secs: u64::MAX,
            max_per_conversation: u32::MAX,
            max_repository_bytes: None,
            max_turns: None,
            ..limits.clone()
        }
    }

    fn counted(state: &ProjectionState, from: &TurnSweepInput, to: &TurnSweepInput) -> usize {
        let now = Instants {
            wall: NOW.to_owned(),
            monotonic_ms: 0,
        };
        turns_taken_by_change(state, from, to, &now)
    }

    #[test]
    fn a_change_counts_only_what_the_saved_limits_keep() {
        let state = state(vec![turn("a", 1, 30), turn("a", 2, 10), turn("a", 3, 5)]);
        let saved = TurnSweepInput {
            max_age_secs: 20 * DAY,
            ..limits()
        };
        let narrower = TurnSweepInput {
            max_age_secs: 7 * DAY,
            ..limits()
        };
        assert_eq!(
            counted(&state, &saved, &narrower),
            1,
            "a-1 goes under either, so only a-2 is the change's"
        );
        assert_eq!(
            counted(&state, &narrower, &saved),
            0,
            "a wider limit takes nothing"
        );
        assert_eq!(counted(&state, &saved, &saved), 0);
    }

    #[test]
    fn a_change_is_counted_past_one_passs_share() {
        let turns: Vec<TurnSummary> = (1..=150).map(|number| turn("a", number, 30)).collect();
        let state = state(turns);
        assert_eq!(counted(&state, &takes_nothing(&limits()), &limits()), 150);
    }

    #[test]
    fn a_change_counts_what_the_size_limit_and_a_held_turn_decide() {
        let turns = vec![
            sized(in_worktree(turn("a", 1, 3), "/w"), "/r", 400),
            sized(in_worktree(turn("a", 2, 2), "/w"), "/r", 400),
            sized(in_worktree(turn("a", 3, 1), "/w"), "/r", 400),
        ];
        let state = state(turns);
        let saved = limits();
        let smaller = TurnSweepInput {
            max_repository_bytes: Some(500),
            ..limits()
        };
        assert_eq!(
            counted(&state, &saved, &smaller),
            2,
            "the oldest two bring it back"
        );
        let mut held = smaller.clone();
        held.held_turn_ids.insert("a-2".to_owned());
        assert_eq!(
            counted(&state, &saved, &held),
            1,
            "a-2 is held, and holds back a-3 after it"
        );
    }

    #[test]
    fn no_sweep_before_protection_loaded() {
        let state = state(vec![turn("a", 1, 30)]);
        assert!(deleted(&state, None).is_empty());
        assert_eq!(deleted(&state, Some(limits())), ["a-1"]);
    }

    #[test]
    fn retention_never_deletes_protected() {
        let mut started = turn("a", 3, 30);
        started.phase = TurnPhase::Started;
        let mut newer = turn("a", 4, 30);
        newer.is_deletable = false;
        let mut current = turn("b", 1, 30);
        current.run_id = "OTHER".to_owned();
        let state = ProjectionState {
            accepted: [run("RUN", None), run("OTHER", Some("b-1"))]
                .into_iter()
                .enumerate()
                .map(|(index, run)| (index.to_string(), run))
                .collect(),
            ..state(vec![
                turn("a", 1, 30),
                turn("a", 2, 30),
                started,
                newer,
                current,
            ])
        };
        let mut limits = limits();
        limits.protected_turn_ids.insert("a-2".to_owned());

        assert_eq!(
            deleted(&state, Some(limits)),
            ["a-1"],
            "unread, running, unwritable, and current turns stay"
        );
    }

    #[test]
    fn a_turn_first_read_in_this_pass_stays() {
        let input = ProjectionInput {
            turn_sweep: Some(limits()),
            ..ProjectionInput::default()
        };
        let now = Instants {
            wall: NOW.to_owned(),
            monotonic_ms: 0,
        };
        let state = state(vec![turn("a", 1, 30)]);
        assert!(
            sweep(&ProjectionState::default(), &state, &input, &now).is_empty(),
            "the host has not judged it yet"
        );
    }

    #[test]
    fn a_started_turn_whose_run_left_this_pass_stays() {
        let mut started = turn("a", 1, 30);
        started.phase = TurnPhase::Started;
        let now_state = state(vec![started]);
        let previous = ProjectionState {
            accepted: std::iter::once(("0".to_owned(), run("RUN", None))).collect(),
            ..now_state.clone()
        };
        let input = ProjectionInput {
            turn_sweep: Some(limits()),
            ..ProjectionInput::default()
        };
        let now = Instants {
            wall: NOW.to_owned(),
            monotonic_ms: 0,
        };
        assert!(
            sweep(&previous, &now_state, &input, &now).is_empty(),
            "the host saw it running when it last judged"
        );
    }

    #[test]
    fn exactly_the_age_limit_stays() {
        let mut limits = limits();
        limits.max_age_secs = 30 * DAY;
        assert!(deleted(&state(vec![turn("a", 1, 30)]), Some(limits)).is_empty());
    }

    /// A conversation shown in a pane keeps its latest
    /// `TURNS_KEPT_PER_SHOWN_CONVERSATION` turns whatever their age, and
    /// against a count limit below that; past it, the count limit takes the
    /// oldest as it does anywhere. Not shown, age alone decides.
    #[test]
    fn a_shown_conversation_keeps_its_latest_turns_against_age_and_count_only() {
        let kept = TURNS_KEPT_PER_SHOWN_CONVERSATION;
        let numbers = |count: usize| 1..=u32::try_from(count).expect("a small count");
        let names = |count: usize| {
            numbers(count)
                .map(|number| format!("a-{number}"))
                .collect::<Vec<_>>()
        };
        let mut shown = limits();
        shown.shown_conversations.insert(conversation("a"));

        let old: Vec<TurnSummary> = numbers(kept + 5)
            .map(|number| turn("a", number, 30))
            .collect();
        assert_eq!(
            deleted(&state(old.clone()), Some(shown.clone())),
            names(5),
            "past the age limit, all but the latest stay while shown"
        );
        assert_eq!(
            deleted(&state(old), Some(limits())).len(),
            kept + 5,
            "not shown: age decides"
        );

        let fresh: Vec<TurnSummary> = numbers(5).map(|number| turn("a", number, 0)).collect();
        let mut below = shown.clone();
        below.max_per_conversation = 3;
        assert!(
            deleted(&state(fresh), Some(below)).is_empty(),
            "a count limit below the kept number takes none of them"
        );

        let many: Vec<TurnSummary> = numbers(kept + 5)
            .map(|number| turn("a", number, 0))
            .collect();
        let mut above = shown;
        above.max_per_conversation = u32::try_from(kept + 2).expect("a small count");
        assert_eq!(
            deleted(&state(many), Some(above)),
            names(3),
            "a count limit above it takes the oldest past it"
        );
    }

    /// `turn` with both snapshots taken in `root`.
    fn in_worktree(mut turn: TurnSummary, root: &str) -> TurnSummary {
        let captured = SnapshotStatus::Captured {
            tree: "t".to_owned(),
            root: root.to_owned(),
        };
        turn.begin = captured.clone();
        turn.end = captured;
        turn
    }

    #[test]
    fn a_held_turn_holds_back_the_later_turns_of_its_worktree() {
        // a-2 is in an open range; a-1 before it may go, a-3 after it stays,
        // as does the turn of another conversation in the same worktree
        // after it. The other worktree is not held back.
        let turns = vec![
            in_worktree(turn("a", 1, 40), "/w"),
            in_worktree(turn("a", 2, 35), "/w"),
            in_worktree(turn("a", 3, 30), "/w"),
            in_worktree(turn("b", 1, 32), "/w"),
            in_worktree(turn("c", 1, 31), "/other"),
        ];
        let mut limits = limits();
        limits.held_turn_ids.insert("a-2".to_owned());

        assert_eq!(deleted(&state(turns), Some(limits)), ["a-1", "c-1"]);
    }

    #[test]
    fn an_old_unread_turn_stays_without_stopping_the_limits_for_its_worktree() {
        let turns = vec![
            in_worktree(turn("a", 1, 40), "/w"),
            in_worktree(turn("a", 2, 35), "/w"),
            in_worktree(turn("b", 1, 30), "/w"),
        ];
        let mut limits = limits();
        limits.protected_turn_ids.insert("a-1".to_owned());

        assert_eq!(deleted(&state(turns), Some(limits)), ["a-2", "b-1"]);
    }

    #[test]
    fn a_held_turn_whose_age_does_not_read_holds_its_worktree() {
        let mut odd = in_worktree(turn("a", 2, 0), "/w");
        odd.started_at = "yesterday".to_owned();
        let turns = vec![in_worktree(turn("a", 1, 40), "/w"), odd.clone()];
        let mut limits = limits();
        limits.held_turn_ids.insert(odd.turn_id);
        assert!(deleted(&state(turns), Some(limits)).is_empty());
    }

    /// `turn` in repository `repository`, holding `bytes` of snapshots.
    fn sized(mut turn: TurnSummary, repository: &str, bytes: u64) -> TurnSummary {
        turn.repository = Some(repository.to_owned());
        turn.added_bytes = Some(bytes);
        turn
    }

    #[test]
    fn a_repository_past_its_size_loses_its_oldest_turns_that_may_go() {
        let turns = vec![
            sized(turn("a", 1, 3), "/r/.git", 40),
            sized(turn("a", 2, 2), "/r/.git", 40),
            sized(turn("a", 3, 1), "/r/.git", 40),
            sized(turn("b", 1, 4), "/other/.git", 500),
        ];
        let mut limits = limits();
        limits.max_repository_bytes = Some(90);
        limits.protected_turn_ids.insert("a-1".to_owned());

        // 120 bytes in /r: the unread a-1 stays, so a-2 goes, which is
        // enough. /other is over too, and its only turn goes.
        assert_eq!(
            deleted(&state(turns.clone()), Some(limits.clone())),
            ["b-1", "a-2"]
        );
        limits.max_repository_bytes = None;
        assert!(
            deleted(&state(turns), Some(limits)).is_empty(),
            "no size limit, all within age"
        );
    }

    #[test]
    fn the_size_limit_takes_nothing_more_when_the_age_limit_already_brings_it_back() {
        let turns = vec![
            sized(turn("a", 1, 30), "/r/.git", 100),
            sized(turn("a", 2, 1), "/r/.git", 10),
        ];
        let mut limits = limits();
        limits.max_repository_bytes = Some(50);
        assert_eq!(deleted(&state(turns), Some(limits)), ["a-1"]);
    }

    #[test]
    fn a_held_turn_still_holds_back_what_the_size_limit_would_take() {
        let turns = vec![
            in_worktree(sized(turn("a", 1, 3), "/w/.git", 100), "/w"),
            in_worktree(sized(turn("a", 2, 2), "/w/.git", 100), "/w"),
        ];
        let mut limits = limits();
        limits.max_repository_bytes = Some(50);
        limits.held_turn_ids.insert("a-1".to_owned());
        assert!(
            deleted(&state(turns), Some(limits)).is_empty(),
            "a-2 comes after the held a-1"
        );
    }

    #[test]
    fn an_unread_turn_outlives_the_age_limit_but_not_the_count() {
        let turns: Vec<TurnSummary> = (1..=4).map(|number| turn("a", number, 30)).collect();
        let mut limits = limits();
        limits.max_per_conversation = 3;
        limits.protected_turn_ids = ["a-1", "a-2", "a-3", "a-4"].map(str::to_owned).into();
        assert_eq!(deleted(&state(turns), Some(limits)), ["a-1"]);
    }

    #[test]
    fn past_the_most_turns_kept_the_oldest_go_read_ones_first() {
        let turns = vec![
            turn("a", 1, 3),
            turn("a", 2, 2),
            turn("a", 3, 1),
            turn("a", 4, 0),
        ];
        let mut limits = limits();
        limits.max_turns = Some(2);
        limits.protected_turn_ids = ["a-1", "a-3"].map(str::to_owned).into();
        // The read ones, a-2 and a-4, before any unread one.
        assert_eq!(
            deleted(&state(turns.clone()), Some(limits.clone())),
            ["a-2", "a-4"]
        );
        limits.held_turn_ids.insert("a-1".to_owned());
        let in_one_worktree = turns
            .into_iter()
            .map(|turn| in_worktree(turn, "/w"))
            .collect();
        assert_eq!(
            deleted(&state(in_one_worktree), Some(limits)),
            Vec::<String>::new(),
            "held stops the later ones of its worktree"
        );
    }

    #[test]
    fn what_the_size_limit_takes_counts_toward_the_cap_once() {
        let turns = vec![
            sized(turn("a", 1, 3), "/r/.git", 100),
            sized(turn("a", 2, 2), "/r/.git", 1),
            sized(turn("a", 3, 1), "/r/.git", 1),
        ];
        let mut limits = limits();
        limits.max_repository_bytes = Some(50);
        limits.max_turns = Some(2);
        // a-1 goes for the size, which brings the count to the cap too.
        assert_eq!(deleted(&state(turns), Some(limits)), ["a-1"]);
    }

    #[test]
    fn a_turn_whose_size_is_unknown_neither_fills_nor_frees_its_repository() {
        let mut unknown = turn("a", 1, 2);
        unknown.repository = Some("/r/.git".to_owned());
        let turns = vec![unknown, sized(turn("a", 2, 1), "/r/.git", 10)];
        let mut limits = limits();
        limits.max_repository_bytes = Some(5);
        assert_eq!(deleted(&state(turns), Some(limits)), ["a-2"]);
    }

    #[test]
    fn a_turn_still_started_by_a_run_that_is_gone_is_history() {
        let mut cut_short = turn("a", 1, 30);
        cut_short.phase = TurnPhase::Started;
        assert_eq!(deleted(&state(vec![cut_short]), Some(limits())), ["a-1"]);
    }

    #[test]
    fn past_the_count_go_whatever_their_age() {
        let turns: Vec<TurnSummary> = (1..=5).map(|number| turn("a", number, 0)).collect();
        let mut limits = limits();
        limits.max_per_conversation = 3;
        assert_eq!(deleted(&state(turns), Some(limits)), ["a-1", "a-2"]);
    }

    #[test]
    fn oldest_go_first_and_a_pass_takes_at_most_its_share() {
        let turns: Vec<TurnSummary> = (1..=150)
            .map(|number| turn("a", number, 400 - u64::from(number)))
            .chain([turn("b", 1, 500)])
            .collect();
        let gone = deleted(&state(turns), Some(limits()));
        assert_eq!(gone.len(), MAX_TURN_DELETIONS_PER_PASS);
        assert_eq!(gone[0], "b-1");
        assert_eq!(gone[1], "a-1");
    }

    #[test]
    fn an_unreadable_start_is_no_evidence_of_age() {
        let mut odd = turn("a", 1, 0);
        odd.started_at = "yesterday".to_owned();
        assert!(deleted(&state(vec![odd]), Some(limits())).is_empty());
    }

    #[test]
    fn sweep_names_the_turn_and_its_provider() {
        let input = ProjectionInput {
            turn_sweep: Some(limits()),
            ..ProjectionInput::default()
        };
        let now = Instants {
            wall: NOW.to_owned(),
            monotonic_ms: 0,
        };
        let state = state(vec![turn("a", 1, 30)]);
        let commands = sweep(&state, &state, &input, &now);
        assert_eq!(
            commands[0].target,
            Target::Turn {
                provider: ProviderId::new("claude").expect("provider id"),
                turn_id: "a-1".to_owned()
            }
        );
    }

    fn run(run_id: &str, current: Option<&str>) -> AcceptedRun {
        let mut record = RunRecord::decode(
            br#"{"schemaVersion":3,"paneId":"11111111-1111-4111-8111-111111111111","state":"running","updatedAt":"2026-10-12T00:00:00Z","revision":1}"#,
        )
        .expect("record");
        record.run_id = Some(run_id.to_owned());
        record.current_turn_id = current.map(str::to_owned);
        AcceptedRun {
            provider: ProviderId::new("claude").expect("provider id"),
            record,
        }
    }
}
