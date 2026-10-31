// WorktreeOpenChoiceTests.swift
// Weir — what a new worktree opens: stored and read back, what an earlier build stored, and the first choice.

import Foundation
import Testing
@testable import Weir

struct WorktreeOpenChoiceTests {
    @Test func aChoice_readsBackAsStored() {
        for choice in [WorktreeOpenChoice.agent(.claude), .agent(.codex), .shell, .nothing] {
            #expect(WorktreeOpenChoice(stored: choice.stored) == choice)
        }
    }

    /// A value a later build wrote is no choice, and "none", an earlier
    /// build's terminal, is the shell.
    @Test func anUnknownValue_isNoChoice_andAnEarlierTerminal_isTheShell() {
        #expect(WorktreeOpenChoice(stored: "gemini") == nil)
        #expect(WorktreeOpenChoice(stored: nil) == nil)
        #expect(WorktreeOpenChoice(stored: "none") == .shell)
    }

    @Test func theFirstChoice_isTheFirstRememberedThatCanOpen_elseTheFirstAgent_elseTheShell() {
        #expect(WorktreeOpenChoice.initial(remembered: ["codex", "claude"], installed: [.claude, .codex]) == .agent(.codex))
        // An agent no longer found is passed over, not offered.
        #expect(WorktreeOpenChoice.initial(remembered: ["codex", "nothing"], installed: [.claude]) == .nothing)
        #expect(WorktreeOpenChoice.initial(remembered: [nil, "gemini"], installed: [.codex]) == .agent(.codex))
        #expect(WorktreeOpenChoice.initial(remembered: [], installed: []) == .shell)
    }

    /// Every agent of the catalog is listed, in its order, whether or not
    /// it was found; the shell and nothing come after, always available.
    @Test func theMenu_listsEveryCatalogAgent_thenTheShell_andNothing() {
        let menu = WorktreeOpenChoice.menuAgents(catalog: [.claude, .codex], installed: [.codex])
        #expect(menu.map(\.kind) == [.claude, .codex])
        #expect(menu.map(\.isAvailable) == [false, true])
        #expect(WorktreeOpenChoice.menuAgents(catalog: [], installed: [.codex]).isEmpty)
        #expect(WorktreeOpenChoice.others == [.shell, .nothing])
        #expect(WorktreeOpenChoice.agent(.claude).isAvailable(installed: []) == false)
        #expect(WorktreeOpenChoice.nothing.isAvailable(installed: []))
    }
}
