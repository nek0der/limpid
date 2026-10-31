//! This is the C ABI for the app's work on turns: deleting the ones the
//! retention sweep chose (`weir_turn_gc_apply_v1`), and ending a turn the
//! person stopped where no hook reports it (`weir_stopped_turn_end_v1`).
//! The git and file work lives in the hook runtime, beside the code that
//! writes what it removes or ends, so the side that pins a turn's trees and
//! the side that unpins them agree on the names, and a stopped turn ends as
//! the hook would end it.

use crate::frame::{self, FrameCodes, call_with_codes};
use serde::Serialize;
use std::path::Path;
use weir_agent_hook::{
    GitSnapshots, HookLog, StoppedTurnRequest, delete_turns, end_stopped_turn, format_utc_seconds,
};

/// Largest input one call accepts: a batch of turn ids and a path.
const MAX_TURN_INPUT_BYTES: usize = 1024 * 1024;

/// Status codes returned by the turn ABI functions, reported as `int32_t`
/// for the same reason as `weir_provider_result`.
#[repr(C)]
#[allow(non_camel_case_types)]
pub enum weir_turn_result {
    /// The call ran and the output buffer holds its body: what became of
    /// each turn, a restore's, undo's, or discard's outcome (a refusal
    /// among them), a recovery, or what became of a stopped turn.
    WEIR_TURN_OK = 0,
    /// A required pointer was null.
    WEIR_TURN_NULL_POINTER = 1,
    /// The input exceeded the limit.
    WEIR_TURN_INPUT_TOO_LARGE = 2,
    /// The input was not UTF-8 or not the JSON shape the call expects.
    WEIR_TURN_INVALID_INPUT = 3,
    /// The result could not be serialized.
    WEIR_TURN_INTERNAL = 4,
    /// Rust caught a panic at the FFI boundary.
    WEIR_TURN_PANIC = 5,
    /// Git could not be asked what the call needs to read (where a
    /// worktree's journals are). No body is returned in its place, as an
    /// empty one would read as nothing there.
    WEIR_TURN_UNREADABLE = 6,
}

pub(crate) const TURN_OK: i32 = weir_turn_result::WEIR_TURN_OK as i32;
pub(crate) const TURN_NULL_POINTER: i32 = weir_turn_result::WEIR_TURN_NULL_POINTER as i32;
const TURN_INPUT_TOO_LARGE: i32 = weir_turn_result::WEIR_TURN_INPUT_TOO_LARGE as i32;
pub(crate) const TURN_INVALID_INPUT: i32 = weir_turn_result::WEIR_TURN_INVALID_INPUT as i32;
pub(crate) const TURN_INTERNAL: i32 = weir_turn_result::WEIR_TURN_INTERNAL as i32;
pub(crate) const TURN_PANIC: i32 = weir_turn_result::WEIR_TURN_PANIC as i32;
pub(crate) const TURN_UNREADABLE: i32 = weir_turn_result::WEIR_TURN_UNREADABLE as i32;

/// Deletes turns from one provider's turns directory: each turn's record and
/// the refs that pin its snapshots, together, after finishing any deletion
/// an earlier call left cut short. `directory` is the directory's path in
/// UTF-8; `turn_ids` is a JSON array of turn ids. The body is a JSON array:
/// one entry per requested id, in order, followed by one for each turn an
/// earlier interrupted call left that this call finished and the input did
/// not name, so the body can be longer than the input and an empty input
/// can yield entries. Consumers match entries by `turnId`, not by position.
/// Each is `{"outcome":"deleted","turnId":...}`, `deletedLeavingRefs` with
/// the `roots` that could not be reached, `alreadyGone`, `unreadable`, or
/// `failed` with a `reason`.
///
/// Runs git, so the caller keeps it off the main thread.
///
/// # Safety
///
/// Each input pointer must be readable for its length (or null with length
/// zero), and the output pointers must be writable. On `WEIR_TURN_OK` the
/// caller owns the body and frees it with `weir_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_turn_gc_apply_v1(
    directory: *const u8,
    directory_len: usize,
    turn_ids: *const u8,
    turn_ids_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    // Only `call_with_output` runs this, after it has checked the output.
    let body = || {
        // SAFETY: The caller guarantees the input regions are readable.
        let directory = unsafe { input_bytes(directory, directory_len) }?;
        let directory = std::str::from_utf8(directory).map_err(|_| TURN_INVALID_INPUT)?;
        if directory.is_empty() {
            return Err(TURN_INVALID_INPUT);
        }
        // SAFETY: As above.
        let turn_ids = unsafe { input_bytes(turn_ids, turn_ids_len) }?;
        let turn_ids: Vec<String> =
            serde_json::from_slice(turn_ids).map_err(|_| TURN_INVALID_INPUT)?;
        let outcome = delete_turns(Path::new(directory), &turn_ids, &GitSnapshots);
        serde_json::to_vec(&outcome).map_err(|_| TURN_INTERNAL)
    };
    // SAFETY: We pass the pointers on under the caller's guarantees.
    unsafe { call_with_output(out, out_len, body) }
}

/// This is what `weir_stopped_turn_end_v1` answers.
#[derive(Serialize)]
struct StoppedTurnAnswer {
    outcome: weir_agent_hook::StoppedTurnEnd,
}

/// Ends a turn a projection pass read as stopped by the person
/// (`endStoppedTurn`): under the run record's lock, if the record is still
/// that turn and, unless the agent's own status report said so, its
/// transcript still reads the wait declined, we end its turn `interrupted`
/// with its end snapshot and what its transcript says it used, and then end
/// the record as an interrupt ends it (`weir_agent_hook::end_stopped_turn`).
/// `request` is a JSON object: `provider`, `stateDirectory`, `storageId`,
/// `episodeToken`, `transcriptPath`, `byProgramStatus`, and `turnId` when the
/// record names one. The body is
/// `{"outcome":"ended"}` once the record is written, even if the turn's write
/// was skipped or failed. It is `movedOn`, `notDeclined`, or `busy` when
/// nothing was written, and `failed` when the request is invalid or the record
/// could not be written, which can follow a turn that was.
///
/// Runs git, and may wait up to a second for the turn's last response to
/// reach the transcript, so the caller keeps it off the main thread.
///
/// # Safety
///
/// The input pointer must be readable for its length (or null with length
/// zero), and the output pointers must be writable. On `WEIR_TURN_OK` the
/// caller owns the body and frees it with `weir_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weir_stopped_turn_end_v1(
    request: *const u8,
    request_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    // Only `call_with_output` runs this, after it has checked the output.
    let body = || {
        // SAFETY: The caller guarantees the input region is readable.
        let request = unsafe { input_bytes(request, request_len) }?;
        let request: StoppedTurnRequest =
            serde_json::from_slice(request).map_err(|_| TURN_INVALID_INPUT)?;
        if !request.state_directory.is_absolute() {
            return Err(TURN_INVALID_INPUT);
        }
        let outcome = end_stopped_turn(
            &request,
            &GitSnapshots,
            &format_utc_seconds(std::time::SystemTime::now()),
            &HookLog::disabled(),
        );
        serde_json::to_vec(&StoppedTurnAnswer { outcome }).map_err(|_| TURN_INTERNAL)
    };
    // SAFETY: We pass the pointers on under the caller's guarantees.
    unsafe { call_with_output(out, out_len, body) }
}

const TURN_FRAME: FrameCodes = FrameCodes {
    ok: TURN_OK,
    null_pointer: TURN_NULL_POINTER,
    input_too_large: TURN_INPUT_TOO_LARGE,
    panic: TURN_PANIC,
};

/// Runs `body` inside the output half of the frame every turn call shares:
/// the output pointers are checked and cleared before anything runs, the body
/// is handed over, and a panic is caught at the boundary. `body` reads and
/// checks the input itself, so that work stays inside the panic catch and
/// after the output check: a call with nowhere to put its answer starts
/// nothing.
///
/// # Safety
///
/// `out` and `out_len` must be writable or null. On `TURN_OK` the caller
/// owns the body and frees it with `weir_approval_bytes_free_v1`.
pub(crate) unsafe fn call_with_output(
    out: *mut *mut u8,
    out_len: *mut usize,
    body: impl FnOnce() -> Result<Vec<u8>, i32>,
) -> i32 {
    // SAFETY: We pass the pointers on under the caller's guarantees.
    unsafe { call_with_codes(out, out_len, TURN_FRAME, body) }
}

/// The input region a turn call was handed, within the turn calls' limit.
///
/// # Safety
///
/// Same contract as `frame::input_bytes`.
pub(crate) unsafe fn input_bytes<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8], i32> {
    // SAFETY: We pass the region on under the caller's guarantees.
    unsafe { frame::input_bytes(pointer, length, MAX_TURN_INPUT_BYTES, TURN_FRAME) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::take_bytes;
    use serde_json::Value;
    use std::ptr;

    fn apply(directory: &str, turn_ids: &[u8]) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len: usize = 99;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            weir_turn_gc_apply_v1(
                directory.as_ptr(),
                directory.len(),
                turn_ids.as_ptr(),
                turn_ids.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        // SAFETY: The pair is what this call wrote.
        let body = unsafe { take_bytes(out, out_len) };
        (
            status,
            body.and_then(|body| serde_json::from_slice(&body).ok()),
        )
    }

    #[test]
    fn each_turn_reports_what_became_of_it() {
        let directory_scratch = tempfile::tempdir().expect("scratch");
        let directory = directory_scratch.path().to_path_buf();
        let id = uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase();
        let (status, body) = apply(
            directory.to_str().expect("path"),
            format!(r#"["{id}","lower-case"]"#).as_bytes(),
        );
        assert_eq!(status, TURN_OK);
        assert_eq!(
            body,
            Some(serde_json::json!([
                {"outcome": "alreadyGone", "turnId": id},
                {"outcome": "failed", "turnId": "lower-case", "reason": "not a turn id"}
            ]))
        );
    }

    #[test]
    fn a_missing_output_pointer_is_refused_before_anything_runs() {
        let ids = b"[]";
        // SAFETY: The input pointers are live locals; the output ones are
        // null on purpose.
        let status = unsafe {
            weir_turn_gc_apply_v1(
                b"/tmp".as_ptr(),
                4,
                ids.as_ptr(),
                ids.len(),
                ptr::null_mut(),
                ptr::null_mut(),
            )
        };
        assert_eq!(status, TURN_NULL_POINTER);
    }

    fn end_turn(request: &[u8]) -> (i32, Option<Value>) {
        let mut out: *mut u8 = ptr::dangling_mut();
        let mut out_len: usize = 99;
        // SAFETY: Every pointer is a live local of this test.
        let status = unsafe {
            weir_stopped_turn_end_v1(
                request.as_ptr(),
                request.len(),
                &raw mut out,
                &raw mut out_len,
            )
        };
        // SAFETY: The pair is what this call wrote.
        let body = unsafe { take_bytes(out, out_len) };
        (
            status,
            body.and_then(|body| serde_json::from_slice(&body).ok()),
        )
    }

    #[test]
    fn a_stopped_turn_whose_record_is_gone_writes_nothing() {
        let scratch = tempfile::tempdir().expect("scratch");
        let request = serde_json::json!({
            "provider": "claude",
            "stateDirectory": scratch.path(),
            "storageId": "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            "episodeToken": "5",
            "transcriptPath": scratch.path().join("session.jsonl"),
        });
        let (status, body) = end_turn(request.to_string().as_bytes());
        assert_eq!(status, TURN_OK);
        assert_eq!(body, Some(serde_json::json!({"outcome": "movedOn"})));
        assert_eq!(
            std::fs::read_dir(scratch.path()).expect("dir").count(),
            0,
            "nothing is created for a record that is not there"
        );
    }

    #[test]
    fn a_stopped_turn_request_of_another_shape_is_refused() {
        assert_eq!(
            end_turn(br#"{"provider":"claude"}"#),
            (TURN_INVALID_INPUT, None)
        );
        let relative = serde_json::json!({
            "provider": "claude",
            "stateDirectory": "states",
            "storageId": "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            "episodeToken": "5",
            "transcriptPath": "/t/session.jsonl",
        });
        assert_eq!(
            end_turn(relative.to_string().as_bytes()),
            (TURN_INVALID_INPUT, None)
        );
        let scratch = tempfile::tempdir().expect("scratch");
        let unknown = serde_json::json!({
            "provider": "other",
            "stateDirectory": scratch.path(),
            "storageId": "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1",
            "episodeToken": "5",
            "transcriptPath": scratch.path().join("session.jsonl"),
        });
        assert_eq!(
            end_turn(unknown.to_string().as_bytes()),
            (TURN_OK, Some(serde_json::json!({"outcome": "failed"})))
        );
    }

    #[test]
    fn input_that_is_not_a_list_of_ids_is_refused() {
        assert_eq!(apply("/tmp", br#"{"id":1}"#), (TURN_INVALID_INPUT, None));
        assert_eq!(apply("", b"[]"), (TURN_INVALID_INPUT, None));
    }
}
