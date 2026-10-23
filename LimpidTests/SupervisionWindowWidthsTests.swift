// SupervisionWindowWidthsTests.swift
// Limpid — the window's minimum, the sidebar's drawn width, and the title bar's widths follow the supervision layout.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@Suite("Supervision window widths")
struct SupervisionWindowWidthsTests {

    // MARK: Window minimum

    @Test func windowMinWidth_addsMarginsRailsSidebarAndSession() {
        let width = SupervisionWindowWidths.windowMinWidth(
            surfaceGap: 6,
            railWidth: 40,
            sidebarMinWidth: 220,
            sessionMinWidth: 400
        )
        // 6 + (40 + 6) + 220 + 6 + 400 + (6 + 40) + 6.
        #expect(width == 730)
    }

    /// At the minimum, with the sidebar at its narrowest, the session's
    /// column is the review's minimum, where the review band's narrowest
    /// fits (374pt in English, 342pt in Japanese) stay whole.
    @Test func windowMinWidth_leavesTheReviewItsMinimum() {
        let layout = LimpidLayout.Supervision.self
        let body = layout.windowMinWidth - 2 * layout.surfaceGap - 2 * (layout.railWidth + layout.surfaceGap)
        let session = body - layout.sidebarWidthRange.lowerBound - layout.surfaceGap
        #expect(layout.windowMinWidth == 730)
        #expect(session == LimpidLayout.reviewMinWidth)
        #expect(session >= 374)
    }

    // MARK: Sidebar

    private static func sidebar(saved: CGFloat, body: CGFloat) -> CGFloat {
        SupervisionWindowWidths.sidebarDrawnWidth(
            saved: saved,
            range: 220...400,
            bodyWidth: body,
            surfaceGap: 6,
            sessionMinWidth: 400
        )
    }

    /// The saved width with room for it (exactly enough is room enough:
    /// 304 + 6 + 400), and before the body is measured, rather than the
    /// floor for one frame; else what leaves the session its minimum, never
    /// under the range's floor; and held to the range.
    @Test(arguments: [
        (CGFloat(304), CGFloat(1100), CGFloat(304)),
        (304, 710, 304),
        (304, 0, 304),
        (304, 680, 274),
        (304, 626, 220),
        (304, 500, 220),
        (100, 1100, 220),
        (900, 2000, 400)
    ])
    func sidebarDrawnWidth_isTheSavedWidthAsFarAsTheBodyAndTheRangeAllow(saved: CGFloat, body: CGFloat, drawn: CGFloat) {
        #expect(Self.sidebar(saved: saved, body: body) == drawn)
    }

    private static func sidebarMax(body: CGFloat) -> CGFloat {
        SupervisionWindowWidths.sidebarDrawnMaxWidth(range: 220...400, bodyWidth: body, surfaceGap: 6, sessionMinWidth: 400)
    }

    /// The divider goes as far as the sidebar can be drawn: the range's
    /// top with room, what leaves the session its minimum without, and
    /// never under the range's floor.
    @Test func sidebarDrawnMaxWidth_followsTheBody() {
        #expect(Self.sidebarMax(body: 1100) == 400)
        #expect(Self.sidebarMax(body: 680) == 274)
        #expect(Self.sidebarMax(body: 600) == 220)
        #expect(Self.sidebarMax(body: 0) == 400)
    }

    // MARK: Divider

    /// Saved at 304 and drawn at 220 in a narrow window, a VoiceOver step
    /// or a drag of a few points that the range takes back to 220 writes
    /// nothing, so the saved 304 comes back when the window widens.
    @Test func dividerWidth_heldBackToTheDrawnWidth_writesNothing() {
        #expect(DividerResizeRule.width(proposed: 244, current: 220, minWidth: 220, maxWidth: 220) == nil)
        #expect(DividerResizeRule.width(proposed: 223, current: 220, minWidth: 220, maxWidth: 220) == nil)
        #expect(DividerResizeRule.width(proposed: 196, current: 220, minWidth: 220, maxWidth: 220) == nil)
    }

    @Test func dividerWidth_withinTheRange_writesTheClampedWidth() {
        #expect(DividerResizeRule.width(proposed: 328, current: 304, minWidth: 220, maxWidth: 400) == 328)
        #expect(DividerResizeRule.width(proposed: 450, current: 380, minWidth: 220, maxWidth: 400) == 400)
        #expect(DividerResizeRule.width(proposed: 100, current: 304, minWidth: 220, maxWidth: 400) == 220)
    }

    // MARK: Title bar

    /// Back and forward as the bar draws them: two 28pt squares 2pt apart
    /// (`TitleBarHistoryTests` measures the real pair).
    static let historyWidth: CGFloat = 58

    /// The bar's rule without back and forward (`history` 0), where the
    /// field alone stands on the center, unless a test passes the pair.
    private static func titleBar(
        width: CGFloat,
        leading: CGFloat,
        history: CGFloat = 0,
        trailing: CGFloat,
        leadingInset: CGFloat = 92
    ) -> SupervisionWindowWidths.TitleBar {
        SupervisionWindowWidths.titleBar(
            width: width,
            leadingIdeal: leading,
            historyWidth: history,
            trailingIdeal: trailing,
            metrics: .init(leadingInset: leadingInset, trailingInset: 12, spacing: 6, fieldRange: 150...340)
        )
    }

    @Test func titleBar_wideWindow_givesTheFieldItsMaximum() {
        let bar = Self.titleBar(width: 1280, leading: 142, trailing: 168)
        #expect(bar == .init(field: 340, leading: 142, trailing: 168))
    }

    /// The field gives way first, to what keeps the busier side whole
    /// with the field still on the bar's center: 365 − 92 − 6 − 142 on
    /// each side of the center.
    @Test func titleBar_narrowWindow_theFieldGivesWayFirst() {
        let bar = Self.titleBar(width: 730, leading: 142, trailing: 168)
        #expect(bar == .init(field: 250, leading: 142, trailing: 168))
    }

    /// At its floor the field stays; the leading names are cut to what is
    /// left beside it.
    @Test func titleBar_longPlace_cutsTheNamesPastTheFieldsFloor() {
        let bar = Self.titleBar(width: 730, leading: 400, trailing: 168)
        #expect(bar == .init(field: 150, leading: 192, trailing: 168))
    }

    /// Short of room on the trailing side, Needs Attention is offered less
    /// than its ideal, which takes its short form.
    @Test func titleBar_crowdedTrailingSide_offersNeedsAttentionLess() {
        let bar = Self.titleBar(width: 600, leading: 142, trailing: 250)
        #expect(bar.field == 150)
        #expect(bar.trailing == 207)
        #expect(bar.trailing < 250)
    }

    /// Full screen takes the traffic lights away; the field still stands
    /// on the bar's center, so the sides' rooms differ only by the insets.
    @Test func titleBar_withoutTrafficLights_keepsTheFieldCentered() {
        let bar = Self.titleBar(width: 730, leading: 400, trailing: 168, leadingInset: 18)
        #expect(bar == .init(field: 150, leading: 266, trailing: 168))
    }

    /// Back and forward stand with the field, so at the window's minimum
    /// the field gives way to them and the sides keep their ideals: the
    /// group (58 + 6 + 186) is centered, and 365 − 125 − 6 − 92 leaves the
    /// place controls their 142.
    @Test func titleBar_withHistory_atTheWindowsMinimum_theFieldGivesWayToTheButtons() {
        let bar = Self.titleBar(width: 730, leading: 142, history: Self.historyWidth, trailing: 168)
        #expect(bar == .init(field: 186, leading: 142, trailing: 168))
    }

    /// With room, the buttons take nothing from the field: it keeps its
    /// maximum beside them.
    @Test func titleBar_withHistory_wideWindow_givesTheFieldItsMaximum() {
        let bar = Self.titleBar(width: 1280, leading: 142, history: Self.historyWidth, trailing: 168)
        #expect(bar == .init(field: 340, leading: 142, trailing: 168))
    }

    /// At the field's floor the buttons keep their width and the names are
    /// cut to what is left: half the bar less half the group (58 + 6 + 150).
    @Test func titleBar_withHistory_longPlace_cutsTheNamesPastTheFieldsFloor() {
        let bar = Self.titleBar(width: 730, leading: 400, history: Self.historyWidth, trailing: 168)
        #expect(bar == .init(field: 150, leading: 160, trailing: 168))
    }

    @Test func titleBar_tooNarrowForAnything_offersNoNegativeWidths() {
        let bar = Self.titleBar(width: 150, leading: 142, trailing: 168)
        #expect(bar.field == 150)
        #expect(bar.leading == 0)
        #expect(bar.trailing == 0)
    }

    /// The row has room for both names: each control takes its ideal.
    /// These are the widths the bar measured with the main checkout
    /// detached (project ▾ "alpha ●", worktree ▾ "alpha" in the monospaced
    /// face), where an `HStack` cut the project's name to "al…": offered
    /// half the row first, the less flexible control took the half.
    @Test func placeControls_withRoomForBoth_takeTheirIdeals() {
        let widths = SupervisionWindowWidths.placeControlWidths(ideals: [105, 91.5], spacing: 6, width: 202.5)
        #expect(widths == [105, 91.5])
        // Room to spare changes nothing: the controls do not stretch.
        #expect(SupervisionWindowWidths.placeControlWidths(ideals: [105, 91.5], spacing: 6, width: 400) == [105, 91.5])
    }

    /// Short of room, the control that fits in an equal share keeps its
    /// width and the other takes what is left, whichever order they are
    /// in: a short branch is never cut for a long project name, nor the
    /// other way round.
    @Test func placeControls_shortOfRoom_cutOnlyWhatDoesNotFitItsShare() {
        #expect(SupervisionWindowWidths.placeControlWidths(ideals: [160, 84], spacing: 6, width: 196) == [106, 84])
        #expect(SupervisionWindowWidths.placeControlWidths(ideals: [84, 160], spacing: 6, width: 196) == [84, 106])
        // Both past their share: an even split.
        #expect(SupervisionWindowWidths.placeControlWidths(ideals: [160, 150], spacing: 6, width: 206) == [100, 100])
        #expect(SupervisionWindowWidths.placeControlWidths(ideals: [160], spacing: 6, width: 100) == [100])
        #expect(SupervisionWindowWidths.placeControlWidths(ideals: [], spacing: 6, width: 100).isEmpty)
        // No room at all offers no negative widths.
        #expect(SupervisionWindowWidths.placeControlWidths(ideals: [160, 84], spacing: 6, width: 0) == [0, 0])
    }

    /// At the window's minimum width (730pt) with the traffic lights shown
    /// and back and forward beside the field, the leading side is offered
    /// 160pt
    /// (`titleBar_withHistory_longPlace_cutsTheNamesPastTheFieldsFloor`),
    /// and the measured detached case needs 202.5: both names are
    /// cut, to an even 77pt each. On record as the trade-off, not a bug: the
    /// row has no room for both, the field is at its floor, and the
    /// buttons stand with the field. Without them the branch
    /// kept its whole name (192pt offered: 94.5 and 91.5).
    @Test func placeControls_atTheWindowsMinimumWidth_cutBothNamesOfTheDetachedCase() {
        let bar = Self.titleBar(width: 730, leading: 202.5, history: Self.historyWidth, trailing: 168)
        #expect(bar.leading == 160)
        #expect(SupervisionWindowWidths.placeControlWidths(ideals: [105, 91.5], spacing: 6, width: bar.leading) == [77, 77])
        let withoutHistory = Self.titleBar(width: 730, leading: 202.5, trailing: 168)
        #expect(SupervisionWindowWidths.placeControlWidths(ideals: [105, 91.5], spacing: 6, width: withoutHistory.leading) == [94.5, 91.5])
    }
}

/// The title bar's layout itself, laid out in a hosting view: the field's
/// center is the bar's, whatever the sides hold.
@MainActor
@Suite("Supervision title bar layout")
struct SupervisionTitleBarLayoutTests {
    private final class Frames {
        var field: CGRect = .zero
        var history: CGRect = .zero
        var leading: CGRect = .zero
        var trailing: CGRect = .zero
    }

    private static func layOut(width: CGFloat, leading: CGFloat, history: CGFloat = 58, trailing: CGFloat) -> Frames {
        let frames = Frames()
        let metrics = SupervisionWindowWidths.TitleBarMetrics(leadingInset: 92, trailingInset: 12, spacing: 6, fieldRange: 150...340)
        let bar = SupervisionTitleBarLayout(metrics: metrics) {
            Color.clear.frame(minWidth: 0, idealWidth: leading, maxWidth: leading).frame(height: 28)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.leading = $0 }
            Color.clear.frame(width: history, height: 28)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.history = $0 }
            Color.clear.frame(height: 28)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.field = $0 }
            Color.clear.frame(width: trailing, height: 28)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.trailing = $0 }
        }
        let host = NSHostingView(rootView: bar.frame(width: width, height: 48))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 48)
        host.layoutSubtreeIfNeeded()
        return frames
    }

    /// Back, forward, and the field stand as one group on the bar's
    /// center, the buttons just before the field.
    @Test func historyAndField_standOnTheBarsCenter() {
        let frames = Self.layOut(width: 730, leading: 142, trailing: 168)
        #expect(frames.field.width == 186)
        #expect(frames.history.width == 58)
        #expect((frames.history.minX + frames.field.maxX) / 2 == 365)
        #expect(frames.field.minX == frames.history.maxX + 6)
        #expect(frames.leading.minX == 92)
        #expect(frames.leading.maxX <= frames.history.minX - 6)
        #expect(frames.trailing.maxX == 718)
        #expect(frames.trailing.minX >= frames.field.maxX + 6)
    }

    /// Without the buttons the field stands on the center itself.
    @Test func field_withoutHistory_standsOnTheBarsCenter() {
        let frames = Self.layOut(width: 730, leading: 142, history: 0, trailing: 168)
        #expect(frames.field.width == 250)
        #expect(frames.field.midX == 365)
    }

    /// A long place is cut beside the buttons rather than push the group
    /// off the center or under the buttons.
    @Test func longPlace_leavesTheGroupCentered() {
        let frames = Self.layOut(width: 730, leading: 400, trailing: 168)
        #expect(frames.field.width == 150)
        #expect((frames.history.minX + frames.field.maxX) / 2 == 365)
        #expect(frames.leading.maxX <= frames.history.minX - 6)
    }
}
