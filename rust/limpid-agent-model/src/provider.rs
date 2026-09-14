//! Provider identity, capabilities, and the descriptor an adapter publishes.

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::fmt;

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
    /// The provider supplies session titles.
    SessionTitle,
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
}

/// What the platform needs to know about a provider without linking its
/// crate: identity, capabilities, timing, and where its records live.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
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

    /// Whether the provider declares `capability`.
    #[must_use]
    pub fn has(&self, capability: Capability) -> bool {
        self.capabilities.contains(&capability)
    }
}

/// A provider-specific configuration blob the platform places for the user.
/// The adapter describes it; only the platform touches the file system.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettingsFragment {
    /// Where the fragment belongs, in the provider's own terms, for example
    /// `claude.settings` or `codex.config`.
    pub target: String,
    /// The fragment body. Placeholders such as `@@HOOK@@` are substituted by
    /// the platform with the paths of the installed hook executables.
    pub body: String,
}

/// Everything a pane needs so the provider's hooks reach Limpid.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct InstallRecipe {
    /// Environment variables to export into the pane shell.
    pub environment: Vec<(String, String)>,
    /// Configuration fragments the platform must place.
    pub settings_fragments: Vec<SettingsFragment>,
}

#[cfg(test)]
mod tests {
    use super::*;

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
    }
}
