//! Provider identity, capabilities, and the descriptor an adapter publishes.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::fmt;
use std::path::{Path, PathBuf};

/// Stable, lowercase identifier of a provider such as `claude` or `codex`.
///
/// The core never enumerates providers; it only checks that an id has this
/// shape, which keeps it usable as a directory name and a runtime key.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct ProviderId(String);

/// Why a string is not a provider id.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ProviderIdError {
    /// Empty, longer than 32 bytes, or containing anything other than
    /// lowercase ASCII letters, digits, and `-`.
    #[error("provider id must be 1 to 32 characters of [a-z0-9-]")]
    Invalid,
}

impl ProviderId {
    /// Longest accepted id.
    pub const MAX_LEN: usize = 32;

    /// Validates `value` as a provider id.
    ///
    /// # Errors
    ///
    /// Returns `ProviderIdError::Invalid` when the shape is wrong.
    pub fn new(value: impl Into<String>) -> Result<Self, ProviderIdError> {
        let value = value.into();
        let ok = (1..=Self::MAX_LEN).contains(&value.len())
            && value
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');
        if ok {
            Ok(Self(value))
        } else {
            Err(ProviderIdError::Invalid)
        }
    }

    /// The id as a string slice.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for ProviderId {
    type Error = ProviderIdError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl TryFrom<&str> for ProviderId {
    type Error = ProviderIdError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<ProviderId> for String {
    fn from(value: ProviderId) -> Self {
        value.0
    }
}

impl fmt::Display for ProviderId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// Behavior a provider opts into. The core and the UI branch on these, never
/// on a provider id, so adding an adapter does not add provider-specific
/// branches to neutral rules.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    /// `SessionEnded` may delete the resume hint.
    SessionEndDropsSession,
    /// A resume command can be generated for a stored session.
    Resume,
    /// Resume yields to another provider's live session in the same pane.
    ResumeDefersToOtherLiveSession,
    /// The provider reports working-directory changes.
    CwdEvents,
    /// The provider reports worktree creation.
    WorktreeEvents,
    /// Approval is answered by a hook process.
    ApprovalHook,
    /// Approval is requested over a connection.
    ApprovalProtocol,
    /// The provider emits subagent events.
    Subagents,
    /// A turn snapshot can be captured on prompt submit.
    TurnSnapshot,
    /// The provider reports when its prompt cache expires, on the event that
    /// ends a turn.
    CacheWindow,
    /// An `idle` status report during a turn means the person stopped it
    /// (Esc, Ctrl+C, a "No" at the agent's own prompt), as no hook says so.
    /// A provider whose every stop already ends with a hook leaves it out:
    /// its `idle` can arrive before the hook that ends the turn, and would
    /// mark a finished turn as stopped.
    ProgramStatusIdleStopsTurn,
}

/// What the platform needs to know about a provider without linking its
/// crate: identity, capabilities, timing, and where its records live.
///
/// Serialized in the camel case the rest of this boundary uses, so the host
/// reads one convention rather than two. The capability names keep their own
/// spelling: they are the vocabulary, not field names.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderDescriptor {
    pub id: ProviderId,
    pub display_name: String,
    pub capabilities: BTreeSet<Capability>,
    /// How often the host checks whether the agent process is still alive.
    pub pid_sweep_interval_ms: u32,
    /// Directory names under the application support directory. Defaults
    /// are derived from the id; Claude declares its legacy names instead to
    /// preserve existing on-disk records across upgrades.
    pub state_directory: String,
    pub session_directory: String,
    pub cwd_events_directory: Option<String>,
    /// `comm` names the parent-process walk accepts as the agent.
    pub process_names: Vec<String>,
    /// The `SessionEnd` reasons that mean the user ended the session rather
    /// than the process going away under it, so the resume hint should go too.
    /// Only read when the provider has `SessionEndDropsSession`; the values are
    /// the provider's own vocabulary, which is why they live with it rather
    /// than in the rules.
    #[serde(default)]
    pub session_end_drop_reasons: Vec<String>,
    /// Directories under the provider's configuration directory where the
    /// provider runs agents of its own rather than the person's: Codex's
    /// memory agent works in `memories` (or `memories_v2`). A hook call or a
    /// record from there is the provider's housekeeping, and neither a turn
    /// to show nor a session to resume. The names live here, with the
    /// provider, so the hook runtime and the projection read one list and
    /// the projection spells no provider's directory.
    #[serde(default)]
    pub internal_agent_directories: Vec<String>,
    /// The `app` name the provider's agent gives itself in an OSC 7501
    /// program status report (`claude-code`), when it reports one. A report
    /// under this name in a run's pane speaks for that run
    /// (`ProjectionInput::program_status`). The name is the agent's own
    /// vocabulary, so it lives here with the provider.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub program_status_app: Option<String>,
}

impl ProviderDescriptor {
    /// Default state directory name for `id`.
    #[must_use]
    pub fn default_state_directory(id: &ProviderId) -> String {
        format!("{id}-agent-states")
    }

    /// Default session directory name for `id`.
    #[must_use]
    pub fn default_session_directory(id: &ProviderId) -> String {
        format!("{id}-sessions")
    }

    /// Default cwd-event directory name for `id`.
    #[must_use]
    pub fn default_cwd_events_directory(id: &ProviderId) -> String {
        format!("{id}-cwd-events")
    }

    /// The provider's configuration directory when the environment does not
    /// move it: `~/.<provider id>` under `user_home`.
    #[must_use]
    pub fn default_home(&self, user_home: &Path) -> PathBuf {
        user_home.join(format!(".{}", self.id))
    }

    /// Whether `path` is one of `internal_agent_directories` under `home`,
    /// or lies inside one. Compared by components, so a trailing `/` does
    /// not matter and `memories-notes` is not `memories`. Both paths are
    /// taken as given: a caller whose paths may name the same directory
    /// differently (a symlink, `/tmp` for `/private/tmp`) resolves them
    /// first. A relative `home` matches nothing, since what it is relative
    /// to is not known here. We ask for a root rather than `is_absolute`:
    /// the paths are the host's POSIX paths, and elsewhere `is_absolute`
    /// also wants a drive, so `/Users/me` would read as relative.
    #[must_use]
    pub fn is_internal_agent_directory(&self, home: &Path, path: &Path) -> bool {
        home.has_root()
            && self
                .internal_agent_directories
                .iter()
                .any(|directory| path.starts_with(home.join(directory)))
    }

    /// Whether the provider declares `capability`.
    #[must_use]
    pub fn has(&self, capability: Capability) -> bool {
        self.capabilities.contains(&capability)
    }
}

#[cfg(any(test, feature = "conformance"))]
impl ProviderDescriptor {
    /// A provider that declares `capabilities` and nothing else: default
    /// directories, no process names, no session-end reasons, no internal
    /// agent directories. For a test whose rule branches on a capability
    /// rather than on what a real provider declares; a test about a real
    /// provider uses that provider's own descriptor instead. Kept in one place
    /// so a new field is added here once rather than in every test.
    ///
    /// # Panics
    ///
    /// Panics when `id` is not a valid provider id, which is a test's own
    /// mistake.
    #[must_use]
    pub fn fixture(id: &str, capabilities: impl IntoIterator<Item = Capability>) -> Self {
        let id = ProviderId::new(id).expect("a fixture names a valid provider id");
        Self {
            display_name: id.to_string(),
            capabilities: capabilities.into_iter().collect(),
            pid_sweep_interval_ms: 3_000,
            state_directory: Self::default_state_directory(&id),
            session_directory: Self::default_session_directory(&id),
            cwd_events_directory: None,
            process_names: Vec::new(),
            session_end_drop_reasons: Vec::new(),
            internal_agent_directories: Vec::new(),
            program_status_app: None,
            id,
        }
    }
}

/// A value the platform substitutes when it installs a recipe.
///
/// Typed rather than spelled out at each use: a literal token on both sides
/// of the boundary is a typo that compiles, installs, and then leaves the
/// agent reporting to nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecipePlaceholder {
    /// Where this provider's run records go.
    StateDirectory,
    /// Where this provider's resume hints go.
    SessionDirectory,
    /// Where this provider's working-directory events go.
    CwdEventsDirectory,
    /// The running application's bundle identifier, which namespaces hooks so
    /// a Debug and a Release install do not answer for each other.
    BundleId,
    /// The arguments the provider's hook command needs, as the platform builds
    /// them.
    HookArguments,
    /// Where the plan usage the agent reports goes, one file per provider.
    /// Shared by every provider rather than one of each provider's own
    /// directories, because the interface reads it as one list.
    UsageDirectory,
}

impl RecipePlaceholder {
    /// The token a settings fragment carries, for providers whose
    /// configuration is a document rather than an environment.
    #[must_use]
    pub fn token(self) -> &'static str {
        match self {
            Self::StateDirectory => "@@STATE_DIRECTORY@@",
            Self::SessionDirectory => "@@SESSION_DIRECTORY@@",
            Self::CwdEventsDirectory => "@@CWD_EVENTS_DIRECTORY@@",
            Self::BundleId => "@@BUNDLE_ID@@",
            Self::HookArguments => "@@HOOK_ARGUMENTS@@",
            Self::UsageDirectory => "@@USAGE_DIRECTORY@@",
        }
    }
}

/// One environment variable a pane needs, and what the platform puts in it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecipeVariable {
    pub name: String,
    pub value: RecipePlaceholder,
}

/// A provider-specific configuration blob the platform places for the user.
/// The adapter describes it; only the platform touches the file system.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettingsFragment {
    /// Where the fragment belongs, in the provider's own terms, for example
    /// `claude.settings` or `codex.config`.
    pub target: String,
    /// The fragment body. `@@HOOK@@` is substituted by the platform with the
    /// path of the installed hook executable; every other token in it is a
    /// `RecipePlaceholder`.
    pub body: String,
}

/// Everything a pane needs so the provider's hooks reach Limpid.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct InstallRecipe {
    /// Environment variables to export into the pane shell.
    pub environment: Vec<RecipeVariable>,
    /// Configuration fragments the platform must place.
    pub settings_fragments: Vec<SettingsFragment>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_internal_directories(directories: &[&str]) -> ProviderDescriptor {
        ProviderDescriptor {
            internal_agent_directories: directories.iter().map(|it| (*it).to_owned()).collect(),
            ..ProviderDescriptor::fixture("keeper", [])
        }
    }

    #[test]
    fn the_default_home_is_the_dotted_id_under_the_users_home() {
        assert_eq!(
            with_internal_directories(&[]).default_home(Path::new("/Users/me")),
            PathBuf::from("/Users/me/.keeper")
        );
    }

    #[test]
    fn an_internal_agent_directory_is_read_under_the_home_by_components() {
        let descriptor = with_internal_directories(&["memories", "memories_v2"]);
        let home = Path::new("/Users/me/.keeper");
        for path in [
            "/Users/me/.keeper/memories",
            "/Users/me/.keeper/memories/",
            "/Users/me/.keeper/./memories",
            "/Users/me/.keeper/memories/skills",
            "/Users/me/.keeper/memories_v2",
        ] {
            assert!(
                descriptor.is_internal_agent_directory(home, Path::new(path)),
                "{path}"
            );
        }
        // The home itself, a directory that only begins with the name, the
        // same names under another directory, and a relative path.
        for path in [
            "/Users/me/.keeper",
            "/Users/me/.keeper/memories-notes",
            "/Users/me/work/.keeper/memories",
            ".keeper/memories",
        ] {
            assert!(
                !descriptor.is_internal_agent_directory(home, Path::new(path)),
                "{path}"
            );
        }
        // A relative home is relative to a directory not known here.
        assert!(
            !descriptor
                .is_internal_agent_directory(Path::new(".keeper"), Path::new(".keeper/memories"))
        );
        // A provider that declares none has none.
        assert!(
            !with_internal_directories(&[])
                .is_internal_agent_directory(home, Path::new("/Users/me/.keeper/memories"))
        );
    }

    #[test]
    fn a_descriptor_without_internal_directories_still_decodes() {
        let mut value =
            serde_json::to_value(with_internal_directories(&["memories"])).expect("serializes");
        assert_eq!(
            value["internalAgentDirectories"],
            serde_json::json!(["memories"])
        );
        value
            .as_object_mut()
            .expect("object")
            .remove("internalAgentDirectories");
        let decoded: ProviderDescriptor = serde_json::from_value(value).expect("decodes");
        assert!(decoded.internal_agent_directories.is_empty());
    }

    #[test]
    fn accepts_lowercase_ascii_digits_and_dashes() {
        for value in ["claude", "codex", "gemini-cli", "a", "x1-2"] {
            assert!(ProviderId::new(value).is_ok(), "{value}");
        }
    }

    #[test]
    fn rejects_empty_uppercase_unicode_and_overlong_ids() {
        for value in [
            "",
            "Claude",
            "co dex",
            "ge_mini",
            "a/b",
            "é",
            &"a".repeat(33),
        ] {
            assert_eq!(
                ProviderId::new(value),
                Err(ProviderIdError::Invalid),
                "{value:?}"
            );
        }
        assert!(ProviderId::new("a".repeat(32)).is_ok());
    }

    #[test]
    fn serde_validates_on_the_way_in() {
        let id: ProviderId = serde_json::from_str("\"codex\"").expect("valid");
        assert_eq!(id.as_str(), "codex");
        assert!(serde_json::from_str::<ProviderId>("\"Codex\"").is_err());
        assert_eq!(serde_json::to_string(&id).expect("serialize"), "\"codex\"");
    }

    #[test]
    fn default_directories_follow_the_id() {
        let id = ProviderId::new("gemini").expect("valid");
        assert_eq!(
            ProviderDescriptor::default_state_directory(&id),
            "gemini-agent-states"
        );
        assert_eq!(
            ProviderDescriptor::default_session_directory(&id),
            "gemini-sessions"
        );
        assert_eq!(
            ProviderDescriptor::default_cwd_events_directory(&id),
            "gemini-cwd-events"
        );
    }

    #[test]
    fn capabilities_serialize_as_snake_case() {
        let json = serde_json::to_string(&Capability::ResumeDefersToOtherLiveSession).expect("ok");
        assert_eq!(json, "\"resume_defers_to_other_live_session\"");
        let json = serde_json::to_string(&Capability::CacheWindow).expect("ok");
        assert_eq!(json, "\"cache_window\"");
    }
}
