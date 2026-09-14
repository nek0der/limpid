//! The neutral event vocabulary every provider adapter maps into.
//!
//! The set is the common subset of the agents' hook APIs. An event is only
//! promoted from `Extension` to a named variant when two providers emit it;
//! `CompactionFinished` is the recorded exception because it closes the
//! existing `Compacting` event rather than introducing a separate concept.

use serde::{Deserialize, Serialize};

/// Title observations a provider can attach to an event. `None` means "no
/// observation", never "cleared": the rules keep the previous value.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Titles {
    /// A title the provider or the user set explicitly.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_title: Option<String>,
    /// A title the provider generated.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generated_title: Option<String>,
}

/// One neutral event derived from one provider hook payload.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AgentEvent {
    SessionStarted {
        /// True when the provider restarted the session after compaction.
        /// A compact start preserves the first prompt and existing titles but
        /// clears the last prompt.
        compact: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_title: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    SessionEnded {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
    },
    PromptSubmitted {
        prompt: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        titles: Option<Titles>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    ToolStarted {
        tool: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    ToolFinished {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tool: Option<String>,
    },
    WaitingForInput {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    ApprovalRequested {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    Compacting {
        /// The provider's context size at the moment it compacts, when it
        /// reports one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        context_tokens: Option<u64>,
    },
    CompactionFinished,
    TurnFinished {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        titles: Option<Titles>,
    },
    Failed {
        error: String,
    },
    Interrupted,
    CwdChanged {
        new_cwd: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        old_cwd: Option<String>,
    },
    WorktreeCreated {
        repo_root: String,
        worktree_path: String,
        branch: String,
    },
    TitleChanged {
        titles: Titles,
    },
    /// A payload the adapter recognized as an event but the vocabulary does
    /// not name. Kept whole so a new provider feature is visible before the
    /// core understands it.
    Extension {
        name: String,
        payload: serde_json::Value,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_round_trip_through_json_with_a_type_tag() {
        let events = vec![
            AgentEvent::SessionStarted {
                compact: false,
                session_id: Some("s".into()),
                session_title: None,
                cwd: Some("/tmp".into()),
            },
            AgentEvent::Compacting {
                context_tokens: Some(12),
            },
            AgentEvent::TurnFinished {
                titles: Some(Titles {
                    session_title: None,
                    generated_title: Some("t".into()),
                }),
            },
            AgentEvent::Extension {
                name: "Notification".into(),
                payload: serde_json::json!({"notification_type": "idle_prompt"}),
            },
        ];
        let json = serde_json::to_string(&events).expect("serialize");
        assert!(json.contains("\"type\":\"session_started\""));
        assert!(json.contains("\"type\":\"compacting\""));
        let back: Vec<AgentEvent> = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, events);
    }

    #[test]
    fn absent_optionals_are_omitted() {
        let json = serde_json::to_string(&AgentEvent::ToolFinished { tool: None }).expect("ok");
        assert_eq!(json, "{\"type\":\"tool_finished\"}");
    }
}
