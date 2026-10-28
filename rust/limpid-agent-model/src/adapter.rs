//! The contract a provider crate implements.

use crate::{
    AgentEvent, ApprovalDecision, ApprovalRequest, EventId, InstallRecipe, ProviderDescriptor,
    Titles, TurnUsage, WorktreeIntent,
};
use serde_json::{Map, Value};
use std::path::PathBuf;
use uuid::Uuid;

/// Longest hook payload an adapter accepts, matching the protocol's client
/// request limit.
pub const MAX_HOOK_INPUT_BYTES: usize = 1024 * 1024;

/// One raw hook invocation as the provider delivered it.
#[derive(Clone, Copy, Debug)]
pub struct RawHookInput<'a> {
    /// The payload read from standard input.
    pub bytes: &'a [u8],
    /// The provider's transcript at the time of the call, when the provider
    /// has one and the runtime chose to read it.
    pub transcript: Option<&'a [u8]>,
}

/// Where the hook runs. Everything here comes from the environment the shim
/// set, never from the payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HookContext {
    pub run_id: Uuid,
    pub pane_id: Uuid,
    pub tmux: Option<TmuxEndpoint>,
    pub pid: Option<u32>,
    /// The id the shim minted for this hook call
    /// (`LIMPID_HOOK_INVOCATION_ID`), a new one for every call. `None` when
    /// the shim did not set one (an older shim).
    pub invocation_id: Option<Uuid>,
    /// The provider's own configuration directory (`~/.codex`, or what
    /// `home_directory_variable` names), resolved by the runtime from the
    /// environment the agent runs in. An adapter reads it to tell the
    /// provider's internal work from the person's: the descriptor's
    /// `internal_agent_directories` lie under this one. `None` when the
    /// environment names no home at all.
    pub provider_home: Option<PathBuf>,
}

/// The tmux server and pane hosting the agent, captured from `TMUX` and
/// `TMUX_PANE`. The session is deliberately absent: membership is mutable and
/// resolved by the host's topology probe.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TmuxEndpoint {
    pub socket_path: String,
    pub pane: String,
    pub server_pid: u32,
    /// Unix epoch seconds the server started, when `ps` could report it.
    pub server_started_at: Option<u64>,
}

/// Why a payload could not be normalized.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum NormalizeError {
    #[error("input exceeds {limit} bytes")]
    TooLarge { limit: usize },
    #[error("input is not a JSON object")]
    NotAnObject,
}

/// A provider is one implementation of this trait plus recorded fixtures.
pub trait ProviderAdapter: Send + Sync {
    /// Identity, capabilities, timing, and directory names.
    fn descriptor(&self) -> &ProviderDescriptor;

    /// What the platform must place so the provider's hooks reach Limpid.
    fn install_recipe(&self) -> InstallRecipe;

    /// The environment variable that moves the provider's configuration
    /// directory (`CODEX_HOME`), when the provider has one. The runtime reads
    /// it to fill `HookContext::provider_home`, falling back to the
    /// descriptor's `default_home`. Hooks run in the agent's own environment,
    /// so the variable the agent honors is the one the hook sees. The value
    /// is handed over as written: an adapter that compares paths resolves
    /// symlinks itself. A relative value, which the agent resolves against
    /// the directory it starts in, cannot be resolved here, where the hook
    /// runs in the session's `cwd`; the provider's shim makes it absolute
    /// before the agent starts.
    fn home_directory_variable(&self) -> Option<&'static str> {
        None
    }

    /// Maps one hook payload to neutral events. Unknown event names become
    /// `AgentEvent::Extension`; unrecognized fields on known events are ignored.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn normalize(
        &self,
        input: RawHookInput<'_>,
        context: &HookContext,
    ) -> Result<Vec<AgentEvent>, NormalizeError>;

    /// Reads a permission request out of a hook payload. `Ok(None)` means the
    /// payload is not a permission request.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn approval_request(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<ApprovalRequest>, NormalizeError>;

    /// Renders a decision as the provider's hook output. `request` is the
    /// `ApprovalRequest` JSON (`tool_name`, `input`, ...) this provider
    /// produced for the decision. An answer needs both fields to render: the
    /// tool name decides whether the request was a question at all, and the
    /// input has to be echoed because the provider replaces the whole tool
    /// input with the hook's.
    fn approval_output(
        &self,
        decision: &ApprovalDecision,
        request: &Value,
    ) -> crate::ProviderOutput;

    /// The identity of this hook call for a turn record (`EventId`). The
    /// default is the shim's invocation id; a provider whose payload carries
    /// an id of its own for the call (Claude's tool use id) uses that. `None`
    /// means the call cannot be told apart from a retry, and the turn record
    /// rejects it rather than risk applying it twice.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn event_id(
        &self,
        input: RawHookInput<'_>,
        context: &HookContext,
    ) -> Result<Option<EventId>, NormalizeError> {
        let _ = input;
        Ok(context
            .invocation_id
            .map(|id| EventId::invocation(&self.descriptor().id, id)))
    }

    /// Names the transcript the runtime should read alongside this payload,
    /// when the provider keeps one and this event's normalization uses it.
    /// Reading the transcript costs a file read per hook, so adapters answer
    /// only for the events that need it. The path comes from the payload and
    /// is opened by the runtime under its own limits.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn transcript_path(&self, input: RawHookInput<'_>) -> Result<Option<String>, NormalizeError> {
        let _ = input;
        Ok(None)
    }

    /// Names the file where the provider keeps its session titles, when it
    /// keeps them apart from the transcript (Codex's `session_index.jsonl`)
    /// and this event's normalization carries titles. The runtime reads the
    /// file's tail under its own limit and hands it to `indexed_titles`.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn title_index_path(
        &self,
        input: RawHookInput<'_>,
        context: &HookContext,
    ) -> Result<Option<PathBuf>, NormalizeError> {
        let _ = (input, context);
        Ok(None)
    }

    /// The titles the file `title_index_path` named gives this call's
    /// session. The runtime adds them to the events that carry titles
    /// (`AgentEvent::add_titles`). `None` means the file names none.
    fn indexed_titles(&self, input: RawHookInput<'_>, index: &[u8]) -> Option<Titles> {
        let _ = (input, index);
        None
    }

    /// Names the transcript of the turn this call begins, or the one that
    /// will show whether the wait this call opens is over, for a call that
    /// puts the run in `NeedsInput`. Only the path is taken, not the file:
    /// the runtime keeps it on the run record through the turn, and the app
    /// reads the transcript while the run waits
    /// (`transcript_shows_wait_declined`) and when it ends a turn the person
    /// stopped (`transcript_turn_reading`). A provider whose every wait and
    /// every turn end with a hook of its own keeps the default.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn turn_transcript_path(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<String>, NormalizeError> {
        let _ = input;
        Ok(None)
    }

    /// Returns whether the transcript tail shows that the person declined
    /// the call the run waits on and the turn stopped there, which no hook
    /// reports. The app reads it on its own schedule rather than in a hook,
    /// from the path `turn_transcript_path` named. `false` means "not seen",
    /// which keeps the wait: ending a live question would hide it from the
    /// person.
    fn transcript_shows_wait_declined(&self, transcript: &[u8]) -> bool {
        let _ = transcript;
        false
    }

    /// Reads a `git worktree add` the agent is about to run out of a tool
    /// payload, so the hook runtime can intercept it. Reported alongside the
    /// neutral events rather than as one of them because it is a request to
    /// act before the tool runs, not an observation. Providers without a
    /// shell tool keep the default.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn worktree_intent(
        &self,
        input: RawHookInput<'_>,
    ) -> Result<Option<WorktreeIntent>, NormalizeError> {
        let _ = input;
        Ok(None)
    }

    /// Reads a shell command the agent ran, and how it exited, out of a tool
    /// payload, so the hook runtime can record a turn's checks.
    /// Reported alongside the neutral events rather than as one: it is an
    /// observation about the turn, not a change in the run's state, and a
    /// provider that answers a question while a command finishes must keep
    /// the question waiting. Providers that report no exit status keep the
    /// default.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    fn command_run(&self, input: RawHookInput<'_>) -> Result<Option<CommandRun>, NormalizeError> {
        let _ = input;
        Ok(None)
    }

    /// Returns whether this call's events are about the run `record`
    /// describes now. The runtime asks under the record lock, just before it
    /// applies them, and drops every event of the call when the answer is no.
    /// A provider's own hooks run while it waits, so they are always current;
    /// a report made from outside the agent (the Codex helper's usage-limit
    /// watcher) can arrive after the run moved on to another conversation or
    /// turn, and only the payload says which one it observed.
    fn applies_to(&self, input: RawHookInput<'_>, record: Option<&crate::RunRecord>) -> bool {
        let _ = (input, record);
        true
    }

    /// The provider's own id for the turn a prompt payload begins, which its
    /// transcript tags the turn's lines with. The runtime keeps it on the
    /// turn record so the turn's end can find where the turn began.
    /// Providers that name no turn keep the default.
    fn turn_marker(&self, input: RawHookInput<'_>) -> Option<String> {
        let _ = input;
        None
    }

    /// What the turn a payload ends used and ran, read from
    /// `input.transcript` back to where the turn `marker` names began (the
    /// payload's own turn when `marker` is `None`). Providers that record
    /// neither keep the default, which reads nothing.
    fn turn_reading(&self, input: RawHookInput<'_>, marker: Option<&str>) -> TurnReading {
        let _ = (input, marker);
        TurnReading::default()
    }

    /// What the turn that began at `marker` used and ran, read from the
    /// tail of the transcript at `path` (`turn_transcript_path`), for a turn
    /// the person stopped, which no hook ends: the app's writer ends it and
    /// has no payload to read (`turn_reading`). Providers that record
    /// neither, or whose every turn ends with a hook, keep the default,
    /// which reads nothing.
    fn transcript_turn_reading(
        &self,
        transcript: &[u8],
        path: &str,
        marker: Option<&str>,
    ) -> TurnReading {
        let _ = (transcript, path, marker);
        TurnReading::default()
    }

    /// What one subagent's whole transcript used, for the transcripts a
    /// `TurnReading` names.
    fn subagent_usage(&self, transcript: &[u8]) -> Option<TurnUsage> {
        let _ = transcript;
        None
    }
}

/// What a provider's transcript says of the turn a payload ends. Each part
/// is empty when the transcript does not say, which keeps what the turn
/// record held.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TurnReading {
    /// The provider's own id for the turn the reading counted from, which
    /// is `marker` where one was given, so the runtime can tell a reading
    /// that started at a turn already recorded.
    pub marker: Option<String>,
    /// What the turn's own requests used, its subagents' left out.
    pub usage: Option<TurnUsage>,
    /// The transcripts of the subagents the turn ran, whose usage the
    /// runtime adds through `subagent_usage`.
    pub subagent_transcripts: Vec<PathBuf>,
    /// The shell commands the turn ran, in a shape the provider reads, for
    /// a provider whose tool hooks report no exit status (`command_run`),
    /// so the runtime records the turn's checks at its end.
    pub commands: Option<Vec<CommandRun>>,
    /// Whether `commands` may leave out the turn's first ones: the part of
    /// the transcript read no longer holds the turn's start.
    pub are_commands_partial: bool,
    /// Whether the turn's last response is not yet in the transcript: the
    /// provider may still be writing it as the hook runs, and the runtime
    /// may read the transcript again for it.
    pub is_awaiting_response: bool,
}

/// A shell command the agent ran, as a tool payload reports it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandRun {
    pub command: String,
    /// `None` when the run was interrupted, or the provider gave none.
    pub exit_code: Option<i32>,
    /// The directory the agent ran it in, when the payload says.
    pub cwd: Option<String>,
}

/// Parses a payload as a JSON object under the shared size limit.
///
/// # Errors
///
/// Returns `TooLarge` past `limit` and `NotAnObject` for invalid JSON or a
/// non-object root.
pub fn parse_object(bytes: &[u8], limit: usize) -> Result<Map<String, Value>, NormalizeError> {
    if bytes.len() > limit {
        return Err(NormalizeError::TooLarge { limit });
    }
    match serde_json::from_slice::<Value>(bytes) {
        Ok(Value::Object(object)) => Ok(object),
        _ => Err(NormalizeError::NotAnObject),
    }
}

/// Returns the payload's `transcript_path` when its `hook_event_name` is one
/// of `events` and the path names a `.jsonl` file (in any case), for an
/// adapter's `transcript_path` or `turn_transcript_path`. For
/// `transcript_path`, each provider passes only the events whose
/// normalization reads the transcript, since every one named there costs a
/// file read per hook; `turn_transcript_path` only keeps the path.
///
/// # Errors
///
/// Returns `NormalizeError` only for input that is too large or is not a
/// JSON object.
pub fn transcript_path_for_events(
    input: RawHookInput<'_>,
    events: &[&str],
) -> Result<Option<String>, NormalizeError> {
    let object = parse_object(input.bytes, MAX_HOOK_INPUT_BYTES)?;
    let text = |key: &str| object.get(key).and_then(Value::as_str);
    if !text("hook_event_name").is_some_and(|event| events.contains(&event)) {
        return Ok(None);
    }
    Ok(text("transcript_path")
        .filter(|path| {
            std::path::Path::new(path)
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("jsonl"))
        })
        .map(str::to_owned))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn transcript(payload: &str, events: &[&str]) -> Option<String> {
        transcript_path_for_events(
            RawHookInput {
                bytes: payload.as_bytes(),
                transcript: None,
            },
            events,
        )
        .expect("an object")
    }

    #[test]
    fn the_transcript_is_named_only_for_the_events_given() {
        let stop = r#"{"hook_event_name":"Stop","transcript_path":"/tmp/a.JSONL"}"#;
        assert_eq!(transcript(stop, &["Stop"]), Some("/tmp/a.JSONL".to_owned()));
        assert_eq!(transcript(stop, &["Other"]), None);
        assert_eq!(
            transcript(
                r#"{"hook_event_name":"Stop","transcript_path":"/tmp/a.txt"}"#,
                &["Stop"]
            ),
            None
        );
        assert_eq!(
            transcript(r#"{"transcript_path":"/a.jsonl"}"#, &["Stop"]),
            None
        );
        assert_eq!(
            transcript_path_for_events(
                RawHookInput {
                    bytes: b"[]",
                    transcript: None
                },
                &["Stop"]
            ),
            Err(NormalizeError::NotAnObject)
        );
    }

    #[test]
    fn parse_object_enforces_the_limit_before_parsing() {
        let payload = vec![b'{'; 8];
        assert_eq!(
            parse_object(&payload, 4),
            Err(NormalizeError::TooLarge { limit: 4 })
        );
        assert_eq!(parse_object(b"[1]", 64), Err(NormalizeError::NotAnObject));
        assert_eq!(
            parse_object(b"not json", 64),
            Err(NormalizeError::NotAnObject)
        );
        let object = parse_object(b"{\"a\":1}", 64).expect("object");
        assert_eq!(object.get("a"), Some(&Value::from(1)));
    }
}
