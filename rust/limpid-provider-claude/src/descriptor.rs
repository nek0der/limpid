//! What the platform needs to know about Claude Code.

use crate::PROVIDER_ID;
use limpid_agent_model::{
    Capability, InstallRecipe, ProviderDescriptor, ProviderId, RecipePlaceholder, RecipeVariable,
    SettingsFragment,
};
use std::collections::BTreeSet;
use std::sync::OnceLock;

/// The settings document the shim hands to `claude --settings`, with the
/// hook command placeholders the platform substitutes. Kept in the Swift
/// resource tree because the shim reads it from the bundle; the recipe
/// carries the same bytes so a provider is self-describing.
const SETTINGS_TEMPLATE: &str =
    include_str!("../../../Limpid/Resources/claude-shim/settings.template.json");

pub(crate) fn descriptor() -> &'static ProviderDescriptor {
    static DESCRIPTOR: OnceLock<ProviderDescriptor> = OnceLock::new();
    DESCRIPTOR.get_or_init(|| ProviderDescriptor {
        id: ProviderId::new(PROVIDER_ID).expect("static id is valid"),
        display_name: "Claude Code".to_owned(),
        capabilities: BTreeSet::from([
            Capability::SessionTitle,
            Capability::SessionEndDropsSession,
            Capability::Resume,
            Capability::CwdEvents,
            Capability::WorktreeEvents,
            Capability::ApprovalHook,
            Capability::Subagents,
            Capability::TurnSnapshot,
        ]),
        // The Claude receiver historically ran a slow sweep; Codex needs a
        // faster one because it emits no Stop when killed mid-turn.
        pid_sweep_interval_ms: 30_000,
        // Keep the names used before providers were distinguished so existing
        // on-disk records remain readable without a migration.
        state_directory: "agent-states".to_owned(),
        session_directory: "sessions".to_owned(),
        cwd_events_directory: Some("cwd-events".to_owned()),
        process_names: vec!["claude".to_owned(), "claude.exe".to_owned()],
        // The reasons Claude reports when the user ended the session rather
        // than the process going away under it. A signal, or a reason this
        // build does not know, keeps the hint so the next launch can resume.
        session_end_drop_reasons: ["clear", "logout", "exit", "prompt_input_exit", "quit"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
    })
}

pub(crate) fn install_recipe() -> InstallRecipe {
    InstallRecipe {
        environment: vec![
            RecipeVariable {
                name: "LIMPID_AGENT_STATES_DIR".to_owned(),
                value: RecipePlaceholder::StateDirectory,
            },
            RecipeVariable {
                name: "LIMPID_SESSIONS_DIR".to_owned(),
                value: RecipePlaceholder::SessionDirectory,
            },
            RecipeVariable {
                name: "LIMPID_CWD_EVENTS_DIR".to_owned(),
                value: RecipePlaceholder::CwdEventsDirectory,
            },
            RecipeVariable {
                name: "LIMPID_CLAUDE_HOOK_NAMESPACE".to_owned(),
                value: RecipePlaceholder::BundleId,
            },
        ],
        settings_fragments: vec![SettingsFragment {
            target: "claude.settings".to_owned(),
            body: SETTINGS_TEMPLATE.to_owned(),
        }],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptor_declares_the_claude_capabilities_and_legacy_directories() {
        let descriptor = descriptor();
        assert_eq!(descriptor.id.as_str(), "claude");
        assert!(descriptor.has(Capability::SessionTitle));
        assert!(descriptor.has(Capability::CwdEvents));
        assert!(!descriptor.has(Capability::ResumeDefersToOtherLiveSession));
        assert_eq!(descriptor.state_directory, "agent-states");
        assert_eq!(
            descriptor.cwd_events_directory.as_deref(),
            Some("cwd-events")
        );
        assert_eq!(descriptor.pid_sweep_interval_ms, 30_000);
    }

    #[test]
    fn recipe_carries_the_hook_template() {
        let recipe = install_recipe();
        let template: serde_json::Value =
            serde_json::from_str(&recipe.settings_fragments[0].body).expect("template is JSON");
        assert!(template["hooks"]["PermissionRequest"].is_array());
        // Named by placeholder rather than by token text: a typo in the token
        // used to compile, install, and leave the agent reporting to nothing.
        let state = recipe
            .environment
            .iter()
            .find(|variable| variable.value == RecipePlaceholder::StateDirectory)
            .expect("a state directory variable");
        assert_eq!(state.name, "LIMPID_AGENT_STATES_DIR");
    }
}
