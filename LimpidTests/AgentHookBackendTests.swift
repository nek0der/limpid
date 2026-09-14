// AgentHookBackendTests.swift
// Limpid — pins which receiver a new pane gets. The bundled `limpid-hook`
// wrappers default to the Rust runtime on their own, so the value only
// matters because it travels with the pane: a pane that started without
// `LIMPID_AGENT_HOOK_BACKEND` would follow the wrapper of whichever build
// happens to be installed when its next event fires, instead of staying on
// the backend it began with. These tests fail if the variable stops being
// exported or silently flips to the rollback value.

import Foundation
import Testing
@testable import Limpid

/// `CodexHookInstaller.environment()` returns nothing in demo mode by
/// design, so we skip rather than assert against the developer's shell.
/// It sits outside the suite because a trait that reads a static member of
/// the type it is attached to makes the macro expansion circular.
private func isRunningInDemoMode() -> Bool {
    ProcessInfo.processInfo.environment["LIMPID_DEMO"] == "1"
}

@Suite("Agent hook backend")
struct AgentHookBackendTests {
    @Test("ships the Rust runtime as the default receiver")
    func current_isRust() {
        #expect(AgentHookBackend.current == .rust)
        #expect(AgentHookBackend.environment[AgentHookBackend.environmentKey] == "rust")
    }

    @Test("exports the backend to a Claude pane")
    func claudeEnvironment_carriesTheBackend() {
        let env = ClaudeShimLocator.environment(forPaneID: UUID())
        #expect(env[AgentHookBackend.environmentKey] == "rust")
    }

    /// The installer is constructed with an injected hook script so the test
    /// does not depend on the test host carrying the bundled resource: the
    /// only thing under test is that the backend survives the merge.
    @Test("exports the backend to a Codex pane", .disabled(if: isRunningInDemoMode(), "demo mode returns no environment"))
    @MainActor
    func codexEnvironment_carriesTheBackend() throws {
        try withTempDir { directory in
            let script = directory.appendingPathComponent("limpid-hook")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
            let installer = CodexHookInstaller(hookScriptURL: script)
            let env = installer.environment()
            #expect(env[AgentHookBackend.environmentKey] == "rust")
        }
    }
}
