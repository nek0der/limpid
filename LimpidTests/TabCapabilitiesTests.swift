// TabCapabilitiesTests.swift
// Limpid — pins the one table that says what each kind of tab lets the user do.

import Foundation
import Testing
@testable import Limpid

@Suite("Tab capabilities")
struct TabCapabilitiesTests {
    @Test("an ordinary tab allows every pane operation and scopes font changes to one pane")
    func terminal_allowsEverything() {
        let capabilities = TabCapabilities.of(.terminal)

        #expect(capabilities.canSplit)
        #expect(capabilities.canSwap)
        #expect(capabilities.canInsert)
        #expect(capabilities.canEqualize)
        #expect(capabilities.canEqualizeSubtree)
        #expect(capabilities.canClosePane)
        #expect(capabilities.canPaste)
        #expect(capabilities.canDropFile)
        #expect(capabilities.canAcceptForeignPane)
        #expect(capabilities.canOpenReview)
        #expect(!capabilities.appliesFontToEveryPane)
    }

    @Test("a tmux mirror tab keeps the verbs tmux can perform and refuses the rest")
    func mirror_keepsOnlyTranslatableVerbs() {
        let capabilities = TabCapabilities.of(.tmuxMirror)

        // Translated to split-window, swap-pane, select-layout -E, resize-pane -Z.
        #expect(capabilities.canSplit)
        #expect(capabilities.canSwap)
        #expect(capabilities.canEqualize)
        // No tmux counterpart, or one that would mislead (design §10 D15).
        #expect(!capabilities.canInsert)
        #expect(!capabilities.canEqualizeSubtree)
        #expect(!capabilities.canClosePane)
        #expect(!capabilities.canPaste)
        #expect(!capabilities.canDropFile)
        #expect(!capabilities.canAcceptForeignPane)
        #expect(!capabilities.canOpenReview)
        // The panes share one cell grid, so a font change reaches all of them.
        #expect(capabilities.appliesFontToEveryPane)
    }

    @Test("a tab reads its capabilities from its kind")
    func tab_readsFromKind() {
        var tab = Tab(title: "t", workingDirectory: nil, pwd: nil, splitTree: SplitTree(leafID: UUID()), container: .loose)
        #expect(tab.capabilities == TabCapabilities.of(.terminal))
        tab.kind = .tmuxMirror
        #expect(tab.capabilities == TabCapabilities.of(.tmuxMirror))
    }
}
