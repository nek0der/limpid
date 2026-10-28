//! The hook runtime: what runs inside the Hook Helper's `hook <provider>`
//! subcommand for every lifecycle event.
//!
//! One call reads the payload, asks the provider adapter for neutral events,
//! applies them to the run record, and performs the writes `apply` asked
//! for under the same lock the Swift stores use.
//! It never opens the approval service; approval stays a separate path.
//!
//! The runtime owns the provider registry; the bridge resolves adapters
//! through it.
//! Platform-specific pieces (file locks, process inspection) are behind
//! `cfg(unix)`; the crate compiles everywhere so the workspace tests run on
//! every CI operating system, but only Unix hosts can run hooks.

mod declined_waits;
mod env;
mod git;
mod hunks;
mod process;
mod records;
pub mod restore;
mod stopped_turns;
mod swap;
mod tmux;
mod turn;
mod turn_gc;
mod worktree;
pub mod worktree_lock;

pub use declined_waits::DeclinedWaits;
pub use env::{HookEnv, PANE_ID_VARIABLE, ResolvedDirectories};
pub use git::{GitSnapshots, LARGE_FILE_BYTES, NoSnapshots, SnapshotRunner, TurnSide};
pub use limpid_agent_model::TURNS_DIRECTORY;
pub use limpid_agent_model::format_utc_seconds;
pub use records::{HookLog, atomic_write, ensure_user_only_directory, with_record_lock};
pub use stopped_turns::{StoppedTurnEnd, StoppedTurnRequest, end_stopped_turn};
pub use turn_gc::{TurnDeletion, delete_turns, delete_turns_waiting};
pub use worktree::{InterceptResult, WORKTREE_ROUTING_FILE};

use limpid_agent_core::{
    ApplyContext, DEFAULT_CHECK_PATTERNS, RecordWrites, SideWrite, TurnSnapshotOp, TurnStep, apply,
    classify_check, event_id_for, idle_outcome, sanitize_text, turn_step,
};
use limpid_agent_model::{
    Capability, CheckResult, EventId, HookContext, InstallRecipe, ProviderAdapter,
    ProviderDescriptor, ProviderId, RawHookInput, RunRecord, SnapshotStatus, TmuxEndpoint,
    TurnReading, TurnUsage, cwd_event_file_name, parse_utc_seconds, run_record_file_name,
    session_hint_file_name,
};
use limpid_provider_claude::ClaudeAdapter;
use limpid_provider_codex::CodexAdapter;
use serde_json::json;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use worktree_lock::{Shared, WorktreeLockPaths};

/// How many times a prompt's hook tries a busy run record lock: two
/// seconds, against the 200 milliseconds every other event gets.
const PROMPT_RECORD_LOCK_ATTEMPTS: u32 = 200;

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
    /// field written by this call carries the same second. A prompt in a
    /// worktree is the one exception: its writes carry the time its wait for
    /// the worktree lock was over (`begin_time`).
    pub now: String,
    /// How long a prompt waits for a restore (`worktree_lock`).
    pub lock_limits: worktree_lock::Limits,
}

impl<'a> HookRuntime<'a> {
    /// A runtime over the process environment and the real git.
    #[must_use]
    pub fn new(env: &'a HookEnv, snapshots: &'a dyn SnapshotRunner) -> Self {
        Self {
            env,
            snapshots,
            now: format_utc_seconds(SystemTime::now()),
            lock_limits: worktree_lock::Limits::HOOK,
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

    let (context, mut apply_context) = identity(runtime.env, adapter, &pane_id);
    // We take only the path, for a call that begins a turn or opens a wait:
    // the app reads the file while the run waits (`declined_waits`) and when
    // it ends a turn the person stopped (`stopped_turns`), so this call
    // costs no read.
    apply_context.transcript_path = adapter.turn_transcript_path(input).ok().flatten();

    let events = match adapter.normalize(input, &context) {
        Ok(events) => events,
        Err(error) => {
            log.line(&format!("payload rejected: {error}"));
            return HookOutcome::Rejected(error.to_string());
        }
    };
    // The payload already normalized, so it cannot fail here; an id that
    // cannot be had only keeps the call out of the turn records.
    let call_id = adapter.event_id(input, &context).ok().flatten();

    write_events(
        &HookCall {
            adapter,
            input,
            events: &events,
            id: call_id.as_ref(),
        },
        &directories,
        &apply_context,
        runtime,
        &log,
    );
    if let Ok(Some(run)) = adapter.command_run(input) {
        write_check(
            &run,
            call_id.as_ref(),
            &directories,
            &apply_context,
            adapter.descriptor(),
            runtime,
            &log,
        );
    }
    HookOutcome::Applied
}

/// Records a shell command the agent ran as its turn's last check, when the
/// project counts it as one.
fn write_check(
    run: &limpid_agent_model::CommandRun,
    call_id: Option<&EventId>,
    directories: &ResolvedDirectories,
    apply_context: &ApplyContext,
    descriptor: &ProviderDescriptor,
    runtime: &HookRuntime<'_>,
    log: &HookLog,
) {
    // A check is part of a turn record, so only a provider that records
    // turns has one.
    if !descriptor.has(Capability::TurnSnapshot) {
        return;
    }
    let Some(check) = check_of(run, directories) else {
        return;
    };
    let record_path = directories
        .state
        .join(run_record_file_name(&apply_context.run_id));
    let turns = turn::Turns {
        directory: directories.state.join(TURNS_DIRECTORY),
        descriptor,
        run_id: &apply_context.run_id,
        pane_id: &apply_context.pane_id,
        now: &runtime.now,
        log,
        transcript: None,
    };
    let written = with_record_lock(&record_path, || {
        turns.record_check(records::read_record(&record_path).as_ref(), call_id, check);
    });
    if written.is_none() {
        log.line(&format!("record lock busy for {}", record_path.display()));
    }
}

/// The check `run` is, when the project counts it as one: by the patterns
/// the project set for the directory it ran in, or the defaults.
fn check_of(
    run: &limpid_agent_model::CommandRun,
    directories: &ResolvedDirectories,
) -> Option<CheckResult> {
    check_with(
        run,
        &check_patterns(&run_directory(run), &directories.state),
    )
}

/// The directory `run` ran in, the hook's own when the payload named none.
fn run_directory(run: &limpid_agent_model::CommandRun) -> PathBuf {
    run.cwd
        .as_deref()
        .map_or_else(turn::current_directory, PathBuf::from)
}

/// The check patterns the project set for `cwd`, or the defaults, as the
/// application data folder that holds the provider's state directory `state`
/// keeps them.
fn check_patterns(cwd: &Path, state: &Path) -> Vec<String> {
    state
        .parent()
        .and_then(|support| worktree::check_patterns(support, cwd))
        .unwrap_or_else(|| {
            DEFAULT_CHECK_PATTERNS
                .iter()
                .map(|&pattern| pattern.to_owned())
                .collect()
        })
}

/// The check `run` is under `patterns`.
fn check_with(run: &limpid_agent_model::CommandRun, patterns: &[String]) -> Option<CheckResult> {
    let check = classify_check(&run.command, patterns)?;
    Some(CheckResult {
        // Kept to the record's text contract: a heredoc can make a command
        // kilobytes long, and the record is shown as text.
        command: sanitize_text(&check.command),
        // The call's status is the check's only when nothing came after it
        // (`cargo test | tail` reports `tail`'s).
        exit_code: run.exit_code.filter(|_| check.is_exit_its_own),
        is_filtered: check.is_filtered,
    })
}

/// One hook call's transcript, as the turns it begins or ends read it.
struct CallTranscript<'a> {
    call: &'a HookCall<'a>,
    directories: &'a ResolvedDirectories,
}

impl turn::TurnTranscript for CallTranscript<'_> {
    fn marker(&self) -> Option<String> {
        self.call.adapter.turn_marker(self.call.input)
    }

    /// A turn whose last response is not yet in the transcript is read
    /// again as the provider writes it (`awaited`), and the rest is read as
    /// `end_reading` reads it. The payload is read for the transcript's path
    /// only then.
    fn read_end(&self, marker: Option<&str>) -> turn::EndReading {
        let adapter = self.call.adapter;
        let reading = adapter.turn_reading(self.call.input, marker);
        let path = reading
            .is_awaiting_response
            .then(|| {
                adapter
                    .transcript_path(RawHookInput {
                        bytes: self.call.input.bytes,
                        transcript: None,
                    })
                    .ok()
                    .flatten()
            })
            .flatten();
        let reading = match path {
            Some(path) => awaited(reading, Path::new(&path), |transcript| {
                adapter.turn_reading(
                    RawHookInput {
                        bytes: self.call.input.bytes,
                        transcript: Some(transcript),
                    },
                    marker,
                )
            }),
            None => reading,
        };
        end_reading(adapter, reading, &self.directories.state)
    }
}

/// The transcript of a turn the app ends because the person stopped it,
/// which no hook does (`stopped_turns`): the file the run record names, read
/// with no payload, as the provider's adapter reads a transcript on its own
/// (`ProviderAdapter::transcript_turn_reading`).
pub(crate) struct TranscriptFile<'a> {
    pub adapter: &'a dyn ProviderAdapter,
    pub path: &'a Path,
    /// This is the provider's state directory, under the data folder whose
    /// project settings name the check patterns.
    pub state: &'a Path,
}

impl turn::TurnTranscript for TranscriptFile<'_> {
    /// No prompt begins a turn here.
    fn marker(&self) -> Option<String> {
        None
    }

    /// Read as a hook's turn end reads its transcript (`awaited` and
    /// `end_reading`). Claude reports itself idle a few milliseconds before
    /// the stopped turn's last lines reach the file, so the reading waits
    /// for them as a `Stop` waits for its last response. A file that cannot
    /// be read says nothing, which keeps what the turn had.
    fn read_end(&self, marker: Option<&str>) -> turn::EndReading {
        let Some(path) = self.path.to_str() else {
            return turn::EndReading::default();
        };
        let Some(transcript) = records::read_bounded_tail(self.path, MAX_TRANSCRIPT_BYTES) else {
            return turn::EndReading::default();
        };
        let read = |transcript: &[u8]| {
            self.adapter
                .transcript_turn_reading(transcript, path, marker)
        };
        let reading = awaited(read(&transcript), self.path, read);
        end_reading(self.adapter, reading, self.state)
    }
}

/// Returns `reading`, read again from the transcript at `path` with `read`
/// while it awaits the turn's last response, for at most `AWAIT_RESPONSE`;
/// past that the reading stays partial.
fn awaited(
    mut reading: TurnReading,
    path: &Path,
    read: impl Fn(&[u8]) -> TurnReading,
) -> TurnReading {
    let started = std::time::Instant::now();
    while reading.is_awaiting_response && started.elapsed() < AWAIT_RESPONSE {
        std::thread::sleep(AWAIT_RESPONSE_STEP);
        let Some(transcript) = records::read_bounded_tail(path, MAX_TRANSCRIPT_BYTES) else {
            break;
        };
        reading = read(&transcript);
    }
    reading
}

/// What a turn's end records of `reading`. The subagents' transcripts share
/// one budget of bytes (`MAX_SUBAGENT_BYTES`), so a turn that fanned out
/// widely does not hold the end up; one read short of its whole, or not at
/// all, leaves the usage partial. The project's check patterns are read
/// once per directory the commands ran in, from the data folder that holds
/// the provider's state directory `state`.
fn end_reading(
    adapter: &dyn ProviderAdapter,
    reading: TurnReading,
    state: &Path,
) -> turn::EndReading {
    let usage = reading.usage.map(|usage| {
        let mut budget = MAX_SUBAGENT_BYTES;
        reading
            .subagent_transcripts
            .iter()
            .fold(usage, |total, path| {
                total.plus(subagent_usage(adapter, path, &mut budget))
            })
    });
    let checks = reading.commands.map(|runs| {
        let mut patterns: HashMap<PathBuf, Vec<String>> = HashMap::new();
        runs.iter()
            .filter_map(|run| {
                let cwd = run_directory(run);
                let patterns = patterns
                    .entry(cwd)
                    .or_insert_with_key(|cwd| check_patterns(cwd, state));
                check_with(run, patterns)
            })
            .collect()
    });
    turn::EndReading {
        marker: reading.marker,
        usage,
        checks,
        are_checks_partial: reading.are_commands_partial,
    }
}

/// How long a turn's end waits for its last response to reach the
/// transcript, and how often it looks. Claude Code wrote it a tenth of a
/// second after Stop began in the sessions we watched; a second keeps a slow
/// disk from costing the count, and a hook that waits no longer.
const AWAIT_RESPONSE: std::time::Duration = std::time::Duration::from_secs(1);
const AWAIT_RESPONSE_STEP: std::time::Duration = std::time::Duration::from_millis(50);

/// Most bytes one turn's end reads of its subagents' transcripts, all of
/// them together.
const MAX_SUBAGENT_BYTES: usize = 4 * MAX_TRANSCRIPT_BYTES;

/// What one subagent's transcript at `path` used, read within what is left
/// of `budget`; partial when the file is longer than that, or cannot be
/// read.
fn subagent_usage(adapter: &dyn ProviderAdapter, path: &Path, budget: &mut usize) -> TurnUsage {
    let unread = TurnUsage {
        is_partial: true,
        ..TurnUsage::default()
    };
    let limit = MAX_TRANSCRIPT_BYTES.min(*budget);
    if limit == 0 {
        return unread;
    }
    let Ok(metadata) = std::fs::metadata(path) else {
        return unread;
    };
    let Some(bytes) = records::read_bounded_tail(path, limit) else {
        return unread;
    };
    *budget -= bytes.len();
    let mut usage = adapter.subagent_usage(&bytes).unwrap_or_default();
    usage.is_partial |= usize::try_from(metadata.len()).map_or(true, |length| length > limit);
    usage
}

/// The identity fields every record carries, resolved from the environment.
fn identity(
    env: &HookEnv,
    adapter: &dyn ProviderAdapter,
    pane_id: &str,
) -> (HookContext, ApplyContext) {
    let descriptor = adapter.descriptor();
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
        invocation_id: env.invocation_id(),
        provider_home: env.provider_home(adapter.home_directory_variable(), descriptor),
    };
    let apply_context = ApplyContext {
        run_id,
        pane_id: pane_id.to_owned(),
        pid,
        tmux,
        is_tmux_hosted,
        // The payload names it, not the environment; `run_hook` sets it.
        transcript_path: None,
    };
    (context, apply_context)
}

fn write_record(path: &Path, record: &RunRecord, log: &HookLog) {
    match record.encode() {
        Ok(bytes) => {
            if let Err(error) = atomic_write(path, &bytes) {
                log.line(&format!("write {}: {error}", path.display()));
            }
        }
        Err(error) => log.line(&format!("encode record: {error}")),
    }
}

/// This is one hook call as `write_events` applies it.
struct HookCall<'a> {
    adapter: &'a dyn ProviderAdapter,
    input: RawHookInput<'a>,
    events: &'a [limpid_agent_model::AgentEvent],
    /// Identifies the call, for the turn records.
    id: Option<&'a EventId>,
}

/// Returns, for the idle prompt, whether it saw the call the run waited on
/// end (`idle_outcome`); it is `None` for every other event.
fn idle_prompt(event: &limpid_agent_model::AgentEvent) -> Option<bool> {
    match event {
        limpid_agent_model::AgentEvent::AwaitingPrompt { awaited_call_ended } => {
            Some(*awaited_call_ended)
        }
        _ => None,
    }
}

/// Applies each event of `call` under the record lock and performs its side
/// writes.
fn write_events(
    call: &HookCall<'_>,
    directories: &ResolvedDirectories,
    apply_context: &ApplyContext,
    runtime: &HookRuntime<'_>,
    log: &HookLog,
) {
    let descriptor = call.adapter.descriptor();
    let applies = |record: Option<&RunRecord>| call.adapter.applies_to(call.input, record);
    let run_id = &apply_context.run_id;
    let pane_id = &apply_context.pane_id;
    let record_path = directories.state.join(run_record_file_name(run_id));
    let transcript = CallTranscript { call, directories };
    let turns = turn::Turns {
        directory: directories.state.join(TURNS_DIRECTORY),
        descriptor,
        run_id,
        pane_id,
        now: &runtime.now,
        log,
        transcript: Some(&transcript),
    };
    for (index, event) in call.events.iter().enumerate() {
        // Read before the lock, like the snapshot it decides: a step that
        // depends on the run (the idle prompt's) is judged from the same
        // record the turn's end is prepared from.
        let before = records::read_record(&record_path);
        // A report about a run that has already moved on costs no snapshot,
        // and is dropped as under the lock.
        let applies_before = applies(before.as_ref());
        let step = applies_before
            .then(|| turn_step(event, descriptor, before.as_ref(), &runtime.now))
            .flatten();
        let idle = idle_prompt(event);
        let idle_before = idle.and_then(|ended| idle_outcome(before.as_ref(), ended, &runtime.now));
        // A prompt holds the worktree lock shared from its snapshot until
        // the run record names it, so a restore neither runs under the
        // snapshot nor lets the agent start while it writes. Dropped once
        // the record is written. A turn's end takes no lock: a restore
        // reads the run records under its own and refuses while one is
        // running, waiting for an answer, or compacting.
        let worktree = matches!(step, Some(TurnStep::Begin))
            .then(|| lock_worktree(&turns.begin_directory(event), run_id, runtime, log))
            .flatten();
        // Once the wait for the lock is over, and before the snapshot. A
        // prompt outside a repository takes no lock and keeps the call's
        // time.
        let stamp = worktree
            .as_ref()
            .map(|_| begin_time(&runtime.now, SystemTime::now()));
        let now = stamp.as_deref().unwrap_or(&runtime.now);
        let turns = turns.at(now);
        let (worktree, worktree_root) = worktree.unzip();
        // `git add -A` can take long in a large repository, so the snapshot
        // is taken before the record lock; the result is written under the
        // lock.
        let prepared = step.map(|step| {
            turns.prepare(
                step,
                event,
                event_id_for(call.id, index),
                before.as_ref(),
                runtime.snapshots,
                worktree.as_ref().and_then(Shared::snapshot_skip_reason),
            )
        });
        // A prompt's record is what a restore reads to see the agent at
        // work, so it waits longer for a busy lock than other events: lost,
        // the agent would start with its record still at rest.
        let attempts = if worktree.is_some() {
            PROMPT_RECORD_LOCK_ATTEMPTS
        } else {
            records::RECORD_LOCK_ATTEMPTS
        };
        let outcome = records::with_record_lock_attempts(&record_path, attempts, || {
            let previous = records::read_record(&record_path);
            // The idle prompt ends what the run showed when the end was
            // prepared. A `Stop` or a prompt that came while the snapshot
            // ran changed that, and the end prepared for it would replace
            // the real one, so the idle prompt is dropped whole.
            if let Some(ended) = idle
                && (idle_outcome(previous.as_ref(), ended, &runtime.now) != idle_before
                    || turn_step(event, descriptor, previous.as_ref(), &runtime.now) != step
                    || !is_same_stretch(before.as_ref(), previous.as_ref()))
            {
                log.line("idle prompt dropped: the run moved on while its end was prepared");
                return (RecordWrites::default(), None);
            }
            // We ask again under the lock: a report about the turn before
            // must not touch the prompt or session that came meanwhile.
            if !applies_before || !applies(previous.as_ref()) {
                log.line("event dropped: the run moved on while its end was prepared");
                return (RecordWrites::default(), None);
            }
            let mut writes = apply(previous.as_ref(), event, apply_context, descriptor, now);
            attach_snapshot(&mut writes, prepared.as_ref());
            if let (Some(record), Some(root)) = (writes.run.as_mut(), &worktree_root) {
                record.worktree_root = Some(root.to_string_lossy().into_owned());
            }
            let pin = prepared.and_then(|prepared| {
                turns.commit(prepared, previous.as_ref(), writes.run.as_mut())
            });
            if let Some(record) = &writes.run {
                write_record(&record_path, record, log);
            }
            (writes, pin)
        });
        drop(worktree);
        let Some((writes, pin)) = outcome else {
            log.line(&format!("record lock busy for {}", record_path.display()));
            continue;
        };
        if let Some(pin) = &pin {
            turns.pin(pin, runtime.snapshots);
        }
        if let Some(TurnSnapshotOp::Remove { cwd }) = &writes.snapshot {
            remove_snapshot(cwd.as_deref(), pane_id, runtime, log);
        }
        for side in &writes.side {
            perform_side_write(
                side,
                directories,
                pane_id,
                run_id,
                now,
                descriptor.has(Capability::SessionEndDropsSession),
                log,
            );
        }
    }
}

/// Removes the pane's snapshot a session's end left in the repository at
/// `cwd`, the hook's own directory when the run named none.
fn remove_snapshot(cwd: Option<&str>, pane_id: &str, runtime: &HookRuntime<'_>, log: &HookLog) {
    let cwd = cwd.map_or_else(turn::current_directory, PathBuf::from);
    if let Err(error) = runtime.snapshots.remove(&cwd, pane_id) {
        log.line(&format!("remove turn snapshot: {error}"));
    }
}

/// The time a prompt in a worktree is stamped with once its hook is through
/// with the worktree lock (`clock`), never earlier than `called`, the time
/// of the hook call. Every field the prompt writes (the turn's `startedAt`,
/// the run's `runStartedAt`) carries it.
///
/// The app counts a turn that began before a restore ran as one the restore
/// took back (`RestoredTurns` in the app), and a restore's time is taken
/// before it asks for the lock. A hook called just before a restore can find
/// the restore holding the lock by the time it asks for it, or even find it
/// already done, so the call's time can come before a restore the agent
/// never ran under. Taken once the lock is held, the stamp is no earlier
/// than any restore that ran before it, and the agent cannot start before
/// this hook returns, so it is when the turn really began. That holds when
/// the snapshot was given up at its limit too (`Shared::HeldLate`): the hook
/// goes on waiting for the restore to let go and is stamped once it has.
/// Only when the restore never lets go (`Shared::NotReleased`) does the
/// agent start beside it; the stamp is then when the hook gave up, which is
/// when the agent starts, and a restore still alive stops at its next look.
/// A clock set back during the wait would put the turn before the call, and
/// before turns the call already saw, so the call's time is the floor.
fn begin_time(called: &str, clock: SystemTime) -> String {
    let after = format_utc_seconds(clock);
    match (parse_utc_seconds(called), parse_utc_seconds(&after)) {
        (Some(called_at), Some(after_at)) if after_at < called_at => called.to_owned(),
        _ => after,
    }
}

/// Whether two reads of a run record show the same stretch of work: the
/// same episode, turn, and rest outside a turn. A run that left and came
/// back to the same state between the reads (a `Stop`, then another late
/// tool) differs here though its state reads the same. The revision is not
/// compared: every write moves it, a title change too, and that does not
/// change what the idle prompt ends.
fn is_same_stretch(before: Option<&RunRecord>, now: Option<&RunRecord>) -> bool {
    let stretch = |record: Option<&RunRecord>| {
        record.map(|record| {
            (
                record.state_episode_token.clone(),
                record.run_started_at.clone(),
                record.outside_turn_rest,
            )
        })
    };
    stretch(before) == stretch(now)
}

/// The worktree lock for a prompt in `cwd`, with the worktree's root, or
/// `None` outside a repository. What kept the hook waiting goes to the log.
fn lock_worktree(
    cwd: &Path,
    run_id: &str,
    runtime: &HookRuntime<'_>,
    log: &HookLog,
) -> Option<(Shared, PathBuf)> {
    let (git_dir, root) = runtime.snapshots.worktree(cwd)?;
    let shared = worktree_lock::acquire_shared(
        &WorktreeLockPaths::new(&git_dir),
        run_id,
        runtime.lock_limits,
    );
    match &shared {
        Shared::Held(_) => {}
        Shared::HeldLate(_) => {
            log.line("worktree lock: a restore held it past the snapshot's limit");
        }
        Shared::NotReleased => {
            log.line("worktree lock: a restore did not let go; went on without it");
        }
        Shared::Unavailable(reason) => log.line(&format!("worktree lock unavailable: {reason}")),
    }
    Some((shared, root))
}

/// Copies the begin snapshot into the record `apply` produced. The app
/// reads `turnRoot` to tell where the run's turn was recorded (restore);
/// `turnBaseTree` stays beside it so the record keeps the shape every
/// earlier build wrote and read. A failed capture leaves the fields empty;
/// a retried prompt, which takes no snapshot, leaves them as they were.
fn attach_snapshot(writes: &mut RecordWrites, prepared: Option<&turn::Prepared>) {
    if !matches!(writes.snapshot, Some(TurnSnapshotOp::Capture { .. })) {
        return;
    }
    let Some(taken) = prepared.and_then(turn::Prepared::begin_snapshot) else {
        return;
    };
    if let Some(record) = &mut writes.run {
        let captured = match &taken.status {
            SnapshotStatus::Captured { tree, root } => Some((tree.clone(), root.clone())),
            _ => None,
        };
        record.turn_base_tree = captured.as_ref().map(|(tree, _)| tree.clone());
        record.turn_root = captured.map(|(_, root)| root);
    }
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
            let path = directories.session.join(session_hint_file_name(pane_id));
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
            let path = directories.session.join(session_hint_file_name(pane_id));
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
            let path = directory.join(cwd_event_file_name(pane_id));
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

#[cfg(test)]
mod stamp_tests {
    use super::begin_time;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn a_prompt_is_stamped_with_the_clock_after_the_lock() {
        let after = UNIX_EPOCH + Duration::from_secs(1_789_315_231);
        assert_eq!(
            begin_time("2026-09-13T16:00:01Z", after),
            "2026-09-13T16:00:31Z"
        );
    }

    #[test]
    fn a_clock_set_back_during_the_wait_keeps_the_call_time() {
        let after = UNIX_EPOCH + Duration::from_secs(1_789_315_141);
        assert_eq!(
            begin_time("2026-09-13T16:00:01Z", after),
            "2026-09-13T16:00:01Z"
        );
    }
}

#[cfg(test)]
mod subagent_tests {
    use super::{MAX_TRANSCRIPT_BYTES, subagent_usage};
    use limpid_provider_claude::ClaudeAdapter;

    /// The subagents share one budget: a file read once the budget is spent
    /// is not read, and the usage says it is short.
    #[test]
    fn subagents_past_the_budget_leave_the_usage_partial() {
        let directory =
            std::env::temp_dir().join(format!("limpid-subagent-budget-{}", std::process::id()));
        std::fs::create_dir_all(&directory).expect("directory");
        let path = directory.join("agent-a.jsonl");
        std::fs::write(
            &path,
            "{\"type\":\"assistant\",\"requestId\":\"r\",\"message\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}}\n",
        )
        .expect("subagent");

        let mut budget = MAX_TRANSCRIPT_BYTES;
        let read = subagent_usage(&ClaudeAdapter, &path, &mut budget);
        assert_eq!(
            (read.input_tokens, read.output_tokens, read.is_partial),
            (1, 2, false)
        );
        assert!(
            budget < MAX_TRANSCRIPT_BYTES,
            "the read is spent from the budget"
        );

        let mut spent = 0;
        let unread = subagent_usage(&ClaudeAdapter, &path, &mut spent);
        assert_eq!((unread.input_tokens, unread.is_partial), (0, true));

        let mut short = 10;
        assert!(
            subagent_usage(&ClaudeAdapter, &path, &mut short).is_partial,
            "read short of its whole"
        );
        let _ = std::fs::remove_dir_all(&directory);
    }
}
