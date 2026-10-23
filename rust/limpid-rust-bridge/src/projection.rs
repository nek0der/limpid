//! The C ABI for the application-side rules.
//!
//! Every call is JSON in, JSON out, and the caller frees the body with
//! `limpid_approval_bytes_free_v1`. What the rules remember between passes
//! stays here, in an engine the host holds by an opaque pointer: the state
//! holds a summary of every turn kept, and handing it across as JSON on every
//! pass cost more than the rules themselves.

use crate::transfer;
use limpid_agent_core::{
    DEFAULT_CHECK_PATTERNS, on_launch, on_terminate, project_with, turns_taken_by_change,
};
use limpid_agent_hook::DeclinedWaits;
use limpid_agent_model::{
    CWD_EVENT_FILE_SUFFIX, Command, Instants, LOCK_FILE_SUFFIX, LifecycleInput, ProjectionInput,
    ProjectionState, RUN_RECORD_FILE_SUFFIX, SESSION_HINT_FILE_SUFFIX, TURN_RECORD_FILE_SUFFIX,
    TURNS_DIRECTORY, TurnSweepInput, WORKTREE_EVENT_FILE_SUFFIX, WORKTREE_EVENTS_DIRECTORY,
};
use serde::Serialize;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;
use std::sync::{Mutex, PoisonError};

/// Largest input one projection call accepts. Generous next to a hook payload
/// because the input carries every record at once, and bounded so a runaway
/// state directory reports a limit rather than exhausting memory. The app
/// warns before a pass reaches it (`AgentProjectionAdapter.inputLimit`); the
/// two sides check the value against `rust/fixtures/contract/shared-values.json`.
pub(crate) const MAX_PROJECTION_INPUT_BYTES: usize = 16 * 1024 * 1024;

/// Status codes returned by the projection ABI functions, reported as
/// `int32_t` for the same reason as `limpid_provider_result`.
#[repr(C)]
#[allow(non_camel_case_types)]
pub enum limpid_projection_result {
    /// The call succeeded and the output buffer holds the result.
    LIMPID_PROJECTION_OK = 0,
    /// A required pointer was null.
    LIMPID_PROJECTION_NULL_POINTER = 1,
    /// The input exceeded the projection input limit.
    LIMPID_PROJECTION_INPUT_TOO_LARGE = 2,
    /// The input was not UTF-8 or not the JSON shape the call expects.
    LIMPID_PROJECTION_INVALID_INPUT = 3,
    /// The result could not be serialized.
    LIMPID_PROJECTION_INTERNAL = 4,
    /// Rust caught a panic at the FFI boundary.
    LIMPID_PROJECTION_PANIC = 5,
    /// The engine holds no proposal by that number that can still be kept:
    /// another pass's was committed since it was made (or it was this one),
    /// or later passes pushed it out. Nothing was remembered.
    LIMPID_PROJECTION_NOT_PROPOSED = 6,
}

const PROJECTION_OK: i32 = limpid_projection_result::LIMPID_PROJECTION_OK as i32;
const PROJECTION_NULL_POINTER: i32 =
    limpid_projection_result::LIMPID_PROJECTION_NULL_POINTER as i32;
const PROJECTION_INPUT_TOO_LARGE: i32 =
    limpid_projection_result::LIMPID_PROJECTION_INPUT_TOO_LARGE as i32;
const PROJECTION_INVALID_INPUT: i32 =
    limpid_projection_result::LIMPID_PROJECTION_INVALID_INPUT as i32;
const PROJECTION_INTERNAL: i32 = limpid_projection_result::LIMPID_PROJECTION_INTERNAL as i32;
const PROJECTION_PANIC: i32 = limpid_projection_result::LIMPID_PROJECTION_PANIC as i32;
const PROJECTION_NOT_PROPOSED: i32 =
    limpid_projection_result::LIMPID_PROJECTION_NOT_PROPOSED as i32;

/// What one pass returns: what to show and what to do.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PassOutput {
    projection: limpid_agent_model::Projection,
    commands: Vec<Command>,
}

/// What the rules remember between passes, for one host.
///
/// A pass proposes the next state and the host commits it once it has read
/// the answer: a pass whose answer the host could not use must leave the
/// memory as it was, or the next pass would take for done what was never
/// shown or carried out.
///
/// Each proposal has a number, and a commit names the one it means. A
/// proposal can be kept only while the state it was made from is still the
/// committed one: a host that runs passes from more than one thread commits
/// the one whose answer it applied, and the others, made from the state that
/// commit replaced, are refused rather than undoing it. The mutex makes the
/// calls safe to make from any thread; the numbers make them mean what the
/// caller read. A panic inside a pass leaves the lock poisoned; the state
/// behind it is still whole, since a pass only reads the committed state and
/// writes its proposal last, so the lock is recovered rather than every
/// later pass failing.
#[allow(non_camel_case_types)]
pub struct limpid_projection_engine_v1 {
    memory: Mutex<Memory>,
    /// This is what each waiting run's transcript last read as
    /// (`limpid_agent_hook::DeclinedWaits`). It is kept apart from `memory`
    /// because it is no state a pass proposes: it describes files, which are
    /// what they are whether or not the host commits, so it is kept as it is
    /// read.
    waits: Mutex<DeclinedWaits>,
}

/// How many uncommitted proposals are kept: the host runs at most one pass
/// in place beside one away from its main thread. Each holds a whole state,
/// so an older one is dropped rather than kept for a commit that will not
/// come.
const KEPT_PROPOSALS: usize = 2;

#[derive(Default)]
struct Memory {
    committed: ProjectionState,
    /// Counts the commits, so a proposal knows which state it was made from.
    version: u64,
    /// Oldest first: number, the version it was made from, and the state.
    proposals: Vec<(u64, u64, ProjectionState)>,
    /// The number the last proposal was given.
    last_proposal: u64,
}

impl limpid_projection_engine_v1 {
    fn memory(&self) -> std::sync::MutexGuard<'_, Memory> {
        self.memory.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Reports the providers this build has, as `{ "<id>": <descriptor>, ... }`.
///
/// # Safety
///
/// The output pointers must be writable. On `LIMPID_PROJECTION_OK` the caller
/// owns the body and frees it with `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_providers_v1(
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let outcome = projection_boundary(|| {
        if out.is_null() || out_len.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }
        let registry: std::collections::BTreeMap<_, _> = limpid_agent_hook::installed_providers()
            .into_iter()
            .map(|descriptor| (descriptor.id.clone(), descriptor))
            .collect();
        let body = serde_json::to_vec(&registry).map_err(|_| PROJECTION_INTERNAL)?;
        unsafe { transfer(body, out, out_len) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

/// Reports what each installed provider needs the platform to set up.
///
/// The body is `{ "<provider id>": <install recipe>, ... }`.
///
/// # Safety
///
/// The output pointers must be writable. On `LIMPID_PROJECTION_OK` the caller
/// owns the body and frees it with `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_install_recipes_v1(
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let outcome = projection_boundary(|| {
        if out.is_null() || out_len.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }
        let recipes: std::collections::BTreeMap<_, _> = limpid_agent_hook::installed_recipes()
            .into_iter()
            .map(|(id, recipe)| (id.clone(), recipe))
            .collect();
        let body = serde_json::to_vec(&recipes).map_err(|_| PROJECTION_INTERNAL)?;
        unsafe { transfer(body, out, out_len) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

/// How the hook runtime names the files in every provider's directories, as
/// `{ "runRecordSuffix", "sessionHintSuffix", "cwdEventSuffix",
/// "worktreeEventsDirectory", "worktreeEventSuffix", "turnsDirectory",
/// "turnRecordSuffix", "lockSuffix" }`. A run record's file name is its
/// storage id followed by `runRecordSuffix`; a resume hint's and a cwd
/// event's are the pane id followed by their suffix; worktree events are the
/// files ending in `worktreeEventSuffix` in the `worktreeEventsDirectory` of
/// the state directory; turn records are the turn id followed by
/// `turnRecordSuffix` in its `turnsDirectory`; and the lock on any of these
/// files is its path followed by `lockSuffix`.
///
/// The hook runtime writes each file under that name, and the host lists,
/// rewrites, locks, and deletes it by the same name. Reporting them here is
/// what keeps the host from spelling the names a second time.
///
/// # Safety
///
/// The output pointers must be writable. On `LIMPID_PROJECTION_OK` the caller
/// owns the body and frees it with `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_record_layout_v1(
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let outcome = projection_boundary(|| {
        if out.is_null() || out_len.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }
        let layout = RecordLayout {
            run_record_suffix: RUN_RECORD_FILE_SUFFIX,
            session_hint_suffix: SESSION_HINT_FILE_SUFFIX,
            cwd_event_suffix: CWD_EVENT_FILE_SUFFIX,
            worktree_events_directory: WORKTREE_EVENTS_DIRECTORY,
            worktree_event_suffix: WORKTREE_EVENT_FILE_SUFFIX,
            turns_directory: TURNS_DIRECTORY,
            turn_record_suffix: TURN_RECORD_FILE_SUFFIX,
            lock_suffix: LOCK_FILE_SUFFIX,
        };
        let body = serde_json::to_vec(&layout).map_err(|_| PROJECTION_INTERNAL)?;
        unsafe { transfer(body, out, out_len) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

/// The check commands a project gets until it sets its own, as a JSON
/// array of patterns. The hook runtime classifies commands with the same
/// list, so the project settings show what is actually in force instead of a
/// copy kept on the host's side.
///
/// # Safety
///
/// The output pointers must be writable. On `LIMPID_PROJECTION_OK` the caller
/// owns the body and frees it with `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_check_defaults_v1(
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let outcome = projection_boundary(|| {
        if out.is_null() || out_len.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }
        let body = serde_json::to_vec(DEFAULT_CHECK_PATTERNS).map_err(|_| PROJECTION_INTERNAL)?;
        unsafe { transfer(body, out, out_len) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

/// What `limpid_projection_record_layout_v1` reports.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RecordLayout {
    run_record_suffix: &'static str,
    session_hint_suffix: &'static str,
    cwd_event_suffix: &'static str,
    worktree_events_directory: &'static str,
    worktree_event_suffix: &'static str,
    turns_directory: &'static str,
    turn_record_suffix: &'static str,
    lock_suffix: &'static str,
}

/// An engine with nothing remembered, as the first pass after launch finds
/// it. The caller owns it and releases it with
/// `limpid_projection_engine_free_v1`.
#[unsafe(no_mangle)]
pub extern "C" fn limpid_projection_engine_create_v1() -> *mut limpid_projection_engine_v1 {
    Box::into_raw(Box::new(limpid_projection_engine_v1 {
        memory: Mutex::new(Memory::default()),
        waits: Mutex::new(DeclinedWaits::default()),
    }))
}

/// Releases an engine. A null pointer is ignored.
///
/// # Safety
///
/// `engine` must be null or a pointer `limpid_projection_engine_create_v1`
/// returned that has not been released, and no other call may be using it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_engine_free_v1(
    engine: *mut limpid_projection_engine_v1,
) {
    if !engine.is_null() {
        // SAFETY: The caller guarantees the pointer came from `Box::into_raw`
        // in `limpid_projection_engine_create_v1` and is released once.
        drop(unsafe { Box::from_raw(engine) });
    }
}

/// Reduces the records the host found into what to show and what to change,
/// from what the engine has committed, and proposes the state that follows.
///
/// `input` is the `ProjectionInput` JSON, `now` the `Instants` JSON; the body
/// is `{ "projection": ..., "commands": [...] }` and `proposal` the number to
/// hand `limpid_projection_engine_commit_v1`. Nothing is remembered until
/// then.
///
/// # Safety
///
/// `engine` must be null or a live engine; null reports
/// `LIMPID_PROJECTION_NULL_POINTER`. Every non-null pointer must remain valid
/// for its declared length for the duration of this call. The output
/// pointers must be writable, and on `LIMPID_PROJECTION_OK` the caller owns
/// the body and frees it with `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_engine_pass_v1(
    engine: *const limpid_projection_engine_v1,
    input: *const u8,
    input_len: usize,
    now: *const u8,
    now_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    proposal: *mut u64,
) -> i32 {
    let outcome = projection_boundary(|| {
        // SAFETY: The caller guarantees a non-null `engine` is live.
        let engine = unsafe { engine.as_ref() }.ok_or(PROJECTION_NULL_POINTER)?;
        let mut memory = engine.memory();
        let input_bytes = unsafe { required_bytes(input, input_len) }?;
        let now_bytes = unsafe { required_bytes(now, now_len) }?;
        if out.is_null() || out_len.is_null() || proposal.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }
        let input: ProjectionInput = decode(input_bytes)?;
        let now: Instants = decode(now_bytes)?;

        // A pass that panicked while reading leaves the readings whole: each
        // is inserted after its file was read.
        let mut waits = engine.waits.lock().unwrap_or_else(PoisonError::into_inner);
        let (next, projection, commands) =
            project_with(&memory.committed, &input, &now, &mut |provider, path| {
                waits.is_declined(provider, path)
            });
        waits.end_pass();
        drop(waits);
        let body = serde_json::to_vec(&PassOutput {
            projection,
            commands,
        })
        .map_err(|_| PROJECTION_INTERNAL)?;
        memory.last_proposal += 1;
        let number = memory.last_proposal;
        let version = memory.version;
        if memory.proposals.len() == KEPT_PROPOSALS {
            memory.proposals.remove(0);
        }
        memory.proposals.push((number, version, next));
        unsafe { transfer(body, out, out_len) };
        // SAFETY: Checked non-null above; the caller guarantees it is writable.
        unsafe { ptr::write(proposal, number) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

/// Remembers what the pass numbered `proposal` proposed, when the state it
/// was made from is still the committed one; otherwise reports
/// `LIMPID_PROJECTION_NOT_PROPOSED` and changes nothing.
///
/// # Safety
///
/// `engine` must be null or a live engine; null reports
/// `LIMPID_PROJECTION_NULL_POINTER`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_engine_commit_v1(
    engine: *const limpid_projection_engine_v1,
    proposal: u64,
) -> i32 {
    let outcome = projection_boundary(|| {
        // SAFETY: The caller guarantees a non-null `engine` is live.
        let engine = unsafe { engine.as_ref() }.ok_or(PROJECTION_NULL_POINTER)?;
        let mut memory = engine.memory();
        let version = memory.version;
        if !memory
            .proposals
            .iter()
            .any(|(number, made_from, _)| *number == proposal && *made_from == version)
        {
            return Err(PROJECTION_NOT_PROPOSED);
        }
        // Every other proposal was made from the state this one replaces.
        let (_, _, next) = std::mem::take(&mut memory.proposals)
            .into_iter()
            .find(|(number, _, _)| *number == proposal)
            .ok_or(PROJECTION_NOT_PROPOSED)?;
        memory.committed = next;
        memory.version += 1;
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

/// A change of the retention limits, for
/// `limpid_projection_engine_turns_taken_v1`: both carry the same
/// protection, and differ in the limits.
#[derive(serde::Deserialize)]
struct TurnSweepChange {
    from: TurnSweepInput,
    to: TurnSweepInput,
}

/// Counts the turns the retention sweep would take under `to` that it keeps
/// under `from`, from what the engine has committed, and deletes nothing: it
/// is the sweep's own choice (`turns_taken_by_change`), so the count the host
/// shows before a change is what the sweep then deletes, a pass's share at
/// a time.
///
/// `change` is `{ "from": <TurnSweepInput>, "to": <TurnSweepInput> }`, `now`
/// the `Instants` JSON, and the count is written to `count`.
///
/// # Safety
///
/// `engine` must be null or a live engine; null reports
/// `LIMPID_PROJECTION_NULL_POINTER`. Every non-null pointer must remain valid
/// for its declared length for the duration of this call, and `count` must be
/// writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_engine_turns_taken_v1(
    engine: *const limpid_projection_engine_v1,
    change: *const u8,
    change_len: usize,
    now: *const u8,
    now_len: usize,
    count: *mut u64,
) -> i32 {
    let outcome = projection_boundary(|| {
        // SAFETY: The caller guarantees a non-null `engine` is live.
        let engine = unsafe { engine.as_ref() }.ok_or(PROJECTION_NULL_POINTER)?;
        let change_bytes = unsafe { required_bytes(change, change_len) }?;
        let now_bytes = unsafe { required_bytes(now, now_len) }?;
        if count.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }
        let change: TurnSweepChange = decode(change_bytes)?;
        let now: Instants = decode(now_bytes)?;
        let taken =
            turns_taken_by_change(&engine.memory().committed, &change.from, &change.to, &now);
        // SAFETY: Checked non-null above; the caller guarantees it is writable.
        unsafe { ptr::write(count, u64::try_from(taken).unwrap_or(u64::MAX)) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

/// Decides what to restore or retire before the interface exists.
///
/// # Safety
///
/// Both pointers must remain valid for their declared lengths for the
/// duration of this call. The output pointers must be writable, and on
/// `LIMPID_PROJECTION_OK` the caller owns the body and frees it with
/// `limpid_approval_bytes_free_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_on_launch_v1(
    input: *const u8,
    input_len: usize,
    now: *const u8,
    now_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe { lifecycle(input, input_len, now, now_len, out, out_len, on_launch) }
}

/// Records what Limpid is about to kill and what would bring it back.
///
/// # Safety
///
/// As `limpid_projection_on_launch_v1`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn limpid_projection_on_terminate_v1(
    input: *const u8,
    input_len: usize,
    now: *const u8,
    now_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    unsafe { lifecycle(input, input_len, now, now_len, out, out_len, on_terminate) }
}

/// The shared body of the two lifecycle calls, which differ only in the rule
/// they run.
unsafe fn lifecycle(
    input: *const u8,
    input_len: usize,
    now: *const u8,
    now_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    rule: fn(&LifecycleInput, &str) -> Vec<Command>,
) -> i32 {
    let outcome = projection_boundary(|| {
        let input_bytes = unsafe { required_bytes(input, input_len) }?;
        let now_bytes = unsafe { required_bytes(now, now_len) }?;
        if out.is_null() || out_len.is_null() {
            return Err(PROJECTION_NULL_POINTER);
        }
        let input: LifecycleInput = decode(input_bytes)?;
        let now = str::from_utf8(now_bytes).map_err(|_| PROJECTION_INVALID_INPUT)?;
        let body = serde_json::to_vec(&rule(&input, now)).map_err(|_| PROJECTION_INTERNAL)?;
        unsafe { transfer(body, out, out_len) };
        Ok(PROJECTION_OK)
    });
    match outcome {
        Ok(code) | Err(code) => code,
    }
}

fn decode<T: serde::de::DeserializeOwned>(bytes: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(bytes).map_err(|_| PROJECTION_INVALID_INPUT)
}

unsafe fn required_bytes<'a>(pointer: *const u8, length: usize) -> Result<&'a [u8], i32> {
    if pointer.is_null() {
        return Err(PROJECTION_NULL_POINTER);
    }
    if length > MAX_PROJECTION_INPUT_BYTES {
        return Err(PROJECTION_INPUT_TOO_LARGE);
    }
    // SAFETY: The caller guarantees the region is readable for `length`.
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}

fn projection_boundary(operation: impl FnOnce() -> Result<i32, i32>) -> Result<i32, i32> {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(result) => result,
        Err(_) => Err(PROJECTION_PANIC),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::take_bytes;
    use serde_json::Value;

    const NOW: &str = r#"{"wall":"2026-09-14T12:00:00Z","monotonicMs":0}"#;

    /// Frees the engine when a test ends, however it ends.
    struct Engine(*mut limpid_projection_engine_v1);

    /// What one pass returned: its status, its body, and its proposal.
    struct Pass {
        status: i32,
        body: Option<Value>,
        proposal: u64,
    }

    impl Engine {
        fn new() -> Self {
            Self(limpid_projection_engine_create_v1())
        }

        fn pass(&self, input: &str) -> Pass {
            let mut out: *mut u8 = ptr::null_mut();
            let mut out_len: usize = 0;
            let mut proposal: u64 = 0;
            let status = unsafe {
                limpid_projection_engine_pass_v1(
                    self.0,
                    input.as_ptr(),
                    input.len(),
                    NOW.as_ptr(),
                    NOW.len(),
                    &raw mut out,
                    &raw mut out_len,
                    &raw mut proposal,
                )
            };
            // SAFETY: The pair is what this call wrote.
            let body = unsafe { take_bytes(out, out_len) };
            Pass {
                status,
                body: body.and_then(|body| serde_json::from_slice(&body).ok()),
                proposal,
            }
        }

        fn commit(&self, proposal: u64) -> i32 {
            unsafe { limpid_projection_engine_commit_v1(self.0, proposal) }
        }

        fn committed(&self) -> ProjectionState {
            unsafe { &*self.0 }.memory().committed.clone()
        }
    }

    impl Drop for Engine {
        fn drop(&mut self) {
            unsafe { limpid_projection_engine_free_v1(self.0) };
        }
    }

    const TURN_ID: &str = "00000000-0000-4000-8000-000000000001";

    /// A pass that remembers something: one turn record, which the state
    /// keeps a summary of.
    fn a_turn() -> String {
        let record = serde_json::json!({
            "schemaVersion": 1,
            "turnId": TURN_ID,
            "provider": "claude",
            "conversation": {"provider": "claude", "conversationId": "s", "isFallback": false},
            "runId": "R",
            "paneId": "P",
            "displayNumber": 1,
            "startedAt": "2026-09-14T11:00:00Z",
            "phase": "started",
            "begin": {"kind": "pending"},
            "end": {"kind": "pending"},
            "changes": {"kind": "unknown"},
        });
        serde_json::json!({
            "turnFiles": [{"provider": "claude", "name": TURN_ID, "content": record.to_string()}],
        })
        .to_string()
    }

    /// The same turn by name only, as the host sends a record the rules
    /// have read: it keeps what they remember of it, and nothing else.
    fn the_turn_by_name() -> String {
        serde_json::json!({ "turnFiles": [{"provider": "claude", "name": TURN_ID}] }).to_string()
    }

    /// Builds a Claude run waiting on its question inside a turn, whose
    /// record names the transcript at `transcript`.
    fn a_question_waiting_in(transcript: &std::path::Path) -> String {
        const RUN: &str = "AAAAAAAA-1111-4111-8111-AAAAAAAAAAA1";
        let record = serde_json::json!({
            "schemaVersion": 3,
            "paneId": "11111111-1111-4111-8111-111111111111",
            "runId": RUN,
            "revision": 5,
            "state": "needsInput",
            "waitKind": "question",
            "detail": "Which color?",
            "runStartedAt": "2026-09-14T11:59:00Z",
            "updatedAt": "2026-09-14T12:00:00Z",
            "transcriptPath": transcript.to_str().expect("utf8"),
        });
        serde_json::json!({
            "records": [{"provider": "claude", "name": RUN, "content": record.to_string()}],
        })
        .to_string()
    }

    fn badge_state(pass: &Pass) -> Value {
        pass.body.as_ref().expect("body")["projection"]["runtimes"][0]["badge"]["state"].clone()
    }

    #[test]
    fn a_question_declined_at_the_agents_prompt_shows_as_stopped() {
        let directory = tempfile::tempdir().expect("dir");
        let transcript = directory.path().join("session.jsonl");
        std::fs::write(
            &transcript,
            include_bytes!("../../fixtures/transcripts/claude-2.1.309-question-open.jsonl"),
        )
        .expect("write");
        let engine = Engine::new();
        let input = a_question_waiting_in(&transcript);
        let pass = engine.pass(&input);
        assert_eq!(pass.status, PROJECTION_OK);
        assert_eq!(badge_state(&pass), "needsInput");

        std::fs::write(
            &transcript,
            include_bytes!("../../fixtures/transcripts/claude-2.1.309-question-declined.jsonl"),
        )
        .expect("write");
        let pass = engine.pass(&input);
        assert_eq!(badge_state(&pass), "finished");
        let badge = &pass.body.as_ref().expect("body")["projection"]["runtimes"][0]["badge"];
        assert!(badge.get("waitKind").is_none());
        // The file is read once for each version it had, not once per pass.
        engine.pass(&input);
        let reads = unsafe { &*engine.0 }.waits.lock().expect("waits").reads();
        assert_eq!(reads, 2);
    }

    #[test]
    fn a_pass_answers_without_the_state() {
        let engine = Engine::new();
        let pass = engine.pass("{}");
        assert_eq!(pass.status, PROJECTION_OK);
        let body = pass.body.expect("body");
        assert!(body.get("state").is_none());
        assert!(body.get("projection").is_some());
        assert_eq!(body["commands"], Value::Array(vec![]));
    }

    impl Engine {
        fn turns_taken(&self, change: &str) -> (i32, u64) {
            let mut count: u64 = 0;
            let status = unsafe {
                limpid_projection_engine_turns_taken_v1(
                    self.0,
                    change.as_ptr(),
                    change.len(),
                    NOW.as_ptr(),
                    NOW.len(),
                    &raw mut count,
                )
            };
            (status, count)
        }
    }

    /// From limits that keep the hour-old turn to `max_age_secs`.
    fn a_change_to(max_age_secs: u64) -> String {
        serde_json::json!({
            "from": {"maxAgeSecs": 86_400, "maxPerConversation": 200},
            "to": {"maxAgeSecs": max_age_secs, "maxPerConversation": 200},
        })
        .to_string()
    }

    #[test]
    fn the_turns_a_change_takes_are_counted_from_what_was_committed() {
        let engine = Engine::new();
        let pass = engine.pass(&a_turn());
        assert_eq!(
            engine.turns_taken(&a_change_to(60)),
            (PROJECTION_OK, 0),
            "not committed yet"
        );
        assert_eq!(engine.commit(pass.proposal), PROJECTION_OK);
        // The hand-written record leaves out fields a rewrite fills in, so
        // the rules read it as one they may not delete; which records may go
        // is the sweep's own tests' matter, not this boundary's.
        for turn in unsafe { &*engine.0 }.memory().committed.turns.values_mut() {
            turn.is_deletable = true;
        }
        assert_eq!(engine.turns_taken(&a_change_to(60)), (PROJECTION_OK, 1));
        assert_eq!(engine.turns_taken(&a_change_to(7_200)), (PROJECTION_OK, 0));
        // Counting deletes nothing.
        assert_eq!(engine.committed().turns.len(), 1);
        assert_eq!(engine.turns_taken("{}").0, PROJECTION_INVALID_INPUT);
    }

    #[test]
    fn only_a_committed_pass_is_remembered() {
        let engine = Engine::new();
        let pass = engine.pass(&a_turn());
        assert_eq!(pass.status, PROJECTION_OK);
        assert!(engine.committed().turns.is_empty());
        assert_eq!(engine.commit(pass.proposal), PROJECTION_OK);
        assert_eq!(engine.committed().turns.len(), 1);
        // Committed already: nothing is proposed any more.
        assert_eq!(engine.commit(pass.proposal), PROJECTION_NOT_PROPOSED);
        assert_eq!(engine.committed().turns.len(), 1);
    }

    #[test]
    fn the_next_pass_starts_from_what_was_committed() {
        let engine = Engine::new();
        assert_eq!(engine.pass(&a_turn()).status, PROJECTION_OK);
        // Not committed, so the turn sent by name is one the rules never
        // read; continuing from the proposal would keep it.
        let next = engine.pass(&the_turn_by_name());
        assert_eq!(engine.commit(next.proposal), PROJECTION_OK);
        assert!(engine.committed().turns.is_empty());
    }

    #[test]
    fn a_commit_names_the_pass_it_read() {
        let engine = Engine::new();
        let first = engine.pass(&a_turn());
        // Another pass ran in between, from the same state: committing the
        // first keeps the first, not the one made after it.
        let second = engine.pass("{}");
        assert_ne!(first.proposal, second.proposal);
        assert_eq!(engine.commit(first.proposal), PROJECTION_OK);
        assert_eq!(engine.committed().turns.len(), 1);
        // The second was made from the state that commit replaced.
        assert_eq!(engine.commit(second.proposal), PROJECTION_NOT_PROPOSED);
        assert_eq!(engine.committed().turns.len(), 1);
    }

    #[test]
    fn a_pass_made_before_a_commit_cannot_undo_it() {
        let engine = Engine::new();
        // A pass away from the host's main thread starts first...
        let away = engine.pass("{}");
        // ...and one run in place finishes and commits before it returns.
        let in_place = engine.pass(&a_turn());
        assert_eq!(engine.commit(in_place.proposal), PROJECTION_OK);
        assert_eq!(engine.commit(away.proposal), PROJECTION_NOT_PROPOSED);
        assert_eq!(engine.committed().turns.len(), 1);
    }

    #[test]
    fn a_failed_pass_leaves_the_others_as_they_were() {
        let engine = Engine::new();
        let first = engine.pass(&a_turn());
        let failed = engine.pass("not json");
        assert_eq!(failed.status, PROJECTION_INVALID_INPUT);
        assert_eq!(engine.commit(failed.proposal), PROJECTION_NOT_PROPOSED);
        assert_eq!(engine.commit(first.proposal), PROJECTION_OK);
        assert_eq!(engine.committed().turns.len(), 1);
    }

    #[test]
    fn only_the_latest_proposals_are_kept() {
        let engine = Engine::new();
        let oldest = engine.pass(&a_turn());
        let _ = engine.pass("{}");
        let latest = engine.pass("{}");
        assert_eq!(engine.commit(oldest.proposal), PROJECTION_NOT_PROPOSED);
        assert_eq!(engine.commit(latest.proposal), PROJECTION_OK);
        assert!(engine.committed().turns.is_empty());
    }

    #[test]
    fn bad_input_is_reported_rather_than_guessed_at() {
        let engine = Engine::new();
        assert_eq!(engine.pass("not json").status, PROJECTION_INVALID_INPUT);

        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let mut proposal: u64 = 0;
        let status = unsafe {
            limpid_projection_engine_pass_v1(
                engine.0,
                ptr::null(),
                0,
                NOW.as_ptr(),
                NOW.len(),
                &raw mut out,
                &raw mut out_len,
                &raw mut proposal,
            )
        };
        assert_eq!(status, PROJECTION_NULL_POINTER);
        assert!(out.is_null());
        let input = b"{}";
        let status = unsafe {
            limpid_projection_engine_pass_v1(
                ptr::null(),
                input.as_ptr(),
                input.len(),
                NOW.as_ptr(),
                NOW.len(),
                &raw mut out,
                &raw mut out_len,
                &raw mut proposal,
            )
        };
        assert_eq!(status, PROJECTION_NULL_POINTER);
        let status = unsafe {
            limpid_projection_engine_pass_v1(
                engine.0,
                input.as_ptr(),
                input.len(),
                NOW.as_ptr(),
                NOW.len(),
                &raw mut out,
                &raw mut out_len,
                ptr::null_mut(),
            )
        };
        assert_eq!(status, PROJECTION_NULL_POINTER);
        assert!(out.is_null());
        assert_eq!(
            unsafe { limpid_projection_engine_commit_v1(ptr::null(), 1) },
            PROJECTION_NULL_POINTER
        );
        // Releasing nothing is allowed.
        unsafe { limpid_projection_engine_free_v1(ptr::null_mut()) };
    }

    #[test]
    fn an_oversized_input_reports_a_limit_rather_than_reading_it() {
        let engine = Engine::new();
        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let mut proposal: u64 = 0;
        let probe = b"{}";
        let status = unsafe {
            limpid_projection_engine_pass_v1(
                engine.0,
                probe.as_ptr(),
                MAX_PROJECTION_INPUT_BYTES + 1,
                NOW.as_ptr(),
                NOW.len(),
                &raw mut out,
                &raw mut out_len,
                &raw mut proposal,
            )
        };
        assert_eq!(status, PROJECTION_INPUT_TOO_LARGE);
    }

    #[test]
    fn a_poisoned_engine_still_answers() {
        let engine = Engine::new();
        let pass = engine.pass(&a_turn());
        assert_eq!(engine.commit(pass.proposal), PROJECTION_OK);
        let shared = unsafe { &*engine.0 };
        let _ = std::thread::scope(|scope| {
            scope
                .spawn(|| {
                    let _guard = shared.memory.lock();
                    panic!("inside a pass");
                })
                .join()
        });
        assert!(shared.memory.is_poisoned());
        assert_eq!(engine.pass("{}").status, PROJECTION_OK);
        assert_eq!(engine.committed().turns.len(), 1);
    }

    #[test]
    fn the_lifecycle_calls_return_a_command_list() {
        for call in [
            limpid_projection_on_launch_v1 as unsafe extern "C" fn(_, _, _, _, _, _) -> i32,
            limpid_projection_on_terminate_v1,
        ] {
            let input = b"{}";
            let now = b"2026-09-14T12:00:00Z";
            let mut out: *mut u8 = ptr::null_mut();
            let mut out_len: usize = 0;
            let status = unsafe {
                call(
                    input.as_ptr(),
                    input.len(),
                    now.as_ptr(),
                    now.len(),
                    &raw mut out,
                    &raw mut out_len,
                )
            };
            assert_eq!(status, PROJECTION_OK);
            // SAFETY: The pair is what this call wrote.
            let body = unsafe { take_bytes(out, out_len) }.expect("body");
            let commands: Value = serde_json::from_slice(&body).expect("decode");
            assert_eq!(commands, Value::Array(vec![]));
        }
    }

    #[test]
    fn the_record_layout_names_the_files_the_hook_writes() {
        let mut out: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let status = unsafe { limpid_projection_record_layout_v1(&raw mut out, &raw mut out_len) };
        assert_eq!(status, PROJECTION_OK);
        // SAFETY: The pair is what this call wrote.
        let body = unsafe { take_bytes(out, out_len) }.expect("body");
        let layout: Value = serde_json::from_slice(&body).expect("decode");
        assert_eq!(
            layout,
            serde_json::json!({
                "runRecordSuffix": RUN_RECORD_FILE_SUFFIX,
                "sessionHintSuffix": SESSION_HINT_FILE_SUFFIX,
                "cwdEventSuffix": CWD_EVENT_FILE_SUFFIX,
                "worktreeEventsDirectory": WORKTREE_EVENTS_DIRECTORY,
                "worktreeEventSuffix": WORKTREE_EVENT_FILE_SUFFIX,
                "turnsDirectory": TURNS_DIRECTORY,
                "turnRecordSuffix": TURN_RECORD_FILE_SUFFIX,
                "lockSuffix": LOCK_FILE_SUFFIX,
            })
        );

        let status =
            unsafe { limpid_projection_record_layout_v1(ptr::null_mut(), &raw mut out_len) };
        assert_eq!(status, PROJECTION_NULL_POINTER);
    }

    #[test]
    fn the_check_defaults_are_the_core_list() {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let status = unsafe { limpid_projection_check_defaults_v1(&raw mut out, &raw mut out_len) };
        assert_eq!(status, PROJECTION_OK);
        // SAFETY: The pair is what this call wrote.
        let body = unsafe { take_bytes(out, out_len) }.expect("body");
        let defaults: Vec<String> = serde_json::from_slice(&body).expect("decode");
        assert_eq!(defaults, DEFAULT_CHECK_PATTERNS);
    }

    #[test]
    fn a_panic_never_crosses_the_boundary() {
        let status = projection_boundary(|| panic!("inside the rules"));
        assert_eq!(status, Err(PROJECTION_PANIC));
    }
}
