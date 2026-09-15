//! File-level mechanics shared by every record the hook writes: the
//! `.flock` sidecar lock the Swift stores and the shell receivers use,
//! atomic replacement, user-only permissions, and the diagnostic log.

use limpid_agent_model::RunRecord;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

/// How many times a busy lock is retried, and how long between attempts.
/// Matches the shell receiver's `lockf` loop.
const LOCK_ATTEMPTS: u32 = 20;
const LOCK_RETRY: Duration = Duration::from_millis(10);

/// The `O_NOFOLLOW` flag, so a symlink planted at a lock or record path is
/// refused instead of followed.
#[cfg(target_os = "macos")]
const O_NOFOLLOW: i32 = 0x0100;
#[cfg(target_os = "linux")]
const O_NOFOLLOW: i32 = 0o400_000;
#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
const O_NOFOLLOW: i32 = 0;

/// Runs `body` while holding the exclusive advisory lock on `path`'s `.flock`
/// sidecar, retrying a busy lock as the shell did. Returns `None` when the
/// lock stayed busy or the sidecar could not be opened (a symlink planted
/// there, for example), in which case the event is dropped rather than
/// written out of order, as the shell receiver and the Swift store do. On
/// non-Unix hosts there is no lock and `body` runs directly.
pub fn with_record_lock<T>(path: &Path, body: impl FnOnce() -> T) -> Option<T> {
    let sidecar = PathBuf::from(format!("{}.flock", path.display()));
    if !cfg!(unix) {
        return Some(body());
    }
    let lock = open_lock_file(&sidecar)?;
    for attempt in 0..LOCK_ATTEMPTS {
        match try_lock(&lock) {
            Ok(()) => {
                let result = body();
                let _ = unlock(&lock);
                return Some(result);
            }
            Err(busy) if busy && attempt + 1 < LOCK_ATTEMPTS => thread::sleep(LOCK_RETRY),
            Err(_) => return None,
        }
    }
    None
}

#[cfg(unix)]
fn open_lock_file(sidecar: &Path) -> Option<File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW)
        .open(sidecar)
        .ok()
}

#[cfg(not(unix))]
fn open_lock_file(_sidecar: &Path) -> Option<File> {
    None
}

/// `Err(true)` means the lock is held by someone else; `Err(false)` means
/// locking failed for another reason.
fn try_lock(file: &File) -> Result<(), bool> {
    match file.try_lock() {
        Ok(()) => Ok(()),
        Err(std::fs::TryLockError::WouldBlock) => Err(true),
        Err(std::fs::TryLockError::Error(_)) => Err(false),
    }
}

fn unlock(file: &File) -> io::Result<()> {
    file.unlock()
}

/// Writes `bytes` to `path` through a user-only temporary file and an atomic
/// rename, so a reader never sees a partial record.
///
/// # Errors
///
/// Returns the I/O error from creating, writing, or renaming the temporary
/// file; the temporary file is removed on failure.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let directory = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = directory.join(format!(".{name}.tmp.{}", std::process::id()));
    let mut file = create_user_only(&temporary)?;
    let written = file.write_all(bytes).and_then(|()| file.sync_data());
    drop(file);
    match written.and_then(|()| fs::rename(&temporary, path)) {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = fs::remove_file(&temporary);
            Err(error)
        }
    }
}

#[cfg(unix)]
fn create_user_only(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW)
        .open(path)
}

#[cfg(not(unix))]
fn create_user_only(path: &Path) -> io::Result<File> {
    File::create(path)
}

/// Creates `directory` with user-only permissions, as the Swift stores do.
pub fn ensure_user_only_directory(directory: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        let _ = fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory);
    }
    #[cfg(not(unix))]
    {
        let _ = fs::create_dir_all(directory);
    }
}

/// Reads and decodes a record, tolerating all supported schema versions.
/// Anything unreadable counts as no record; the run then restarts at revision
/// one, which is what the shell receiver did when it could not read `revision`.
#[must_use]
pub fn read_record(path: &Path) -> Option<RunRecord> {
    let bytes = fs::read(path).ok()?;
    RunRecord::decode(&bytes).ok()
}

/// Reads at most `limit` bytes from the end of `path`. A transcript's title
/// lines are appended as the session goes on, so the tail is what matters.
#[must_use]
pub fn read_bounded_tail(path: &Path, limit: usize) -> Option<Vec<u8>> {
    let mut file = open_nonblocking(path)?;
    // Check the opened descriptor, not only `path`: another process may have
    // replaced the path after we opened it. In particular, a FIFO must never
    // be read as a transcript.
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() {
        return None;
    }
    let length = metadata.len();
    let limit_u64 = u64::try_from(limit).ok()?;
    if length > limit_u64 {
        file.seek(SeekFrom::Start(length - limit_u64)).ok()?;
    }
    let mut bytes = Vec::with_capacity(usize::try_from(length.min(limit_u64)).ok()?);
    // A writer may append after the seek. `take` keeps that race from making
    // the returned transcript exceed the caller's hard limit.
    file.take(limit_u64).read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

/// Opens a possible transcript without allowing a FIFO to wait for a writer.
/// Unix gives us `O_NONBLOCK`; other platforms first reject non-files before
/// opening because their standard library does not expose an equivalent flag.
#[cfg(unix)]
fn open_nonblocking(path: &Path) -> Option<File> {
    use std::os::unix::fs::OpenOptionsExt;

    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .ok()
}

#[cfg(not(unix))]
fn open_nonblocking(path: &Path) -> Option<File> {
    path.metadata()
        .ok()?
        .is_file()
        .then(|| File::open(path).ok())?
}

/// Copies one raw payload into the fixture recording directory, numbered by
/// the payloads already there; the event name comes from the payload.
pub fn record_raw_payload(record_dir: &Path, payload: &[u8]) {
    let parsed = serde_json::from_slice::<serde_json::Value>(payload).ok();
    let event = parsed
        .as_ref()
        .and_then(|value| {
            value
                .get("hook_event_name")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
        })
        .filter(|name| {
            name.bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
        })
        .unwrap_or_else(|| "unknown".to_owned());
    let count = fs::read_dir(record_dir).map_or(0, |entries| {
        entries
            .flatten()
            .filter(|entry| {
                let path = entry.path();
                let name = entry.file_name().to_string_lossy().into_owned();
                path.extension()
                    .is_some_and(|extension| extension == "json")
                    && name.len() > 5
                    && name.bytes().take(4).all(|byte| byte.is_ascii_digit())
            })
            .count()
    });
    let base = record_dir.join(format!("{count:04}-{event}"));
    // Payloads carry prompts and tool output, so they get the same
    // user-only mode as the records.
    let _ = write_user_only(&base.with_extension("json"), payload);
    // Claude's transcript keeps changing after the hook returns, so the
    // shell receiver copied it next to the payload; keep that for fixtures
    // recorded through this backend. Only a transcript file is copied.
    let transcript = parsed
        .as_ref()
        .and_then(|value| {
            value
                .get("transcript_path")
                .and_then(serde_json::Value::as_str)
                .map(PathBuf::from)
        })
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
                && path.is_file()
        });
    if let Some(bytes) = transcript.and_then(|path| fs::read(path).ok()) {
        let _ = write_user_only(&base.with_extension("transcript.jsonl"), &bytes);
    }
}

fn write_user_only(path: &Path, bytes: &[u8]) -> io::Result<()> {
    create_user_only(path)?.write_all(bytes)
}

/// Appends a worktree creation event for the Swift host to pick up. The
/// file name orders events by time and stays unique across concurrent hooks.
///
/// # Errors
///
/// Returns the I/O error from writing the event file.
pub fn write_worktree_event(
    state_directory: &Path,
    repo_root: &str,
    worktree_path: &str,
    branch: &str,
) -> io::Result<()> {
    let directory = state_directory.join("worktree-events");
    ensure_user_only_directory(&directory);
    let name = format!(
        "{}-{}-{}-create.json",
        limpid_agent_model::unix_seconds(std::time::SystemTime::now()),
        std::process::id(),
        uuid::Uuid::new_v4().simple()
    );
    let body = serde_json::json!({
        "schemaVersion": 1,
        "event": "WorktreeCreate",
        "repoRoot": repo_root,
        "worktreePath": worktree_path,
        "branch": branch,
    });
    atomic_write(&directory.join(name), body.to_string().as_bytes())
}

/// Whether the resume hint at `path` may be deleted by run `run_id` for
/// `session_id`: the stored session must match, and the hint must belong to
/// this run, or be a legacy hint without a run id while no other live run
/// record for the pane is newer than the hint.
#[must_use]
pub fn hint_is_owned(
    path: &Path,
    session_id: &str,
    run_id: &str,
    pane_id: &str,
    state_directory: &Path,
) -> bool {
    let Ok(bytes) = fs::read(path) else {
        return false;
    };
    let Ok(hint) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return false;
    };
    if hint.get("sessionId").and_then(serde_json::Value::as_str) != Some(session_id) {
        return false;
    }
    match hint.get("runId").and_then(serde_json::Value::as_str) {
        Some(owner) if owner == run_id => true,
        Some(_) => false,
        None => {
            let hint_updated = hint
                .get("updatedAt")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();
            !newer_run_record_exists(state_directory, pane_id, hint_updated)
        }
    }
}

/// Ambiguous ownership preserves data: a run-scoped record for the same pane
/// that is at least as new as the hint means the hint may be someone else's.
fn newer_run_record_exists(state_directory: &Path, pane_id: &str, hint_updated: &str) -> bool {
    let Ok(entries) = fs::read_dir(state_directory) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let path = entry.path();
        if path.extension().is_none_or(|extension| extension != "json") {
            return false;
        }
        let Some(record) = read_record(&path) else {
            return false;
        };
        record.pane_id == pane_id
            && record.run_id.as_deref().is_some_and(|run| run != pane_id)
            && record.updated_at.as_str() >= hint_updated
    })
}

/// One-line diagnostics appended to `LIMPID_HOOK_LOG` when it is set.
pub struct HookLog {
    path: Option<PathBuf>,
}

impl HookLog {
    #[must_use]
    pub fn from_env(env: &crate::HookEnv) -> Self {
        Self {
            path: env.log_path(),
        }
    }

    /// A log that drops every line, for callers without an environment.
    #[must_use]
    pub fn disabled() -> Self {
        Self { path: None }
    }

    /// Appends `message` with a timestamp; failures to log are ignored.
    pub fn line(&self, message: &str) {
        let Some(path) = &self.path else { return };
        if let Ok(mut file) = OpenOptions::new().append(true).create(true).open(path) {
            let _ = writeln!(
                file,
                "{} limpid-agent-hook: {message}",
                crate::format_utc_seconds(std::time::SystemTime::now())
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PANE: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10";
    const RUN: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11";
    const OTHER_RUN: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F12";

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "limpid-hook-records-{name}-{}",
                uuid::Uuid::new_v4()
            ));
            fs::create_dir_all(&root).expect("scratch");
            Self(root)
        }

        fn hint(&self, run_id: Option<&str>, updated_at: &str) -> PathBuf {
            let path = self.0.join(format!("{PANE}.json"));
            let run = run_id.map_or(String::new(), |run| format!(r#","runId":"{run}""#));
            fs::write(
                &path,
                format!(
                    r#"{{"schemaVersion":1,"paneId":"{PANE}","sessionId":"s-1","updatedAt":"{updated_at}"{run}}}"#
                ),
            )
            .expect("hint");
            path
        }

        fn record(&self, run_id: &str, updated_at: &str) {
            fs::write(
                self.0.join(format!("{run_id}.state.json")),
                format!(
                    r#"{{"schemaVersion":3,"paneId":"{PANE}","runId":"{run_id}","revision":1,"state":"running","updatedAt":"{updated_at}"}}"#
                ),
            )
            .expect("record");
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_hint_belongs_to_the_run_that_wrote_it() {
        let scratch = Scratch::new("owned");
        let hint = scratch.hint(Some(RUN), "2026-09-14T00:00:10Z");
        assert!(hint_is_owned(&hint, "s-1", RUN, PANE, &scratch.0));
        assert!(
            !hint_is_owned(&hint, "s-1", OTHER_RUN, PANE, &scratch.0),
            "another run may not delete it"
        );
        assert!(
            !hint_is_owned(&hint, "s-2", RUN, PANE, &scratch.0),
            "a different session is not this hint"
        );
    }

    #[test]
    fn a_legacy_hint_is_owned_unless_a_newer_run_record_exists() {
        let scratch = Scratch::new("legacy");
        let hint = scratch.hint(None, "2026-09-14T00:00:10Z");
        assert!(hint_is_owned(&hint, "s-1", RUN, PANE, &scratch.0));
        // A pane-scoped record from before run ids does not claim it.
        scratch.record(PANE, "2026-09-14T00:00:20Z");
        assert!(hint_is_owned(&hint, "s-1", RUN, PANE, &scratch.0));
        // An older run-scoped record does not claim it either.
        scratch.record(OTHER_RUN, "2026-09-14T00:00:05Z");
        assert!(hint_is_owned(&hint, "s-1", RUN, PANE, &scratch.0));
        // A run-scoped record at least as new as the hint may own it.
        scratch.record(OTHER_RUN, "2026-09-14T00:00:10Z");
        assert!(!hint_is_owned(&hint, "s-1", RUN, PANE, &scratch.0));
    }

    #[test]
    fn a_missing_or_malformed_hint_is_never_owned() {
        let scratch = Scratch::new("malformed");
        let path = scratch.0.join("missing.json");
        assert!(!hint_is_owned(&path, "s-1", RUN, PANE, &scratch.0));
        fs::write(&path, b"{").expect("write");
        assert!(!hint_is_owned(&path, "s-1", RUN, PANE, &scratch.0));
    }

    #[test]
    fn bounded_tail_reads_only_regular_files() {
        let scratch = Scratch::new("bounded-tail");
        let path = scratch.0.join("transcript.jsonl");
        fs::write(&path, b"0123456789").expect("write transcript");
        assert_eq!(read_bounded_tail(&path, 4), Some(b"6789".to_vec()));
        assert_eq!(read_bounded_tail(&scratch.0, 4), None);
    }

    #[cfg(unix)]
    #[test]
    fn bounded_tail_rejects_a_fifo_without_waiting_for_a_writer() {
        let scratch = Scratch::new("bounded-tail-fifo");
        let fifo = scratch.0.join("transcript.jsonl");
        let status = std::process::Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .expect("mkfifo starts");
        assert!(status.success(), "mkfifo succeeds");
        assert_eq!(read_bounded_tail(&fifo, 4), None);
    }
}
