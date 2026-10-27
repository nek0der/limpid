//! This module tells the app's projection passes whether a waiting run's
//! provider transcript shows the person declined the call it waits on, and
//! holds the writer that then ends the wait on disk (`end_declined_wait`).
//!
//! Claude sends no hook when its question or permission prompt is declined
//! with Esc, so the wait stays in the record until the next prompt or until
//! a later idle prompt that finds the awaited call ended in the transcript.
//! The transcript the wait's own hook named (`RunRecord::transcript_path`)
//! says otherwise sooner, and the projection asks here on every pass for
//! each run that waits inside a turn. Passes come often, so while every pass
//! asks about a transcript, it is read again only when its size or
//! modification time changed; an unchanged file costs one `stat`. A pass
//! that does not ask forgets it, and the next one that asks reads it again
//! (`DeclinedWaits::end_pass`). The adapter decides what the bytes mean
//! (`ProviderAdapter::transcript_shows_wait_declined`), so no provider is
//! named here.
//!
//! A pass that finds a wait declined asks the app to write its end
//! (`CommandOp::EndDeclinedWait`), which the app does through
//! `end_declined_wait` off its main thread: the run record ends as an
//! interrupt ends it and the turn ends `interrupted`, with its end snapshot
//! and difference taken as the hook takes them. Until then only the badge
//! says so, while the Changes panel would show the turn running and a
//! restore would refuse the worktree as at work.

use crate::git::SnapshotRunner;
use crate::records::{HookLog, atomic_write};
use crate::{MAX_TRANSCRIPT_BYTES, adapter_for, records, turn};
use limpid_agent_core::{end_declined_wait as ended_record, turn_step};
use limpid_agent_model::{
    AgentEvent, EventId, ProviderAdapter, ProviderId, RunRecord, RunState, TURNS_DIRECTORY,
    run_record_file_name,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// This is what one transcript last read as, with the size and modification
/// time of the file it was read from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Reading {
    length: u64,
    modified: Option<SystemTime>,
    is_declined: bool,
}

/// These are the transcripts the passes have asked about, which the
/// projection engine holds between passes.
#[derive(Debug, Default)]
pub struct DeclinedWaits {
    readings: BTreeMap<(ProviderId, PathBuf), Reading>,
    /// These are the transcripts asked about since the last `end_pass`, the
    /// ones the next `end_pass` keeps.
    asked: Vec<(ProviderId, PathBuf)>,
    /// This counts how many times a transcript was read, for the tests that
    /// check an unchanged one is not read again.
    reads: u64,
}

impl DeclinedWaits {
    /// Returns whether the transcript at `path` shows that the person
    /// declined the call a run of `provider` waits on. It is `false` for a
    /// path that is not a transcript, a file that is missing or not a regular
    /// file, and one that is read and cannot be judged: a wait that cannot be
    /// judged stays a wait, since ending a live question would hide it from
    /// the person. While the size and modification time stay the same, we
    /// return the last answer without reading the file again.
    pub fn is_declined(&mut self, provider: &ProviderId, path: &str) -> bool {
        let Some(adapter) = adapter_for(provider.as_str()) else {
            return false;
        };
        let path = Path::new(path);
        if !is_transcript_path(path) {
            return false;
        }
        let key = (provider.clone(), path.to_path_buf());
        self.asked.push(key.clone());
        let Ok(metadata) = std::fs::metadata(path) else {
            self.readings.remove(&key);
            return false;
        };
        if !metadata.is_file() {
            self.readings.remove(&key);
            return false;
        }
        let length = metadata.len();
        let modified = metadata.modified().ok();
        if let Some(reading) = self.readings.get(&key)
            && reading.length == length
            && reading.modified == modified
        {
            return reading.is_declined;
        }
        self.reads += 1;
        let is_declined = reads_declined(adapter, path);
        self.readings.insert(
            key,
            Reading {
                length,
                modified,
                is_declined,
            },
        );
        is_declined
    }

    /// Forgets every transcript the pass just made did not ask about. Its
    /// run moved on, so the next wait reads its file afresh.
    pub fn end_pass(&mut self) {
        let asked = std::mem::take(&mut self.asked);
        self.readings.retain(|key, _| asked.contains(key));
    }

    /// Returns how many times a transcript was read since this was made.
    #[must_use]
    pub fn reads(&self) -> u64 {
        self.reads
    }
}

/// Returns whether `path` is taken as the transcript a hook names. The record
/// is the hook's, under the person's own data folder, but a path is still
/// only taken as an absolute `.jsonl` file, never a FIFO or a directory
/// (which `reads_declined` refuses as not a regular file).
fn is_transcript_path(path: &Path) -> bool {
    path.is_absolute()
        && path
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
}

/// Reads the transcript's tail and asks the adapter about it.
fn reads_declined(adapter: &dyn ProviderAdapter, path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
        && records::read_bounded_tail(path, MAX_TRANSCRIPT_BYTES)
            .is_some_and(|tail| adapter.transcript_shows_wait_declined(&tail))
}

/// This is the wait a projection pass read as declined, as the app hands it
/// to the writer (`CommandOp::EndDeclinedWait` and the command's target).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeclinedWaitRequest {
    pub provider: ProviderId,
    /// This is the provider's state directory, where its run records are.
    pub state_directory: PathBuf,
    /// This is the record's storage id, its file name without the suffix.
    pub storage_id: String,
    pub episode_token: String,
    #[serde(default)]
    pub turn_id: Option<String>,
    pub transcript_path: String,
    /// The agent reported itself idle over OSC 7501 after the wait began
    /// (`CommandOp::EndDeclinedWait::by_program_status`), so the transcript
    /// is not asked: it has no line that reads declined when the person
    /// chose "No" at the agent's prompt.
    #[serde(default)]
    pub by_program_status: bool,
}

/// This says what became of one request to end a declined wait.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DeclinedWaitEnd {
    /// The run record now says the turn stopped. Its turn record says so
    /// too unless that write was skipped or failed, which is best effort
    /// and only logged.
    Ended,
    /// The record is not that wait any more: a prompt or another hook moved
    /// the run on, or the record is gone. Nothing was written, and nothing
    /// will be for this wait.
    MovedOn,
    /// The request names no transcript path we accept, or the record is
    /// still the wait but its transcript no longer reads declined or cannot
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

/// Returns whether `record` is still the wait `request` names: the same run,
/// still waiting inside a turn, in the same episode and turn, on the same
/// transcript. A prompt the person typed since gives a new episode and a new
/// turn, so a late write is dropped.
fn is_the_wait(record: Option<&RunRecord>, request: &DeclinedWaitRequest) -> bool {
    record.is_some_and(|record| {
        record.state == RunState::NeedsInput
            && record.run_started_at.is_some()
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

/// Ends the wait `request` names, which the person declined at the agent's
/// own prompt and no hook reported, at `now`: the run record as
/// `lifecycle::end_declined_wait` has it, and the turn `interrupted`, as an
/// interrupt ends it.
///
/// The end snapshot runs git, so it is taken before the record lock from
/// the record as it stood then, as the hook takes a turn's end
/// (`write_events`). Under the lock the record is read again, and the write
/// goes ahead only if it is still the same wait (`is_the_wait`) and, unless
/// the agent's own status report is what said so, its transcript still reads
/// declined; anything else drops it whole, the snapshot with it. The prompt
/// the person types next takes the same lock, so either its write comes first
/// and this one finds a new episode, or this one comes first and the prompt
/// begins its turn after it.
#[must_use]
pub fn end_declined_wait(
    request: &DeclinedWaitRequest,
    snapshots: &dyn SnapshotRunner,
    now: &str,
    log: &HookLog,
) -> DeclinedWaitEnd {
    let Some(adapter) = adapter_for(request.provider.as_str()) else {
        return DeclinedWaitEnd::Failed;
    };
    if !is_storage_id(&request.storage_id) {
        return DeclinedWaitEnd::Failed;
    }
    let transcript = Path::new(&request.transcript_path);
    if !is_transcript_path(transcript) {
        return DeclinedWaitEnd::NotDeclined;
    }
    let record_path = request
        .state_directory
        .join(run_record_file_name(&request.storage_id));
    let before = records::read_record(&record_path);
    let Some(waiting) = before
        .as_ref()
        .filter(|record| is_the_wait(Some(record), request))
    else {
        return DeclinedWaitEnd::MovedOn;
    };
    if !request.by_program_status && !reads_declined(adapter, transcript) {
        return DeclinedWaitEnd::NotDeclined;
    }
    let descriptor = adapter.descriptor();
    let turns = turn::Turns {
        directory: request.state_directory.join(TURNS_DIRECTORY),
        descriptor,
        run_id: waiting.run_id.as_deref().unwrap_or(&request.storage_id),
        pane_id: &waiting.pane_id,
        now,
        log,
        // The app ends the wait; no hook call brought a transcript.
        transcript: None,
    };
    // The turn ends as an interrupt ends it, which is what the person did;
    // a provider that records no turns takes no step.
    let interrupted = AgentEvent::Interrupted;
    let prepared = turn_step(&interrupted, descriptor, before.as_ref(), now).map(|step| {
        turns.prepare(
            step,
            &interrupted,
            Some(EventId::declined_wait(
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
        if !is_the_wait(previous.as_ref(), request) {
            log.line("declined wait not ended: the run moved on");
            return (DeclinedWaitEnd::MovedOn, None);
        }
        // We read the transcript again under the lock, as we did the record:
        // what the person did at the prompt is in the transcript, not in the
        // record. The agent's own report was read once by the pass, and the
        // record check above is what stops a late write.
        if !request.by_program_status && !reads_declined(adapter, transcript) {
            return (DeclinedWaitEnd::NotDeclined, None);
        }
        let Some(mut next) = previous
            .as_ref()
            .and_then(|record| ended_record(record, now))
        else {
            return (DeclinedWaitEnd::MovedOn, None);
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
            Ok(()) => (DeclinedWaitEnd::Ended, pin),
            Err(error) => {
                log.line(&format!("write {}: {error}", record_path.display()));
                (DeclinedWaitEnd::Failed, None)
            }
        }
    });
    let Some((outcome, pin)) = outcome else {
        log.line(&format!("record lock busy for {}", record_path.display()));
        return DeclinedWaitEnd::Busy;
    };
    if let Some(pin) = &pin {
        turns.pin(pin, snapshots);
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    const DECLINED: &[u8] =
        include_bytes!("../../fixtures/transcripts/claude-2.1.309-question-declined.jsonl");
    const OPEN: &[u8] =
        include_bytes!("../../fixtures/transcripts/claude-2.1.309-question-open.jsonl");

    fn claude() -> ProviderId {
        ProviderId::new(limpid_provider_claude::PROVIDER_ID).expect("id")
    }

    fn codex() -> ProviderId {
        ProviderId::new(limpid_provider_codex::PROVIDER_ID).expect("id")
    }

    fn path_text(path: &Path) -> String {
        path.to_str().expect("utf8").to_owned()
    }

    #[test]
    fn a_question_still_up_waits_and_reads_declined_once_the_person_declines_it() {
        let directory = tempfile::tempdir().expect("dir");
        let path = directory.path().join("session.jsonl");
        std::fs::write(&path, OPEN).expect("write");
        let mut waits = DeclinedWaits::default();
        assert!(!waits.is_declined(&claude(), &path_text(&path)));
        waits.end_pass();

        // Claude appends the result, the interrupt, and what follows.
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("open");
        file.write_all(&DECLINED[OPEN.len()..]).expect("append");
        drop(file);
        assert!(waits.is_declined(&claude(), &path_text(&path)));
        assert_eq!(waits.reads(), 2);
    }

    #[test]
    fn an_unchanged_transcript_is_not_read_again() {
        let directory = tempfile::tempdir().expect("dir");
        let path = directory.path().join("session.jsonl");
        std::fs::write(&path, DECLINED).expect("write");
        let mut waits = DeclinedWaits::default();
        for _ in 0..5 {
            assert!(waits.is_declined(&claude(), &path_text(&path)));
            waits.end_pass();
        }
        assert_eq!(waits.reads(), 1);

        // A pass that no longer asks forgets it, so a later wait reads it.
        waits.end_pass();
        assert!(waits.is_declined(&claude(), &path_text(&path)));
        assert_eq!(waits.reads(), 2);
    }

    #[test]
    fn what_cannot_be_read_as_a_transcript_keeps_the_wait() {
        let directory = tempfile::tempdir().expect("dir");
        let mut waits = DeclinedWaits::default();
        let missing = directory.path().join("missing.jsonl");
        assert!(!waits.is_declined(&claude(), &path_text(&missing)));
        let named_otherwise = directory.path().join("session.txt");
        std::fs::write(&named_otherwise, DECLINED).expect("write");
        assert!(!waits.is_declined(&claude(), &path_text(&named_otherwise)));
        let folder = directory.path().join("folder.jsonl");
        std::fs::create_dir(&folder).expect("dir");
        assert!(!waits.is_declined(&claude(), &path_text(&folder)));
        assert!(!waits.is_declined(&claude(), "relative/session.jsonl"));
        assert_eq!(waits.reads(), 0);
        // A provider that reads no wait from its transcript says nothing,
        // and neither does one this build does not have.
        let path = directory.path().join("session.jsonl");
        std::fs::write(&path, DECLINED).expect("write");
        assert!(!waits.is_declined(&codex(), &path_text(&path)));
        assert!(!waits.is_declined(&ProviderId::new("other").expect("id"), &path_text(&path)));
        assert!(waits.is_declined(&claude(), &path_text(&path)));
    }
}
