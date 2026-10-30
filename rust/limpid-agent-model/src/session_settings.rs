//! The model a session runs and how freely it may act, as the provider's
//! hooks report them.
//!
//! Both agents say so on most hook calls: Codex sends `model` and
//! `permission_mode` on nearly every event, and Claude sends
//! `permission_mode` on most events and the model on `SessionStart` and
//! `PostModelSwitch`. Neither sends a hook when the person changes the mode
//! between turns, so a change shows with the next call that carries it.

use serde::{Deserialize, Serialize};

/// How freely the agent may act without asking, in Claude Code's words for
/// it, which Codex's hooks use too. Codex maps its approval policy onto two
/// of them: `bypassPermissions` for a policy that never asks, `default` for
/// every other.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionMode {
    /// The agent asks before each action its settings do not allow.
    Default,
    /// File edits go ahead without asking; other actions still ask.
    AcceptEdits,
    /// The agent plans and makes no change.
    Plan,
    /// A classifier decides each action, asking or stopping the risky ones.
    Auto,
    /// Actions its settings do not allow are refused rather than asked.
    DontAsk,
    /// Every action goes ahead without asking.
    BypassPermissions,
}

impl PermissionMode {
    /// The provider's `permission_mode` word; `None` for a word this build
    /// does not know, so a mode it cannot describe is not shown as another.
    #[must_use]
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "default" => Some(Self::Default),
            "acceptEdits" => Some(Self::AcceptEdits),
            "plan" => Some(Self::Plan),
            "auto" => Some(Self::Auto),
            "dontAsk" => Some(Self::DontAsk),
            "bypassPermissions" => Some(Self::BypassPermissions),
            _ => None,
        }
    }
}

/// What one hook call says of the session's settings. `None` means "not
/// said", never "cleared": the record keeps the value it has.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionSettings {
    /// The model, as the adapter names it for a person to read.
    pub model: Option<String>,
    pub permission_mode: Option<PermissionMode>,
}

impl SessionSettings {
    /// Whether the call said nothing of either.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.model.is_none() && self.permission_mode.is_none()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_word_parses_back_to_the_mode_it_is_written_as() {
        for mode in [
            PermissionMode::Default,
            PermissionMode::AcceptEdits,
            PermissionMode::Plan,
            PermissionMode::Auto,
            PermissionMode::DontAsk,
            PermissionMode::BypassPermissions,
        ] {
            let word = serde_json::to_value(mode).unwrap();
            assert_eq!(PermissionMode::parse(word.as_str().unwrap()), Some(mode));
        }
    }

    #[test]
    fn a_word_this_build_does_not_know_is_no_mode() {
        assert_eq!(PermissionMode::parse("yolo"), None);
    }
}
