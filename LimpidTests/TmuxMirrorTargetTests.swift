// TmuxMirrorTargetTests.swift
// Limpid — parsing of `list-windows -a` into mirror targets.

import Foundation
import Testing
@testable import Limpid

struct TmuxMirrorTargetTests {
    @Test func parse_listWindowsOutput_yieldsOneTargetPerWindow() {
        let output = """
        $0\t@0\t%0\tmain\tzsh
        $0\t@1\t%3\tmain\tvim
        $1\t@2\t%5\twork space\tname with\ttab
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

    @Test func parse_rejectsLinesThatAreNotWindowRecords() {
        let output = "no tabs here\n\t\t\t\t\n$0\t@0\t%0\tmain\n$0\tmain\t@0\tzsh\t%0\n"
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
        let target = TmuxMirrorTarget(binding: binding, windowID: "@4", windowName: "w", activePaneID: "%9")
        #expect(CommandPaletteAction.mirrorTmuxWindow(target).frecencyKey == "tmux.mirror./tmp/s.@4")
    }
}
