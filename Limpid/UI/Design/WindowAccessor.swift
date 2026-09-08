// WindowAccessor.swift
// Limpid — `NSViewRepresentable` bridge that exposes the hosting
// `NSWindow` to SwiftUI so we can apply Liquid Glass toolbar tweaks.

import AppKit
import OSLog
import SwiftUI

private let log = Logger.limpid("window.toolbar")

/// Bridge that hands back the underlying `NSWindow` to SwiftUI.
///
/// SwiftUI's `WindowGroup` hides the `NSWindow`, but we need direct access
/// to set transparency / titlebar style for the Liquid Glass look. Drop
/// this as a `.background(WindowAccessor { ... })` and the closure fires
/// once the view is in a window.
///
/// **One-shot semantics:** both `configure` and `repositionsTrafficLights`
/// are captured at init time and consumed exactly once from
/// `viewDidMoveToWindow`. A SwiftUI re-render that passes a fresh
/// closure / flag is **not** observed — the previously-applied values
/// keep running. Pass stable closures only.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    /// When `true`, the view observes `didResizeNotification` and
    /// re-applies `repositionTrafficLights` after every resize. Leave
    /// it `false` for a window whose traffic lights should keep
    /// AppKit's own placement.
    let repositionsTrafficLights: Bool

    init(repositionsTrafficLights: Bool = false, configure: @escaping (NSWindow) -> Void) {
        self.repositionsTrafficLights = repositionsTrafficLights
        self.configure = configure
    }

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.configure = configure
        view.repositionsTrafficLights = repositionsTrafficLights
        return view
    }

    func updateNSView(_: NSView, context _: Context) {
        // No-op by design. `viewDidMoveToWindow` runs `configure`
        // exactly once; the post-init re-assignment that used to be
        // here was never observed (the closure isn't re-invoked, the
        // flag isn't re-read). Drop the misleading write so the
        // type's one-shot semantics read as intentional.
    }

    @MainActor
    private final class AccessorView: NSView {
        var configure: ((NSWindow) -> Void)?
        var repositionsTrafficLights: Bool = false
        private var didConfigure = false
        private var resizeObserver: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didConfigure, let window else { return }
            didConfigure = true
            configure?(window)
            guard repositionsTrafficLights else { return }
            // AppKit re-lays out the traffic lights back to their
            // default position on every resize, and we override their
            // vertical placement, so re-apply after every resize.
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated {
                    repositionTrafficLights(in: window)
                }
            }
        }

        isolated deinit {
            // Block-based observers live on `NotificationCenter` until
            // explicit removal; ARC releasing this view does NOT detach
            // the closure (the `[weak window]` capture prevents a cycle
            // but does not unhook the observation). Mirrors the
            // install/remove pattern used by `SurfaceView`,
            // `GitSyncCoordinator`, and `ReduceTransparencyResolver`.
            // `isolated deinit` (SE-0371) makes the destructor run on
            // MainActor so we can touch the non-Sendable `Any?`
            // token without breaking Swift 6 strict-concurrency.
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }
    }
}

/// Place the three traffic-light buttons: pushed down onto the top
/// strip's midline so their row shares a center with the toolbar
/// content beside it (both land at `topStripMidline`, 26 from the
/// window top, and the buttons occupy 19–33), and moved right so the
/// row carries the same left margin as the sidebar rows below it — see
/// `trafficLightOriginX`. The strip is the input and the buttons
/// follow, not the other way round.
///
/// The spacing is AppKit's own rather than a number of our own: we are
/// moving the row, not re-laying it out.
@MainActor
func repositionTrafficLights(in window: NSWindow) {
    // AppKit measures a titlebar subview from the titlebar's bottom, so
    // the arithmetic below turns this into the button's top edge in
    // window coordinates. Centering the row on the strip's midline puts
    // it on the same line as the toolbar content beside it.
    let originY = LimpidLayout.topStripMidline
        - LimpidLayout.trafficLightButtonSize / 2
    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for (index, type) in buttons.enumerated() {
        guard let button = window.standardWindowButton(type),
              let titlebar = button.superview else { continue }
        var frame = button.frame
        frame.origin.x = LimpidLayout.trafficLightOriginX
            + CGFloat(index) * LimpidLayout.trafficLightSpacing
        frame.origin.y = titlebar.bounds.height - originY - frame.height
        button.frame = frame
        button.autoresizingMask = [.maxXMargin, .minYMargin]
    }
}

extension View {
    /// Transparent-title-bar toolbar for the main terminal window. The
    /// AppKit traffic lights are pushed down so their row lines up with
    /// the toolbar content in each column. Pair with the resize-aware
    /// observer in `WindowAccessor` so the offset survives AppKit's
    /// re-layouts.
    func limpidWindowToolbar(onWindow: ((NSWindow) -> Void)? = nil) -> some View {
        background(WindowAccessor(repositionsTrafficLights: true) { window in
            onWindow?(window)
            applyTransparentTitleToolbar(to: window, clearBackground: true)
            repositionTrafficLights(in: window)
        })
    }

    /// Flush-sidebar toolbar for the Settings window. Same transparent
    /// title bar as the main window so the toolbar strip blends with
    /// the sidebar, but the window stays opaque — Settings has no
    /// terminal painting its own background, so a clear `NSWindow` would
    /// show through in Mission Control / Exposé snapshots. The traffic
    /// lights go through the same `repositionTrafficLights` the main
    /// window uses, so they land on the strip's midline and at the
    /// sidebar's own left margin here too. Settings' sidebar is
    /// narrower than the main window's and does not resize, but the
    /// margin the buttons align to is the row indent, which both
    /// windows share.
    func limpidSettingsToolbar(onWindow: ((NSWindow) -> Void)? = nil) -> some View {
        background(WindowAccessor(repositionsTrafficLights: true) { window in
            onWindow?(window)
            // `clearBackground: true` so the SwiftUI body's
            // behind-window `NSVisualEffectView` (see
            // `SettingsScene.settingsBaseFill`) can actually read
            // the wallpaper. An opaque `NSWindow` would block the VEV
            // and we'd see a flat fill instead of Liquid Glass.
            applyTransparentTitleToolbar(to: window, clearBackground: true)
            repositionTrafficLights(in: window)
        })
    }
}

/// Shared toolbar setup: transparent title bar so the SwiftUI content
/// (sidebar, panes, glass slabs) flows into the toolbar area.
/// `clearBackground` controls whether the underlying `NSWindow` is made
/// see-through. The terminal window needs it (libghostty paints its own
/// background); Settings does not (the desktop would leak through).
@MainActor
private func applyTransparentTitleToolbar(to window: NSWindow, clearBackground: Bool = true) {
    if clearBackground {
        window.isOpaque = false
        window.backgroundColor = .clear
    }
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.styleMask.insert(.fullSizeContentView)
    // Disable "drag-anywhere-to-move-window" so it doesn't steal the
    // .draggable gestures on tabs and the sidebar. Dragging from the
    // title-bar strip (where the traffic lights live) still works.
    window.isMovableByWindowBackground = false
}
