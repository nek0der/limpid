// PromptCacheMarkView.swift
// Limpid — the clock that says a pane's prompt cache is about to expire or
// already has.
//
// Drawn beside the agent state mark in a split pane's header, at that
// mark's metrics, so the two read as one status group, and as a chip with
// words in the supervision window's session header. Either one is the way
// into the cache panel, below itself: resting the pointer on it, clicking
// it, or its accessibility action. Neither header changes height for it. Amber and red alone would carry the
// meaning by color, which is why the spoken label names the state and the
// spoken value names the cost.

import AppKit
import OSLog
import SwiftUI

/// What every clock shows and says, wherever it is drawn.
private extension PromptCacheMark {
    /// The clock's tint: amber while the cache is about to expire, the
    /// stopped red once it has. The chip shows the same pair through its
    /// tone.
    var tint: Color {
        status == .expired ? SupervisionTokens.stopped.color : SupervisionTokens.waiting.color
    }

    var accessibilityLabel: Text {
        Text(spokenStatus)
    }

    /// The cost sentence alone. Not the time: SwiftUI reads the value when
    /// the view is drawn, and the clock is drawn again only at the status
    /// thresholds, so a time here would be stale for most of an hour. The
    /// panel says how long ago or how soon.
    var accessibilityValue: Text {
        let costLine = PromptCacheRules.panelContent(
            status: status,
            window: window,
            isAnswered: false,
            commandBlock: nil
        )?.costLine
        return costLine.map { Text($0) } ?? Text(verbatim: "")
    }
}

extension PromptCacheMark {
    /// The words the session header's chip shows for the clock, the
    /// panel's own title.
    var chipTitle: LocalizedStringResource {
        status == .expired
            ? LocalizedStringResource("Cache Expired", comment: "Title of the expired prompt cache panel")
            : LocalizedStringResource("Cache Expires Soon", comment: "Title of the expiring prompt cache panel")
    }
}

/// The interactive clock in a split pane's header, or the chip in the
/// supervision window's session header.
struct PromptCacheMarkView: View {
    /// How the clock is drawn: a glyph beside a pane header's state mark,
    /// or a chip with words among the session header's exception chips.
    enum Style {
        case clock
        case chip
    }

    let mark: PromptCacheMark
    /// The key this clock's frame is published under, so its panel hangs
    /// below it.
    let place: PromptCacheClockPlace
    var style: Style = .clock

    @Environment(PromptCachePanelPresentation.self) private var presentation
    /// Tells this clock apart from another drawn for the same place, so a
    /// panel opened here hangs from this clock; see
    /// `PromptCachePanelPresentation`.
    @State private var instance = UUID()
    /// This clock's frame in global coordinates as last laid out, handed
    /// over with every hover and click so the panel opens below the clock
    /// the pointer is on.
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            presentation.clockClicked(place: place, instance: instance, anchor: frame, target: mark.target)
        } label: {
            switch style {
            case .clock:
                // The slot of `AgentStateMark.Placement.headerStatus`, so the clock and
                // the state mark beside it share one square.
                Image(systemName: "clock")
                    .foregroundStyle(mark.tint)
                    .font(.supervision(LimpidLayout.promptCacheClockFontSize, weight: .semibold))
                    .frame(
                        width: LimpidLayout.stateMarkSlot,
                        height: LimpidLayout.stateMarkSlot
                    )
                    // No fill behind it, open or hovered: the panel's arrow
                    // already points at the clock it came from.
                    .contentShape(Rectangle())
            case .chip:
                // The header's chip, edged and worded in the tone of what
                // it says: amber while the cache is about to expire, red
                // once it has.
                SupervisionChip(
                    text: Text(mark.chipTitle),
                    tone: mark.status == .expired ? .stopped : .waiting,
                    systemImage: "clock"
                )
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
        // The pointer is followed with an AppKit tracking area rather than
        // `onHover`; see `PromptCacheHoverTracker`.
        .background {
            PromptCacheHoverTracker { isHovering in
                if isHovering {
                    presentation.clockEntered(place: place, instance: instance, anchor: frame, target: mark.target)
                } else {
                    presentation.clockExited(place: place, instance: instance)
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            self.frame = frame
            presentation.clockMoved(place: place, instance: instance, anchor: frame)
        }
        .onDisappear {
            presentation.clockDisappeared(place: place, instance: instance)
        }
        .accessibilityLabel(mark.accessibilityLabel)
        .accessibilityValue(mark.accessibilityValue)
        // Only the expired panel offers answers; the expiring one informs,
        // so it gets no hint.
        .modifier(OptionalAccessibilityHint(hint: mark.status == .expired ? Text("Shows ways to continue") : nil))
        // Opened from VoiceOver, the panel must not close because the
        // pointer happens to be elsewhere; the trigger says so.
        .accessibilityAction {
            presentation.open(
                target: mark.target,
                place: place,
                clock: .init(instance: instance, frame: frame),
                trigger: .accessibility
            )
        }
    }
}

/// The clock in a split pane's header, or nothing while the pane's agent
/// has none. Its own view so the header names it in one line and drops it
/// together with the state mark beside it.
struct PromptCachePaneClock: View {
    let paneID: UUID
    @Environment(AttentionState.self) private var attention

    var body: some View {
        if let mark = attention.promptCacheMark(paneID: paneID) {
            PromptCacheMarkView(mark: mark, place: .paneHeader(paneID: paneID))
        }
    }
}

/// An accessibility hint only when there is one to give, rather than an
/// empty one.
private struct OptionalAccessibilityHint: ViewModifier {
    let hint: Text?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

extension View {
    /// Offers the clock's panel as a named accessibility action on a header
    /// that folds its children into one element, where the clock's own
    /// action would not be reachable. No action while there is no clock.
    func promptCacheAccessibilityAction(
        _ mark: PromptCacheMark?,
        places: @escaping (PromptCacheMark) -> [PromptCacheClockPlace]
    ) -> some View {
        modifier(PromptCacheAccessibilityAction(mark: mark, places: places))
    }
}

private struct PromptCacheAccessibilityAction: ViewModifier {
    let mark: PromptCacheMark?
    /// The clocks the panel may hang from, first choice first; the first
    /// one on screen is used.
    let places: (PromptCacheMark) -> [PromptCacheClockPlace]
    @Environment(PromptCachePanelPresentation.self) private var presentation

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if let mark {
                Button {
                    presentation.open(target: mark.target, places: places(mark), trigger: .accessibility)
                } label: {
                    Text("Show Prompt Cache")
                }
            }
        }
    }
}

/// Tells a clock when the pointer arrives on it and leaves, from an AppKit
/// tracking area over the clock's own frame.
///
/// A tracking area rather than `onHover`, so whether the pointer is on the
/// clock is answered from the clock's geometry alone, the same way in a tab
/// row and inside a pane header full of hover, tap and drag handling of its
/// own.
///
/// The area is the view's bounds, not `.inVisibleRect`: SwiftUI hosts this
/// view in a container whose visible rect is the visible part of the row or
/// the window around it, measured in tests at the whole header strip or
/// the whole window, so a visible-rect area fires wherever the pointer goes
/// in that region rather than on the clock.
///
/// Exits are also checked against where the pointer is. One that arrives
/// while the pointer is still on the clock is not a departure, and the area
/// is armed again, assuming the pointer inside, so the real departure still
/// reports one; a stray exit cannot close the panel under a resting
/// pointer.
private struct PromptCacheHoverTracker: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context _: Context) -> TrackingView {
        let view = TrackingView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ view: TrackingView, context _: Context) {
        view.onHoverChanged = onHoverChanged
    }

    static func dismantleNSView(_ view: TrackingView, coordinator _: ()) {
        view.endTracking()
    }

    @MainActor final class TrackingView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        /// What was last reported, so an enter or exit is reported once.
        private var isInside = false

        /// Clicks go to the clock's button under this view, never here.
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Laid out on the next pass; ask where the pointer is once the
            // frame is real.
            DispatchQueue.main.async { [weak self] in
                self?.checkPointer()
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            arm()
            checkPointer()
        }

        override func mouseEntered(with _: NSEvent) {
            guard isTracking else { return }
            setInside(true)
        }

        override func mouseExited(with _: NSEvent) {
            if isPointerInside == true {
                // Not a departure. Armed again assuming the pointer inside,
                // so leaving for real still sends an exit.
                trackerLog.debug("prompt cache clock exit ignored: the pointer is still on the clock")
                arm()
                return
            }
            setInside(false)
        }

        /// The clock is leaving the screen; a pointer on it leaves with it.
        func endTracking() {
            setInside(false)
            onHoverChanged = nil
        }

        /// Replaces the tracking area with one over the bounds. While the
        /// pointer is reported inside it is armed assuming so, which makes
        /// the next event the exit. AppKit calls `updateTrackingAreas` again
        /// whenever the view's geometry changes, so the rect stays current.
        private func arm() {
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp]
            if isInside {
                options.insert(.assumeInside)
            }
            addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
        }

        /// A tracking area added under a resting pointer reports nothing
        /// until the pointer moves, so a clock that appears or moves under
        /// it asks where the pointer is.
        private func checkPointer() {
            guard isTracking, let isPointerInside else { return }
            setInside(isPointerInside)
        }

        /// Whether the pointer's arrival may count. Not while the app is in
        /// the background, where a pointer passing over the window is not
        /// the user turning to this clock, nor while the window is hidden.
        /// Departures always count.
        private var isTracking: Bool {
            NSApp.isActive && window?.isVisible == true
        }

        /// Whether the pointer is over this view, or nil when there is no
        /// window or no frame to ask about yet.
        private var isPointerInside: Bool? {
            guard let window, !bounds.isEmpty else { return nil }
            return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }

        private func setInside(_ isInside: Bool) {
            guard self.isInside != isInside else { return }
            self.isInside = isInside
            if isInside {
                // From now on the next event is the exit.
                arm()
            }
            onHoverChanged?(isInside)
        }
    }
}

/// The clock trackers' debug log, under the panel's category so one stream
/// shows both.
private let trackerLog = Logger.limpid("prompt-cache.panel")
