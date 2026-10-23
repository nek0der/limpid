// PaneShellEnvironmentTests.swift
// Limpid — pins the env every pty inherits regardless of which agent runs
// in it. The behavior lived in `ClaudeShimLocator`, which resolves its
// paths from `Bundle.main` and so could not be exercised from a test
// bundle at all; taking the values as arguments is what makes these
// assertions possible.

import Foundation
import Testing
@testable import Limpid

@Suite("PaneShellEnvironment")
struct PaneShellEnvironmentTests {
    private let base = "/usr/bin:/bin"

    /// With no pane, no shim directory, and no agent tmux, every optional
    /// variable is left out: a bundle without the shim resources (the test
    /// target's own case) leaves the person's PATH untouched rather than
    /// with an empty leading entry, and the shims host in tmux only when
    /// the tmux variables are there, so they are absent, not empty, with
    /// the setting off.
    @Test("the least input sets no optional variable")
    func variables_leastInput_setsNoOptionalVariable() {
        let env = PaneShellEnvironment.variables(
            paneID: nil, shimDirectories: [], zdotdir: nil, basePath: base
        )
        for key in ["PATH", "LIMPID_PANE_ID", "ZDOTDIR", "LIMPID_AGENT_TMUX", "LIMPID_AGENT_TMUX_SOCKET"] {
            #expect(env[key] == nil, "\(key)")
        }
    }

    @Test("prepends every shim directory to PATH, in order")
    func variables_prependsShimDirectories() {
        let env = PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
            zdotdir: nil,
            basePath: base
        )
        #expect(env["PATH"] == "/a:/b:\(base)")
    }

    @Test("carries the pane id and the startup-file redirect")
    func variables_carriesPaneIDAndZdotdir() {
        let id = UUID()
        let env = PaneShellEnvironment.variables(
            paneID: id,
            shimDirectories: [],
            zdotdir: URL(fileURLWithPath: "/z"),
            basePath: base
        )
        #expect(env["LIMPID_PANE_ID"] == id.uuidString)
        #expect(env["ZDOTDIR"] == "/z")
    }

    /// The shims test one variable to decide whether to host the agent
    /// in tmux, so it has to be absent — not empty — when the setting is
    /// off. The socket name rides along because the server has to be
    /// ours alone: a session created on an existing server inherits that
    /// server's environment, so a Debug build sharing a Release build's
    /// server would write its records into the Release directories.
    @Test("carries the tmux binary and socket when the agent is hosted")
    func variables_carriesAgentTmuxHost() {
        let env = PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [],
            zdotdir: nil,
            basePath: base,
            agentTmux: .init(binary: "/opt/homebrew/bin/tmux", socketName: "limpid-x")
        )
        #expect(env["LIMPID_AGENT_TMUX"] == "/opt/homebrew/bin/tmux")
        #expect(env["LIMPID_AGENT_TMUX_SOCKET"] == "limpid-x")
    }

    /// Namespaced so two builds never share a server; see above.
    @Test("names the socket after the running build")
    func defaultAgentSocketName_isNamespaced() {
        let name = PaneShellEnvironment.defaultAgentSocketName()
        #expect(name.hasPrefix("limpid-"))
        #expect(name != "limpid-unknown")
    }

    @Test func aPanesEnvironment_namesTheRecord_onlyWhenGivenOne() {
        let record = URL(fileURLWithPath: "/tmp/limpid-test/pane-path.txt")
        let with = PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [],
            zdotdir: nil,
            basePath: base,
            panePathRecord: record
        )
        #expect(with[AgentCatalog.panePathRecordVariable] == record.path)
        let without = PaneShellEnvironment.variables(paneID: nil, shimDirectories: [], zdotdir: nil, basePath: base)
        #expect(without[AgentCatalog.panePathRecordVariable] == nil)
    }

    /// A pane's `PATH` can hold its own folders (`$PWD/bin`), so each
    /// project's panes write their own record, the one the sheet reads for
    /// that project alone; a scratch pane, in no project, writes none.
    /// Otherwise one project's `bin/claude` could be started in another.
    @Test func eachProjectsPanes_recordTheirOwnPath_andAScratchPaneNone() {
        let first = UUID()
        let second = UUID()
        let record = { (project: UUID?) in
            PaneShellEnvironment.resolved(forPaneID: nil, recordsPanePath: true, projectID: project)[
                AgentCatalog.panePathRecordVariable
            ]
        }
        let directory = LimpidPaths.applicationSupportDirectory()
        #expect(record(first) == AgentCatalog.panePathRecordURL(in: directory, project: first).path)
        #expect(record(first) != record(second))
        #expect(record(nil) == nil)
        #expect(PaneShellEnvironment.resolved(forPaneID: nil, recordsPanePath: false, projectID: first)[
            AgentCatalog.panePathRecordVariable
        ] == nil)
    }
}
