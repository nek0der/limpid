// ChangesPanelLayoutRuleTests.swift
// Weir — where the changes panel goes so the terminal keeps 100 columns: beside, beside without the sidebar, or over it.

import CoreGraphics
import Foundation
import Testing
@testable import Weir

@Suite("Changes panel layout rule")
struct ChangesPanelLayoutRuleTests {
    /// 8pt cells and no inset, a sidebar at 300 unless hidden, and the
    /// panel at 360: 100 columns are 800pt of terminal, so beside takes a
    /// shared width of 1460 and beside without the sidebar 1160 (with no
    /// gaps between the surfaces unless `gap` says).
    private static func input(
        shared: CGFloat,
        isPresented: Bool = false,
        current: ChangesPanelLayout = .beside,
        sidebar: CGFloat? = 300,
        isSidebarKept: Bool = false,
        fraction: CGFloat? = 1,
        cell: CGFloat? = 8,
        gap: CGFloat = 0
    ) -> ChangesPanelLayoutRule.Input {
        ChangesPanelLayoutRule.Input(
            sharedWidth: shared,
            isPresented: isPresented,
            current: current,
            sidebarWidth: sidebar,
            isSidebarKept: isSidebarKept,
            panelWidth: 360,
            surfaceGap: gap,
            paneFraction: fraction,
            cellWidth: cell,
            paneInset: 0
        )
    }

    @Test func thePanel_opensBeside_thenWithoutTheSidebar_thenOverTheTerminal() {
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1460)) == .beside)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1459)) == .besideHidingSidebar, "the sidebar folds first")
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1160)) == .besideHidingSidebar)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1159)) == .overlay, "the terminal's columns do not change")
    }

    @Test func eachSurfaceBesideTheTerminal_takesItsGapToo() {
        // 6pt gaps: beside takes 800 + 300 + 6 + 360 + 6, without the
        // sidebar 800 + 360 + 6.
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1472, gap: 6)) == .beside)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1471, gap: 6)) == .besideHidingSidebar)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1166, gap: 6)) == .besideHidingSidebar)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1165, gap: 6)) == .overlay)
        // A sidebar the person hid takes no gap; the panel still does.
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1166, sidebar: nil, gap: 6)) == .beside)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1165, sidebar: nil, gap: 6)) == .overlay)
        // Over the terminal, coming back beside counts the gap with the
        // margin: 102 columns and the panel's gap.
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1181, isPresented: true, current: .overlay, gap: 6)) == .overlay)
        #expect(ChangesPanelLayoutRule
            .layout(Self.input(shared: 1182, isPresented: true, current: .overlay, gap: 6)) == .besideHidingSidebar)
    }

    @Test func aLayoutThatTakesMore_waitsForAFewColumnsToSpare() {
        // Without the sidebar, adding it back takes 102 columns beside it.
        #expect(ChangesPanelLayoutRule
            .layout(Self.input(shared: 1475, isPresented: true, current: .besideHidingSidebar)) == .besideHidingSidebar)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1476, isPresented: true, current: .besideHidingSidebar)) == .beside)
        // Over the terminal, moving beside without the sidebar too.
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1175, isPresented: true, current: .overlay)) == .overlay, "101 columns")
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1176, isPresented: true, current: .overlay)) == .besideHidingSidebar)
        // A layout that takes less needs no margin.
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1459, isPresented: true, current: .beside)) == .besideHidingSidebar)
        // Opening, nothing is on screen to keep: no margin either.
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1460, current: .besideHidingSidebar)) == .beside)
    }

    @Test func aLayoutJustChosen_isChosenAgain() {
        // What the rule writes is read back at once, against the same width.
        for shared in stride(from: CGFloat(1000), through: 1600, by: 7) {
            for sidebar in [CGFloat(300), 400, nil] {
                let first = ChangesPanelLayoutRule.layout(Self.input(shared: shared, sidebar: sidebar))
                let again = ChangesPanelLayoutRule.layout(Self.input(shared: shared, isPresented: true, current: first, sidebar: sidebar))
                #expect(again == first, "at \(shared) with a sidebar of \(String(describing: sidebar))")
            }
        }
    }

    @Test func aSidebarThePersonHidOrKept_isNotFolded() {
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1160, sidebar: nil)) == .beside)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1159, sidebar: nil)) == .overlay)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1459, isSidebarKept: true)) == .overlay, "asked for, it stays")
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 1460, isSidebarKept: true)) == .beside)
    }

    @Test func aSplitPanesShare_countsAgainstTheRoom() {
        // A pane at half the width needs twice the area for its 100 columns.
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 2260, fraction: 0.5)) == .beside)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 2259, fraction: 0.5)) == .besideHidingSidebar)
    }

    @Test func beforeTheCellsAreKnown_theLayoutStays() {
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 100, current: .beside, cell: nil)) == .beside)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 4000, current: .overlay, fraction: nil)) == .overlay)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 4000, current: .overlay, cell: 0)) == .overlay)
        #expect(ChangesPanelLayoutRule.layout(Self.input(shared: 0, current: .beside)) == .beside, "the body not measured yet")
    }

    // MARK: - When the layout is decided again

    /// What a layout was decided against: the shared width, the open panel,
    /// and the tab `tab` laid out as `root`.
    private static func basis(
        shared: CGFloat = 1200,
        isPresented: Bool = true,
        sidebar: CGFloat? = 300,
        tab: Tab,
        cell: CGFloat? = 8
    ) -> ChangesPanelLayoutRule.Basis {
        ChangesPanelLayoutRule.Basis(
            input(shared: shared, isPresented: isPresented, sidebar: sidebar),
            panes: .init(tab: tab, cellWidth: cell)
        )
    }

    /// A tab of one pane.
    private static func tab(_ title: String) -> Tab {
        Tab(title: title, splitTree: SplitTree(leafID: UUID()), container: .project(UUID()))
    }

    private static func redecides(
        _ old: ChangesPanelLayoutRule.Basis?,
        _ new: ChangesPanelLayoutRule.Basis,
        open: Set<UUID> = []
    ) -> Bool {
        ChangesPanelLayoutRule.redecides(from: old, to: new, isTabOpen: open.contains)
    }

    @Test func movingToAnotherTab_keepsTheOpenPanelsLayout() {
        let single = Self.tab("a")
        var split = Self.tab("b")
        split.splitTree = split.splitTree.insert(at: split.splitTree.allLeafIDs()[0], direction: .horizontal).tree
        let old = Self.basis(tab: single)

        #expect(!Self.redecides(old, Self.basis(tab: split), open: [single.id]), "another project's or workspace's tab")
        #expect(!Self.redecides(Self.basis(tab: split), Self.basis(tab: single), open: [split.id]))
        #expect(!Self.redecides(old, old), "nothing changed")
        // Closed, the panel follows any move: it opens straight into place.
        #expect(Self.redecides(Self.basis(isPresented: false, tab: single), Self.basis(isPresented: false, tab: split)))
        #expect(Self.redecides(nil, Self.basis(tab: split)), "never decided")
    }

    @Test func aResize_theSidebarOrThePanel_orTheShownTabsPanes_decideItAgain() {
        var tab = Self.tab("a")
        let old = Self.basis(tab: tab)

        #expect(Self.redecides(old, Self.basis(shared: 1300, tab: tab)), "the window resized")
        #expect(Self.redecides(old, Self.basis(sidebar: nil, tab: tab)), "the sidebar hidden")
        #expect(Self.redecides(Self.basis(isPresented: false, tab: tab), old), "the panel opened")
        #expect(Self.redecides(old, Self.basis(tab: tab, cell: 9)), "the font's size")
        tab.splitTree = tab.splitTree.insert(at: tab.splitTree.allLeafIDs()[0], direction: .horizontal).tree
        #expect(Self.redecides(old, Self.basis(tab: tab)), "the pane split")
        var zoomed = tab
        zoomed.zoomedLeafID = tab.splitTree.allLeafIDs().first
        #expect(Self.redecides(Self.basis(tab: tab), Self.basis(tab: zoomed)), "a pane zoomed")
    }

    @Test func theShownTabClosed_decidesItAgain_forTheTabShownNext() {
        let closed = Self.tab("a")
        let next = Self.tab("b")

        #expect(Self.redecides(Self.basis(tab: closed), Self.basis(tab: next), open: [next.id]))
    }
}
