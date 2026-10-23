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
//! A restore that never came back is the one exception, and a deliberate one.
//! The resume Limpid types at launch has no fresh agent behind it: when
//! it fails, the conversation's place stays in the pane as a stop that offers
//! the same resume again or a new conversation, and a stop is the person's to
//! end, not the clock's. So a record still carrying its restore mark, with
//! nothing written to it since and a pane whose hint still names it, is
//! restored again rather than retired, and the resume is typed once more.
//! That loops only as long as the person leaves the stop in place.
//!
//! None of this applies to a session that never held a conversation: started
//! anew and never prompted (`RunRecord::has_prompt` is `false`), it has no
//! transcript, so no resume of it can succeed and nothing is lost by not
//! trying. Such a run retires quietly whatever else would have restored it.
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
        .filter_map(|run| {
            if run.record.has_prompt == Some(false) {
                // A session started anew that never received a prompt has
                // no transcript: nothing was said in it, and nothing on disk
                // for a resume to find. Typing one would only fail into a
                // stop over nothing, so the run retires quietly and
                // the pane opens as a plain shell. An older record that does
                // not say goes on to the checks below.
                return Some(retire(&run));
            }
            if let Some(intent) = intents.get(run.storage_id.as_str())
                && claims(intent, &run, &hints, now)
            {
                return Some(restore(&run, now).then(Command::new(
                    CommandOp::Delete,
                    Target::ResumeIntent {
                        run_id: run.storage_id.clone(),
                    },
                    Precondition::Exists,
                )));
            }
            if was_killed_recently(&run.record, now) {
                // Best effort. If the write fails the marker stays and the
                // next launch retries exactly this, which is better than
                // abandoning the rest of the sweep over one row.
                return Some(restore(&run, now).continuing());
            }
            if awaits_its_resume(&run, &hints) {
                // The previous launch's resume did not bring the run back,
                // and the pane still holds the conversation's place as a
                // stop. Retiring it here would end that stop by
                // relaunch alone; typing the resume again keeps it the
                // person's to end.
                return Some(restore(&run, now).continuing());
            }
            if died_at_work_unseen(&run, input) {
                // Died in the moments between the last sweep and the quit,
                // so no pass has shown it as stopped yet. Retiring it here
                // would end a stop before it was ever listed; left to
                // the first pass, it shows once as stopped (processExited)
                // and is retired then, as a death seen live is. An intent
                // it still has is stale (`claims` said no) and goes now, as
                // the first pass retires without touching intents.
                return intents.contains_key(run.storage_id.as_str()).then(|| {
                    Command::new(
                        CommandOp::Delete,
                        Target::ResumeIntent {
                            run_id: run.storage_id.clone(),
                        },
                        Precondition::Exists,
                    )
                    .continuing()
                });
            }
            // Nothing says Limpid killed it, so nothing says it should come
            // back. The same reading for every provider: a hint that survived
            // its process is not evidence of a crash, because a provider's
            // session-end report can be lost the same way the process was.
            Some(retire(&run))
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

/// Whether the run died at work (`gc::died_at_work`: mid-turn, with no
/// kill of Limpid's) and is confirmed dead, with no pass having seen it
/// yet. The one record a launch leaves alone, so that the first pass
/// lists the stop a live death would have.
fn died_at_work_unseen(run: &Run, input: &LifecycleInput) -> bool {
    let is_dead = run
        .record
        .pid
        .as_deref()
        .is_some_and(|pid| input.pid_status.get(pid).copied() == Some(PidStatus::Dead));
    is_dead && crate::gc::died_at_work(&run.record)
}

/// Whether Limpid's own kill marker is recent enough to act on.
fn was_killed_recently(record: &RunRecord, now: &str) -> bool {
    record
        .killed_by_limpid_at
        .as_deref()
        .and_then(|killed| seconds_between(killed, now))
        .is_some_and(|age| age < RESUME_WINDOW_SECS)
}

/// Whether the run's last restore never came back: the record still carries
/// the mark that restore left, nothing has written to it since (the pid the
/// restore cleared is still clear, and `updated_at` is not after the mark —
/// a restore sets the mark without touching `updated_at`, and every hook
/// event sets both the pid and `updated_at`), and the pane's hint still names
/// this run as its conversation. A hint another run has taken over, or a
/// record from before run ids, claims nothing; nor does a pane that was
/// closed, whose hint the next pass swept with the pane store (`gc::sweep`
/// keeps only the panes a tab holds).
fn awaits_its_resume(run: &Run, hints: &BTreeMap<(ProviderId, Uuid), Hint>) -> bool {
    let record = &run.record;
    let Some(attempted) = record.resume_attempted_at.as_deref() else {
        return false;
    };
    if record.pid.is_some() {
        return false;
    }
    if seconds_between(attempted, &record.updated_at).is_none_or(|age| age > 0) {
        return false;
    }
    let Some(run_id) = record.run_id.as_deref() else {
        return false;
    };
    let Ok(pane) = Uuid::parse_str(&record.pane_id) else {
        return false;
    };
    hints
        .get(&(run.provider.clone(), pane))
        .is_some_and(|hint| hint.run_id.as_deref() == Some(run_id))
}

/// Puts a record back into a state the next hook can pick up.
///
/// The pid is cleared along with the marker. Leaving a dead pid would have the
/// liveness sweep retire the record moments later, undoing the restore this is
/// trying to protect, and the kill marker is cleared so a later launch does
/// not restore the run again on the marker alone; one that never came back
/// is restored again only while nothing has written its record since and
/// its pane still names it (`awaits_its_resume`).
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

    const PANE: &str = "11111111-1111-4111-8111-111111111111";
    const RUN: &str = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1";
    const NOW: &str = "2026-09-15T12:00:00Z";

    fn provider(name: &str) -> ProviderId {
        ProviderId::new(name).expect("provider id")
    }

    fn descriptor(name: &str, resume: bool) -> ProviderDescriptor {
        ProviderDescriptor::fixture(name, resume.then_some(Capability::Resume))
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
            }],
            session_records: vec![RecordFile {
                provider: provider(name),
                name: PANE.to_owned(),
                content: Some(format!(
                    r#"{{"schemaVersion":1,"paneId":"{PANE}","runId":"{RUN}","sessionId":"S"}}"#
                )),
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
            // A run that had ended on its own terms: one still at work is
            // left for the first pass (`died_at_work_unseen`).
            input.records[0].content = Some(record_json("").replace("\"running\"", "\"finished\""));
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
        let finished = record_json("").replace("\"running\"", "\"finished\"");
        let mut input = base("codex", true, finished, PidStatus::Dead);
        input.resume_intents = vec![intent("2026-09-13T12:00:00Z")];
        // Falls through to the retirement chain rather than restoring.
        assert_eq!(ops(&on_launch(&input, NOW)), vec!["delete"]);
        assert!(matches!(
            on_launch(&input, NOW)[0].then[0].op,
            CommandOp::Retire
        ));
    }

    #[test]
    fn a_run_that_died_at_work_unseen_is_left_for_the_first_pass_to_list_its_stop() {
        // Killed in the moments between the last sweep and the quit: no
        // pass showed it stopped, and the stop ledger never heard of it.
        // Retired here, the stop would never exist; left alone, the
        // first pass shows it once as stopped and retires it then.
        for state in ["running", "needsInput", "compacting"] {
            let json = record_json("").replace("\"running\"", &format!("\"{state}\""));
            let input = base("claude", true, json, PidStatus::Dead);
            assert!(on_launch(&input, NOW).is_empty(), "{state}");
        }

        // A stale intent for it is not a claim, and would otherwise stay.
        let mut stale = base("claude", true, record_json(""), PidStatus::Dead);
        stale.resume_intents = vec![intent("2026-09-13T12:00:00Z")];
        let commands = on_launch(&stale, NOW);
        assert_eq!(ops(&commands), vec!["delete"]);
        assert!(matches!(commands[0].target, Target::ResumeIntent { .. }));

        // A run at rest when it died, one that had ended, or one Limpid
        // killed too long ago to restore: nothing stopped at work, so each
        // retires.
        for state in ["idle", "finished", "error", "unknown"] {
            let json = record_json("").replace("\"running\"", &format!("\"{state}\""));
            let input = base("claude", true, json, PidStatus::Dead);
            assert_eq!(ops(&on_launch(&input, NOW)), vec!["delete"], "{state}");
        }
        let killed = record_json(r#","killedByLimpidAt":"2026-09-13T11:00:00Z""#);
        let input = base("claude", true, killed, PidStatus::Dead);
        assert_eq!(ops(&on_launch(&input, NOW)), vec!["delete"]);

        // Only a confirmed death: a pid the host could not ask about is no
        // evidence either way.
        let input = base("claude", true, record_json(""), PidStatus::Unknown);
        assert!(on_launch(&input, NOW).is_empty());
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

    /// A record carrying the mark of the previous launch's restore, last
    /// written at `updated_at`: nothing since the restore when that is before
    /// the mark, which a restore sets without touching `updatedAt`.
    fn restored_record_json(updated_at: &str, extra: &str) -> String {
        format!(
            r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{RUN}","revision":4,
               "state":"unknown","updatedAt":"{updated_at}",
               "resumeAttemptedAt":"2026-09-14T12:00:30Z"{extra}}}"#
        )
    }

    #[test]
    fn a_restore_that_never_came_back_is_tried_again_while_the_pane_names_the_run() {
        // The resume typed last time failed, or its run never reported. The
        // pane keeps the conversation's place as a stop, so the record
        // and its hint stay and the resume is typed once more.
        let mut input = base(
            "claude",
            true,
            restored_record_json("2026-09-14T12:00:00Z", ""),
            PidStatus::Unknown,
        );
        input.pid_status.clear();
        let commands = on_launch(&input, NOW);
        assert_eq!(ops(&commands), vec!["update"]);
        let CommandOp::Update(patch) = &commands[0].op else {
            panic!("expected a restore");
        };
        assert_eq!(patch.resume_attempted_at, Patch::Set(NOW.to_owned()));
        assert_eq!(
            commands[0].on_mismatch,
            limpid_agent_model::OnMismatch::Continue
        );

        // The pane has moved on to another run: this one has no place left
        // to keep, and retires.
        let mut taken = input.clone();
        taken.session_records[0].content = Some(format!(
            r#"{{"schemaVersion":1,"paneId":"{PANE}","runId":"OTHER","sessionId":"S"}}"#
        ));
        let commands = on_launch(&taken, NOW);
        assert_eq!(ops(&commands), vec!["delete"]);
        assert!(matches!(commands[0].then[0].op, CommandOp::Retire));

        // The pane was closed: the first pass after that swept its hint
        // (the pane store keeps only the panes a tab holds), so the stop
        // has no pane to stay in and the run retires rather than coming
        // back at every launch.
        let mut closed = input.clone();
        closed.session_records.clear();
        let commands = on_launch(&closed, NOW);
        assert_eq!(ops(&commands), vec!["delete"]);
        assert!(matches!(commands[0].then[0].op, CommandOp::Retire));

        // The run did come back after the restore and died later: the mark
        // is history, and the death is read as any other.
        let mut reported = input.clone();
        reported.records[0].content = Some(restored_record_json(
            "2026-09-14T12:05:00Z",
            r#","pid":"4242""#,
        ));
        reported
            .pid_status
            .insert("4242".to_owned(), PidStatus::Dead);
        let commands = on_launch(&reported, NOW);
        assert_eq!(ops(&commands), vec!["delete"]);
        assert!(matches!(commands[0].then[0].op, CommandOp::Retire));
    }

    #[test]
    fn a_session_that_never_received_a_prompt_retires_quietly_whatever_would_restore_it() {
        // Nothing was said in it, so there is no transcript for a resume to
        // find: neither an intent nor a kill marker brings it back.
        let never = record_json(r#","hasPrompt":false"#);
        let mut input = base("claude", true, never.clone(), PidStatus::Dead);
        input.resume_intents = vec![intent("2026-09-15T11:00:00Z")];
        let commands = on_launch(&input, NOW);
        assert_eq!(ops(&commands), vec!["delete"]);
        assert!(matches!(commands[0].then[0].op, CommandOp::Retire));

        let killed = record_json(r#","hasPrompt":false,"killedByLimpidAt":"2026-09-15T11:00:00Z""#);
        let input = base("codex", true, killed, PidStatus::Dead);
        let commands = on_launch(&input, NOW);
        assert_eq!(ops(&commands), vec!["delete"]);
        assert!(matches!(commands[0].then[0].op, CommandOp::Retire));

        // One with a conversation, or one from before the field, is restored.
        for extra in [r#","hasPrompt":true"#, ""] {
            let mut input = base("claude", true, record_json(extra), PidStatus::Dead);
            input.resume_intents = vec![intent("2026-09-15T11:00:00Z")];
            assert_eq!(ops(&on_launch(&input, NOW)), vec!["update"], "{extra}");
        }
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
