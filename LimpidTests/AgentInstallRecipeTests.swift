// AgentInstallRecipeTests.swift
// Limpid — the variables a provider says it needs, against the ones the shim
// scripts read.
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

    @Test("only the provider whose hook takes arguments names a variable for them")
    func hookArgumentsVariable_isCodexOnly() {
        #expect(AgentProviderRegistry.hookArgumentsVariable(for: "codex") == "LIMPID_CODEX_HOOK_ARGS")
        // Claude's hooks carry their arguments in the settings document, so
        // there is nothing for the installer to export.
        #expect(AgentProviderRegistry.hookArgumentsVariable(for: "claude") == nil)
        #expect(AgentProviderRegistry.hookArgumentsVariable(for: "gemini") == nil)
    }

    @Test("the record directories are the ones the installers used to carry")
    func directories_matchWhatTheInstallersDeclared() throws {
        let root = URL(fileURLWithPath: "/support")
        let directories = AgentProviderRegistry.directories(under: root)

        let claude = try #require(directories["claude"])
        #expect(claude.state == root.appendingPathComponent("agent-states", isDirectory: true))
        #expect(claude.sessions == root.appendingPathComponent("sessions", isDirectory: true))
        #expect(claude.cwdEvents == root.appendingPathComponent("cwd-events", isDirectory: true))

        let codex = try #require(directories["codex"])
        #expect(codex.state == root.appendingPathComponent("codex-agent-states", isDirectory: true))
        #expect(codex.sessions == root.appendingPathComponent("codex-sessions", isDirectory: true))
        // Codex reports no cwd changes, so there is no directory to watch.
        #expect(codex.cwdEvents == nil)
    }

    @Test("the codex installer exports the directories the projection reads")
    @MainActor
    func codexInstaller_environment_pointsAtTheProjectionDirectories() throws {
        let directories = try #require(
            AgentProviderRegistry.directories(under: LimpidPaths.applicationSupportDirectory())["codex"]
        )
        let installer = CodexHookInstaller(
            hookScriptURL: URL(fileURLWithPath: "/tmp/limpid-hook")
        )

        let environment = installer.environment()

        #expect(environment["LIMPID_CODEX_AGENT_STATES_DIR"] == directories.state.path)
        #expect(environment["LIMPID_CODEX_SESSIONS_DIR"] == directories.sessions.path)
        #expect(environment["LIMPID_CODEX_HOOK_ARGS"]?.isEmpty == false)
    }

    @Test("the claude shim exports the directories the projection reads")
    func claudeShim_environment_pointsAtTheProjectionDirectories() throws {
        let directories = try #require(
            AgentProviderRegistry.directories(under: LimpidPaths.applicationSupportDirectory())["claude"]
        )

        let environment = ClaudeShimLocator.environment(forPaneID: nil)

        #expect(environment["LIMPID_AGENT_STATES_DIR"] == directories.state.path)
        #expect(environment["LIMPID_SESSIONS_DIR"] == directories.sessions.path)
        #expect(environment["LIMPID_CWD_EVENTS_DIR"] == directories.cwdEvents?.path)
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
