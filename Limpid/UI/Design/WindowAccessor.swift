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
    /// re-applies `repositionTrafficLights` after every resize. Pass
    /// `false` for windows whose traffic lights stay at default
    /// position (e.g. Settings).
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
            // default position on every resize. The main window's
            // floating slab needs them at a custom offset, so re-apply
            // after every resize.
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

/// Slide the three traffic-light buttons inward to land inside the container column
/// floating slab. Apple's apps with flush-edge sidebars don't need
/// this — Limpid does because its sidebar is a floating Liquid Glass
/// card inset by `LimpidLayout.containerColumnInsetH`. The offset puts the
/// close-button center near (x: 20, y: 14 from window top), inside
/// the rounded slab corner.
@MainActor
func repositionTrafficLights(in window: NSWindow) {
    let originX: CGFloat = 26 // slab inset (10) + corner radius (10) + 6 margin
    let originY: CGFloat = 22 // pushes the row below the slab top edge
    let spacing: CGFloat = 20
    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    for (index, type) in buttons.enumerated() {
        guard let button = window.standardWindowButton(type),
              let titlebar = button.superview else { continue }
        var frame = button.frame
        frame.origin.x = originX + CGFloat(index) * spacing
        frame.origin.y = titlebar.bounds.height - originY - frame.height
        button.frame = frame
        button.autoresizingMask = [.maxXMargin, .minYMargin]
    }
}

extension View {
    /// Floating Liquid Glass toolbar for the main terminal window. The
    /// container column sidebar is a floating card inset by `LimpidLayout.containerColumnInsetH`,
    /// so the AppKit traffic lights need to slide inward to land
    /// inside the card (otherwise they draw on bare window
    /// background). Pair with the resize-aware observer in
    /// `WindowAccessor` so the offset survives AppKit's re-layouts.
    func limpidWindowToolbar(onWindow: ((NSWindow) -> Void)? = nil) -> some View {
        background(WindowAccessor(repositionsTrafficLights: true) { window in
            onWindow?(window)
            applyTransparentTitleToolbar(to: window, clearBackground: true)
            // Container slab inset is 10pt + 10pt corner radius → push the
            // close button to (26, 22) so it lands inside the slab.
            repositionTrafficLights(in: window)
        })
    }

    /// Flush-sidebar toolbar for the Settings window. Same transparent
    /// title bar as the main window so the toolbar strip blends with
    /// the sidebar, but the window stays opaque — Settings has no
    /// terminal painting its own background, so a clear `NSWindow` would
    /// show through in Mission Control / Exposé snapshots. Traffic
    /// lights stay at their AppKit default (8, 14), which already
    /// lands inside Settings' flush sidebar (Notes / Mail / System
    /// Settings pattern).
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
