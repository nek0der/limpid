//! What to do about running agents when Limpid starts and stops.
//!
//! An agent Limpid launched directly dies with it. That is indistinguishable
//! on disk from an agent the user quit, and the two deserve opposite
//! treatment: one should come back, the other should be forgotten. So the
//! shutdown leaves a marker and, where a session can be resumed, an intent
//! naming what to restore; the next launch reads both and decides.
//!
//! The decision is deliberately conservative in one direction. A marker is
//! honored once and then cleared, so a run that does not come back cannot
//! loop through restore attempts forever, and a marker older than the window
//! is treated as no marker at all.
//!
//! Neither of these is provider-specific. The rule is "Limpid killed a process
//! it owned, and can put it back", which is true of any provider that can
//! resume.

use limpid_agent_model::{
    Capability, Command, CommandOp, LifecycleInput, Patch, PidStatus, Precondition, RecordFile,
    RecordPatch, ResumeIntent, RunRecord, RunState, Target, seconds_between,
};
use limpid_agent_model::{ProviderId, RESUME_WINDOW_SECS};
use serde_json::Value;
use std::collections::BTreeMap;
use uuid::Uuid;

/// One pane's resume hint, as the reader needs it.
struct Hint {
    run_id: Option<String>,
    session_id: String,
}

/// A record paired with the provider whose directory it came from.
struct Run {
    provider: ProviderId,
    storage_id: String,
    record: RunRecord,
}

/// Decides what to restore or retire before the interface is built.
///
/// Runs before anything reads the state directories, so it works from the
/// files alone. Nothing here depends on tabs or panes, which do not exist yet.
#[must_use]
pub fn on_launch(input: &LifecycleInput, now: &str) -> Vec<Command> {
    let hints = hints(input);
    let intents: BTreeMap<&str, &ResumeIntent> = input
        .resume_intents
        .iter()
        .map(|intent| (intent.run_id.as_str(), intent))
        .collect();

    runs(input)
        .into_iter()
        .filter(|run| shows_evidence_of_death(&run.record, input))
        .map(|run| {
            if let Some(intent) = intents.get(run.storage_id.as_str())
                && claims(intent, &run, &hints, now)
            {
                return restore(&run, now).then(Command::new(
                    CommandOp::Delete,
                    Target::ResumeIntent {
                        run_id: run.storage_id.clone(),
                    },
                    Precondition::Exists,
                ));
            }
            if was_killed_recently(&run.record, now) {
                // Best effort. If the write fails the marker stays and the
                // next launch retries exactly this, which is better than
                // abandoning the rest of the sweep over one row.
                return restore(&run, now).continuing();
            }
            // Nothing says Limpid killed it, so nothing says it should come
            // back. The same reading for every provider: a hint that survived
            // its process is not evidence of a crash, because a provider's
            // session-end report can be lost the same way the process was.
            retire(&run)
        })
        .collect()
}

/// Records that Limpid is about to kill the processes it owns, and what it
/// would take to bring them back.
///
/// Runs while the application is exiting, so every write is best effort: a
/// failure costs one row its restore, which is safer than blocking the exit.
#[must_use]
pub fn on_terminate(input: &LifecycleInput, now: &str) -> Vec<Command> {
    let hints = hints(input);
    let mut commands = Vec::new();
    for run in runs(input) {
        // A run inside tmux outlives Limpid, so it needs neither a marker nor
        // a restore.
        if run.record.tmux_socket_path.is_some() {
            continue;
        }
        let Some(pid) = run.record.pid.clone() else {
            continue;
        };
        if input.pid_status.get(&pid).copied() != Some(PidStatus::Alive) {
            continue;
        }

        if let Ok(pane) = Uuid::parse_str(&run.record.pane_id)
            && let Some(hint) = hints.get(&(run.provider.clone(), pane))
            && hint.run_id == run.record.run_id
        {
            commands.push(
                Command::new(
                    CommandOp::WriteResumeIntent(ResumeIntent {
                        run_id: run.storage_id.clone(),
                        pane_id: pane,
                        session_id: hint.session_id.clone(),
                        owner_run_id: hint.run_id.clone(),
                        pid: pid.clone(),
                        created_at: now.to_owned(),
                    }),
                    Target::ResumeIntent {
                        run_id: run.storage_id.clone(),
                    },
                    Precondition::None,
                )
                .continuing(),
            );
        }

        commands.push(
            Command::new(
                CommandOp::Update(RecordPatch {
                    killed_by_limpid_at: Patch::Set(now.to_owned()),
                    ..RecordPatch::default()
                }),
                Target::Record {
                    provider: run.provider.clone(),
                    storage_id: run.storage_id.clone(),
                },
                Precondition::Exists,
            )
            .continuing(),
        );
    }
    commands
}

/// The records of providers that can resume, which is the only kind these
/// rules have anything to say about.
fn runs(input: &LifecycleInput) -> Vec<Run> {
    input
        .records
        .iter()
        .filter(|file| {
            input
                .providers
                .get(&file.provider)
                .is_some_and(|descriptor| descriptor.has(Capability::Resume))
        })
        .filter_map(|file| {
            let record = RunRecord::decode(file.content.as_deref()?.as_bytes()).ok()?;
            Some(Run {
                provider: file.provider.clone(),
                storage_id: file.name.clone(),
                record,
            })
        })
        .collect()
}

fn hints(input: &LifecycleInput) -> BTreeMap<(ProviderId, Uuid), Hint> {
    input
        .session_records
        .iter()
        .filter_map(|file: &RecordFile| {
            let value: Value = serde_json::from_str(file.content.as_deref()?).ok()?;
            let pane = Uuid::parse_str(value.get("paneId")?.as_str()?).ok()?;
            Some((
                (file.provider.clone(), pane),
                Hint {
                    run_id: value
                        .get("runId")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    session_id: value.get("sessionId")?.as_str()?.to_owned(),
                },
            ))
        })
        .collect()
}

/// Whether a record describes a run that is over.
///
/// A live process is left alone, and so is one the host could not ask about
/// unless the run already carries a mark from a previous launch. Without that
/// caution a flaky liveness check would retire working sessions.
fn shows_evidence_of_death(record: &RunRecord, input: &LifecycleInput) -> bool {
    // A tmux-hosted run with no pid outlives Limpid by design.
    if record.tmux_socket_path.is_some() && record.pid.is_none() {
        return false;
    }
    let status = record.pid.as_deref().map_or(PidStatus::Unknown, |pid| {
        input
            .pid_status
            .get(pid)
            .copied()
            .unwrap_or(PidStatus::Unknown)
    });
    match status {
        PidStatus::Alive => false,
        PidStatus::Dead => true,
        PidStatus::Unknown => {
            record.resume_attempted_at.is_some() || record.killed_by_limpid_at.is_some()
        }
    }
}

/// Whether the intent really describes this run and still has a session to
/// return to. Every field has to line up: an intent naming a different
/// process, or pointing at a hint that has since been taken over, is stale.
fn claims(
    intent: &ResumeIntent,
    run: &Run,
    hints: &BTreeMap<(ProviderId, Uuid), Hint>,
    now: &str,
) -> bool {
    if intent.run_id != run.storage_id || intent.pid != run.record.pid.clone().unwrap_or_default() {
        return false;
    }
    if intent.pane_id.to_string().to_uppercase() != run.record.pane_id.to_uppercase() {
        return false;
    }
    if seconds_between(&intent.created_at, now).is_none_or(|age| age >= RESUME_WINDOW_SECS) {
        return false;
    }
    hints
        .get(&(run.provider.clone(), intent.pane_id))
        .is_some_and(|hint| {
            hint.run_id == intent.owner_run_id && hint.session_id == intent.session_id
        })
}

/// Whether Limpid's own kill marker is recent enough to act on.
fn was_killed_recently(record: &RunRecord, now: &str) -> bool {
    record
        .killed_by_limpid_at
        .as_deref()
        .and_then(|killed| seconds_between(killed, now))
        .is_some_and(|age| age < RESUME_WINDOW_SECS)
}

/// Puts a record back into a state the next hook can pick up.
///
/// The pid is cleared along with the marker. Leaving a dead pid would have the
/// liveness sweep retire the record moments later, undoing the restore this is
/// trying to protect, and the marker is cleared so a run that never comes back
/// cannot be restored again and again.
fn restore(run: &Run, now: &str) -> Command {
    Command::new(
        CommandOp::Update(RecordPatch {
            state: Patch::Set(RunState::Unknown),
            pid: Patch::Clear,
            killed_by_limpid_at: Patch::Clear,
            resume_attempted_at: Patch::Set(now.to_owned()),
        }),
        Target::Record {
            provider: run.provider.clone(),
            storage_id: run.storage_id.clone(),
        },
        Precondition::PidAndRevision {
            pid: run.record.pid.clone(),
            revision: run.record.revision,
        },
    )
}

/// Drops everything a run left behind: its hint, its record, and any intent
/// that outlived the session it named.
fn retire(run: &Run) -> Command {
    let record = Command::new(
        CommandOp::Retire,
        Target::Record {
            provider: run.provider.clone(),
            storage_id: run.storage_id.clone(),
        },
        Precondition::RecordUnchanged {
            storage_id: run.storage_id.clone(),
            revision: run.record.revision,
            pid: run.record.pid.clone(),
            updated_at: run.record.updated_at.clone(),
        },
    )
    .then(
        Command::new(
            CommandOp::Delete,
            Target::ResumeIntent {
                run_id: run.storage_id.clone(),
            },
            Precondition::Exists,
        )
        .continuing(),
    );

    let Ok(pane) = Uuid::parse_str(&run.record.pane_id) else {
        return record;
    };
    Command::new(
        CommandOp::Delete,
        Target::SessionHint {
            provider: run.provider.clone(),
            pane,
        },
        Precondition::HintOwner {
            run_id: run.record.run_id.clone(),
        },
    )
    .continuing()
    .then(record)
}

#[cfg(test)]
mod tests {
    use super::*;
    use limpid_agent_model::ProviderDescriptor;
    use std::collections::BTreeSet;

    const PANE: &str = "11111111-1111-4111-8111-111111111111";
    const RUN: &str = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1";
    const NOW: &str = "2026-09-15T12:00:00Z";

    fn provider(name: &str) -> ProviderId {
        ProviderId::new(name).expect("provider id")
    }

    fn descriptor(name: &str, resume: bool) -> ProviderDescriptor {
        let id = provider(name);
        ProviderDescriptor {
            display_name: name.to_owned(),
            capabilities: if resume {
                [Capability::Resume].into_iter().collect()
            } else {
                BTreeSet::default()
            },
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

    fn record_json(extra: &str) -> String {
        format!(
            r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{RUN}","revision":4,
               "state":"running","updatedAt":"2026-09-14T12:00:00Z","pid":"4242"{extra}}}"#
        )
    }

    fn base(name: &str, resume: bool, record: String, status: PidStatus) -> LifecycleInput {
        LifecycleInput {
            providers: [(provider(name), descriptor(name, resume))]
                .into_iter()
                .collect(),
            records: vec![RecordFile {
                provider: provider(name),
                name: RUN.to_owned(),
                content: Some(record),
                is_tmux_hosted: false,
            }],
            session_records: vec![RecordFile {
                provider: provider(name),
                name: PANE.to_owned(),
                content: Some(format!(
                    r#"{{"schemaVersion":1,"paneId":"{PANE}","runId":"{RUN}","sessionId":"S"}}"#
                )),
                is_tmux_hosted: false,
            }],
            resume_intents: Vec::new(),
            pid_status: [("4242".to_owned(), status)].into_iter().collect(),
        }
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

    fn ops(commands: &[Command]) -> Vec<&'static str> {
        commands
            .iter()
            .map(|command| match &command.op {
                CommandOp::Retire => "retire",
                CommandOp::Update(_) => "update",
                CommandOp::Delete => "delete",
                CommandOp::WriteResumeIntent(_) => "write-intent",
                _ => "other",
            })
            .collect()
    }

    #[test]
    fn a_dead_run_without_a_marker_is_retired_whatever_the_provider() {
        // No marker and no intent means Limpid did not kill it, and that is
        // read the same way for a provider that reports its own session ends
        // as for one that does not: the hint goes with the record.
        for name in ["codex", "claude"] {
            let mut input = base(name, true, record_json(""), PidStatus::Dead);
            if name == "claude"
                && let Some(descriptor) = input.providers.get_mut(&provider(name))
            {
                descriptor
                    .capabilities
                    .insert(Capability::SessionEndDropsSession);
            }
            let commands = on_launch(&input, NOW);
            assert_eq!(ops(&commands), vec!["delete"], "{name}");
            assert!(
                matches!(commands[0].then[0].op, CommandOp::Retire),
                "{name}"
            );
        }
    }

    #[test]
    fn shutting_down_records_what_it_would_take_to_come_back() {
        let input = base("codex", true, record_json(""), PidStatus::Alive);
        let commands = on_terminate(&input, NOW);
        assert_eq!(ops(&commands), vec!["write-intent", "update"]);

        // A run inside tmux survives the exit, so neither is written.
        let mut hosted = input.clone();
        hosted.records[0].content = Some(record_json(r#","tmuxSocketPath":"/tmp/s""#));
        assert!(on_terminate(&hosted, NOW).is_empty());

        // A process that is already gone is not one Limpid is killing.
        let mut gone = input.clone();
        gone.pid_status.insert("4242".to_owned(), PidStatus::Dead);
        assert!(on_terminate(&gone, NOW).is_empty());
    }

    #[test]
    fn a_hint_owned_by_another_run_yields_only_the_marker() {
        // The pane has moved on to a newer run. There is no session this
        // record can claim, but it is still a process Limpid is about to kill.
        let mut input = base("codex", true, record_json(""), PidStatus::Alive);
        input.session_records[0].content = Some(format!(
            r#"{{"schemaVersion":1,"paneId":"{PANE}","runId":"OTHER","sessionId":"S"}}"#
        ));
        assert_eq!(ops(&on_terminate(&input, NOW)), vec!["update"]);
    }

    #[test]
    fn a_matching_intent_restores_the_run_and_is_consumed() {
        let mut input = base("codex", true, record_json(""), PidStatus::Dead);
        input.resume_intents = vec![intent("2026-09-15T11:00:00Z")];
        let commands = on_launch(&input, NOW);
        assert_eq!(ops(&commands), vec!["update"]);

        // The intent is only dropped once the restore actually lands.
        let restore = &commands[0];
        assert_eq!(restore.on_mismatch, limpid_agent_model::OnMismatch::Abort);
        assert!(matches!(restore.then[0].op, CommandOp::Delete));

        let CommandOp::Update(patch) = &restore.op else {
            panic!("expected an update");
        };
        // Clearing the pid matters: left in place, the liveness sweep would
        // retire the record moments after this restore protected it.
        assert_eq!(patch.pid, Patch::Clear);
        assert_eq!(patch.killed_by_limpid_at, Patch::Clear);
        assert_eq!(patch.state, Patch::Set(RunState::Unknown));
    }

    #[test]
    fn an_intent_past_its_window_is_no_longer_authority() {
        let mut input = base("codex", true, record_json(""), PidStatus::Dead);
        input.resume_intents = vec![intent("2026-09-13T12:00:00Z")];
        // Falls through to the retirement chain rather than restoring.
        assert_eq!(ops(&on_launch(&input, NOW)), vec!["delete"]);
        assert!(matches!(
            on_launch(&input, NOW)[0].then[0].op,
            CommandOp::Retire
        ));
    }

    #[test]
    fn a_recent_kill_marker_is_honored_once() {
        let killed = record_json(r#","killedByLimpidAt":"2026-09-15T11:00:00Z""#);
        let input = base("codex", true, killed, PidStatus::Dead);
        let commands = on_launch(&input, NOW);
        assert_eq!(ops(&commands), vec!["update"]);
        // Best effort: a failed write leaves the marker for the next launch
        // rather than abandoning the rest of the sweep.
        assert_eq!(
            commands[0].on_mismatch,
            limpid_agent_model::OnMismatch::Continue
        );

        // A marker older than the window is treated as no marker at all, so a
        // run that never came back cannot be restored forever.
        let stale = record_json(r#","killedByLimpidAt":"2026-09-13T11:00:00Z""#);
        let input = base("codex", true, stale, PidStatus::Dead);
        assert_eq!(ops(&on_launch(&input, NOW)), vec!["delete"]);
    }

    #[test]
    fn a_run_with_no_evidence_of_death_is_left_alone() {
        // Alive, so nothing to do.
        let input = base("codex", true, record_json(""), PidStatus::Alive);
        assert!(on_launch(&input, NOW).is_empty());

        // The host could not tell, and the run carries no mark from a previous
        // launch. A flaky liveness check must not retire a working session.
        let input = base("codex", true, record_json(""), PidStatus::Unknown);
        assert!(on_launch(&input, NOW).is_empty());

        // The same uncertainty plus a mark from last time is enough.
        let marked = record_json(r#","resumeAttemptedAt":"2026-09-14T12:00:00Z""#);
        let input = base("codex", true, marked, PidStatus::Unknown);
        assert_eq!(ops(&on_launch(&input, NOW)), vec!["delete"]);
    }

    #[test]
    fn every_provider_that_can_resume_takes_part() {
        // The rule is "Limpid killed a process it owned and can put it back",
        // which has nothing to do with which provider it was.
        let input = base("claude", true, record_json(""), PidStatus::Alive);
        assert_eq!(
            ops(&on_terminate(&input, NOW)),
            vec!["write-intent", "update"]
        );

        // A provider that cannot resume has nothing to preserve.
        let input = base("claude", false, record_json(""), PidStatus::Alive);
        assert!(on_terminate(&input, NOW).is_empty());
        assert!(on_launch(&input, NOW).is_empty());
    }
}
