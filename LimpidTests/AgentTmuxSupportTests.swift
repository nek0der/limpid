// AgentTmuxSupportTests.swift
// Limpid — a pane is told to host its agents in tmux only when a mirror tab
// could show them.

import Foundation
import Synchronization
import Testing
@testable import Limpid

@Suite("AgentTmuxSupport")
struct AgentTmuxSupportTests {
    private static let binary = "/opt/homebrew/bin/tmux"

    private static func version(_ text: String) -> AgentTmuxSupport {
        AgentTmuxSupport.evaluate(binary: binary, versionOutput: .success(text))
    }

    /// The variables a pane gets for `support` with the setting on.
    private static func environment(for support: AgentTmuxSupport, isRequested: Bool = true) -> [String: String] {
        PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [],
            zdotdir: nil,
            basePath: "/usr/bin",
            agentTmux: PaneShellEnvironment.agentTmuxHost(
                hostsAgentsInTmux: isRequested,
                support: support,
                socketName: "limpid-test"
            )
        )
    }

    @Test(arguments: ["tmux 3.3", "tmux 3.3a", "tmux 3.5", "tmux next-3.4", "tmux 4.0"])
    func supportedVersion_injectsTheHost(output: String) {
        let env = Self.environment(for: Self.version(output))
        #expect(env["LIMPID_AGENT_TMUX"] == Self.binary)
        #expect(env["LIMPID_AGENT_TMUX_SOCKET"] == "limpid-test")
    }

    /// A development build sorts with the release it precedes, so `next-3.3`
    /// is a 3.3 and passes, while `next-3.2` does not.
    @Test(arguments: ["tmux 3.2a", "tmux 3.2", "tmux 2.9", "tmux next-3.2"])
    func olderVersion_injectsNothing(output: String) {
        let support = Self.version(output)
        guard case .unsupported = support else {
            Issue.record("expected unsupported, got \(support)")
            return
        }
        let env = Self.environment(for: support)
        #expect(env["LIMPID_AGENT_TMUX"] == nil)
        #expect(env["LIMPID_AGENT_TMUX_SOCKET"] == nil)
    }

    @Test(arguments: [
        TmuxCommandResult.success("tmux master"),
        .success(""),
        .failed(1),
        .timedOut,
        .launchFailed
    ])
    func unreadableVersion_injectsNothing(result: TmuxCommandResult) {
        let support = AgentTmuxSupport.evaluate(binary: Self.binary, versionOutput: result)
        #expect(support == .unreadableVersion(binary: Self.binary))
        #expect(Self.environment(for: support)["LIMPID_AGENT_TMUX"] == nil)
    }

    @Test func missingTmux_injectsNothing() {
        let support = AgentTmuxSupport.evaluate(binary: nil, versionOutput: nil)
        #expect(support == .notInstalled)
        #expect(Self.environment(for: support)["LIMPID_AGENT_TMUX"] == nil)
    }

    /// A pane created before the probe answers must not be told to host:
    /// nothing yet says a tab could be opened for its agent.
    @Test func pendingProbe_injectsNothing() {
        let env = Self.environment(for: .pending)
        #expect(env["LIMPID_AGENT_TMUX"] == nil)
        #expect(env["LIMPID_AGENT_TMUX_SOCKET"] == nil)
    }

    @Test func settingOff_injectsNothingEvenWhenSupported() {
        let env = Self.environment(for: Self.version("tmux 3.5"), isRequested: false)
        #expect(env["LIMPID_AGENT_TMUX"] == nil)
    }

    @Test func probe_readsTheVersionOfTheLocatedBinary() async {
        let asked = Mutex<[String]>([])
        let support = await AgentTmuxSupport.probe(
            locate: { Self.binary },
            readVersion: { binary in
                asked.withLock { $0.append(binary) }
                return .success("tmux 3.4\n")
            }
        )
        #expect(support == .supported(
            binary: Self.binary,
            version: TmuxVersion(major: 3, minor: 4, patch: nil, isDevelopment: false)
        ))
        #expect(asked.withLock { $0 } == [Self.binary])
    }

    @Test func probe_withoutTmux_startsNoProcess() async {
        let asked = Mutex(false)
        let support = await AgentTmuxSupport.probe(
            locate: { nil },
            readVersion: { _ in
                asked.withLock { $0 = true }
                return .launchFailed
            }
        )
        #expect(support == .notInstalled)
        #expect(!asked.withLock { $0 })
    }
}
