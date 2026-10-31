// ProjectWindowController.swift
// Limpid — one app-owned main window, closed or hidden through the registry.

import AppKit
import SwiftUI

/// Owns one supervision window: an `NSWindow` whose content is SwiftUI.
///
/// App-owned rather than a SwiftUI `WindowGroup` window so closing goes
/// through the registry with the public delegate API alone, which hides
/// the last window rather than closing it. A scene window closes for
/// real; retargeting its close button still lets ⌘W close it in full
/// screen, and wrapping its delegate depends on a private SwiftUI class
/// that a later release could change. The window is also never restored
/// by AppKit or SwiftUI: Limpid restores its own windows from the session,
/// so the system restoring one too would open it twice.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate {
    /// The size a window opens at before it has a saved frame.
    static let initialContentSize = NSSize(width: 1280, height: 800)
    /// The smallest the window's root may be laid out at, under
    /// the title bar; the window's `contentMinSize` adds the title bar.
    static let minimumContentSize = NSSize(
        width: LimpidLayout.Supervision.windowMinWidth,
        height: LimpidLayout.mainWindowMinHeight
    )

    /// What the controller tells its owner about its window.
    struct Events {
        /// The window was asked to close; the registry closes it, or hides
        /// it when it is the last one shown.
        let close: (WindowID) -> Void
        let becameKey: (WindowID) -> Void
        /// The window gave the keyboard up — to another main window, which
        /// reports in turn, or to Settings, a sheet, or the quick terminal,
        /// which do not.
        let resignedKey: (WindowID) -> Void
        /// The window began its transition into full screen.
        let willEnterFullScreen: (WindowID) -> Void
        /// The window arrived in full screen, or could not.
        let fullScreenSettled: (WindowID) -> Void
    }

    let windowID: WindowID
    private let events: Events
    /// Held for the window's lifetime; set once the window exists, because
    /// the observers need it.
    private var syncs: WindowSyncs?
    /// Whether the window was saved in full screen and has not been shown
    /// since: the presenter takes it back into full screen once shown.
    var entersFullScreenWhenShown = false

    init(
        windowID: WindowID,
        rootView: AnyView,
        contentSize: NSSize = initialContentSize,
        events: Events
    ) {
        self.windowID = windowID
        self.events = events
        let minimum = Self.minimumContentSize
        let hosting = NSHostingController(rootView: AnyView(
            MainWindowMinimumLayout(minimum: minimum) { rootView }
        ))
        // The window's frame is ours (the saved one, or the initial size),
        // not the content's ideal size. Its minimum is the hosting view's
        // to set: from the first layout in the window on, it writes the
        // window's `contentMinSize` itself, and with no `.minSize` it
        // writes zero over ours, which let a window be dragged narrower
        // than any surface fits. With `.minSize` it writes what its root
        // reports, and `MainWindowMinimumLayout` reports `minimum` alone,
        // whatever the content's own sizes, so the floor does not move
        // with the sidebar's width or a rigid view inside. To the height
        // it adds the title bar's safe area, which the root is laid out
        // under: 432pt for the root's 400 out of full screen.
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(contentSize)
        // The same value set here, for the time before the window is
        // shown: a saved frame is widened to it as the window's syncs bind
        // (`WindowFrameSync`). Asking the hosting view to write it now
        // would not do: before the window is on screen it knows a 1pt
        // safe area, not the title bar's, so it would write 401. The title
        // bar's height is known here from the window's own geometry
        // (`contentLayoutRect`), so the floor a restore widens to is the
        // one the hosting view holds the window to once it is shown.
        window.contentMinSize = Self.windowContentMinSize(for: window, rootMinimum: minimum)
        window.collectionBehavior.insert(.fullScreenPrimary)
        // The controller owns the window and lets it go once the presenter
        // drops the controller; AppKit releasing it on close too would
        // free it twice.
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Limpid has its own tabs; AppKit's window tabs would be a second set.
        window.tabbingMode = .disallowed
        // A supervision window is watched beside the app the person works
        // in, so the pointer often rests on it while Limpid is not the
        // active app. AppKit shows no tooltip in an inactive app's window
        // unless the window allows it, and every icon here is named by its
        // tooltip: without this, hovering the rails showed nothing.
        window.allowsToolTipsWhenApplicationIsInactive = true
        super.init(window: window)
        window.delegate = self
    }

    /// The window's content minimum for a root held to `rootMinimum`: the
    /// root's height plus the title bar the root is laid out under, as the
    /// hosting view counts it (`sizingOptions` `.minSize`).
    private static func windowContentMinSize(for window: NSWindow, rootMinimum: NSSize) -> NSSize {
        let content = window.contentRect(forFrameRect: window.frame)
        let titleBar = max(content.height - window.contentLayoutRect.height, 0)
        return NSSize(width: rootMinimum.width, height: rootMinimum.height + titleBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func bind(_ syncs: WindowSyncs) {
        self.syncs = syncs
    }

    /// Stops the observers, as the window is about to close for good.
    func unbind() {
        syncs = nil
    }

    /// The close button and Close Window, from the menu or its key, all end
    /// here, in and out of full screen. ⌘W never does: with nothing in the
    /// window to close it does nothing (`CloseKeyCommand.nothing`). AppKit closes
    /// nothing itself: the registry closes the window, or hides it when it
    /// is the last one shown (`WindowRegistry.close`).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        events.close(windowID)
        return false
    }

    /// The registry learns which window the person is in, which is the
    /// window the menu's commands act on (`WindowRegistry.commandTarget`):
    /// AppKit's answer, since SwiftUI's focused value is not published
    /// while an AppKit view (a terminal) is first responder.
    func windowDidBecomeKey(_: Notification) {
        events.becameKey(windowID)
    }

    func windowDidResignKey(_: Notification) {
        events.resignedKey(windowID)
    }

    /// The presenter takes saved windows into full screen one at a time
    /// (`FullScreenEntryQueue`); each start, arrival, or failure to arrive
    /// moves the line on.
    func windowWillEnterFullScreen(_: Notification) {
        events.willEnterFullScreen(windowID)
    }

    func windowDidEnterFullScreen(_: Notification) {
        events.fullScreenSettled(windowID)
    }

    /// No notification says this, so the selection, set to full screen as
    /// the transition began, learns it here.
    func windowDidFailToEnterFullScreen(_: NSWindow) {
        syncs?.fullScreenEntryFailed()
        events.fullScreenSettled(windowID)
    }
}
