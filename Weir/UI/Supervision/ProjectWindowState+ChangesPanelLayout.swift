// ProjectWindowState+ChangesPanelLayout.swift
// Weir — how a window's changes panel shares it with the terminal, worked out from the window and the tab it shows.

import CoreGraphics
import Foundation

extension ProjectWindowState {
    /// The width this window's changes panel is drawn at: the person's,
    /// else the default, within the panel's range.
    var changesPanelDrawnWidth: CGFloat {
        let range = WeirLayout.Supervision.changesPanelWidthRange
        return min(
            max(selection.changesPanelWidth ?? WeirLayout.Supervision.changesPanelDefaultWidth, range.lowerBound),
            range.upperBound
        )
    }

    /// What the layout rule reads of this window now
    /// (`ChangesPanelLayoutRule.Input`): its chrome, its body, and the pane
    /// of the tab it shows whose columns count
    /// (`ChangesPanelLayoutRule.measuredPane`), with the shown tab's panes
    /// as the person laid them out, which say whether the layout is decided
    /// again (`ChangesPanelLayoutRule.redecides`). `isAgentPane` and
    /// `cellWidth` are the app's to answer: which panes an agent runs in,
    /// and the font's cell width as a pane's surface reads it. A pane with
    /// no surface to read (the review tab covers the panes) counts by the
    /// cell width last read, which moves only with the font.
    func changesPanelLayoutReading(
        in session: WorkspaceSession,
        isAgentPane: (UUID) -> Bool,
        cellWidth: (UUID) -> CGFloat?
    ) -> ChangesPanelLayoutReading {
        let tab = session.activeTab(in: id)
        let pane = tab.flatMap { ChangesPanelLayoutRule.measuredPane(in: $0, isAgentPane: isAgentPane) }
        let isSplit = (pane?.fraction ?? 1) < 1
        let input = ChangesPanelLayoutRule.Input(
            sharedWidth: changesPanelSharedWidth,
            isPresented: selection.isChangesPanelPresented,
            current: changesPanelLayout,
            sidebarWidth: selection.sidebarHidden ? nil : sidebarDrawnWidth,
            isSidebarKept: isSidebarKeptOverPanel,
            panelWidth: changesPanelDrawnWidth,
            surfaceGap: WeirLayout.Supervision.surfaceGap,
            paneFraction: pane?.fraction,
            cellWidth: pane.flatMap { cellWidth($0.id) } ?? changesPanelCellWidth,
            // The terminal's padding on both sides, and half a divider on
            // each side of a split pane.
            paneInset: CGFloat(2 * GhosttyConfigBridge.windowPaddingX) + (isSplit ? PaneSplit.dividerThickness : 0)
        )
        return ChangesPanelLayoutReading(
            input: input,
            basis: ChangesPanelLayoutRule.Basis(input, panes: .init(tab: tab, cellWidth: input.cellWidth))
        )
    }

    /// Keeps the layout `reading` gives, when the rule decides it again
    /// (`ChangesPanelLayoutRule.redecides`), and the cell width it read.
    /// Written only when it changes, so a window whose layout holds is not
    /// redrawn. `isTabOpen` tells a tab closed under the window from one it
    /// moved away from.
    func settleChangesPanelLayout(_ reading: ChangesPanelLayoutReading, isTabOpen: (UUID) -> Bool) {
        let input = reading.input
        if let cell = input.cellWidth, cell != changesPanelCellWidth {
            changesPanelCellWidth = cell
        }
        let redecides = ChangesPanelLayoutRule.redecides(from: changesPanelLayoutBasis, to: reading.basis, isTabOpen: isTabOpen)
        changesPanelLayoutBasis = reading.basis
        guard redecides else { return }
        let next = ChangesPanelLayoutRule.layout(input)
        if changesPanelLayout != next {
            changesPanelLayout = next
        }
    }

    /// Reads the window and settles its layout in one step: what the
    /// window's follower and a switch in place both do.
    func followChangesPanelLayout(
        in session: WorkspaceSession,
        isAgentPane: (UUID) -> Bool,
        cellWidth: (UUID) -> CGFloat?
    ) {
        settleChangesPanelLayout(
            changesPanelLayoutReading(in: session, isAgentPane: isAgentPane, cellWidth: cellWidth),
            isTabOpen: { session.tab($0) != nil }
        )
    }
}

/// What the changes panel's layout is decided from
/// (`ProjectWindowState.changesPanelLayoutReading`): the rule's input, and
/// what tells whether to decide it again.
struct ChangesPanelLayoutReading: Equatable {
    let input: ChangesPanelLayoutRule.Input
    let basis: ChangesPanelLayoutRule.Basis
}
