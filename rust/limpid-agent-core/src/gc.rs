//! Retiring records for runs that are gone, and keeping the directories from
//! growing without bound.
//!
//! Removing state is the one thing here that cannot be undone by the next
//! pass, so the bar is high. A record is retired only when three independent
//! facts agree: the pane it belonged to is no longer in any tab, its process
//! is confirmed dead, and nothing has claimed it for a restore. A missing pid
//! is not evidence of death, and neither is one the host could not ask
//! about: silence is not an answer, so the record stays.
//!
//! Retiring is a move, not a delete. A record that turns out to have been
//! live is still there to be read.

use limpid_agent_model::{
    AcceptedRun, Capability, Command, CommandOp, MAX_PANE_RECORDS, MAX_RETIRED_RECORDS,
    PaneStoreKind, PidStatus, Precondition, ProjectionInput, RETIRED_RECORD_LIFETIME_SECS,
    RunRecord, Target,
};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

/// Returns the retirements and sweeps this pass calls for.
pub(crate) fn sweep(
    accepted: &BTreeMap<String, AcceptedRun>,
    input: &ProjectionInput,
    alive: &BTreeSet<Uuid>,
) -> Vec<Command> {
    let claimed: BTreeSet<&str> = input
        .resume_intents
        .iter()
        .map(|intent| intent.run_id.as_str())
        .collect();

    let mut commands: Vec<Command> = accepted
        .iter()
        .filter(|(storage_id, run)| {
            // A restore has already claimed this run. Retiring it now would
            // take away the record the restore is about to rebuild from.
            !claimed.contains(storage_id.as_str()) && is_removable(&run.record, input, alive)
        })
        .map(|(storage_id, run)| retire(storage_id, run, accepted))
        .collect();

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
        commands.push(cleanup(provider, PaneStoreKind::Sessions, alive));
        if descriptor.has(Capability::CwdEvents) {
            commands.push(cleanup(provider, PaneStoreKind::CwdEvents, alive));
        }
    }
    commands
}

/// Whether a record describes a run that is definitely over.
fn is_removable(record: &RunRecord, input: &ProjectionInput, alive: &BTreeSet<Uuid>) -> bool {
    // A run inside tmux outlives the window that was showing it, which is the
    // point of hosting it there. Its pane going away says nothing about it.
    if record.tmux_socket_path.is_some() {
        return false;
    }
    let Ok(pane) = Uuid::parse_str(&record.pane_id) else {
        return false;
    };
    if alive.contains(&pane) {
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
        let commands = sweep(&entries, &input(PidStatus::Dead), &BTreeSet::new());
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
    fn nothing_is_retired_without_three_agreeing_facts() {
        let entries = records(vec![(RUN, run(Some(RUN), Some("4242")))]);
        let pane: Uuid = PANE.parse().expect("pane");

        // The pane is still open.
        let alive = [pane].into_iter().collect();
        assert!(retirements(&sweep(&entries, &input(PidStatus::Dead), &alive)).is_empty());

        // The host could not tell whether the process is alive.
        assert!(
            retirements(&sweep(
                &entries,
                &input(PidStatus::Unknown),
                &BTreeSet::new()
            ))
            .is_empty()
        );

        // The record names no process at all.
        let anonymous = records(vec![(RUN, run(Some(RUN), None))]);
        assert!(
            retirements(&sweep(
                &anonymous,
                &input(PidStatus::Dead),
                &BTreeSet::new()
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
            retirements(&sweep(&entries, &input(PidStatus::Dead), &BTreeSet::new())).is_empty()
        );
    }

    #[test]
    fn a_run_a_restore_has_claimed_is_left_alone() {
        let entries = records(vec![(RUN, run(Some(RUN), Some("4242")))]);
        let mut input = input(PidStatus::Dead);
        input.resume_intents = vec![ResumeIntent {
            run_id: RUN.to_owned(),
            pane_id: PANE.parse().expect("pane"),
            session_id: "S".to_owned(),
            owner_run_id: Some(RUN.to_owned()),
            pid: "4242".to_owned(),
            created_at: "2026-09-14T12:00:00Z".to_owned(),
        }];
        assert!(retirements(&sweep(&entries, &input, &BTreeSet::new())).is_empty());
    }

    #[test]
    fn a_record_without_a_run_id_does_not_claim_a_shared_pane_hint() {
        // Both records would match a hint that carries no run id. Taking it
        // would strand whichever run is actually using it, so neither does.
        let entries = records(vec![
            (PANE, run(None, Some("4242"))),
            (RUN, run(Some(RUN), Some("4242"))),
        ]);
        let commands = sweep(&entries, &input(PidStatus::Dead), &BTreeSet::new());
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
        let commands = sweep(&BTreeMap::new(), &input, &BTreeSet::new());
        assert_eq!(commands.len(), 3, "prune plus two pane stores");

        // A provider that reports no cwd changes has no such directory to
        // sweep, so it gets one fewer command rather than an empty one.
        descriptor.capabilities.clear();
        input.providers.insert(claude(), descriptor);
        assert_eq!(sweep(&BTreeMap::new(), &input, &BTreeSet::new()).len(), 2);
    }
}
