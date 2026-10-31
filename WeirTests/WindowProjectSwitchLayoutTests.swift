// WindowProjectSwitchLayoutTests.swift
// Weir — a switch to another project keeps the changes panel's layout and the folded sidebar; a resize or a split decides again.

import CoreGraphics
import Foundation
import Testing
@testable import Weir

/// Switching projects does not move the sidebars. The automatic fold is
/// decided again only as the window is resized, the shown tab's panes are
/// split or closed, or the person acts on the sidebar or the panel.
extension WindowProjectSwitchTests {
    /// Follows the window's layout as its view and a switch in place do,
    /// every pane at `cell` points a column and none an agent's.
    fileprivate static func follow(_ window: ProjectWindowState, in session: WorkspaceSession, cell: CGFloat) {
        window.followChangesPanelLayout(in: session, isAgentPane: { _ in false }, cellWidth: { _ in cell })
    }

    /// The layout the rule gives `window` as it stands, whatever was
    /// decided before.
    fileprivate static func freshLayout(_ window: ProjectWindowState, in session: WorkspaceSession, cell: CGFloat) -> ChangesPanelLayout {
        ChangesPanelLayoutRule.layout(window.changesPanelLayoutReading(
            in: session,
            isAgentPane: { _ in false },
            cellWidth: { _ in cell }
        ).input)
    }

    /// The primary with the panel open at 1200 points of shared width and 6
    /// point cells, `b`'s tab split in two side by side: `a`'s one pane keeps
    /// 100 columns once the sidebar folds, and `b`'s halves keep them in no
    /// layout. Laid out on `a`.
    fileprivate static func splitProjectFixture() throws -> Fixture {
        let fixture = Fixture()
        let window = fixture.primary
        window.changesPanelSharedWidth = 1200
        window.selection.isChangesPanelPresented = true
        fixture.registry.onDidSwitchProject = { follow($0, in: fixture.session, cell: 6) }
        fixture.choose(fixture.bTab, in: window)
        PaneActions.split(fixture.session, direction: .horizontal, in: window.id)
        try #require(freshLayout(window, in: fixture.session, cell: 6) == .overlay)
        fixture.choose(fixture.aTab, in: window)
        window.changesPanelLayoutBasis = nil
        follow(window, in: fixture.session, cell: 6)
        try #require(window.changesPanelLayout == .besideHidingSidebar)
        return fixture
    }

    @Test func switchingBetweenASplitAndASinglePaneProject_keepsTheSidebarAndThePanelAsTheyAre() throws {
        let fixture = try Self.splitProjectFixture()
        let window = fixture.primary

        fixture.choose(fixture.bTab, in: window)
        // As its view follows it once drawn.
        Self.follow(window, in: fixture.session, cell: 6)

        // `b` alone would lay the panel over the terminal; the switch keeps
        // the sidebar folded and the panel beside, as on `a`.
        #expect(window.selection.shownProjectID == fixture.b.id)
        #expect(window.changesPanelLayout == .besideHidingSidebar)
        #expect(window.isSidebarFoldedForChanges(isPresented: true))

        // Over the terminal, decided on `b`, the panel stays over it back
        // on `a`, whose one pane would have room beside.
        window.changesPanelSharedWidth = 1199
        Self.follow(window, in: fixture.session, cell: 6)
        #expect(window.changesPanelLayout == .overlay)
        fixture.choose(fixture.aTab, in: window)
        Self.follow(window, in: fixture.session, cell: 6)
        #expect(window.selection.shownProjectID == fixture.a.id)
        #expect(window.changesPanelLayout == .overlay)
        #expect(Self.freshLayout(window, in: fixture.session, cell: 6) == .besideHidingSidebar)
    }

    @Test func aResize_decidesTheLayoutAgain_forTheProjectShown() throws {
        let fixture = try Self.splitProjectFixture()
        let window = fixture.primary
        fixture.choose(fixture.bTab, in: window)
        #expect(window.changesPanelLayout == .besideHidingSidebar)

        window.changesPanelSharedWidth = 1201
        Self.follow(window, in: fixture.session, cell: 6)

        #expect(window.changesPanelLayout == .overlay)
    }

    @Test func aSplitInTheProjectShown_decidesTheLayoutAgain() throws {
        let fixture = try Self.splitProjectFixture()
        let window = fixture.primary

        PaneActions.split(fixture.session, direction: .horizontal, in: window.id)
        Self.follow(window, in: fixture.session, cell: 6)

        #expect(window.selection.shownProjectID == fixture.a.id)
        #expect(window.changesPanelLayout == .overlay)
    }

    @Test func switchingProject_withThePanelClosed_decidesWhereItWillOpen_beforeTheWindowDraws() throws {
        let fixture = try Self.splitProjectFixture()
        let window = fixture.primary
        window.selection.isChangesPanelPresented = false
        Self.follow(window, in: fixture.session, cell: 6)

        fixture.choose(fixture.bTab, in: window)

        // Decided by the switch itself, with no view to follow it: nothing
        // of a closed panel is on screen to move.
        #expect(window.changesPanelLayout == .overlay)
        #expect(window.changesPanelCellWidth == 6)
    }
}
