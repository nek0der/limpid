// TerminalScrollView.swift
// Limpid — hosts a terminal surface in a native, libghostty-driven scroll view.

import AppKit
import GhosttyKit

/// Uses the same native-scroll-document architecture as Ghostty's MIT-licensed
/// macOS `SurfaceScrollView`, adapted to Limpid's persistent surface lifecycle.
@MainActor
final class TerminalScrollView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let surfaceView: SurfaceView
    private var isLiveScrolling = false
    private var lastSentRow: UInt64?

    /// SwiftUI can retain an old host after reparenting its persistent surface.
    /// We use the actual view hierarchy as the authority for geometry and input.
    private var isSurfaceMounted: Bool {
        surfaceView.superview === documentView
    }

    init(surfaceView: SurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)

        autoresizesSubviews = true
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.contentView.clipsToBounds = false
        // We size the renderer from the viewport, never from the history.
        // Otherwise the surface's flexible height turns every document growth
        // into a terminal resize and feeds new row counts back into this host.
        documentView.autoresizesSubviews = false
        scrollView.documentView = documentView
        addSubview(scrollView)
        documentView.addSubview(surfaceView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        observeScrollView()
        surfaceView.onScrollbarStateChange = { [weak self] state in
            self?.applyScrollbarState(state)
        }
        surfaceView.onScrollGesture = { [weak self] in
            self?.scrollView.flashScrollers()
        }
        applyScrollbarState(surfaceView.scrollbarState)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layoutContent(for: bounds.size)
    }

    override func updateTrackingAreas() {
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        super.updateTrackingAreas()
        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [.mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        scrollView.flashScrollers()
    }

    /// GeometryReader reaches the final pane size before AppKit's frame
    /// cascade during live resize. Keep this second channel so libghostty's
    /// Metal surface and the native scroller resize in the same frame.
    func applyExpectedSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        layoutContent(for: size)
    }

    private func observeScrollView() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(preferredScrollerStyleDidChange(_:)),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        center.addObserver(
            self,
            selector: #selector(liveScrollWillStart(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        center.addObserver(
            self,
            selector: #selector(liveScrollDidChange(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        center.addObserver(
            self,
            selector: #selector(liveScrollDidEnd(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
    }

    @objc private func preferredScrollerStyleDidChange(_ notification: Notification) {
        // AppKit applies the new system preference to existing scroll views.
        // We retain overlay scrollers so they never consume terminal columns.
        scrollView.scrollerStyle = .overlay
    }

    @objc private func scrollBoundsDidChange(_ notification: Notification) {
        synchronizeSurfaceOrigin()
    }

    @objc private func liveScrollWillStart(_ notification: Notification) {
        isLiveScrolling = true
    }

    @objc private func liveScrollDidChange(_ notification: Notification) {
        synchronizeSurfaceOrigin()
        sendLiveScrollPosition()
    }

    @objc private func liveScrollDidEnd(_ notification: Notification) {
        isLiveScrolling = false
        let viewportHeight = scrollView.contentView.documentVisibleRect.height
        synchronizeScrollPosition(viewportHeight: viewportHeight)
        synchronizeSurfaceOrigin()
    }

    private func layoutContent(for size: CGSize) {
        guard isSurfaceMounted else { return }
        scrollView.frame = NSRect(origin: .zero, size: size)
        let viewport = scrollView.contentSize
        documentView.frame.size.width = viewport.width
        surfaceView.frame.size = viewport
        synchronizeDocumentHeight(viewportHeight: viewport.height)
        synchronizeScrollPosition(viewportHeight: viewport.height)
        synchronizeSurfaceOrigin()
    }

    private func applyScrollbarState(_ state: TerminalScrollbarState?) {
        guard isSurfaceMounted else { return }
        scrollView.hasVerticalScroller = surfaceView.isScrollbarEnabled && state?.isScrollable == true
        let viewportHeight = scrollView.contentSize.height
        synchronizeDocumentHeight(viewportHeight: viewportHeight)
        synchronizeScrollPosition(viewportHeight: viewportHeight)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func synchronizeDocumentHeight(viewportHeight: CGFloat) {
        let height = surfaceView.scrollbarState?.documentHeight(for: viewportHeight)
            ?? max(0, viewportHeight)
        documentView.frame.size.height = height
    }

    private func synchronizeScrollPosition(viewportHeight: CGFloat) {
        guard isSurfaceMounted, !isLiveScrolling, let state = surfaceView.scrollbarState else { return }
        let originY = state.documentOriginY(for: viewportHeight)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: originY))
        // `NSView.boundsDidChangeNotification` is not guaranteed to arrive
        // before the next display pass. Move the Metal surface in the same
        // transaction so a growing document never exposes an empty clip view.
        synchronizeSurfaceOrigin()
        lastSentRow = state.offset
    }

    private func synchronizeSurfaceOrigin() {
        guard isSurfaceMounted else { return }
        surfaceView.frame.origin = scrollView.contentView.documentVisibleRect.origin
    }

    private func sendLiveScrollPosition() {
        guard isSurfaceMounted, isLiveScrolling,
              let state = surfaceView.scrollbarState,
              let surface = surfaceView.surface
        else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let row = state.rowOffset(
            forDocumentOriginY: visible.origin.y,
            viewportHeight: visible.height
        )
        guard row != lastSentRow else { return }
        lastSentRow = row
        let action = "scroll_to_row:\(row)"
        GhosttyFFI.performBindingAction(action, on: surface)
    }
}
