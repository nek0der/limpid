// TmuxMirrorTargetTests.swift
// Limpid — parsing of `list-windows -a` into mirror targets.

import Foundation
import Testing
@testable import Limpid

struct TmuxMirrorTargetTests {
    @Test func parse_listWindowsOutput_yieldsOneTargetPerWindow() {
        let output = """
        $0\t@0\t%0\t3.7c\t4242\t1789000000\tmain\tzsh
        $0\t@1\t%3\t3.7c\t4242\t1789000000\tmain\tvim
        $1\t@2\t%5\t3.7c\t4242\t1789000000\twork space\tname with\ttab
        """
        let targets = TmuxMirrorTargetLister.parse(output, socketPath: "/tmp/tmux-501/default")

        #expect(targets.count == 3)
        #expect(targets[0].binding.sessionID == "$0")
        #expect(targets[0].binding.sessionName == "main")
        #expect(targets[0].windowID == "@0")
        #expect(targets[0].activePaneID == "%0")
        #expect(targets[1].displayName == "main:vim")
        // The window name is the last field, so a tab inside it is kept.
        #expect(targets[2].windowName == "name with\ttab")
        #expect(targets[2].binding.sessionName == "work space")
        #expect(targets[2].binding.socketPath == "/tmp/tmux-501/default")
    }

    @Test func parse_recordsTheServerGenerationAndVersion() throws {
        let output = "$0\t@0\t%0\t3.7c\t4242\t1789000000\tmain\tzsh"
        let target = try #require(TmuxMirrorTargetLister.parse(output, socketPath: "/tmp/s").first)

        #expect(target.binding.serverPID == "4242")
        #expect(target.binding.serverStartedAt == "1789000000")
        #expect(target.serverVersion == TmuxProtocol.parseVersion("3.7c"))
    }

    /// tmux expands an unknown format variable to an empty string, so a
    /// server without these fields still lists its windows. The window is
    /// kept, with nothing recorded, for the palette to show as unavailable.
    @Test func parse_serverWithoutVersionOrGeneration_keepsTheWindowUnplaced() {
        let output = "$0\t@0\t%0\t\t\t\tmain\tzsh"
        let targets = TmuxMirrorTargetLister.parse(output, socketPath: "/tmp/s")

        #expect(targets.count == 1)
        #expect(targets.first?.serverVersion == nil)
        #expect(targets.first?.binding.serverPID == nil)
        #expect(targets.first?.binding.serverStartedAt == nil)
    }

    @Test func parse_halfAGeneration_recordsNeitherHalf() {
        let output = """
        $0\t@0\t%0\t3.7c\t4242\t\tmain\tzsh
        $0\t@1\t%1\t3.7c\tpid\t1789000000\tmain\tvim
        """
        let targets = TmuxMirrorTargetLister.parse(output, socketPath: "/tmp/s")

        #expect(targets.count == 2)
        for target in targets {
            #expect(target.binding.serverPID == nil)
            #expect(target.binding.serverStartedAt == nil)
        }
    }

    @Test func parse_rejectsLinesThatAreNotWindowRecords() {
        let output = """
        no tabs here
        \t\t\t\t\t\t\t
        $0\t@0\t%0\tmain\tzsh
        $0\tmain\t@0\t3.7c\t1\t2\tzsh\t%0
        """
        #expect(TmuxMirrorTargetLister.parse(output, socketPath: "/tmp/s").isEmpty)
    }

    @Test func agentSockets_ofEveryBuild_areRecognized() {
        #expect(PaneShellEnvironment.isAgentSocketName("limpid-dev.limpid.Limpid"))
        #expect(PaneShellEnvironment.isAgentSocketName("limpid-dev.limpid.Limpid.dev"))
        #expect(PaneShellEnvironment.isAgentSocketName(PaneShellEnvironment.defaultAgentSocketName()))
        #expect(!PaneShellEnvironment.isAgentSocketName("default"))
        #expect(!PaneShellEnvironment.isAgentSocketName("limpid-verify"))
    }

    @Test func frecencyKey_isStablePerWindow() {
        let binding = TmuxBinding(socketPath: "/tmp/s", sessionID: "$0", sessionName: "main")
        let target = TmuxMirrorTarget(binding: binding, windowID: "@4", windowName: "w", activePaneID: "%9", serverVersion: nil)
        #expect(CommandPaletteAction.mirrorTmuxWindow(target).frecencyKey == "tmux.mirror./tmp/s.@4")
    }
}

/// The listing as the palette runs it, against a real server. This is the
/// only place the format string meets tmux: a misspelled variable, or
/// output whose tabs tmux replaced, lists nothing, and no parse test with
/// hand-written input can see either.
@Suite(
    "tmux window listing",
    .tags(.smoke),
    .disabled(if: TmuxServerFixture.isUnavailable, "tmux is not installed")
)
struct TmuxMirrorTargetListingTests {
    @Test func targets_fromARealServer_carryItsVersionAndGeneration() throws {
        let server = try TmuxServerFixture.launch(windows: 2)
        defer { server.tearDown() }

        let targets = TmuxMirrorTargetLister.targets(
            tmuxPath: server.executable,
            socketPaths: [URL(fileURLWithPath: server.socketPath)]
        )

        #expect(try targets.map(\.windowID) == server.windowIDs())
        let version = try TmuxProtocol.parseVersion(server.format("#{version}"))
        let pid = try server.format("#{pid}")
        let startedAt = try server.format("#{start_time}")
        #expect(version != nil)
        for target in targets {
            #expect(target.serverVersion == version)
            #expect(target.binding.serverPID == pid)
            #expect(target.binding.serverStartedAt == startedAt)
        }
    }

    /// Without a UTF-8 locale, a client that is not told `-u` gets every tab
    /// of the format back as `_`, and no line parses.
    @Test func targets_fromAClientWithoutAUTF8Locale_stillParse() throws {
        let server = try TmuxServerFixture.launch(windows: 2)
        defer { server.tearDown() }

        let targets = try TmuxMirrorTargetLister.targets(
            tmuxPath: server.localeFreeExecutable(),
            socketPaths: [URL(fileURLWithPath: server.socketPath)]
        )

        #expect(try targets.map(\.windowID) == server.windowIDs())
        #expect(targets.allSatisfy { $0.binding.sessionName == "t" && $0.serverVersion != nil })
    }
}
