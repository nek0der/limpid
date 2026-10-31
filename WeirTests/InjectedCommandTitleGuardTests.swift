// InjectedCommandTitleGuardTests.swift
// Weir — the shell's title for a command Weir typed is not taken for the pane's name until the command finishes.

import Foundation
import Testing
@testable import Weir

@Suite("Injected command title guard")
@MainActor
struct InjectedCommandTitleGuardTests {
    @Test("the shell title for an injected command is left off every time it is reported")
    func injectedCommandTitle_matchingTitle_isLeftOffAgain() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("cd '/work' && claude --resume session")
        let firstMatch = guardState.matches("cd '/work' && claude --resume session")
        let repeatedMatch = guardState.matches("cd '/work' && claude --resume session")

        #expect(firstMatch)
        #expect(repeatedMatch)
    }

    @Test("a late prompt title cannot disarm the injected command guard")
    func injectedCommandTitle_nonmatchingPrompt_keepsGuard() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("codex resume session")
        let latePromptTitle = guardState.matches("~/dev/weir")
        let commandTitle = guardState.matches("codex resume session")

        #expect(!latePromptTitle)
        #expect(commandTitle)
    }

    @Test("a line typed to the agent meanwhile does not let the resume's title through")
    func injectedCommandTitle_laterTypedLine_keepsTheEarlierCommand() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("cd '/work' && claude --resume session")
        guardState.arm("/compact")
        #expect(guardState.matches("cd '/work' && claude --resume session"))
        #expect(guardState.matches("/compact"))
        guardState.clear()
        #expect(!guardState.matches("/compact"))
    }

    @Test("the shell's control filtering still matches a multiline injected command")
    func injectedCommandTitle_multilineCommand_matchesShellReport() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("printf first\nprintf second")
        let shellTitle = guardState.matches("printf firstprintf second")

        #expect(shellTitle)
    }

    @Test("command completion clears a guard when the shell emits no title")
    func injectedCommandTitle_commandFinished_clearsGuard() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("codex resume session")
        guardState.clear()
        let laterTitle = guardState.matches("codex resume session")

        #expect(!laterTitle)
    }

    @Test("router sanitization is shared by the command and received title")
    func injectedCommandTitle_sanitizedInput_stillMatches() {
        var guardState = InjectedCommandTitleGuard()
        guardState.arm("cd '/tmp/zero\u{200B}' && claude --resume session")
        let sanitizedTitle = guardState.matches("cd '/tmp/zero' && claude --resume session")

        #expect(sanitizedTitle)
    }

    @Test(
        "a command Weir types by any path is guarded until the command finishes",
        .tags(.ffi),
        .enabled("libghostty is unavailable") { await GhosttyAvailability.isAvailable() }
    )
    @MainActor
    func typedOwnCommand_guardsItsTitle_untilTheCommandFinishes() throws {
        let ghosttyApp = try #require(GhosttyApp.placeholder.target)
        let view = PaneHostRepresentable.makeSurfaceView(ghosttyApp: ghosttyApp, environment: [:])
        let command = "cd '/work' && claude --resume session"
        #expect(!view.isInjectedCommandTitle(command))
        view.noteTypedOwnCommand(command)
        #expect(view.isInjectedCommandTitle(command))
        #expect(!view.isInjectedCommandTitle("~/work"))
        view.clearInjectedCommandTitleGuard()
        #expect(!view.isInjectedCommandTitle(command))
    }
}
