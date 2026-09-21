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
        intake: AgentMirrorIntake = .watching(directory: URL(fileURLWithPath: "/private/tmp/requests", isDirectory: true)),
        isBackFromTmux: Bool = false
    ) -> [String: String] {
        PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [],
            zdotdir: nil,
            basePath: "/usr/bin",
            agentTmux: PaneShellEnvironment.agentTmuxAnswer(
                hostsAgentsInTmux: isRequested,
                support: support,
                intake: intake,
                isBackFromTmux: isBackFromTmux,
                socketName: "limpid-test"
            ).host
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

    /// The Pane menu greys "Reconnect to tmux" out for exactly the answers
    /// the tab's card hides its Reconnect button for, and trails the item's
    /// title with the reason. A pending probe is no obstacle, as everywhere
    /// else.
    @Test func reconnectObstacle_namesEveryAnswerThatRulesAReconnectOut() {
        #expect(AgentTmuxSupport.pending.reconnectObstacle == nil)
        #expect(Self.version("tmux 3.5").reconnectObstacle == nil)
        #expect(AgentTmuxSupport.notInstalled.reconnectObstacle != nil)
        #expect(AgentTmuxSupport.unreadableVersion(binary: Self.binary).reconnectObstacle != nil)

        let old = Self.version("tmux 3.2")
        let obstacle = old.reconnectObstacle
        #expect(obstacle != nil)
        #expect(obstacle?.contains(TmuxMirrorTarget.minimumVersion.description) == true)
        // Each answer is named apart: a Mac with an old tmux must not be
        // told it has none.
        #expect(obstacle != AgentTmuxSupport.notInstalled.reconnectObstacle)
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

    /// Nor may it be told to run its agents directly while the setting is on:
    /// its environment is fixed when its shell starts, and every pane a
    /// launch restores is created before the probe answers. It waits for the
    /// answer instead, and takes whichever one comes.
    @Test func pendingAnswer_withTheSettingOn_holdsThePane() {
        let watching = AgentMirrorIntake.watching(directory: URL(fileURLWithPath: "/private/tmp/requests", isDirectory: true))
        func answer(
            _ support: AgentTmuxSupport,
            isRequested: Bool = true,
            intake: AgentMirrorIntake = watching
        ) -> PaneShellEnvironment.AgentTmuxAnswer {
            PaneShellEnvironment.agentTmuxAnswer(
                hostsAgentsInTmux: isRequested,
                support: support,
                intake: intake,
                isBackFromTmux: false,
                socketName: "limpid-test"
            )
        }
        #expect(answer(.pending) == .pending)
        #expect(answer(Self.version("tmux 3.5"), intake: .pending) == .pending)
        // With the setting off nothing is asked, so nothing is waited for.
        #expect(answer(.pending, isRequested: false) == .direct)
        // Once the answer is in, the pane takes it, whichever it is.
        #expect(answer(Self.version("tmux 3.5")) == .host(PaneShellEnvironment.AgentTmuxHost(
            binary: Self.binary,
            socketName: "limpid-test",
            mirrorRequestsDirectory: "/private/tmp/requests"
        )))
        #expect(answer(Self.version("tmux 3.2")) == .direct)
        #expect(answer(.notInstalled) == .direct)
        #expect(answer(Self.version("tmux 3.5"), intake: .unavailable) == .direct)
    }

    /// A leaf whose agent's tmux went away became a terminal that resumes the
    /// conversation, and the resume has to run there: told to host, the shim
    /// would open a second tab for it and exit successfully, so the resume
    /// command's fallback never ran and nothing was left (2026-09-19). The
    /// leaf is not held back by a pending answer either.
    @Test(arguments: [
        AgentTmuxSupport.supported(
            binary: "/opt/homebrew/bin/tmux",
            version: TmuxVersion(major: 3, minor: 5, patch: nil, isDevelopment: false)
        ),
        .pending
    ])
    func aLeafBackFromTmux_runsItsAgentsDirectly(support: AgentTmuxSupport) {
        let answer = PaneShellEnvironment.agentTmuxAnswer(
            hostsAgentsInTmux: true,
            support: support,
            intake: .watching(directory: URL(fileURLWithPath: "/private/tmp/requests", isDirectory: true)),
            isBackFromTmux: true,
            socketName: "limpid-test"
        )
        #expect(answer == .direct)
        let env = Self.environment(for: support, isBackFromTmux: true)
        #expect(env["LIMPID_AGENT_TMUX"] == nil)
        #expect(env["LIMPID_AGENT_TMUX_SOCKET"] == nil)
        #expect(env[AgentMirrorRequest.directoryVariable] == nil)
    }

    /// Every other pane, new or old, is told to host as before.
    @Test func aLeafNotBackFromTmux_isStillToldToHost() {
        let env = Self.environment(for: Self.version("tmux 3.5"), isBackFromTmux: false)
        #expect(env["LIMPID_AGENT_TMUX"] == Self.binary)
        #expect(env["LIMPID_AGENT_TMUX_SOCKET"] == "limpid-test")
        #expect(env[AgentMirrorRequest.directoryVariable] == "/private/tmp/requests")
    }

    /// Only a pane that starts a shell of its own has an environment to wait
    /// for. A mirror pane reads its channel whatever the answer.
    @Test func onlyAPaneWithItsOwnProcess_waitsForThePendingAnswer() {
        #expect(PaneHostRepresentable.waitsForShellEnvironment(backing: .ownProcess, agentTmux: .pending))
        #expect(!PaneHostRepresentable.waitsForShellEnvironment(backing: .ownProcess, agentTmux: .direct))
        #expect(!PaneHostRepresentable.waitsForShellEnvironment(backing: .noSurface, agentTmux: .pending))
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
    /// of launch, and a pane opened before it does waits for it.
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
