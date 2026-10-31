// ChangesPanelLayoutRule.swift
// Weir — where the changes panel goes so the terminal keeps 100 columns.

import CoreGraphics
import Foundation

/// How the changes panel shares the window with the terminal.
enum ChangesPanelLayout: Equatable, Sendable {
    /// Beside the terminal, which keeps 100 columns or more.
    case beside
    /// Beside the terminal with the sidebar folded for now, which the
    /// session header says; closing the panel brings the sidebar back.
    case besideHidingSidebar
    /// Laid over the terminal, whose columns do not change: even without
    /// the sidebar there is no room beside it.
    case overlay
}

/// The rule: the panel stands beside the terminal while the terminal
/// keeps 100 columns; failing that the sidebar folds first; failing that
/// too, the panel is laid over the terminal.
///
/// Columns are worked out for each layout from the font's cell width and
/// the pane's share of the terminal area, not read off the grid: the grid
/// is reported a moment after a resize, and a width divided by a grid of
/// another width would push the panel from one layout to the next. The
/// pane is the narrowest agent's in the tab, so moving the focus does not
/// move the panel.
enum ChangesPanelLayoutRule {
    static let minimumColumns = 100
    /// A layout that takes more from the terminal than the one on screen
    /// needs a little to spare, so a width at the boundary does not move
    /// the panel back and forth on a rounding.
    static let marginColumns = 2

    struct Input: Equatable, Sendable {
        /// What the sidebar, the terminal area, and the panel share: the
        /// window's body less its rails, the same width whatever the
        /// layout. Measured that way, a layout just written is
        /// read against the width it was chosen for, and choosing again
        /// gives the same answer. It holds the gaps between the surfaces;
        /// `sidebarWidth` and `panelWidth` do not, and `surfaceGap` says
        /// what each takes besides.
        var sharedWidth: CGFloat
        /// What is on screen now: whether the panel is open, and how. Only
        /// for the margin.
        var isPresented: Bool
        var current: ChangesPanelLayout
        /// The sidebar's width while the person shows it, `nil` while they
        /// hide it.
        var sidebarWidth: CGFloat?
        /// Whether the person asked for the sidebar while the panel had
        /// folded it (⌘B, its rail button): it stays, and the panel goes
        /// over the terminal if it must.
        var isSidebarKept: Bool
        var panelWidth: CGFloat
        /// The gap between two surfaces: the sidebar and the panel
        /// beside the terminal each take one with their width. The panel
        /// over the terminal takes none.
        var surfaceGap: CGFloat
        /// The measured pane's share of the terminal area, its cell width,
        /// and what of its width is not cells (padding); `nil` until known.
        var paneFraction: CGFloat?
        var cellWidth: CGFloat?
        var paneInset: CGFloat
    }

    /// The layout the panel takes when open: the one drawn while that
    /// still holds, and the one it would open in while it is closed.
    static func layout(_ input: Input) -> ChangesPanelLayout {
        // Until the cells and the body have been measured (a window just
        // restored), the layout stays rather than move once they are.
        guard let fraction = input.paneFraction, let cell = input.cellWidth, fraction > 0, cell > 0, input.sharedWidth > 0 else {
            return input.current
        }
        func fits(_ layout: ChangesPanelLayout) -> Bool {
            let area = input.sharedWidth - taken(layout, input: input)
            let columns = Int(((area * fraction - input.paneInset) / cell).rounded(.down))
            let isNarrower = input.isPresented && rank(layout) < rank(input.current)
            return columns >= minimumColumns + (isNarrower ? marginColumns : 0)
        }
        if input.sidebarWidth != nil, !input.isSidebarKept {
            if fits(.beside) {
                return .beside
            }
            return fits(.besideHidingSidebar) ? .besideHidingSidebar : .overlay
        }
        return fits(.beside) ? .beside : .overlay
    }

    /// The shown tab as the person laid it out: which tab, its splits and
    /// its zoom, and the cell width its measured pane reads. Which pane
    /// has the keyboard is left out: moving the focus never moves the
    /// panel.
    struct ShownPanes: Equatable {
        var tabID: UUID?
        var root: PaneNode?
        var zoomedLeafID: UUID?
        var cellWidth: CGFloat?

        init(tab: Tab?, cellWidth: CGFloat?) {
            tabID = tab?.id
            root = tab?.splitTree.root
            zoomedLeafID = tab?.zoomedLeafID
            self.cellWidth = cellWidth
        }
    }

    /// What a layout is decided against, less what only follows from it:
    /// the window's body, the sidebar and the panel as the person set
    /// them, and the shown tab's panes (`redecides`).
    struct Basis: Equatable {
        var sharedWidth: CGFloat
        var isPresented: Bool
        var sidebarWidth: CGFloat?
        var isSidebarKept: Bool
        var panelWidth: CGFloat
        var panes: ShownPanes

        init(_ input: Input, panes: ShownPanes) {
            sharedWidth = input.sharedWidth
            isPresented = input.isPresented
            sidebarWidth = input.sidebarWidth
            isSidebarKept = input.isSidebarKept
            panelWidth = input.panelWidth
            self.panes = panes
        }
    }

    /// Whether the layout of the open panel is decided again, going from
    /// what it was last decided against, `old`, to `new`. Moving to another project, workspace, or
    /// tab keeps the sidebar folded or not and the panel beside or over
    /// the terminal as they are: the sidebars are the window's, and a
    /// window whose chrome moved with each switch, because one project's
    /// tab is split and another's is not, read as the window rearranging
    /// itself. The layout is decided again when the window is resized, the
    /// person acts on the sidebar or the panel, or the shown tab's panes
    /// change in place: a split, a pane closed (its tab with it, when it
    /// was the last), a divider moved, a zoom, the font's size. A closed
    /// panel follows everything: nothing of it is on screen to move, and
    /// it opens straight into its place.
    static func redecides(from old: Basis?, to new: Basis, isTabOpen: (UUID) -> Bool) -> Bool {
        guard let old, new.isPresented else { return true }
        var chrome = old
        chrome.panes = new.panes
        if chrome != new {
            return true
        }
        guard old.panes != new.panes else { return false }
        if old.panes.tabID == new.panes.tabID {
            // The same tab, its panes changed in place.
            return true
        }
        // Another tab: a move, unless the tab shown before was closed.
        guard let oldTab = old.panes.tabID else { return false }
        return !isTabOpen(oldTab)
    }

    /// The pane of `tab` whose columns count, with its share of the
    /// terminal area: the zoomed one, else the narrowest of the tab's
    /// agents (the TUIs the 100 columns are for), else the narrowest of
    /// all. Never the focused one as such, so moving the focus does not
    /// move the panel.
    static func measuredPane(in tab: Tab, isAgentPane: (UUID) -> Bool) -> (id: UUID, fraction: CGFloat)? {
        if let zoomed = tab.zoomedLeafID {
            return (zoomed, 1)
        }
        let leaves = tab.splitTree.allLeafIDs()
        let agents = leaves.filter(isAgentPane)
        return (agents.isEmpty ? leaves : agents)
            .compactMap { leaf in tab.splitTree.widthFraction(of: leaf).map { (id: leaf, fraction: $0) } }
            .min { $0.fraction < $1.fraction }
    }

    /// The width a layout of the open panel takes from the terminal area,
    /// each surface with the gap that parts it from the terminal's.
    private static func taken(_ layout: ChangesPanelLayout, input: Input) -> CGFloat {
        let sidebar = input.sidebarWidth.map { $0 + input.surfaceGap } ?? 0
        let panel = input.panelWidth + input.surfaceGap
        switch layout {
        case .beside: return panel + sidebar
        case .besideHidingSidebar: return panel
        case .overlay: return sidebar
        }
    }

    /// How much a layout takes from the terminal: the panel and the sidebar
    /// beside it, the panel alone, or at most the sidebar, the panel lying
    /// over the terminal.
    private static func rank(_ layout: ChangesPanelLayout) -> Int {
        switch layout {
        case .beside: 0
        case .besideHidingSidebar: 1
        case .overlay: 2
        }
    }
}
