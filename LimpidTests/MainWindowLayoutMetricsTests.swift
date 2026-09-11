// MainWindowLayoutMetricsTests.swift
// Limpid — verifies one layout plan across sidebar and tab presentations.

import CoreGraphics
import Testing
@testable import Limpid

private enum LayoutFixture {
    static let sidebarWidth: CGFloat = 240
    static let tabWidth: CGFloat = 240
}

@Suite("Main window layout plan")
struct MainWindowLayoutPlanTests {
    @Test("A vertical review assigns container chrome to its reserved tab toolbar")
    func verticalReviewWide_reservesAllColumns() {
        let width = LayoutFixture.sidebarWidth + LayoutFixture.tabWidth + ReviewRail.inlineMinimumWidth
        let plan = resolve(width: width, isReviewPresented: true)

        #expect(plan.sidebarPresentation == .reserved(width: LayoutFixture.sidebarWidth))
        #expect(plan.tabColumnWidth == LayoutFixture.tabWidth)
        #expect(plan.primaryContentWidth == ReviewRail.inlineMinimumWidth)
        #expect(plan.regularContainerIdentityPlacement == .tabToolbar)
    }

    @Test("A minimum-width vertical review overlays its sidebar")
    func verticalReviewMinimum_preservesReviewWidth() {
        let plan = resolve(width: 560, requestedTabWidth: 500, isReviewPresented: true)

        #expect(plan.sidebarPresentation == .overlay(width: LayoutFixture.sidebarWidth, isPresented: false))
        #expect(plan.tabColumnWidth == 200)
        #expect(plan.primaryContentWidth == 360)
        #expect(plan.regularContainerIdentityPlacement == .terminalToolbar)
    }

    @Test("A manually hidden sidebar keeps context in a roomy terminal toolbar")
    func verticalHiddenWide_assignsContextOnce() {
        let plan = resolve(width: 1100, isSidebarHidden: true)

        #expect(plan.sidebarPresentation == .hidden)
        #expect(plan.reservedSidebarWidth == 0)
        #expect(plan.regularContainerIdentityPlacement == .terminalToolbar)
    }

    @Test("Horizontal tabs do not reserve a vertical tab column")
    func horizontalTerminal_usesActualPrimaryWidth() {
        let plan = resolve(width: 700, isTabColumnHorizontal: true)

        #expect(!plan.usesCompactSidebar)
        #expect(plan.sidebarPresentation == .reserved(width: LayoutFixture.sidebarWidth))
        #expect(plan.tabColumnWidth == 0)
        #expect(plan.primaryContentWidth == 460)
    }

    @Test("A minimum-width horizontal review overlays its sidebar")
    func horizontalReviewMinimum_preservesFileRailAndDiff() {
        let plan = resolve(
            width: 560,
            isTabColumnHorizontal: true,
            isReviewPresented: true
        )

        #expect(plan.sidebarPresentation == .overlay(width: LayoutFixture.sidebarWidth, isPresented: false))
        #expect(plan.tabColumnWidth == 0)
        #expect(plan.primaryContentWidth == 560)
    }

    @Test("A roomy horizontal toolbar owns container context once")
    func horizontalWide_assignsContextToUnifiedToolbar() {
        let plan = resolve(width: 1100, isTabColumnHorizontal: true)

        #expect(plan.sidebarPresentation == .reserved(width: LayoutFixture.sidebarWidth))
        #expect(plan.primaryContentWidth == 860)
        #expect(plan.regularContainerIdentityPlacement == .terminalToolbar)
    }

    @Test("Opening a compact sidebar changes presentation without relocating chrome")
    func compactOverlayOpen_preservesChromeAssignment() {
        let closed = resolve(width: 560, isReviewPresented: true)
        let open = resolve(
            width: 560,
            isCompactSidebarPresented: true,
            isReviewPresented: true
        )

        #expect(closed.sidebarPresentation == .overlay(width: LayoutFixture.sidebarWidth, isPresented: false))
        #expect(open.sidebarPresentation == .overlay(width: LayoutFixture.sidebarWidth, isPresented: true))
        #expect(open.regularContainerIdentityPlacement == closed.regularContainerIdentityPlacement)
        #expect(open.primaryContentWidth == closed.primaryContentWidth)
    }

    @Test("Sidebar reservation changes exactly at each content threshold", arguments: [
        SidebarBoundary(
            threshold: LayoutFixture.sidebarWidth
                + LimpidLayout.tabColumnMinWidth
                + LimpidLayout.terminalColumnMinWidth,
            isHorizontal: false,
            isReviewPresented: false
        ),
        SidebarBoundary(
            threshold: LayoutFixture.sidebarWidth
                + LimpidLayout.tabColumnMinWidth
                + ReviewRail.inlineMinimumWidth,
            isHorizontal: false,
            isReviewPresented: true
        ),
        SidebarBoundary(
            threshold: LayoutFixture.sidebarWidth + LimpidLayout.terminalColumnMinWidth,
            isHorizontal: true,
            isReviewPresented: false
        ),
        SidebarBoundary(
            threshold: LayoutFixture.sidebarWidth + ReviewRail.inlineMinimumWidth,
            isHorizontal: true,
            isReviewPresented: true
        ),
    ])
    func sidebarReservation_changesAtBoundary(boundary: SidebarBoundary) {
        let below = resolve(
            width: boundary.threshold - 1,
            isTabColumnHorizontal: boundary.isHorizontal,
            isReviewPresented: boundary.isReviewPresented
        )
        let exact = resolve(
            width: boundary.threshold,
            isTabColumnHorizontal: boundary.isHorizontal,
            isReviewPresented: boundary.isReviewPresented
        )

        #expect(below.usesCompactSidebar)
        #expect(exact.sidebarPresentation == .reserved(width: LayoutFixture.sidebarWidth))
    }

    private func resolve(
        width: CGFloat,
        requestedTabWidth: CGFloat = LayoutFixture.tabWidth,
        isSidebarHidden: Bool = false,
        isCompactSidebarPresented: Bool = false,
        isTabColumnHorizontal: Bool = false,
        isReviewPresented: Bool = false
    ) -> MainWindowLayoutPlan {
        MainWindowLayoutPlan.resolve(.init(
            availableWidth: width,
            requestedSidebarWidth: LayoutFixture.sidebarWidth,
            requestedTabWidth: requestedTabWidth,
            isSidebarHidden: isSidebarHidden,
            isCompactSidebarPresented: isCompactSidebarPresented,
            isTabColumnHorizontal: isTabColumnHorizontal,
            isReviewPresented: isReviewPresented
        ))
    }

    struct SidebarBoundary: Sendable {
        let threshold: CGFloat
        let isHorizontal: Bool
        let isReviewPresented: Bool
    }
}

@Suite("Window frame restoration")
@MainActor
struct WindowFrameRestorationTests {
    @Test("A saved frame expands to the app minimum while preserving its top edge")
    func narrowSavedFrame_expandsBeforeRestore() {
        let saved = CGRect(x: 100, y: 200, width: 500, height: 300)
        let minimum = CGSize(width: LimpidLayout.mainWindowMinWidth, height: 422)

        let restored = WindowFrameSync.expanding(saved, toAtLeast: minimum)

        #expect(restored == CGRect(x: 100, y: 78, width: 560, height: 422))
        #expect(restored.maxY == saved.maxY)
    }

    @Test("A saved frame already above the minimum stays unchanged")
    func largeSavedFrame_isUnchanged() {
        let saved = CGRect(x: 100, y: 200, width: 900, height: 700)
        let minimum = CGSize(width: LimpidLayout.mainWindowMinWidth, height: 422)

        let restored = WindowFrameSync.expanding(saved, toAtLeast: minimum)

        #expect(restored == saved)
    }
}
