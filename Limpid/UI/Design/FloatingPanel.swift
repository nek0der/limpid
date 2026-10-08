// FloatingPanel.swift
// Limpid — the pieces Limpid's arrowed floating panels share: the outline
// with its arrow, the frame that places the panel below or above what opened
// it, and the monitor that closes it on Escape or a click elsewhere.
//
// The prompt cache panel and the container color picker are drawn this way,
// at scene root on the command palette's surface, rather than through
// `.popover`. A popover's arrow, frame and corner radius cannot be changed,
// so it could never match the app's other floating panels; and with one
// open, a click elsewhere only dismissed it (see `PRHoverCard`). Where the
// panel goes is `FloatingPanelPlacement`'s job; these views lay that out.

import AppKit
import SwiftUI

/// Hosts an arrowed floating panel over a whole window: the request's
/// panel while one is open, nothing otherwise. Owns what every such host
/// needs and is easy to get subtly wrong: reading the window's frame, an
/// identity per opening (which restarts the measurement), the fade and its
/// Reduce Motion substitute, and reaching past the safe area. Empty regions
/// pass clicks through to the window, as `PRHoverCardHost`'s do.
struct FloatingArrowPanelHost<Request: FloatingPanelRequest, Content: View>: View {
    /// The open panel, or nil.
    let request: Request?
    let width: CGFloat
    /// A mouse button went down outside the panel. The click still reaches
    /// what it landed on.
    let onPointerPressedOutside: () -> Void
    /// A key went down. True spends it, so it reaches nothing else.
    let onKey: (FloatingPanelKey) -> Bool
    /// Whether a press on the anchor is left to the anchor's own control,
    /// which then toggles the panel, rather than closing it as a click
    /// outside. For an anchor that is a button opening this panel; without
    /// it the press would close the panel and the release reopen it.
    var isAnchorPressLeftToAnchor = false
    /// The pointer came onto or left the panel, for a panel that closes
    /// when the pointer has gone.
    var onHover: ((Bool) -> Void)?
    @ViewBuilder let content: (Request) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { overlay in
            if let request {
                FloatingArrowPanel(
                    anchor: request.anchor,
                    container: overlay.frame(in: .global),
                    width: width,
                    onPointerPressedOutside: onPointerPressedOutside,
                    onKey: onKey,
                    isAnchorPressLeftToAnchor: isAnchorPressLeftToAnchor,
                    onHover: onHover
                ) {
                    content(request)
                }
                .transition(.opacity)
                .id(request.id)
            }
        }
        .ignoresSafeArea()
        // Off under Reduce Motion, as the other floating panels do.
        .animation(reduceMotion ? nil : LimpidMotion.paletteToggle, value: request?.id)
    }
}

/// An arrowed floating panel: `content` at `width` on the floating panel
/// surface, centered on `anchor` and hung below it, or above it near the
/// window's bottom, clamped into the window, with its arrow pointing at the
/// anchor from wherever it ended up. Watches the window's keys and clicks
/// while up. Held back until measured, so a panel near the bottom never
/// shows below its anchor for a frame and then jumps above it.
/// `FloatingArrowPanelHost` gives each opening its own identity, which
/// starts the measurement afresh.
struct FloatingArrowPanel<Content: View>: View {
    /// What the panel hangs from, in global coordinates.
    let anchor: CGRect
    /// The host overlay's frame in global coordinates: the window's content.
    let container: CGRect
    let width: CGFloat
    let onPointerPressedOutside: () -> Void
    let onKey: (FloatingPanelKey) -> Bool
    let isAnchorPressLeftToAnchor: Bool
    let onHover: ((Bool) -> Void)?
    @ViewBuilder let content: Content

    /// The panel's measured height. Zero until the first layout.
    @State private var height: CGFloat = 0

    var body: some View {
        let local = anchor.offsetBy(dx: -container.minX, dy: -container.minY)
        let size = CGSize(width: width, height: height)
        let origin = FloatingPanelPlacement.origin(
            anchor: local,
            panelSize: size,
            container: container.size,
            margin: LimpidLayout.floatingPanelWindowMargin,
            gap: LimpidLayout.floatingPanelArrowAnchorGap,
            alignment: .centered
        )
        // Points at the anchor from wherever the clamping above put the
        // panel, so the panel says where it came from even when it has slid
        // over the rows or panes beside it.
        let arrow = FloatingPanelPlacement.arrow(
            anchor: local,
            panelOrigin: origin,
            panelSize: size,
            minimumInset: LimpidLayout.floatingPanelArrowInset
        )
        content
            .frame(width: width, alignment: .leading)
            .onHover { onHover?($0) }
            // Behind the content and inside the surface's frame, so the
            // monitor's bounds are the panel's own.
            .background(FloatingPanelEventMonitor(
                onPointerPressedOutside: onPointerPressedOutside,
                onKey: onKey,
                anchorInPanel: isAnchorPressLeftToAnchor
                    ? local.offsetBy(dx: -origin.x, dy: -origin.y)
                    : nil
            ))
            .floatingPanelSurface(in: FloatingPanelShape(
                cornerRadius: LimpidLayout.floatingPanelCornerRadius,
                arrow: arrow,
                arrowHeight: LimpidLayout.floatingPanelArrowHeight
            ))
            .pointerStyle(.default)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .opacity(height > 0 ? 1 : 0)
            .offset(x: origin.x, y: origin.y)
    }
}

/// A floating panel's outline: its rounded rectangle with an arrow on the
/// edge that faces its anchor, drawn as one closed path so the surface fills
/// and strokes it as one piece, with no seam where the arrow meets the edge.
/// The arrow stands outside the panel's frame, in the gap left for it.
struct FloatingPanelShape: Shape {
    let cornerRadius: CGFloat
    /// Nil draws the plain rounded rectangle.
    let arrow: FloatingPanelPlacement.Arrow?
    /// How far the tip stands out, which is also the half-width of its base,
    /// as for a square turned 45 degrees.
    let arrowHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let topArrowX = arrow?.edge == .top ? arrow.map { rect.minX + $0.x } : nil
        let bottomArrowX = arrow?.edge == .bottom ? arrow.map { rect.minX + $0.x } : nil
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        if let x = topArrowX {
            path.addLine(to: CGPoint(x: x - arrowHeight, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.minY - arrowHeight))
            path.addLine(to: CGPoint(x: x + arrowHeight, y: rect.minY))
        }
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
            radius: radius
        )
        if let x = bottomArrowX {
            path.addLine(to: CGPoint(x: x + arrowHeight, y: rect.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + arrowHeight))
            path.addLine(to: CGPoint(x: x - arrowHeight, y: rect.maxY))
        }
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: radius
        )
        path.closeSubpath()
        return path
    }
}

/// A key press while a floating panel is up, as the panel's monitor saw it.
struct FloatingPanelKey: Equatable {
    /// Escape with no modifier.
    let isEscape: Bool
    /// The key goes to a terminal, which is typing at a prompt, rather than
    /// to the panel's own controls.
    let isTypingInTerminal: Bool
}

/// Watches the window's keys and clicks while a floating panel is up. An
/// AppKit monitor because the keyboard stays with the terminal while the
/// panel is up: the panel never takes focus, so SwiftUI's own key handling
/// would not see the keys. Placed as the panel's background, so its bounds
/// are the panel's.
struct FloatingPanelEventMonitor: NSViewRepresentable {
    /// A mouse button went down outside the panel. The click still reaches
    /// what it landed on.
    let onPointerPressedOutside: () -> Void
    /// A key went down. True spends it, so it reaches nothing else.
    let onKey: (FloatingPanelKey) -> Bool
    /// The anchor in the panel's own coordinates (top-left origin), when a
    /// press on it is left to the anchor; nil when it counts as outside.
    var anchorInPanel: CGRect?

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.onPointerPressedOutside = onPointerPressedOutside
        view.onKey = onKey
        view.anchorInPanel = anchorInPanel
    }

    static func dismantleNSView(_ view: MonitorView, coordinator _: ()) {
        view.removeMonitor()
    }

    /// Whether a press at `location`, in the monitor's own coordinates,
    /// lands on `anchor`, given in the panel's coordinates, which run down
    /// from the top. The monitor's run up from the bottom unless the view is
    /// flipped, so the press is turned over first.
    nonisolated static func isPress(
        at location: CGPoint,
        onAnchor anchor: CGRect,
        panelHeight: CGFloat,
        isFlipped: Bool
    ) -> Bool {
        let fromTop = isFlipped ? location : CGPoint(x: location.x, y: panelHeight - location.y)
        return anchor.contains(fromTop)
    }

    @MainActor final class MonitorView: NSView {
        var onPointerPressedOutside: (() -> Void)?
        var onKey: ((FloatingPanelKey) -> Bool)?
        var anchorInPanel: CGRect?
        private var monitor: Any?

        /// Never the target of a click: a press on the panel's padding
        /// belongs to the panel, not to this watcher behind it.
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitor()
            }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self, let window, event.window === window else { return event }
                guard event.type == .keyDown else {
                    // A click on the panel itself is for its controls. Asked
                    // of the panel's frame rather than of any hover state: a
                    // panel that opened under a pointer that never moved has
                    // had no hover, and closing it here would eat the click
                    // before the control sees it.
                    let location = convert(event.locationInWindow, from: nil)
                    let isOnAnchor = anchorInPanel.map { anchor in
                        FloatingPanelEventMonitor.isPress(
                            at: location,
                            onAnchor: anchor,
                            panelHeight: bounds.height,
                            isFlipped: isFlipped
                        )
                    } ?? false
                    if !bounds.contains(location), !isOnAnchor {
                        onPointerPressedOutside?()
                    }
                    return event
                }
                // An input method composing text owns its keys, Escape
                // included.
                if let input = window.firstResponder as? any NSTextInputClient, input.hasMarkedText() {
                    return event
                }
                let key = FloatingPanelKey(
                    isEscape: event.namedKey == .escape
                        && event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
                    isTypingInTerminal: window.firstResponder is SurfaceView
                )
                return onKey?(key) == true ? nil : event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
