//! The C ABI for restoring a worktree to the start of a turn
//! and for discarding review hunks: the restore, the discard, the undo
//! of either, and the recovery of operations a crash cut short.
//! Every call runs git and may wait up to two seconds for the worktree lock,
//! so the caller keeps it off the main thread. The work lives in the hook
//! runtime (`limpid_agent_hook::restore`), beside the lock the hooks take.

use crate::turns::{
    TURN_INTERNAL, TURN_INVALID_INPUT, TURN_UNREADABLE, call_with_output, input_bytes,
};
use limpid_agent_hook::format_utc_seconds;
use limpid_agent_hook::restore::{
    DiscardRequest, RestoreRequest, UndoRequest, discard_hunks, recover, restore_turn, undo_restore,
};
use serde::Serialize;
use std::path::Path;
use std::time::SystemTime;

/// Restores a worktree to the start of a turn. `request` is JSON:
/// `{"root":…,"turnId":…,"paneId":…,"stateDirectories":[{"provider":…,"directory":…}]}`.
/// The body is `{"outcome":"refused","refusal":{"kind":…}}` or
/// `{"outcome":"finished","journal":{…}}`, the journal's stage saying how it
/// ended.
///
/// # Safety
///
/// The input pointer must be readable for its length (or null with length
/// zero), and the output pointers must be writable. On `LIMPID_TURN_OK` the
/// caller owns the body and frees it with `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_restore_turn_v1(
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    // SAFETY: Passed through under the caller's guarantees.
    unsafe {
        call(request, request_len, out, out_len, |bytes| {
            let request: RestoreRequest =
                serde_json::from_slice(bytes).map_err(|_| TURN_INVALID_INPUT)?;
            encode(&restore_turn(&request, &now()))
        })
    }
}

/// Undoes a restore. `request` is JSON:
/// `{"root":…,"opId":…,"stateDirectories":[…]}`. The body is as for
/// `limpid_restore_turn_v1`, the journal being the undo's own.
///
/// # Safety
///
/// As for `limpid_restore_turn_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_restore_undo_v1(
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    // SAFETY: Passed through under the caller's guarantees.
    unsafe {
        call(request, request_len, out, out_len, |bytes| {
            let request: UndoRequest =
                serde_json::from_slice(bytes).map_err(|_| TURN_INVALID_INPUT)?;
            encode(&undo_restore(&request, &now()))
        })
    }
}

/// Discards hunks the review showed. `request` is JSON:
/// `{"root":…,"fromTree":…,"toTree":…,"turnId":…,"turnNumber":…,"paneId":…,
/// "files":[{"path":…,"hunks":["@@ … @@",…]}],"stateDirectories":[…]}`,
/// the trees being the ones the review diffed. The body is
/// `{"outcome":"refused","refusal":{…}}` or
/// `{"outcome":"finished","journal":{…}|null,"hunks":[{"path","header","result"}]}`;
/// the journal's undo is `limpid_restore_undo_v1`.
///
/// # Safety
///
/// As for `limpid_restore_turn_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_discard_hunks_v1(
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    // SAFETY: Passed through under the caller's guarantees.
    unsafe {
        call(request, request_len, out, out_len, |bytes| {
            let request: DiscardRequest =
                serde_json::from_slice(bytes).map_err(|_| TURN_INVALID_INPUT)?;
            encode(&discard_hunks(&request, &now()))
        })
    }
}

/// Settles the restores of the worktree at `root` (UTF-8) that a crash cut
/// short, and drops the journals past their lifetime. The body is
/// `{"journals":[…],"settled":[…],"isIncomplete":…}`: every journal of the
/// worktree that could be read, oldest first, the operations this call
/// settled, and whether some journals are there but could not be read.
/// Those keep no other from being settled or dropped, and stay as they are;
/// when the list is incomplete the caller keeps what it knew of the rest
/// rather than read them as gone. Called at launch and before showing a
/// worktree's records. `LIMPID_TURN_UNREADABLE`, with no body, when git
/// could not say where the journals are: nothing was read or settled. A
/// folder that is no worktree of a repository has none, and is
/// `LIMPID_TURN_OK`.
///
/// # Safety
///
/// As for `limpid_restore_turn_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_restore_recover_v1(
    root: *const u8,
    root_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    // SAFETY: Passed through under the caller's guarantees.
    unsafe {
        call(root, root_len, out, out_len, |bytes| {
            let root = std::str::from_utf8(bytes).map_err(|_| TURN_INVALID_INPUT)?;
            if root.is_empty() {
                return Err(TURN_INVALID_INPUT);
            }
            let recovery = recover(Path::new(root), &now()).map_err(|_| TURN_UNREADABLE)?;
            encode(&recovery)
        })
    }
}

fn now() -> String {
    format_utc_seconds(SystemTime::now())
}

fn encode(value: &impl Serialize) -> Result<Vec<u8>, i32> {
    serde_json::to_vec(value).map_err(|_| TURN_INTERNAL)
}

/// This is the frame every restore call shares: the turn calls' output frame,
/// with the one input read inside it, after the output is checked.
unsafe fn call(
    input: *const u8,
    input_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    body: impl FnOnce(&[u8]) -> Result<Vec<u8>, i32>,
) -> i32 {
    let read_and_run = || {
        // SAFETY: The caller guarantees the input region is readable.
        let input = unsafe { input_bytes(input, input_len) }?;
        body(input)
    };
    // SAFETY: We pass the pointers on under the caller's guarantees.
    unsafe { call_with_output(out, out_len, read_and_run) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::take_bytes;
    use crate::turns::{TURN_NULL_POINTER, TURN_OK};
    use serde_json::Value;
    use std::ptr;

    type Entry = unsafe extern "C" fn(*const u8, usize, *mut *mut u8, *mut usize) -> i32;

    fn run(entry: Entry, input: &[u8]) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len: usize = 99;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe { entry(input.as_ptr(), input.len(), &raw mut out, &raw mut out_len) };
        // SAFETY: The pair is what this call wrote.
        let body = unsafe { take_bytes(out, out_len) };
        (
            status,
            body.and_then(|body| serde_json::from_slice(&body).ok()),
        )
    }

    #[test]
    fn a_restore_outside_a_repository_is_refused_with_its_reason() {
        let root_scratch = tempfile::tempdir().expect("scratch");
        let root = root_scratch.path().to_path_buf();
        let request = serde_json::json!({
            "root": root,
            "turnId": "4C1E8F7A-0000-4000-8000-000000000001",
            "paneId": "P",
            "stateDirectories": [],
        });
        let (status, body) = run(limpid_restore_turn_v1, request.to_string().as_bytes());
        assert_eq!(status, TURN_OK);
        assert_eq!(
            body,
            Some(serde_json::json!({"outcome": "refused", "refusal": {"kind": "notARepository"}}))
        );
        let (status, body) = run(limpid_restore_recover_v1, root.to_str().unwrap().as_bytes());
        assert_eq!(
            (status, body),
            (
                TURN_OK,
                Some(serde_json::json!({"journals": [], "settled": [], "isIncomplete": false}))
            )
        );
    }

    /// Journals that are there but cannot be read are no plain empty list:
    /// the body says it is incomplete, or the app would read the worktree
    /// as having no operation, and drop the record and the Undo of one it
    /// has.
    #[cfg(unix)]
    #[test]
    fn journals_that_cannot_be_read_are_an_incomplete_list_not_none() {
        use std::os::unix::fs::PermissionsExt;
        let scratch = tempfile::tempdir().expect("scratch");
        let root = scratch.path().join("repo");
        std::fs::create_dir(&root).unwrap();
        let initialized = std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(&root)
            .status()
            .unwrap();
        assert!(initialized.success());
        let journals = root
            .join(".git/limpid")
            .join(limpid_agent_model::RESTORE_DIRECTORY);
        std::fs::create_dir_all(&journals).unwrap();
        let input = root.to_str().unwrap().as_bytes().to_vec();
        assert_eq!(
            run(limpid_restore_recover_v1, &input),
            (
                TURN_OK,
                Some(serde_json::json!({"journals": [], "settled": [], "isIncomplete": false}))
            )
        );

        std::fs::set_permissions(&journals, std::fs::Permissions::from_mode(0o000)).unwrap();
        let unreadable = run(limpid_restore_recover_v1, &input);
        std::fs::set_permissions(&journals, std::fs::Permissions::from_mode(0o700)).unwrap();

        assert_eq!(
            unreadable,
            (
                TURN_OK,
                Some(serde_json::json!({"journals": [], "settled": [], "isIncomplete": true}))
            )
        );
    }

    #[test]
    fn input_that_is_not_a_request_is_refused() {
        assert_eq!(
            run(limpid_restore_turn_v1, b"[]"),
            (TURN_INVALID_INPUT, None)
        );
        assert_eq!(
            run(limpid_restore_undo_v1, b"{}"),
            (TURN_INVALID_INPUT, None)
        );
        assert_eq!(
            run(limpid_restore_recover_v1, b""),
            (TURN_INVALID_INPUT, None)
        );
    }

    #[test]
    fn a_missing_output_pointer_is_refused_before_anything_runs() {
        // SAFETY: The input pointer is a live local; the output ones are
        // null on purpose.
        let status = unsafe {
            limpid_restore_recover_v1(b"/tmp".as_ptr(), 4, ptr::null_mut(), ptr::null_mut())
        };
        assert_eq!(status, TURN_NULL_POINTER);
    }
}
