//! Retiring records for runs that are gone, and keeping the directories from
//! growing without bound.
//!
//! Removing state is the one thing here that cannot be undone by the next
//! pass, so the bar is high. A record is retired only when its process is
//! confirmed dead and nothing has claimed it for a restore. A missing pid is
//! not evidence of death, and neither is one the host could not ask about:
//! silence is not an answer, so the record stays.
//!
//! Whether the pane is still open is deliberately not a condition. A run that
//! crashed mid-turn leaves its pane open with a badge that says "running", and
//! the pane stays open across a relaunch because the session restores it. The
//! pid is what says the run is over; the pane says nothing either way.
//!
//! Retiring is a move, not a delete. A record that turns out to have been
//! live is still there to be read.

use limpid_agent_model::{
    AcceptedRun, Capability, Command, CommandOp, Instants, MAX_PANE_RECORDS, MAX_RETIRED_RECORDS,
    PaneStoreKind, PidStatus, Precondition, ProjectionInput, RESUME_WINDOW_SECS,
    RETIRED_RECORD_LIFETIME_SECS, RunRecord, Target, seconds_between,
};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

/// Returns the retirements and sweeps this pass calls for.
///
/// `alive` is the set of panes the interface still has. Together with the
/// runs in tmux it decides which pane-scoped files the sweeps keep; it plays
/// no part in retiring records.
pub(crate) fn sweep(
    accepted: &BTreeMap<String, AcceptedRun>,
    input: &ProjectionInput,
    alive: &BTreeSet<Uuid>,
    now: &Instants,
) -> Vec<Command> {
    // An intent past its window is no longer a claim. The launch rules would
    // not honor it either, so letting it hold a dead record would keep both
    // on disk for good.
    let claimed: BTreeSet<&str> = input
        .resume_intents
        .iter()
        .filter(|intent| {
            seconds_between(&intent.created_at, &now.wall)
                .is_some_and(|age| age < RESUME_WINDOW_SECS)
        })
        .map(|intent| intent.run_id.as_str())
        .collect();

    let mut commands: Vec<Command> = accepted
        .iter()
        .filter(|(storage_id, run)| {
            // A restore has already claimed this run. Retiring it now would
            // take away the record the restore is about to rebuild from.
            !claimed.contains(storage_id.as_str()) && is_removable(&run.record, input)
        })
        .map(|(storage_id, run)| retire(storage_id, run, accepted))
        .collect();

    let keep = pane_store_keep(accepted, alive);
    for (provider, descriptor) in &input.providers {
        commands.push(Command::new(
            CommandOp::PruneRetired {
                max: MAX_RETIRED_RECORDS,
                lifetime_secs: RETIRED_RECORD_LIFETIME_SECS,
            },
            Target::RetiredRecords {
                provider: provider.clone(),
            },
            Precondition::None,
        ));
        commands.push(cleanup(provider, PaneStoreKind::Sessions, &keep));
        if descriptor.has(Capability::CwdEvents) {
            commands.push(cleanup(provider, PaneStoreKind::CwdEvents, &keep));
        }
    }
    commands
}

/// The panes whose side files the sweep keeps: every pane the interface has,
/// and the pane of every run in tmux whose session has not ended.
///
/// A run in tmux can write under a pane before the interface has one. Limpid
/// hands the agent the id of the pane that will show it, and the hook may
/// report before the application has built that pane. Sweeping by open panes
/// alone would take the run's resume hint in that window.
///
/// Which runs count is `is_live_tmux_run`'s to say, so this and the resume
/// rules cannot disagree about whether a run is still going.
fn pane_store_keep(
    accepted: &BTreeMap<String, AcceptedRun>,
    alive: &BTreeSet<Uuid>,
) -> BTreeSet<Uuid> {
    let mut keep = alive.clone();
    keep.extend(
        accepted
            .values()
            .map(|run| &run.record)
            .filter(|record| crate::lifecycle::is_live_tmux_run(record))
            .filter_map(|record| Uuid::parse_str(&record.pane_id).ok()),
    );
    keep
}

/// Whether a record describes a run that is definitely over.
fn is_removable(record: &RunRecord, input: &ProjectionInput) -> bool {
    // A run inside tmux outlives the window that was showing it, which is the
    // point of hosting it there. Its record names no pid of ours to ask about.
    if record.tmux_socket_path.is_some() {
        return false;
    }
    if Uuid::parse_str(&record.pane_id).is_err() {
        return false;
    }
    // Only a confirmed death counts. A record with no pid, or one the host
    // could not ask about, is left alone.
    record
        .pid
        .as_deref()
        .is_some_and(|pid| input.pid_status.get(pid).copied() == Some(PidStatus::Dead))
}

/// Drops the run's resume hint and then retires its record.
///
/// The hint goes first and best-effort. It may already belong to a newer run
/// on the same pane, in which case it is left where it is — but the dead
/// record still has to go, or it would sit there forever being re-examined
/// every pass.
fn retire(
    storage_id: &str,
    run: &AcceptedRun,
    accepted: &BTreeMap<String, AcceptedRun>,
) -> Command {
    let record = &run.record;
    let retire = Command::new(
        CommandOp::Retire,
        Target::Record {
            provider: run.provider.clone(),
            storage_id: storage_id.to_owned(),
        },
        Precondition::RecordUnchanged {
            storage_id: storage_id.to_owned(),
            revision: record.revision,
            pid: record.pid.clone(),
            updated_at: record.updated_at.clone(),
        },
    );

    let Ok(pane) = Uuid::parse_str(&record.pane_id) else {
        return retire;
    };
    if !owns_hint(storage_id, run, accepted) {
        return retire;
    }
    Command::new(
        CommandOp::Delete,
        Target::SessionHint {
            provider: run.provider.clone(),
            pane,
        },
        Precondition::HintOwner {
            run_id: record.run_id.clone(),
        },
    )
    .continuing()
    .then(retire)
}

/// Whether this run's record is allowed to claim the pane's hint.
///
/// A record from before run ids existed carries none, so the hint's missing
/// run id would match it by default. When another record shares the pane, that
/// match is a coincidence rather than ownership, and taking the hint would
/// strand the run that is actually using it.
fn owns_hint(
    storage_id: &str,
    run: &AcceptedRun,
    accepted: &BTreeMap<String, AcceptedRun>,
) -> bool {
    if run.record.run_id.is_some() {
        return true;
    }
    !accepted.iter().any(|(other_id, other)| {
        other_id != storage_id && other.record.pane_id == run.record.pane_id
    })
}

fn cleanup(
    provider: &limpid_agent_model::ProviderId,
    store: PaneStoreKind,
    alive: &BTreeSet<Uuid>,
) -> Command {
    Command::new(
        CommandOp::CleanupPaneStore {
            keep: alive.clone(),
            max: MAX_PANE_RECORDS,
        },
        Target::PaneStore {
            provider: provider.clone(),
            store,
        },
        Precondition::None,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use limpid_agent_model::{ProviderId, ResumeIntent, RunState};

    const PANE: &str = "11111111-1111-4111-8111-111111111111";
    const RUN: &str = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1";

    fn claude() -> ProviderId {
        ProviderId::new("claude").expect("provider id")
    }

    fn run(run_id: Option<&str>, pid: Option<&str>) -> AcceptedRun {
        let mut record = RunRecord::decode(
            format!(
                r#"{{"schemaVersion":3,"paneId":"{PANE}","state":"finished",
                   "updatedAt":"2026-09-14T12:00:00Z","revision":4}}"#
            )
            .as_bytes(),
        )
        .expect("record");
        record.run_id = run_id.map(str::to_owned);
        record.pid = pid.map(str::to_owned);
        AcceptedRun {
            provider: claude(),
            record,
        }
    }

    fn records(entries: Vec<(&str, AcceptedRun)>) -> BTreeMap<String, AcceptedRun> {
        entries
            .into_iter()
            .map(|(id, run)| (id.to_owned(), run))
            .collect()
    }

    fn input(status: PidStatus) -> ProjectionInput {
        ProjectionInput {
            pid_status: [("4242".to_owned(), status)].into_iter().collect(),
            ..ProjectionInput::default()
        }
    }

    fn now() -> Instants {
        Instants {
            wall: "2026-09-14T12:10:00Z".to_owned(),
            monotonic_ms: 0,
        }
    }

    fn retirements(commands: &[Command]) -> Vec<&Command> {
        commands
            .iter()
            .filter(|command| {
                matches!(command.op, CommandOp::Retire)
                    || command
                        .then
                        .iter()
                        .any(|next| matches!(next.op, CommandOp::Retire))
            })
            .collect()
    }

    #[test]
    fn a_dead_run_on_a_closed_pane_loses_its_hint_and_then_its_record() {
        let entries = records(vec![(RUN, run(Some(RUN), Some("4242")))]);
        let commands = sweep(&entries, &input(PidStatus::Dead), &BTreeSet::new(), &now());
        let chain = retirements(&commands);
        assert_eq!(chain.len(), 1);

        // The hint goes first and best-effort; the record goes after and only
        // if nothing has rewritten it.
        assert!(matches!(chain[0].op, CommandOp::Delete));
        assert_eq!(
            chain[0].on_mismatch,
            limpid_agent_model::OnMismatch::Continue
        );
        assert!(matches!(chain[0].then[0].op, CommandOp::Retire));
        assert_eq!(
            chain[0].then[0].on_mismatch,
            limpid_agent_model::OnMismatch::Abort
        );
    }

    #[test]
    fn a_dead_run_is_retired_even_while_its_pane_is_open() {
        // The pane outlives the process: a crash mid-turn leaves it open with a
        // "running" badge, and a relaunch restores it. Waiting for the pane
        // would leave that badge there until the user closed it by hand.
        let entries = records(vec![(RUN, run(Some(RUN), Some("4242")))]);
        let pane: Uuid = PANE.parse().expect("pane");
        let alive = [pane].into_iter().collect();
        assert_eq!(
            retirements(&sweep(&entries, &input(PidStatus::Dead), &alive, &now())).len(),
            1
        );
    }

    #[test]
    fn nothing_is_retired_without_a_confirmed_death() {
        let entries = records(vec![(RUN, run(Some(RUN), Some("4242")))]);

        // The host could not tell whether the process is alive.
        assert!(
            retirements(&sweep(
                &entries,
                &input(PidStatus::Unknown),
                &BTreeSet::new(),
                &now()
            ))
            .is_empty()
        );

        // The record names no process at all.
        let anonymous = records(vec![(RUN, run(Some(RUN), None))]);
        assert!(
            retirements(&sweep(
                &anonymous,
                &input(PidStatus::Dead),
                &BTreeSet::new(),
                &now()
            ))
            .is_empty()
        );
    }

    #[test]
    fn a_run_inside_tmux_survives_its_pane() {
        // Outliving the window is the point of hosting a run in tmux, so the
        // pane closing says nothing about the run.
        let mut hosted = run(Some(RUN), Some("4242"));
        hosted.record.tmux_socket_path = Some("/tmp/socket".to_owned());
        hosted.record.state = RunState::Running;
        let entries = records(vec![(RUN, hosted)]);
        assert!(
            retirements(&sweep(
                &entries,
                &input(PidStatus::Dead),
                &BTreeSet::new(),
                &now()
            ))
            .is_empty()
        );
    }

    fn intent(created_at: &str) -> ResumeIntent {
        ResumeIntent {
            run_id: RUN.to_owned(),
            pane_id: PANE.parse().expect("pane"),
            session_id: "S".to_owned(),
            owner_run_id: Some(RUN.to_owned()),
            pid: "4242".to_owned(),
            created_at: created_at.to_owned(),
        }
    }

    #[test]
    fn a_run_a_restore_has_claimed_is_left_alone() {
        let entries = records(vec![(RUN, run(Some(RUN), Some("4242")))]);
        let mut input = input(PidStatus::Dead);
        input.resume_intents = vec![intent("2026-09-14T12:00:00Z")];
        assert!(retirements(&sweep(&entries, &input, &BTreeSet::new(), &now())).is_empty());
    }

    #[test]
    fn an_intent_past_its_window_no_longer_holds_the_record() {
        // The launch rules would not restore from it either, so honoring it
        // here would keep the record and the intent on disk indefinitely.
        let entries = records(vec![(RUN, run(Some(RUN), Some("4242")))]);
        let mut input = input(PidStatus::Dead);
        input.resume_intents = vec![intent("2026-09-13T12:00:00Z")];
        assert_eq!(
            retirements(&sweep(&entries, &input, &BTreeSet::new(), &now())).len(),
            1
        );

        // An intent whose timestamp cannot be read makes no claim either.
        input.resume_intents = vec![intent("not a time")];
        assert_eq!(
            retirements(&sweep(&entries, &input, &BTreeSet::new(), &now())).len(),
            1
        );
    }

    #[test]
    fn a_record_without_a_run_id_does_not_claim_a_shared_pane_hint() {
        // Both records would match a hint that carries no run id. Taking it
        // would strand whichever run is actually using it, so neither does.
        let entries = records(vec![
            (PANE, run(None, Some("4242"))),
            (RUN, run(Some(RUN), Some("4242"))),
        ]);
        let commands = sweep(&entries, &input(PidStatus::Dead), &BTreeSet::new(), &now());
        let legacy = retirements(&commands)
            .into_iter()
            .find(|command| matches!(&command.target, Target::Record { storage_id, .. } if storage_id == PANE))
            .expect("the legacy record is retired");
        assert!(matches!(legacy.op, CommandOp::Retire));
        assert!(legacy.then.is_empty());
    }

    #[test]
    fn every_pass_sweeps_the_directories_it_is_responsible_for() {
        let mut input = ProjectionInput::default();
        let mut descriptor = limpid_agent_model::ProviderDescriptor {
            id: claude(),
            display_name: "Claude".to_owned(),
            capabilities: [Capability::CwdEvents].into_iter().collect(),
            pid_sweep_interval_ms: 30_000,
            state_directory: "agent-states".to_owned(),
            session_directory: "sessions".to_owned(),
            cwd_events_directory: Some("cwd-events".to_owned()),
            process_names: Vec::new(),
            session_end_drop_reasons: Vec::new(),
        };
        input.providers.insert(claude(), descriptor.clone());
        let commands = sweep(&BTreeMap::new(), &input, &BTreeSet::new(), &now());
        assert_eq!(commands.len(), 3, "prune plus two pane stores");

        // A provider that reports no cwd changes has no such directory to
        // sweep, so it gets one fewer command rather than an empty one.
        descriptor.capabilities.clear();
        input.providers.insert(claude(), descriptor);
        assert_eq!(
            sweep(&BTreeMap::new(), &input, &BTreeSet::new(), &now()).len(),
            2
        );
    }

    fn kept(commands: &[Command]) -> Vec<&BTreeSet<Uuid>> {
        commands
            .iter()
            .filter_map(|command| match &command.op {
                CommandOp::CleanupPaneStore { keep, .. } => Some(keep),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_run_in_tmux_keeps_its_pane_files_until_its_session_ends() {
        // The hook can write under the pane before the interface has built
        // it, so an open pane cannot be the only reason to keep the files.
        let mut input = input(PidStatus::Unknown);
        let mut descriptor = limpid_agent_model::ProviderDescriptor {
            id: claude(),
            display_name: "Claude".to_owned(),
            capabilities: [Capability::CwdEvents].into_iter().collect(),
            pid_sweep_interval_ms: 30_000,
            state_directory: "agent-states".to_owned(),
            session_directory: "sessions".to_owned(),
            cwd_events_directory: Some("cwd-events".to_owned()),
            process_names: Vec::new(),
            session_end_drop_reasons: Vec::new(),
        };
        descriptor.capabilities.insert(Capability::Resume);
        input.providers.insert(claude(), descriptor);
        let pane: Uuid = PANE.parse().expect("pane");
        let open: Uuid = "22222222-2222-4222-8222-222222222222"
            .parse()
            .expect("pane");
        let alive: BTreeSet<Uuid> = [open].into_iter().collect();

        let mut hosted = run(Some(RUN), None);
        hosted.record.tmux_socket_path = Some("/tmp/socket".to_owned());
        hosted.record.last_hook_event = Some("session_started".to_owned());
        let entries = records(vec![(RUN, hosted.clone())]);
        let commands = sweep(&entries, &input, &alive, &now());
        let expected: BTreeSet<Uuid> = [pane, open].into_iter().collect();
        assert_eq!(kept(&commands), vec![&expected, &expected]);

        // Once the session has ended the pane is kept only while it is open.
        for ended in ["session_ended", "SessionEnd"] {
            let mut over = hosted.clone();
            over.record.last_hook_event = Some(ended.to_owned());
            let entries = records(vec![(RUN, over)]);
            let commands = sweep(&entries, &input, &alive, &now());
            assert_eq!(kept(&commands), vec![&alive, &alive], "{ended}");
        }

        // A run outside tmux is kept by its pane or not at all.
        let entries = records(vec![(RUN, run(Some(RUN), Some("4242")))]);
        let commands = sweep(&entries, &input, &alive, &now());
        assert_eq!(kept(&commands), vec![&alive, &alive]);
    }
}
