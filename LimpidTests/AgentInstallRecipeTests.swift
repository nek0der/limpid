// AgentInstallRecipeTests.swift
// Limpid — the variables a provider says it needs, against the ones the shims
// actually carried before the recipe supplied them.
//
// A wrong name here does not fail: the agent starts, runs, and reports
// nothing, with no error on either side. So the names are pinned literally.

import Foundation
import Testing
@testable import Limpid

@Suite("AgentInstallRecipe")
struct AgentInstallRecipeTests {
    @Test("every installed provider declares a recipe")
    func recipes_coverTheInstalledProviders() {
        let recipes = AgentProviderRegistry.recipes
        #expect(recipes["claude"] != nil)
        #expect(recipes["codex"] != nil)
    }

    @Test("the resolved environment is the one the shims carried")
    func environment_matchesWhatTheShimsExported() {
        let state = URL(fileURLWithPath: "/states")
        let sessions = URL(fileURLWithPath: "/sessions")
        let cwd = URL(fileURLWithPath: "/cwd")

        let claude = AgentProviderRegistry.environment(
            for: "claude", state: state, sessions: sessions, cwdEvents: cwd
        )
        #expect(claude["LIMPID_AGENT_STATES_DIR"] == "/states")
        #expect(claude["LIMPID_SESSIONS_DIR"] == "/sessions")
        #expect(claude["LIMPID_CWD_EVENTS_DIR"] == "/cwd")
        #expect(claude["LIMPID_CLAUDE_HOOK_NAMESPACE"] == LimpidPaths.bundleID)

        let codex = AgentProviderRegistry.environment(
            for: "codex", state: state, sessions: sessions, cwdEvents: nil
        )
        #expect(codex["LIMPID_CODEX_AGENT_STATES_DIR"] == "/states")
        #expect(codex["LIMPID_CODEX_SESSIONS_DIR"] == "/sessions")
        // Codex has no cwd events, so nothing claims to point at them.
        #expect(codex.values.contains("/cwd") == false)
    }

    @Test("a provider this build does not have contributes nothing")
    func unknownProvider_yieldsNothing() {
        let environment = AgentProviderRegistry.environment(
            for: "gemini",
            state: URL(fileURLWithPath: "/states"),
            sessions: URL(fileURLWithPath: "/sessions"),
            cwdEvents: nil
        )
        #expect(environment.isEmpty)
    }
}
