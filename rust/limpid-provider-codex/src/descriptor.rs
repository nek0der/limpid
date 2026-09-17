//! What the platform needs to know about Codex CLI.

use crate::PROVIDER_ID;
use limpid_agent_model::{
    Capability, InstallRecipe, ProviderDescriptor, ProviderId, RecipePlaceholder, RecipeVariable,
    SettingsFragment,
};
use serde_json::json;
use std::collections::BTreeSet;
use std::sync::OnceLock;

/// Hook events Codex is asked to call, with the timeout each definition is
/// hashed with. Codex trusts a hook by the hash of its full definition, so
/// the timeouts are part of the identity and must be stated. The two events
/// that end a session or a turn default to one second in Codex; the rest to
/// 600.
pub const SUBSCRIBED_EVENTS: [(&str, u32); 10] = [
    ("SessionStart", 600),
    ("SessionEnd", 1),
    ("UserPromptSubmit", 600),
    ("PreToolUse", 600),
    ("PostToolUse", 600),
    ("PreCompact", 600),
    ("PostCompact", 600),
    ("PermissionRequest", 600),
    ("Interrupt", 1),
    ("Stop", 600),
];

/// Regex Codex evaluates against the tool name for the worktree intercept.
pub const WORKTREE_MATCHER: &str = "^Bash$";

pub(crate) fn descriptor() -> &'static ProviderDescriptor {
    static DESCRIPTOR: OnceLock<ProviderDescriptor> = OnceLock::new();
    DESCRIPTOR.get_or_init(|| {
        let id = ProviderId::new(PROVIDER_ID).expect("static id is valid");
        ProviderDescriptor {
            display_name: "Codex".to_owned(),
            capabilities: BTreeSet::from([
                Capability::Resume,
                Capability::ResumeDefersToOtherLiveSession,
                Capability::WorktreeEvents,
                Capability::ApprovalHook,
                Capability::Subagents,
                Capability::TurnSnapshot,
            ]),
            // Codex emits no Stop when it is killed mid-turn, so the host
            // polls its pid often enough for the badge to clear promptly.
            pid_sweep_interval_ms: 3_000,
            state_directory: ProviderDescriptor::default_state_directory(&id),
            session_directory: ProviderDescriptor::default_session_directory(&id),
            cwd_events_directory: None,
            process_names: vec!["codex".to_owned(), "codex-darwin-arm64".to_owned()],
            // Empty, and unread: Codex reports `other` even for `/quit`, so it
            // has no `SessionEndDropsSession` capability and its hint always
            // survives for the next launch to resume from.
            session_end_drop_reasons: Vec::new(),
            session_end_restart_reasons: Vec::new(),
            id,
        }
    })
}

pub(crate) fn install_recipe() -> InstallRecipe {
    let events: Vec<serde_json::Value> = SUBSCRIBED_EVENTS
        .iter()
        .map(|(key, timeout)| json!({"event": key, "timeout_seconds": timeout}))
        .collect();
    InstallRecipe {
        environment: vec![
            RecipeVariable {
                name: "LIMPID_CODEX_AGENT_STATES_DIR".to_owned(),
                value: RecipePlaceholder::StateDirectory,
            },
            RecipeVariable {
                name: "LIMPID_CODEX_SESSIONS_DIR".to_owned(),
                value: RecipePlaceholder::SessionDirectory,
            },
            RecipeVariable {
                name: "LIMPID_CODEX_HOOK_ARGS".to_owned(),
                value: RecipePlaceholder::HookArguments,
            },
        ],
        settings_fragments: vec![SettingsFragment {
            target: "codex.hooks".to_owned(),
            body: json!({
                "events": events,
                "worktree_matcher": WORKTREE_MATCHER,
            })
            .to_string(),
        }],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_declares_the_codex_capabilities_and_default_directories() {
        let descriptor = descriptor();
        assert_eq!(descriptor.id.as_str(), "codex");
        assert!(descriptor.has(Capability::ResumeDefersToOtherLiveSession));
        assert!(!descriptor.has(Capability::SessionTitle));
        assert!(!descriptor.has(Capability::SessionEndDropsSession));
        assert_eq!(descriptor.state_directory, "codex-agent-states");
        assert_eq!(descriptor.session_directory, "codex-sessions");
        assert_eq!(descriptor.cwd_events_directory, None);
        assert_eq!(descriptor.pid_sweep_interval_ms, 3_000);
    }

    #[test]
    fn recipe_lists_every_subscribed_event() {
        let recipe = install_recipe();
        let body: serde_json::Value =
            serde_json::from_str(&recipe.settings_fragments[0].body).expect("JSON");
        assert_eq!(
            body["events"].as_array().map(Vec::len),
            Some(SUBSCRIBED_EVENTS.len())
        );
        assert_eq!(body["worktree_matcher"], "^Bash$");
    }
}
