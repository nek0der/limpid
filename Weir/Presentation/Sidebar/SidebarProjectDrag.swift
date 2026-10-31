// SidebarProjectDrag.swift
// Weir — a project's header dragged up and down the layer laid over the sidebar's list.

import Foundation
import Observation

/// The reorder of the projects, on a layer of their headers over the list. The
/// list does not change until the release, as changing it under a held pointer
/// flickers: its heights and its scroll land on separate passes. Held apart from
/// the list, so a pointer's move redraws the layer alone.
@MainActor
@Observable
final class SidebarProjectDrag {
    struct Entry: Equatable, Identifiable {
        let id: UUID
        let name: String
        let paletteIndex: Int?
        let isCollapsed: Bool
    }

    enum Phase {
        /// The headers stand where the list has them, about to gather.
        case gathering
        /// The headers stand one after another, the held one on the pointer.
        case carrying
        /// The order is written, and they go back to the list's places.
        case returning
        /// They stand on the list's headers, and the layer fades off them.
        case leaving
    }

    private(set) var phase: Phase?
    private(set) var sourceID: UUID?
    /// Told apart from any drag before, even of the same header.
    private(set) var dragID: UUID?
    /// Every header, in the order the drag has made so far.
    private(set) var entries: [Entry] = []
    private(set) var pointerY: CGFloat = 0
    /// Where the first header's line is, which keeps the held one under the
    /// pointer as they gather, and which moves when they scroll.
    private(set) var firstLineTop: CGFloat = 0
    private var returnTops: [UUID: CGFloat] = [:]
    @ObservationIgnored private var grabOffset: CGFloat = 0
    @ObservationIgnored private var startPointerY: CGFloat = 0
    /// Where the list draws each header it has laid out. Not observed, as it
    /// changes with every line scrolled past (`setHeaderTop`).
    @ObservationIgnored private(set) var headerTops: [UUID: CGFloat] = [:]
    @ObservationIgnored var visibleHeight: CGFloat = 0

    private let headerHeight: CGFloat
    /// From one header's line on the layer to the next.
    private let step: CGFloat

    init(headerHeight: CGFloat, step: CGFloat) {
        self.headerHeight = headerHeight
        self.step = step
    }

    /// The list drew `id` at `top`, or stopped drawing it. During the return
    /// the headers follow it, as the list lays the new order out in its own time.
    func setHeaderTop(_ top: CGFloat?, of id: UUID) {
        headerTops[id] = top
        if phase == .returning {
            returnTops[id] = top
        }
    }

    /// Takes hold of `id` among `entries`, pressed at `startY`; `false` while
    /// another drag or its return is under way.
    func begin(_ id: UUID, entries: [Entry], startY: CGFloat, pointerY: CGFloat) -> Bool {
        guard phase == nil, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let grabOffset = headerTops[id].map { startY - $0 } ?? headerHeight / 2
        let top = pointerY - grabOffset
        phase = .gathering
        sourceID = id
        dragID = UUID()
        self.entries = entries
        self.pointerY = pointerY
        startPointerY = pointerY
        self.grabOffset = grabOffset
        firstLineTop = top - CGFloat(index) * step
        returnTops = [:]
        return true
    }

    /// The layer has drawn the headers at the list's places: they can gather.
    func gather() {
        guard phase == .gathering else { return }
        phase = .carrying
    }

    func move(pointerY: CGFloat) {
        guard phase == .gathering || phase == .carrying else { return }
        self.pointerY = pointerY
        carry()
    }

    /// Scrolls a step when the held header rests at an edge with more headers
    /// past it. Only once carried: a header held still near an edge stays put.
    func scrollAtEdge() {
        guard phase == .carrying, pointerY != startPointerY, visibleHeight > 0, let top = liftedTop else { return }
        let edge = headerHeight / 2
        let listHeight = CGFloat(entries.count) * step
        if top < edge, firstLineTop < 0 {
            firstLineTop = min(0, firstLineTop + step)
        } else if top + headerHeight > visibleHeight - edge, firstLineTop + listHeight > visibleHeight {
            firstLineTop = max(visibleHeight - listHeight, firstLineTop - step)
        } else {
            return
        }
        carry()
    }

    /// The release: the order to write. The headers go back to the list's
    /// places as it reports them (`setHeaderTop`).
    func release() -> [UUID] {
        guard phase == .gathering || phase == .carrying else { return [] }
        phase = .returning
        returnTops = headerTops
        return entries.map(\.id)
    }

    /// Sees the release through: `travel` for the headers to arrive, `fade`
    /// for the layer to leave. Time goes by each animation's length, as nothing
    /// reports an animation's end.
    func finishRelease(travel: Duration, fade: Duration) async {
        try? await Task.sleep(for: travel)
        phase = .leaving
        try? await Task.sleep(for: fade)
        phase = nil
        sourceID = nil
        dragID = nil
        returnTops = [:]
    }

    /// The held header's top: on the pointer where it was taken, kept inside.
    var liftedTop: CGFloat? {
        guard sourceID != nil else { return nil }
        return clampedTop(pointerY - grabOffset)
    }

    /// Whether the list leaves `id` for the layer to draw. A leaving layer
    /// fades over the list's own header, so there is no gap as it goes.
    func hidesHeader(_ id: UUID) -> Bool {
        id == sourceID && phase != .leaving
    }

    /// Whether the layer shows `id`. A header the list has not laid out has
    /// no place to go from or to, so it fades at its line rather than stand
    /// over what the list shows there.
    func isShown(_ id: UUID) -> Bool {
        switch phase {
        case .gathering: headerTops[id] != nil
        case .carrying: true
        case .returning: returnTops[id] != nil
        case .leaving, nil: false
        }
    }

    /// Whether the layer's ground hides the list. It stays until the headers
    /// are back, as headers moving over the list's own words read as clutter.
    var hidesList: Bool {
        phase == .carrying || phase == .returning
    }

    /// Whether `id` follows the pointer rather than its line.
    func isLifted(_ id: UUID) -> Bool {
        phase == .carrying && id == sourceID
    }

    /// Where the layer draws `id`.
    func top(of id: UUID) -> CGFloat {
        let line = firstLineTop + CGFloat(entries.firstIndex { $0.id == id } ?? 0) * step
        switch phase {
        case .gathering: return headerTops[id] ?? line
        case .returning, .leaving: return returnTops[id] ?? line
        default: return isLifted(id) ? liftedTop ?? line : line
        }
    }

    private func clampedTop(_ top: CGFloat) -> CGFloat {
        // Before the list reports its height there is nothing to keep it in.
        guard visibleHeight > 0 else { return top }
        return min(max(0, visibleHeight - headerHeight), max(0, top))
    }

    /// Moves the held header to the line it is over.
    private func carry() {
        guard let sourceID, let top = liftedTop,
              let current = entries.firstIndex(where: { $0.id == sourceID })
        else { return }
        let target = min(entries.count - 1, max(0, Int(((top - firstLineTop) / step).rounded())))
        guard target != current else { return }
        let entry = entries.remove(at: current)
        entries.insert(entry, at: target)
    }
}
