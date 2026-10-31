// SidebarProjectDragTests.swift
// Weir — the reorder of the projects on the layer over the sidebar's list.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite("SidebarProjectDrag")
struct SidebarProjectDragTests {
    private let step: CGFloat = 36
    private let entries = (0..<5).map { SidebarProjectDrag.Entry(id: UUID(), name: "p\($0)", paletteIndex: nil, isCollapsed: true) }

    private var ids: [UUID] {
        entries.map(\.id)
    }

    /// A drag of the header at `index`, which the list draws at 200, taken 10
    /// below its top and gathered.
    private func drag(from index: Int, height: CGFloat = 500) -> SidebarProjectDrag {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.visibleHeight = height
        drag.setHeaderTop(200, of: ids[index])
        _ = drag.begin(ids[index], entries: entries, startY: 210, pointerY: 210)
        drag.gather()
        return drag
    }

    @Test func aSecondDrag_doesNotBegin_untilTheFirstHasFinished() {
        let drag = drag(from: 0)
        #expect(!drag.begin(ids[1], entries: entries, startY: 0, pointerY: 0))
        _ = drag.release()
        #expect(!drag.begin(ids[1], entries: entries, startY: 0, pointerY: 0))
    }

    @Test func aFinishedRelease_letsTheNextDragBegin_andTellsItApart() async {
        let drag = drag(from: 0)
        let first = drag.dragID
        _ = drag.release()
        await drag.finishRelease(travel: .zero, fade: .zero)
        #expect(drag.phase == nil)
        #expect(drag.begin(ids[0], entries: entries, startY: 0, pointerY: 0))
        #expect(drag.dragID != first)
    }

    @Test func aHeaderNotAmongTheEntries_doesNotBegin() {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        #expect(!drag.begin(UUID(), entries: entries, startY: 0, pointerY: 0))
    }

    @Test func nothingMoves_afterTheRelease() {
        let drag = drag(from: 2)
        let order = drag.release()
        drag.move(pointerY: 900)
        #expect(drag.entries.map(\.id) == order)
        #expect(drag.release().isEmpty)
    }

    /// A press during the last drag's return keeps its grab, however far the
    /// pointer has gone by the time that return ends.
    @Test func aDragBegunLate_keepsThePlaceItWasPressedAt() {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.visibleHeight = 500
        drag.setHeaderTop(100, of: ids[1])
        _ = drag.begin(ids[1], entries: entries, startY: 110, pointerY: 150)
        #expect(drag.liftedTop == 140)
    }

    @Test func beforeTheListReportsItsHeight_theHeaderIsNotClamped() {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.setHeaderTop(100, of: ids[1])
        _ = drag.begin(ids[1], entries: entries, startY: 110, pointerY: 110)
        #expect(drag.liftedTop == 100)
    }

    @Test func theHeldHeader_staysUnderThePointer_asTheOthersGather() {
        let drag = drag(from: 2)
        #expect(drag.top(of: ids[2]) == 200)
        #expect(drag.top(of: ids[3]) == 200 + step)
        #expect(drag.top(of: ids[0]) == 200 - step * 2)
    }

    @Test func theHeaders_startAtTheListsPlaces() {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.visibleHeight = 500
        drag.setHeaderTop(40, of: ids[0])
        drag.setHeaderTop(120, of: ids[1])
        _ = drag.begin(ids[1], entries: entries, startY: 130, pointerY: 130)
        #expect(drag.top(of: ids[0]) == 40)
        drag.gather()
        #expect(drag.top(of: ids[0]) == 120 - step)
    }

    @Test func aHeaderMoves_onlyOnceCarriedPastHalfALine() {
        let drag = drag(from: 2)
        drag.move(pointerY: 210 + step * 0.4)
        #expect(drag.entries.map(\.id) == ids)
        drag.move(pointerY: 210 + step * 0.6)
        #expect(drag.entries.map(\.id) == [ids[0], ids[1], ids[3], ids[2], ids[4]])
        drag.move(pointerY: 210 - step * 0.6)
        #expect(drag.entries.map(\.id) == [ids[0], ids[2], ids[1], ids[3], ids[4]])
    }

    @Test func carryingBack_restoresTheOrder() {
        let drag = drag(from: 2)
        drag.move(pointerY: 210 + step * 2)
        drag.move(pointerY: 210)
        #expect(drag.release() == ids)
    }

    @Test func theHeldHeader_staysInSight() {
        let drag = drag(from: 2)
        drag.move(pointerY: -500)
        #expect(drag.liftedTop == 0)
        drag.move(pointerY: 2000)
        #expect(drag.liftedTop == 472)
    }

    @Test func aHeaderHeldStillAtAnEdge_doesNotScroll() {
        let drag = drag(from: 4, height: 100)
        let before = drag.firstLineTop
        drag.scrollAtEdge()
        #expect(drag.firstLineTop == before)
    }

    @Test func aHeaderCarriedToAnEdge_scrollsPastTheOthers() {
        let drag = drag(from: 0, height: 100)
        drag.move(pointerY: 2000)
        let before = drag.firstLineTop
        drag.scrollAtEdge()
        #expect(drag.firstLineTop < before)
    }

    @Test func aHeaderCarriedToTheTop_scrollsBack_noFurtherThanTheFirstLine() {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.visibleHeight = 100
        drag.setHeaderTop(0, of: ids[4])
        _ = drag.begin(ids[4], entries: entries, startY: 10, pointerY: 10)
        drag.gather()
        #expect(drag.firstLineTop == -step * 4)
        drag.move(pointerY: -500)
        for _ in 0..<20 {
            drag.scrollAtEdge()
        }
        #expect(drag.firstLineTop == 0)
    }

    @Test func aHeaderWithNoPlaceInTheList_isNotShown_untilTheHeadersGather() {
        let drag = SidebarProjectDrag(headerHeight: 28, step: step)
        drag.visibleHeight = 500
        drag.setHeaderTop(120, of: ids[1])
        _ = drag.begin(ids[1], entries: entries, startY: 130, pointerY: 130)
        #expect(drag.isShown(ids[1]))
        #expect(!drag.isShown(ids[0]))
        drag.gather()
        #expect(drag.isShown(ids[0]))
    }

    @Test func theLayer_keepsTheListHidden_untilTheHeadersAreBack() async {
        let drag = drag(from: 2)
        #expect(drag.hidesList)
        #expect(drag.hidesHeader(ids[2]))
        _ = drag.release()
        #expect(drag.hidesList)
        await drag.finishRelease(travel: .zero, fade: .zero)
        #expect(!drag.hidesList)
        #expect(!drag.hidesHeader(ids[2]))
    }

    @Test func theHeaders_returnToTheListsNewPlaces() {
        let drag = drag(from: 2)
        _ = drag.release()
        #expect(drag.top(of: ids[2]) == 200)
        drag.setHeaderTop(60, of: ids[2])
        #expect(drag.top(of: ids[2]) == 60)
    }
}
