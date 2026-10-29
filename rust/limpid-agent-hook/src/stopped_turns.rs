//! This module holds the writer that ends, on disk, a turn the person
//! stopped where no hook reports it (`end_stopped_turn`).
//!
//! Claude sends no hook when its question or permission prompt is declined
//! with Esc or "No", nor when its work is stopped with Esc or Ctrl+C, so the
//! record keeps saying the run waits or works until the next prompt or an
//! idle prompt, if one comes a minute later. A projection pass reads the
//! stop sooner, from the agent's own status report or from the transcript
//! the record names (`declined_waits`), shows the turn stopped on its badge,
//! and asks the app to write the end (`CommandOp::EndStoppedTurn`). The app
//! does that through `end_stopped_turn` off its main thread: the run record
//! ends as an interrupt ends it, and the turn ends `interrupted`, with its
//! end snapshot and difference taken as the hook takes them and what the
//! transcript says it used and ran. Until then only the badge says so, while
//! the Changes panel would show the turn running and a restore would refuse
//! the worktree as at work.

use crate::declined_waits::{is_transcript_path, reads_declined};
use crate::git::SnapshotRunner;
use crate::records::{HookLog, atomic_write};
use crate::{TranscriptFile, adapter_for, records, turn};
use limpid_agent_core::{end_stopped_turn as ended_record, turn_step};
use limpid_agent_model::{
    AgentEvent, EventId, ProviderId, RunRecord, RunState, TURNS_DIRECTORY, run_record_file_name,
};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// This is the turn a projection pass read as stopped, as the app hands it
/// to the writer (`CommandOp::EndStoppedTurn` and the command's target).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoppedTurnRequest {
    pub provider: ProviderId,
    /// This is the provider's state directory, where its run records are.
    pub state_directory: PathBuf,
    /// This is the record's storage id, its file name without the suffix.
    pub storage_id: String,
    pub episode_token: String,
    #[serde(default)]
    pub turn_id: Option<String>,
    pub transcript_path: String,
    /// The agent reported itself idle over OSC 7501 after the record last
    /// changed (`CommandOp::EndStoppedTurn::by_program_status`), so the
    /// transcript is not asked whether a wait was declined: it has no line
    /// that says so when the person chose "No" at the agent's prompt, nor
    /// when they stopped its work before its first response.
    #[serde(default)]
    pub by_program_status: bool,
}

/// This says what became of one request to end a stopped turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum StoppedTurnEnd {
    /// The run record now says the turn stopped. Its turn record says so
    /// too unless that write was skipped or failed, which is best effort
    /// and only logged.
    Ended,
    /// The record is not that turn as the pass read it any more: a prompt
    /// or another hook moved the run on, or the record is gone. Nothing was
    /// written, and nothing will be for this request.
    MovedOn,
    /// The request names no transcript path we accept, or the record still
    /// waits but its transcript no longer reads the wait declined or cannot
    /// be read. Nothing was written: a wait that cannot be judged stays a
    /// wait.
    NotDeclined,
    /// The record lock could not be taken, most often because it stayed
    /// busy while a hook wrote. Nothing was written.
    Busy,
    /// The request names no provider this build has or no record id, or
    /// the record could not be written.
    Failed,
}

/// Returns whether `record` is still the turn `request` names: the same run,
/// still at work or waiting inside a turn, in the same episode and turn, on
/// the same transcript. A prompt the person typed since gives a new episode
/// and a new turn, and so does a wait or work that followed, so a late write
/// is dropped.
fn is_the_turn(record: Option<&RunRecord>, request: &StoppedTurnRequest) -> bool {
    record.is_some_and(|record| {
        matches!(
            record.state,
            RunState::NeedsInput | RunState::Running | RunState::Compacting
        ) && record.run_started_at.is_some()
            && record.state_episode_token.as_deref() == Some(request.episode_token.as_str())
            && record.current_turn_id == request.turn_id
            && record.transcript_path.as_deref() == Some(request.transcript_path.as_str())
    })
}

/// Returns whether `value` is a storage id as the writer spells it: an
/// upper-case hyphenated UUID, so it names no file outside the state
/// directory.
fn is_storage_id(value: &str) -> bool {
    uuid::Uuid::parse_str(value)
        .is_ok_and(|uuid| uuid.hyphenated().to_string().to_uppercase() == value)
}

/// Ends the turn `request` names, which the person stopped and no hook
/// reported, at `now`: the run record as `lifecycle::end_stopped_turn` has
/// it, and the turn `interrupted`, as an interrupt ends it, with what its
/// transcript says it used and ran.
///
/// The end snapshot runs git, and the transcript may still be taking the
/// turn's last response, so both are taken before the record lock from the
/// record as it stood then, as the hook takes a turn's end (`write_events`).
/// Under the lock the record is read again, and the write goes ahead only if
/// it is still the same turn (`is_the_turn`) and, unless the agent's own
/// status report is what said so, its transcript still reads the wait
/// declined; anything else drops it whole, the snapshot with it. The prompt
/// the person types next takes the same lock, so either its write comes
/// first and this one finds a new episode, or this one comes first and the
/// prompt begins its turn after it.
#[must_use]
pub fn end_stopped_turn(
    request: &StoppedTurnRequest,
    snapshots: &dyn SnapshotRunner,
    now: &str,
    log: &HookLog,
) -> StoppedTurnEnd {
    let Some(adapter) = adapter_for(request.provider.as_str()) else {
        return StoppedTurnEnd::Failed;
    };
    if !is_storage_id(&request.storage_id) {
        return StoppedTurnEnd::Failed;
    }
    let transcript = Path::new(&request.transcript_path);
    if !is_transcript_path(transcript) {
        return StoppedTurnEnd::NotDeclined;
    }
    let record_path = request
        .state_directory
        .join(run_record_file_name(&request.storage_id));
    let before = records::read_record(&record_path);
    let Some(stopped) = before
        .as_ref()
        .filter(|record| is_the_turn(Some(record), request))
    else {
        return StoppedTurnEnd::MovedOn;
    };
    if !request.by_program_status && !reads_declined(adapter, transcript) {
        return StoppedTurnEnd::NotDeclined;
    }
    let descriptor = adapter.descriptor();
    // No hook call brought the transcript, so we read the file the record
    // names, as a hook's turn end reads its own.
    let file = TranscriptFile {
        adapter,
        path: transcript,
        state: &request.state_directory,
    };
    let turns = turn::Turns {
        directory: request.state_directory.join(TURNS_DIRECTORY),
        descriptor,
        run_id: stopped.run_id.as_deref().unwrap_or(&request.storage_id),
        pane_id: &stopped.pane_id,
        now,
        log,
        transcript: Some(&file),
    };
    // The turn ends as an interrupt ends it, which is what the person did;
    // a provider that records no turns takes no step.
    let interrupted = AgentEvent::Interrupted;
    let prepared = turn_step(&interrupted, descriptor, before.as_ref(), now).map(|step| {
        turns.prepare(
            step,
            &interrupted,
            Some(EventId::stopped_turn(
                &request.provider,
                &request.episode_token,
            )),
            before.as_ref(),
            snapshots,
            None,
        )
    });
    let outcome = records::with_record_lock(&record_path, || {
        let previous = records::read_record(&record_path);
        if !is_the_turn(previous.as_ref(), request) {
            log.line("stopped turn not ended: the run moved on");
            return (StoppedTurnEnd::MovedOn, None);
        }
        // We read the transcript again under the lock, as we did the record:
        // what the person did at the prompt is in the transcript, not in the
        // record. The agent's own report was read once by the pass, and the
        // record check above is what stops a late write.
        if !request.by_program_status && !reads_declined(adapter, transcript) {
            return (StoppedTurnEnd::NotDeclined, None);
        }
        let Some(mut next) = previous
            .as_ref()
            .and_then(|record| ended_record(record, now))
        else {
            return (StoppedTurnEnd::MovedOn, None);
        };
        let pin = prepared
            .and_then(|prepared| turns.commit(prepared, previous.as_ref(), Some(&mut next)));
        let written = next
            .encode()
            .map_err(|error| error.to_string())
            .and_then(|bytes| {
                atomic_write(&record_path, &bytes).map_err(|error| error.to_string())
            });
        match written {
            Ok(()) => (StoppedTurnEnd::Ended, pin),
            Err(error) => {
                log.line(&format!("write {}: {error}", record_path.display()));
                (StoppedTurnEnd::Failed, None)
            }
        }
    });
    let Some((outcome, pin)) = outcome else {
        log.line(&format!("record lock busy for {}", record_path.display()));
        return StoppedTurnEnd::Busy;
    };
    if let Some(pin) = &pin {
        turns.pin(pin, snapshots);
    }
    outcome
}
