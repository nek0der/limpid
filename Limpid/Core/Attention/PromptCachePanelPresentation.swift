// PromptCachePanelPresentation.swift
// Limpid — which prompt cache panel is open, which clock it hangs from, and
// when it opens and closes.
//
// Held at the scene root, like `PRHoverPresentation`, because the panel is
// wider than the tab row or the pane header its clock sits in, and each of
// those clips what it draws. `PromptCachePanelHost` draws the
// open panel over the whole window, below its clock.
//
// A place can have more than one clock on screen at once. Every main window
// renders the same session, and a row or header that swaps one layout for
// another can draw the new clock before the old one has gone. So each clock
// reports under its place *and* its own instance, and a panel hangs from the
// instance it was opened from. A panel the pointer opens hangs from the clock
// under the pointer, whatever any other clock of that place reported last.
//
// Opening and closing:
//   - open  : the pointer rests on a clock for `openDelay`, or a click or a
//             VoiceOver action on a clock opens it at once. The panel also
//             opens by itself, once per expiry; see
//             `AttentionState.autoOpenPromptCachePanel`.
//   - close : leaving the clock and the panel feeds one dismiss task, so the
//             pointer can cross the gap between them, as it does for the PR
//             card. Escape, a key typed elsewhere, a click outside, or one
//             of the panel's buttons closes it at once.
//   - only a real departure starts that task: an exit from a clock the
//     pointer was reported entering, or the pointer leaving the panel after
//     being on it. An exit with no enter before it, or a panel that has
//     never had the pointer, starts nothing. So a panel opened by itself,
//     from VoiceOver, or by a click whose clock never reported the pointer
//     arriving, stays until the pointer has come and gone, or until one of
//     the immediate closes above.

import Foundation
import Observation
import OSLog

private let log = Logger.limpid("prompt-cache.panel")

@MainActor
@Observable
final class PromptCachePanelPresentation {
    /// What opened the panel.
    enum Trigger: Equatable {
        /// A hover or a click on the clock.
        case pointer
        /// Focus arrived at a pane whose cache had expired.
        case automatic
        /// An accessibility action on the clock or the row carrying it.
        case accessibility
    }

    /// One clock on screen: the view instance that drew it, and its frame in
    /// global coordinates.
    struct Clock: Equatable {
        let instance: UUID
        var frame: CGRect
    }

    struct Request: Equatable, FloatingPanelRequest {
        /// Minted per open, so a view can tell a reopened panel from the
        /// one it saw before.
        let id: UUID
        let target: PromptCacheTarget
        let place: PromptCacheClockPlace
        /// The clock the panel hangs from. It follows this clock's frame
        /// while the window or the split moves it, and no other clock's.
        var clock: Clock
        let trigger: Trigger

        var anchor: CGRect {
            clock.frame
        }
    }

    /// The panel on screen, if any. One at a time: opening another replaces
    /// it.
    private(set) var request: Request?

    /// Set while something else floats over the window (see
    /// `FloatingSurfaceKind`). Neither a pointer resting on a clock nor the
    /// panel that opens by itself opens anything then: the pointer is on its
    /// way to or from that surface, and a second one would cover it. A click
    /// still opens, since it asks. Read when the open would happen, not when
    /// it was scheduled. `FloatingPanelLayer` keeps this current.
    @ObservationIgnored var isAnotherSurfaceOpen = false

    /// Set while a working surface is up (the command palette, an approval
    /// card, the notification history, review): no opening at all, a click
    /// included, so the panel never stands over it or competes with it for
    /// Escape. See `FloatingSurfaceRules.isOpeningBlocked`.
    /// `FloatingPanelLayer` keeps this current.
    @ObservationIgnored var isOpeningBlocked = false

    /// How long the pointer rests on a clock before its panel opens: long
    /// enough that sweeping across a column of tab rows does not flash a
    /// panel per clock.
    static let openDelay: Duration = .milliseconds(300)

    /// How long the pointer may be off both the clock and the panel before
    /// the panel goes, so it can cross the gap between them.
    static let dismissGrace: Duration = .milliseconds(300)

    // MARK: - Internal state

    /// Every clock on screen, by place, the one that reported last at the
    /// end. A place with no clock has no entry, which is how the panel that
    /// opens by itself knows there is nothing to hang from.
    @ObservationIgnored private var clocks: [PromptCacheClockPlace: [Clock]] = [:]
    /// The clocks the pointer is on, by place and view instance. Per
    /// instance because the pointer can be reported entering one clock of a
    /// place before leaving another: the next clock in a column, or the
    /// clock a row or header swaps in for the one it drew before. A place is
    /// hovered while any of its clocks is.
    @ObservationIgnored private var hoveringClocks: [PromptCacheClockPlace: Set<UUID>] = [:]
    @ObservationIgnored private var isPanelHovering = false
    @ObservationIgnored private var showTask: Task<Void, Never>?
    /// The clock the pending `showTask` belongs to, so leaving one clock
    /// does not cancel the open the next one just armed.
    @ObservationIgnored private var showTaskPlace: PromptCacheClockPlace?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private let openDelay: Duration
    @ObservationIgnored private let dismissDelay: Duration

    /// The delays are injectable so tests can drive the timing without
    /// sleeping for real.
    init(
        openDelay: Duration = PromptCachePanelPresentation.openDelay,
        dismissDelay: Duration = PromptCachePanelPresentation.dismissGrace
    ) {
        self.openDelay = openDelay
        self.dismissDelay = dismissDelay
    }

    func isOpen(place: PromptCacheClockPlace) -> Bool {
        request?.place == place
    }

    /// The frame of the clock at `place` that reported last, or nil when
    /// none is on screen.
    func anchor(for place: PromptCacheClockPlace) -> CGRect? {
        clocks[place]?.last?.frame
    }

    // MARK: - Clock-side events

    /// A clock was laid out or moved. `instance` identifies the view that
    /// drew it.
    func clockMoved(place: PromptCacheClockPlace, instance: UUID, anchor: CGRect) {
        record(Clock(instance: instance, frame: anchor), at: place)
        guard var current = request, current.place == place, current.clock.instance == instance,
              current.clock.frame != anchor
        else { return }
        current.clock.frame = anchor
        request = current
    }

    /// A clock left the screen: its run's cache was answered or renewed, or
    /// the row or header carrying it went away. SwiftUI sends no final
    /// hover exit then, so the bookkeeping is dropped here.
    ///
    /// A panel hanging from it moves to another clock of the same place
    /// when one is on screen. When none is, the panel waits one turn of the
    /// main actor before it goes: a row or header swapping layouts can take
    /// its old clock away before the new one reports.
    func clockDisappeared(place: PromptCacheClockPlace, instance: UUID) {
        clocks[place]?.removeAll { $0.instance == instance }
        hoveringClocks[place]?.remove(instance)
        if hoveringClocks[place]?.isEmpty == true {
            hoveringClocks[place] = nil
        }
        if clocks[place]?.isEmpty == true {
            clocks[place] = nil
            hoveringClocks[place] = nil
            if showTaskPlace == place {
                cancelShow()
            }
        }
        guard let current = request, current.place == place, current.clock.instance == instance else { return }
        if let replacement = clocks[place]?.last {
            request?.clock = replacement
            return
        }
        let requestID = current.id
        Task { @MainActor [weak self] in
            self?.rehangOrClose(requestID: requestID)
        }
    }

    func clockEntered(place: PromptCacheClockPlace, instance: UUID, anchor: CGRect, target: PromptCacheTarget) {
        record(Clock(instance: instance, frame: anchor), at: place)
        hoveringClocks[place, default: []].insert(instance)
        dismissTask?.cancel()
        if request?.place == place {
            return
        }
        cancelShow()
        guard !isAnotherSurfaceOpen else { return }
        showTaskPlace = place
        let delay = openDelay
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            // A cancelled sleep falls through rather than throwing out.
            guard !Task.isCancelled, let self, isHovering(place), !isAnotherSurfaceOpen else { return }
            // The clock under the pointer, at its latest frame.
            let clock = clocks[place]?.first { $0.instance == instance }
                ?? Clock(instance: instance, frame: anchor)
            open(target: target, place: place, clock: clock, trigger: .pointer)
        }
    }

    /// The pointer left a clock. Ignored for a clock it was never reported
    /// entering: that exit says nothing about where the pointer is now.
    func clockExited(place: PromptCacheClockPlace, instance: UUID) {
        guard hoveringClocks[place]?.remove(instance) != nil else {
            log.debug("prompt cache clock exit ignored: no enter before it")
            return
        }
        if hoveringClocks[place]?.isEmpty == true {
            hoveringClocks[place] = nil
        }
        if showTaskPlace == place, !isHovering(place) {
            cancelShow()
        }
        scheduleDismiss()
    }

    /// A click on a clock opens its panel at once, below that clock. A
    /// click on the clock whose panel is already open keeps it, rather than
    /// closing what the rest of the pointer just opened.
    func clockClicked(place: PromptCacheClockPlace, instance: UUID, anchor: CGRect, target: PromptCacheTarget) {
        cancelShow()
        record(Clock(instance: instance, frame: anchor), at: place)
        if let current = request, current.place == place, current.target == target {
            if current.clock.instance != instance {
                request?.clock = Clock(instance: instance, frame: anchor)
            }
            return
        }
        open(target: target, place: place, clock: Clock(instance: instance, frame: anchor), trigger: .pointer)
    }

    /// Opens the panel for `target` below the clock at `place` that
    /// reported last. False when no clock of that place is on screen. For
    /// openings that do not come from one particular clock: the panel that
    /// opens by itself, and a row's accessibility action.
    @discardableResult
    func open(target: PromptCacheTarget, place: PromptCacheClockPlace, trigger: Trigger) -> Bool {
        guard let clock = clocks[place]?.last else {
            log.debug("prompt cache panel not opened: no clock on screen for its place")
            return false
        }
        return open(target: target, place: place, clock: clock, trigger: trigger)
    }

    /// Opens the panel below the first of `places` with a clock on screen.
    /// False when none has one.
    @discardableResult
    func open(target: PromptCacheTarget, places: [PromptCacheClockPlace], trigger: Trigger) -> Bool {
        guard let place = places.first(where: { clocks[$0]?.isEmpty == false }) else {
            log.debug("prompt cache panel not opened: no clock on screen for any of its places")
            return false
        }
        return open(target: target, place: place, trigger: trigger)
    }

    /// Opens the panel below one particular clock.
    /// Every opening comes through here, and none happens while a working
    /// surface is up. False when refused.
    @discardableResult
    func open(target: PromptCacheTarget, place: PromptCacheClockPlace, clock: Clock, trigger: Trigger) -> Bool {
        record(clock, at: place)
        guard !isOpeningBlocked else {
            log.debug("prompt cache panel not opened: a working surface is up")
            return false
        }
        cancelShow()
        dismissTask?.cancel()
        request = Request(id: UUID(), target: target, place: place, clock: clock, trigger: trigger)
        isPanelHovering = false
        return true
    }

    // MARK: - Panel-side events

    /// The pointer came onto or left the panel. Leaving counts only after
    /// the panel had the pointer.
    func panelHoverChanged(_ isHovering: Bool) {
        let wasHovering = isPanelHovering
        isPanelHovering = isHovering
        if isHovering {
            dismissTask?.cancel()
        } else if wasHovering {
            scheduleDismiss()
        }
    }

    /// A mouse button went down somewhere in the window. Outside the panel
    /// and its clock that closes the panel, as a click outside closes a
    /// popover; the click still reaches what it landed on.
    func pointerPressed() {
        guard request != nil else { return }
        if isPanelHovering || request.map({ isHovering($0.place) }) == true {
            return
        }
        clear()
    }

    /// A key went down in the window. Any key closes the panel: Escape
    /// because that is what it is for, and any other because the user is
    /// typing at a prompt, which is answering the panel by carrying on.
    /// True when the key was Escape and was spent on closing the panel, so
    /// it must not also reach the terminal, where an agent reads Escape as
    /// a command of its own.
    func keyPressed(isEscape: Bool) -> Bool {
        guard request != nil else { return false }
        clear()
        return isEscape
    }

    /// Closes whatever panel is open.
    func close() {
        clear()
    }

    // MARK: - Bookkeeping

    /// Records `clock` as the latest report for `place`, replacing what the
    /// same instance reported before.
    private func record(_ clock: Clock, at place: PromptCacheClockPlace) {
        var reported = clocks[place] ?? []
        reported.removeAll { $0.instance == clock.instance }
        reported.append(clock)
        clocks[place] = reported
    }

    /// After a clock the panel hung from went away: hang it from the clock
    /// that replaced it, or close it when none did.
    private func rehangOrClose(requestID: UUID) {
        guard let current = request, current.id == requestID,
              clocks[current.place]?.contains(where: { $0.instance == current.clock.instance }) != true
        else { return }
        if let replacement = clocks[current.place]?.last {
            request?.clock = replacement
        } else {
            clear()
        }
    }

    private func isHovering(_ place: PromptCacheClockPlace) -> Bool {
        hoveringClocks[place]?.isEmpty == false
    }

    /// Starts the grace period after a real departure; whether the panel
    /// goes is decided when it ends.
    private func scheduleDismiss() {
        guard request != nil else { return }
        dismissTask?.cancel()
        let delay = dismissDelay
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if hoveringClocks.isEmpty, !isPanelHovering {
                clear()
            }
        }
    }

    private func cancelShow() {
        showTask?.cancel()
        showTask = nil
        showTaskPlace = nil
    }

    /// Drops the panel and its hover bookkeeping. The panel's own hover flag
    /// is reset because SwiftUI does not reliably deliver a final hover exit
    /// when a hovered view leaves the hierarchy, and a latched flag would
    /// keep the next panel from ever closing.
    private func clear() {
        cancelShow()
        dismissTask?.cancel()
        request = nil
        isPanelHovering = false
    }
}
