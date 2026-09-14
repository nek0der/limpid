//! The hook runtime: what runs inside the Hook Helper's `hook <provider>`
//! subcommand for every lifecycle event.
//!
//! One call reads the payload, asks the provider adapter for neutral events,
//! applies them to the run record, and performs the writes `apply` asked
//! for under the same lock the shell receivers and the Swift stores use.
//! It never opens the approval service; approval stays a separate path.
//!
//! The runtime owns the provider registry; the bridge resolves adapters
//! through it.
//! Platform-specific pieces (file locks, process inspection) are behind
//! `cfg(unix)`; the crate compiles everywhere so the workspace tests run on
//! every CI operating system, but only Unix hosts can run hooks.

mod env;
mod git;
mod process;
mod records;
mod tmux;
mod worktree;

pub use env::{HookEnv, ResolvedDirectories};
pub use git::{GitSnapshots, NoSnapshots, SnapshotRunner, TurnSnapshot};
pub use limpid_agent_model::format_utc_seconds;
pub use records::{HookLog, atomic_write, ensure_user_only_directory, with_record_lock};
pub use worktree::InterceptResult;

use limpid_agent_core::{
    ApplyContext, RecordWrites, SideWrite, TurnSnapshotOp, apply, turn_snapshot_cwd,
};
use limpid_agent_model::{
    Capability, HookContext, InstallRecipe, ProviderAdapter, ProviderDescriptor, ProviderId,
    RawHookInput, RunRecord, TmuxEndpoint,
};
use limpid_provider_claude::ClaudeAdapter;
use limpid_provider_codex::CodexAdapter;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Longest transcript slice the runtime hands an adapter. Title lines sit
/// near the end, so a longer transcript is read from its tail.
pub const MAX_TRANSCRIPT_BYTES: usize = 4 * 1024 * 1024;

/// How the helper should finish after one hook call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HookOutcome {
    /// Records were updated (or the event needed none). Exit 0, no output.
    Applied,
    /// The environment the shim sets is missing, so this process was not
    /// launched through Limpid. Nothing is written because falling back to a
    /// global directory could mix Debug, Release, and unrelated agent data.
    NotInLimpid,
    /// The payload could not be read as a hook payload. Nothing is written;
    /// the hook still exits 0 so the agent is never blocked by Limpid.
    Rejected(String),
    /// The provider id is not registered in this build.
    UnknownProvider,
    /// The tool call was intercepted (a worktree was created on the agent's
    /// behalf); the helper prints `message` to stderr and exits with `code`.
    Intercepted { code: i32, message: String },
}

impl HookOutcome {
    /// The process exit status for this outcome.
    #[must_use]
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Intercepted { code, .. } => *code,
            _ => 0,
        }
    }
}

/// Resolves a provider adapter by id.
#[must_use]
pub fn adapter_for(id: &str) -> Option<&'static dyn ProviderAdapter> {
    static CLAUDE: ClaudeAdapter = ClaudeAdapter;
    static CODEX: CodexAdapter = CodexAdapter;
    match id {
        limpid_provider_claude::PROVIDER_ID => Some(&CLAUDE),
        limpid_provider_codex::PROVIDER_ID => Some(&CODEX),
        _ => None,
    }
}

/// Every provider this build has, in id order.
///
/// The rules branch on capabilities rather than names, so the host has to be
/// able to ask what the installed providers are instead of holding a list of
/// its own that could disagree with this one.
#[must_use]
pub fn installed_providers() -> Vec<&'static ProviderDescriptor> {
    [
        limpid_provider_claude::PROVIDER_ID,
        limpid_provider_codex::PROVIDER_ID,
    ]
    .into_iter()
    .filter_map(|id| adapter_for(id).map(ProviderAdapter::descriptor))
    .collect()
}

/// What each installed provider needs the platform to set up, by provider id.
///
/// Asked for rather than listed on the platform side, for the same reason as
/// `installed_providers`: a second list there could disagree about a variable
/// name, and a wrong name stops the agent reporting without an error anywhere.
#[must_use]
pub fn installed_recipes() -> Vec<(&'static ProviderId, InstallRecipe)> {
    [
        limpid_provider_claude::PROVIDER_ID,
        limpid_provider_codex::PROVIDER_ID,
    ]
    .into_iter()
    .filter_map(|id| {
        adapter_for(id).map(|adapter| (&adapter.descriptor().id, adapter.install_recipe()))
    })
    .collect()
}

/// Everything one hook call needs besides the payload.
pub struct HookRuntime<'a> {
    pub env: &'a HookEnv,
    pub snapshots: &'a dyn SnapshotRunner,
    /// The wall clock at the start of the call, formatted once so every
    /// field written by this call carries the same second.
    pub now: String,
}

impl<'a> HookRuntime<'a> {
    /// A runtime over the process environment and the real git.
    #[must_use]
    pub fn new(env: &'a HookEnv, snapshots: &'a dyn SnapshotRunner) -> Self {
        Self {
            env,
            snapshots,
            now: format_utc_seconds(SystemTime::now()),
        }
    }
}

/// Runs one lifecycle hook call for `provider` with `stdin` as the payload.
///
/// Failures never block the agent: anything that cannot be written is logged
/// to `LIMPID_HOOK_LOG` when set and the call still returns an outcome with
/// exit status zero. Only a successful worktree intercept exits non-zero.
#[must_use]
pub fn run_hook(provider: &str, stdin: &[u8], runtime: &HookRuntime<'_>) -> HookOutcome {
    let log = HookLog::from_env(runtime.env);
    let Some(adapter) = adapter_for(provider) else {
        log.line(&format!("unknown provider {provider:?}"));
        return HookOutcome::UnknownProvider;
    };
    let descriptor = adapter.descriptor();
    let recipe = adapter.install_recipe();

    let Some(pane_id) = runtime.env.pane_id() else {
        log.line("LIMPID_PANE_ID is missing or malformed; not a Limpid pane");
        return HookOutcome::NotInLimpid;
    };
    let Some(directories) = runtime.env.directories(&recipe) else {
        log.line("state directories are not set; not launched through the Limpid shim");
        return HookOutcome::NotInLimpid;
    };
    for directory in directories.all() {
        ensure_user_only_directory(directory);
    }
    if let Some(record_dir) = runtime.env.record_dir() {
        records::record_raw_payload(&record_dir, stdin);
    }

    let transcript = adapter
        .transcript_path(RawHookInput {
            bytes: stdin,
            transcript: None,
        })
        .ok()
        .flatten()
        .and_then(|path| records::read_bounded_tail(Path::new(&path), MAX_TRANSCRIPT_BYTES));
    let input = RawHookInput {
        bytes: stdin,
        transcript: transcript.as_deref(),
    };

    let (context, apply_context) = identity(runtime.env, descriptor, &pane_id);

    let events = match adapter.normalize(input, &context) {
        Ok(events) => events,
        Err(error) => {
            log.line(&format!("payload rejected: {error}"));
            return HookOutcome::Rejected(error.to_string());
        }
    };

    write_events(
        &events,
        &directories,
        &apply_context,
        adapter.descriptor(),
        runtime,
        &log,
    );
    HookOutcome::Applied
}

/// The identity fields every record carries, resolved from the environment.
fn identity(
    env: &HookEnv,
    descriptor: &limpid_agent_model::ProviderDescriptor,
    pane_id: &str,
) -> (HookContext, ApplyContext) {
    // A pane-keyed fallback is uppercased like a minted run id so the file
    // name matches what the Swift store derives.
    let run_id = env.run_id().unwrap_or_else(|| pane_id.to_uppercase());
    let tmux = env.tmux_endpoint();
    let is_tmux_hosted = env.is_tmux_hosted();
    // Inside tmux the exported pid names the client, not the agent, and the
    // Swift host resolves the agent through the tmux server instead.
    let pid = if is_tmux_hosted {
        None
    } else {
        env.exported_pid(descriptor.id.as_str())
            .or_else(|| process::find_ancestor_named(&descriptor.process_names))
    };
    let context = HookContext {
        run_id: uuid::Uuid::parse_str(&run_id).unwrap_or_default(),
        pane_id: uuid::Uuid::parse_str(pane_id).unwrap_or_default(),
        tmux: tmux.clone(),
        pid,
    };
    let apply_context = ApplyContext {
        run_id,
        pane_id: pane_id.to_owned(),
        pid,
        tmux,
        is_tmux_hosted,
    };
    (context, apply_context)
}

/// Applies each event under the record lock and performs its side writes.
fn write_events(
    events: &[limpid_agent_model::AgentEvent],
    directories: &ResolvedDirectories,
    apply_context: &ApplyContext,
    descriptor: &limpid_agent_model::ProviderDescriptor,
    runtime: &HookRuntime<'_>,
    log: &HookLog,
) {
    let run_id = &apply_context.run_id;
    let pane_id = &apply_context.pane_id;
    let record_path = directories.state.join(format!("{run_id}.state.json"));
    for event in events {
        // `git add -A` can take long in a large repository, so the capture
        // happens before the record lock is taken, as the shell receiver did;
        // the result is copied into the record under the lock.
        let captured = capture_before_lock(event, descriptor, pane_id, runtime.snapshots);
        let outcome = with_record_lock(&record_path, || {
            let previous = records::read_record(&record_path);
            let mut writes = apply(
                previous.as_ref(),
                event,
                apply_context,
                descriptor,
                &runtime.now,
            );
            attach_snapshot(&mut writes, captured.as_ref());
            if let Some(record) = &writes.run {
                match record.encode() {
                    Ok(bytes) => {
                        if let Err(error) = atomic_write(&record_path, &bytes) {
                            log.line(&format!("write {}: {error}", record_path.display()));
                        }
                    }
                    Err(error) => log.line(&format!("encode record: {error}")),
                }
            }
            writes
        });
        let Some(writes) = outcome else {
            log.line(&format!("record lock busy for {}", record_path.display()));
            continue;
        };
        if let Some(TurnSnapshotOp::Remove { cwd }) = &writes.snapshot {
            let cwd = cwd.clone().map_or_else(current_directory, PathBuf::from);
            if let Err(error) = runtime.snapshots.remove(&cwd, pane_id) {
                log.line(&format!("remove turn snapshot: {error}"));
            }
        }
        for side in &writes.side {
            perform_side_write(
                side,
                directories,
                pane_id,
                run_id,
                &runtime.now,
                descriptor.has(Capability::SessionEndDropsSession),
                log,
            );
        }
    }
}

/// Captures the turn snapshot `apply` will ask for, before any lock is held.
fn capture_before_lock(
    event: &limpid_agent_model::AgentEvent,
    descriptor: &limpid_agent_model::ProviderDescriptor,
    pane_id: &str,
    snapshots: &dyn SnapshotRunner,
) -> Option<TurnSnapshot> {
    let cwd = turn_snapshot_cwd(event, descriptor)?;
    let cwd = cwd.map_or_else(current_directory, PathBuf::from);
    snapshots.capture(&cwd, pane_id)
}

/// Copies a capture into the record `apply` produced; a failed capture
/// leaves the turn fields empty, as the shell receiver did.
fn attach_snapshot(writes: &mut RecordWrites, captured: Option<&TurnSnapshot>) {
    if !matches!(writes.snapshot, Some(TurnSnapshotOp::Capture { .. })) {
        return;
    }
    if let Some(record) = &mut writes.run {
        record.turn_base_tree = captured.map(|snapshot| snapshot.tree.clone());
        record.turn_root = captured.map(|snapshot| snapshot.root.clone());
    }
}

fn current_directory() -> PathBuf {
    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

fn perform_side_write(
    side: &SideWrite,
    directories: &ResolvedDirectories,
    pane_id: &str,
    run_id: &str,
    now: &str,
    drops_session: bool,
    log: &HookLog,
) {
    match side {
        SideWrite::SessionHint { session_id, cwd } => {
            let path = directories.session.join(format!("{pane_id}.json"));
            let body = json!({
                "schemaVersion": 1,
                "paneId": pane_id,
                "sessionId": session_id,
                "cwd": cwd.clone().unwrap_or_default(),
                "updatedAt": now,
                "lastHookEvent": "session_started",
                "runId": run_id,
            });
            let written = with_record_lock(&path, || {
                atomic_write(&path, body.to_string().as_bytes())
                    .map_err(|error| log.line(&format!("write {}: {error}", path.display())))
                    .ok()
            });
            if written.is_none() {
                log.line(&format!("session hint lock busy for {}", path.display()));
            }
        }
        SideWrite::DeleteSessionHint { session_id } => {
            if !drops_session {
                return;
            }
            let path = directories.session.join(format!("{pane_id}.json"));
            let deleted = with_record_lock(&path, || {
                if records::hint_is_owned(&path, session_id, run_id, pane_id, &directories.state) {
                    std::fs::remove_file(&path).is_ok()
                } else {
                    false
                }
            });
            if deleted.is_none() {
                log.line(&format!("session hint lock busy for {}", path.display()));
            }
        }
        SideWrite::CwdEvent { new_cwd, old_cwd } => {
            let Some(directory) = &directories.cwd_events else {
                return;
            };
            let path = directory.join(format!("{pane_id}.cwd.json"));
            let body = json!({
                "schemaVersion": 1,
                "paneId": pane_id,
                "newCwd": new_cwd,
                "oldCwd": old_cwd.clone().unwrap_or_default(),
                "updatedAt": now,
            });
            let written = with_record_lock(&path, || {
                atomic_write(&path, body.to_string().as_bytes())
                    .map_err(|error| log.line(&format!("write {}: {error}", path.display())))
                    .ok()
            });
            if written.is_none() {
                log.line(&format!("cwd event lock busy for {}", path.display()));
            }
        }
        SideWrite::WorktreeEvent {
            repo_root,
            worktree_path,
            branch,
        } => {
            if let Err(error) =
                records::write_worktree_event(&directories.state, repo_root, worktree_path, branch)
            {
                log.line(&format!("write worktree event: {error}"));
            }
        }
    }
}

/// Runs the worktree intercept directly on a parsed intent; `state_dir` is
/// the provider's agent-state directory. Diagnostics are dropped: the
/// worktree exists either way, and a missing event only costs the sidebar
/// its automatic refresh.
#[must_use]
pub fn run_worktree_intercept(
    intent: &limpid_agent_model::WorktreeIntent,
    provider_id: &str,
    state_dir: &Path,
) -> InterceptResult {
    intercept_and_record(intent, provider_id, state_dir, &HookLog::disabled())
}

/// The intercept plus the event the Swift host refreshes the sidebar from,
/// so both entry points record a creation the same way.
fn intercept_and_record(
    intent: &limpid_agent_model::WorktreeIntent,
    provider_id: &str,
    state_dir: &Path,
    log: &HookLog,
) -> InterceptResult {
    let result = worktree::run(intent, provider_id, state_dir);
    if let InterceptResult::Created {
        repo_root,
        path,
        branch,
        ..
    } = &result
        && let Err(error) = records::write_worktree_event(
            state_dir,
            &repo_root.to_string_lossy(),
            &path.to_string_lossy(),
            branch,
        )
    {
        log.line(&format!("write worktree event: {error}"));
    }
    result
}

/// Runs the worktree intercept for `provider` on the tool payload `stdin`.
/// This is the second hook the providers call on `PreToolUse` for their
/// shell tool; it writes no run record.
#[must_use]
pub fn run_worktree_hook(provider: &str, stdin: &[u8], runtime: &HookRuntime<'_>) -> HookOutcome {
    let log = HookLog::from_env(runtime.env);
    let Some(adapter) = adapter_for(provider) else {
        return HookOutcome::UnknownProvider;
    };
    let Some(directories) = runtime.env.directories(&adapter.install_recipe()) else {
        return HookOutcome::NotInLimpid;
    };
    let intent = match adapter.worktree_intent(RawHookInput {
        bytes: stdin,
        transcript: None,
    }) {
        Ok(Some(intent)) => intent,
        Ok(None) => return HookOutcome::Applied,
        Err(error) => {
            log.line(&format!("payload rejected: {error}"));
            return HookOutcome::Rejected(error.to_string());
        }
    };
    match intercept_and_record(
        &intent,
        adapter.descriptor().id.as_str(),
        &directories.state,
        &log,
    ) {
        InterceptResult::Passthrough => HookOutcome::Applied,
        // Exit status 2 is the hook convention both providers share: the
        // tool call is canceled and stderr is shown to the model.
        InterceptResult::Created { message, .. } => HookOutcome::Intercepted { code: 2, message },
    }
}

/// The endpoint the record carries for a tmux-hosted agent.
#[must_use]
pub fn tmux_endpoint_from(env: &HookEnv) -> Option<TmuxEndpoint> {
    env.tmux_endpoint()
}

/// Decodes a record file for callers outside this crate (the helper's
/// diagnostics), tolerating all supported schema versions.
#[must_use]
pub fn read_record(path: &Path) -> Option<RunRecord> {
    records::read_record(path)
}
