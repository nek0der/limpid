//! This module tells the app's projection passes whether a waiting run's
//! provider transcript shows the person declined the call it waits on.
//!
//! Claude sends no hook when its question or permission prompt is declined
//! with Esc, so the wait stays in the record until the next prompt or until
//! a later idle prompt that finds the awaited call ended in the transcript.
//! The transcript the record names (`RunRecord::transcript_path`) says
//! otherwise sooner, and the projection asks here on every pass for each run
//! that waits inside a turn and whose agent has not said it is idle again.
//! Passes come often, so while every pass asks about a transcript, it is
//! read again only when its size or modification time changed; an unchanged
//! file costs one `stat`. A pass that does not ask forgets it, and the next
//! one that asks reads it again (`DeclinedWaits::end_pass`). The adapter
//! decides what the bytes mean
//! (`ProviderAdapter::transcript_shows_wait_declined`), so no provider is
//! named here. A pass that finds a wait declined asks the app to end its
//! turn (`stopped_turns`).

use crate::{MAX_TRANSCRIPT_BYTES, adapter_for, records};
use limpid_agent_model::{ProviderAdapter, ProviderId};
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
pub(crate) fn is_transcript_path(path: &Path) -> bool {
    path.is_absolute()
        && path
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
}

/// Reads the transcript's tail and asks the adapter about it.
pub(crate) fn reads_declined(adapter: &dyn ProviderAdapter, path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
        && records::read_bounded_tail(path, MAX_TRANSCRIPT_BYTES)
            .is_some_and(|tail| adapter.transcript_shows_wait_declined(&tail))
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
