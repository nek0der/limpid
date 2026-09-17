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
    private static func environment(
        for support: AgentTmuxSupport,
        isRequested: Bool = true,
        intake: AgentMirrorIntake = .watching(directory: URL(fileURLWithPath: "/private/tmp/requests", isDirectory: true))
    ) -> [String: String] {
        PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [],
            zdotdir: nil,
            basePath: "/usr/bin",
            agentTmux: PaneShellEnvironment.agentTmuxHost(
                hostsAgentsInTmux: isRequested,
                support: support,
                intake: intake,
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

    /// The same rule for the other half of the promise: a tmux a mirror
    /// could attach to is no use while nothing is reading the requests. Demo
    /// mode is the launch that reaches this, and an agent started there has
    /// to run in the pane rather than ask for a tab nobody opens.
    @Test(arguments: [AgentMirrorIntake.pending, .unavailable])
    func withoutAnIntake_injectsNothing(intake: AgentMirrorIntake) {
        let env = Self.environment(for: Self.version("tmux 3.5"), intake: intake)
        #expect(env["LIMPID_AGENT_TMUX"] == nil)
        #expect(env["LIMPID_AGENT_TMUX_SOCKET"] == nil)
        #expect(env[AgentMirrorRequest.directoryVariable] == nil)
    }

    @Test func settingOff_injectsNothingEvenWhenSupported() {
        let env = Self.environment(for: Self.version("tmux 3.5"), isRequested: false)
        #expect(env["LIMPID_AGENT_TMUX"] == nil)
    }

    /// The setting offers a tab, so it is only offered when a tab could be
    /// opened. A pending probe is not a refusal: it answers within a moment
    /// of launch, and a pane opened before it does just runs its agents
    /// directly.
    @Test func hostingSetting_isOfferedOnlyWhenAMirrorCouldAttach() {
        #expect(Self.version("tmux 3.5").allowsHostingSetting)
        #expect(AgentTmuxSupport.pending.allowsHostingSetting)
        #expect(!Self.version("tmux 3.2").allowsHostingSetting)
        #expect(!AgentTmuxSupport.notInstalled.allowsHostingSetting)
        #expect(!AgentTmuxSupport.unreadableVersion(binary: Self.binary).allowsHostingSetting)
    }

    /// The reasons the pane prints beside a disabled switch. English is the
    /// key, so a missing `ja` is what an untranslated reason looks like.
    @Test(arguments: [
        "No tmux found. Showing agents in a tab needs tmux %@ or newer.",
        "Limpid couldn't read the version of the tmux it found. Showing agents in a tab needs tmux %@ or newer.",
        "The tmux found is version %@. Showing agents in a tab needs %@ or newer.",
        "Show agents in a tmux tab"
    ])
    func hostingSetting_stringsAreLocalized(key: String) throws {
        let app = Bundle(for: SettingsStore.self)
        let path = try #require(app.path(forResource: "ja", ofType: "lproj"))
        let japanese = try #require(Bundle(path: path))
        #expect(japanese.localizedString(forKey: key, value: nil, table: nil) != key)
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
