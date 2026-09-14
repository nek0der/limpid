//! The environment the shim sets for a pane, read as data.

use limpid_agent_model::{InstallRecipe, TmuxEndpoint};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// A snapshot of the process environment. A map rather than live lookups so
/// tests can build one and so one call sees one consistent view.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HookEnv {
    variables: BTreeMap<String, String>,
}

/// Where this provider's records go, resolved from the environment.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedDirectories {
    pub state: PathBuf,
    pub session: PathBuf,
    pub cwd_events: Option<PathBuf>,
}

impl ResolvedDirectories {
    /// Every directory that must exist before writing.
    #[must_use]
    pub fn all(&self) -> Vec<&PathBuf> {
        let mut all = vec![&self.state, &self.session];
        all.extend(self.cwd_events.as_ref());
        all
    }
}

impl HookEnv {
    /// The current process environment.
    #[must_use]
    pub fn from_process() -> Self {
        Self {
            variables: std::env::vars().collect(),
        }
    }

    /// An environment built from pairs, for tests and for the ABI, which
    /// receives the variables as JSON.
    pub fn from_pairs<I, K, V>(pairs: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        Self {
            variables: pairs
                .into_iter()
                .map(|(key, value)| (key.into(), value.into()))
                .collect(),
        }
    }

    /// One variable, when set and non-empty.
    #[must_use]
    pub fn get(&self, name: &str) -> Option<&str> {
        self.variables
            .get(name)
            .map(String::as_str)
            .filter(|value| !value.is_empty())
    }

    /// The pane id, accepted only when it is UUID-shaped (hex and dashes, at
    /// most 64 characters) so a hostile value cannot traverse directories.
    #[must_use]
    pub fn pane_id(&self) -> Option<String> {
        let value = self.get("LIMPID_PANE_ID")?;
        let shaped = value.len() <= 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() || byte == b'-');
        shaped.then(|| value.to_owned())
    }

    /// The run id the shim minted, uppercased, when it is a UUID.
    #[must_use]
    pub fn run_id(&self) -> Option<String> {
        let value = self.get("LIMPID_AGENT_RUN_ID")?;
        uuid::Uuid::parse_str(value)
            .ok()
            .map(|uuid| uuid.hyphenated().to_string().to_uppercase())
    }

    /// The directories named by the recipe's placeholders. `None` when the
    /// state directory is not set: the shim always sets it, so its absence
    /// means the agent was not launched through Limpid.
    #[must_use]
    pub fn directories(&self, recipe: &InstallRecipe) -> Option<ResolvedDirectories> {
        let named = |placeholder: &str| {
            recipe
                .environment
                .iter()
                .find(|(_, value)| value == placeholder)
                .and_then(|(name, _)| self.get(name))
                .map(PathBuf::from)
        };
        let state = named("@@STATE_DIRECTORY@@")?;
        let session = named("@@SESSION_DIRECTORY@@")?;
        Some(ResolvedDirectories {
            state,
            session,
            cwd_events: named("@@CWD_EVENTS_DIRECTORY@@"),
        })
    }

    /// The directory raw payloads are copied into for fixture recording.
    #[must_use]
    pub fn record_dir(&self) -> Option<PathBuf> {
        self.get("LIMPID_HOOK_RECORD_DIR")
            .map(PathBuf::from)
            .filter(|path| path.is_dir())
    }

    /// Whether the agent runs inside tmux, hosted or manual.
    #[must_use]
    pub fn is_tmux_hosted(&self) -> bool {
        self.get("TMUX").is_some()
    }

    /// The agent pid the shim exported (`LIMPID_<PROVIDER>_PID`), when it is
    /// a number.
    #[must_use]
    pub fn exported_pid(&self, provider_id: &str) -> Option<u32> {
        let name = format!(
            "LIMPID_{}_PID",
            provider_id.to_ascii_uppercase().replace('-', "_")
        );
        self.get(&name)?.parse().ok()
    }

    /// The tmux server and pane from `TMUX` and `TMUX_PANE`.
    #[must_use]
    pub fn tmux_endpoint(&self) -> Option<TmuxEndpoint> {
        crate::tmux::endpoint(self.get("TMUX")?, self.get("TMUX_PANE")?)
    }

    /// The path `LIMPID_HOOK_LOG` names, when set.
    #[must_use]
    pub fn log_path(&self) -> Option<PathBuf> {
        self.get("LIMPID_HOOK_LOG").map(PathBuf::from)
    }

    /// Whether turn snapshots are disabled (`LIMPID_TURN_SNAPSHOT=0`).
    #[must_use]
    pub fn turn_snapshots_disabled(&self) -> bool {
        self.get("LIMPID_TURN_SNAPSHOT") == Some("0")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pane_ids_must_look_like_uuids() {
        let env = HookEnv::from_pairs([("LIMPID_PANE_ID", "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10")]);
        assert!(env.pane_id().is_some());
        for bad in [
            "",
            "../x",
            "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F1G",
            &"a".repeat(65),
        ] {
            let env = HookEnv::from_pairs([("LIMPID_PANE_ID", bad)]);
            assert_eq!(env.pane_id(), None, "{bad:?}");
        }
    }

    #[test]
    fn run_ids_are_uppercased_and_validated() {
        let env = HookEnv::from_pairs([(
            "LIMPID_AGENT_RUN_ID",
            "6f1d6a1e-0e34-4a1a-9a8e-2f2b6c1d7f11",
        )]);
        assert_eq!(
            env.run_id().as_deref(),
            Some("6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F11")
        );
        let env = HookEnv::from_pairs([("LIMPID_AGENT_RUN_ID", "nope")]);
        assert_eq!(env.run_id(), None);
    }

    #[test]
    fn exported_pid_follows_the_provider_name() {
        let env = HookEnv::from_pairs([("LIMPID_CODEX_PID", "42"), ("LIMPID_CLAUDE_PID", "x")]);
        assert_eq!(env.exported_pid("codex"), Some(42));
        assert_eq!(env.exported_pid("claude"), None);
        assert_eq!(env.exported_pid("gemini-cli"), None);
    }
}
