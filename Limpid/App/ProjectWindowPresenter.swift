// ProjectWindowPresenter.swift
// Limpid — makes, shows, and hides the app-owned main windows.

import AppKit
import OSLog
import SwiftUI

private let log = Logger.limpid("window.presenter")

/// The app layer's side of `ProjectWindowPresenting`: one
/// `ProjectWindowController` per window, made the first time the window is
/// shown and kept after it is hidden, so showing it again brings back the
/// same window with its views and their state. A window closed for real
/// lets its controller go (`close`).
@MainActor
final class ProjectWindowPresenter: ProjectWindowPresenting {
    private let session: WorkspaceSession
    private weak var registry: WindowRegistry?
    private let makeRoot: (ProjectWindowState) -> AnyView
    private var controllers: [WindowID: ProjectWindowController] = [:]
    /// Where the last window opened from each window was put, its top-left,
    /// so the next one opened from that window steps on from it rather
    /// than landing on it (`place`). Let go with the window it is kept for.
    private var lastCascade: [WindowID: NSPoint] = [:]
    /// The windows saved in full screen, shown and going back into it.
    private var fullScreen = FullScreenEntryQueue()

    init(
        session: WorkspaceSession,
        registry: WindowRegistry,
        makeRoot: @escaping (ProjectWindowState) -> AnyView
    ) {
        self.session = session
        self.registry = registry
        self.makeRoot = makeRoot
    }

    func show(_ window: ProjectWindowState, openedFrom origin: WindowID?) {
        guard let controller = controllers[window.id] ?? makeController(for: window, openedFrom: origin) else {
            return
        }
        controller.showWindow(nil)
        fullScreen.shown(window.id)
        // A window saved in full screen goes back into it once it is on
        // screen; AppKit enters full screen only from a visible window.
        if controller.entersFullScreenWhenShown {
            controller.entersFullScreenWhenShown = false
            enterFullScreen(fullScreen.add(window.id))
        }
    }

    func raiseAfterFullScreenEntries(_ windowID: WindowID) {
        fullScreen.raiseWhenDone(windowID)
    }

    /// Takes `next`, the window whose turn it is (`FullScreenEntryQueue`),
    /// into full screen; once the line is done, brings the window last
    /// used back to the front, while it is still shown. A hidden window
    /// has left the line already (`hide`); one minimized meanwhile, or in
    /// full screen already, is passed over and stays as it is.
    private func enterFullScreen(_ next: WindowID?) {
        var next = next
        while let id = next {
            guard let window = controllers[id]?.window, window.isVisible, !window.styleMask.contains(.fullScreen) else {
                next = fullScreen.settled(id)
                continue
            }
            window.toggleFullScreen(nil)
            // AppKit can drop the request without a word; one that has not
            // begun by then lets the next go.
            let attempt = fullScreen.attempt
            Task { [weak self] in
                try? await Task.sleep(for: Self.fullScreenStartLimit)
                self?.fullScreenEntryTimedOut(id, attempt: attempt)
            }
            return
        }
        if let front = fullScreen.takeFrontIfDone(), registry?.window(front)?.isHidden == false {
            controllers[front]?.showWindow(nil)
        }
    }

    /// How long a window asked into full screen has to begin.
    private static let fullScreenStartLimit: Duration = .seconds(1)

    private func fullScreenEntryTimedOut(_ windowID: WindowID, attempt: Int) {
        let wasEntering = fullScreen.entering == windowID
        let next = fullScreen.timedOut(windowID, attempt: attempt)
        guard wasEntering, fullScreen.entering != windowID else { return }
        // Its saved full screen is lost with the dropped request: the
        // window stays as it is, and is saved so.
        log.notice("full screen request dropped for window \(windowID.rawValue.uuidString, privacy: .public)")
        enterFullScreen(next)
    }

    private func fullScreenEntryStarted(_ windowID: WindowID) {
        fullScreen.started(windowID)
    }

    private func fullScreenEntrySettled(_ windowID: WindowID) {
        enterFullScreen(fullScreen.settled(windowID))
    }

    func hide(_ windowID: WindowID) {
        let withdrawn = fullScreen.withdraw(windowID)
        // Hidden before it went back into full screen: it goes when shown
        // again, and is saved as in full screen meanwhile, as it was.
        if withdrawn.wasPending, let controller = controllers[windowID],
           controller.window?.styleMask.contains(.fullScreen) == false
        {
            controller.entersFullScreenWhenShown = true
            session.selections[windowID]?.isFullScreen = true
        }
        if let window = controllers[windowID]?.window {
            // A close question on a window going out of sight is answered
            // Cancel: no one can see it to answer.
            WindowAlert.cancelPending(on: window)
            window.orderOut(nil)
        }
        enterFullScreen(withdrawn.next)
    }

    /// Ends the window: it leaves the line into full screen, its observers
    /// stop before it goes so nothing it says as it closes reaches the
    /// selection or the registry, and its controller is let go with its
    /// SwiftUI views. AppKit closes a full screen window's Space with it.
    func close(_ windowID: WindowID) {
        lastCascade[windowID] = nil
        let withdrawn = fullScreen.withdraw(windowID)
        if let controller = controllers.removeValue(forKey: windowID) {
            controller.unbind()
            // Nothing the window says as it goes is the registry's now.
            controller.window?.delegate = nil
            // The SwiftUI content leaves first, so each terminal leaves the
            // window the usual way (it is told it has no window) rather
            // than as the window is freed, and no view of a closed window
            // can mount a terminal another window draws.
            controller.window?.contentViewController = nil
            controller.close()
            // The close button asks the controller itself
            // (`windowShouldClose`), and AppKit is still in that call: the
            // controller goes once it has returned.
            Task { @MainActor in
                withExtendedLifetime(controller) {}
            }
        }
        enterFullScreen(withdrawn.next)
    }

    /// The windows the presenter has made and not closed. Read by tests,
    /// which check a closed window's controller is let go.
    var windowIDs: Set<WindowID> {
        Set(controllers.keys)
    }

    /// The AppKit window drawing `windowID`, for what is shown on it (a
    /// close confirmation's sheet).
    func nsWindow(for windowID: WindowID) -> NSWindow? {
        controllers[windowID]?.window
    }

    func isOnScreen(_ windowID: WindowID) -> Bool {
        controllers[windowID]?.window?.isVisible ?? false
    }

    private func makeController(for state: ProjectWindowState, openedFrom origin: WindowID?) -> ProjectWindowController? {
        guard let registry, let selection = session.selections[state.id] else {
            // A window without a selection would show another window's
            // tabs; refusing is the only safe answer.
            log.error("no selection for window \(state.id.rawValue.uuidString, privacy: .public)")
            return nil
        }
        let controller = ProjectWindowController(
            windowID: state.id,
            rootView: makeRoot(state),
            events: ProjectWindowController.Events(
                close: { [weak registry, session = self.session] id in registry?.close(id, in: session) },
                becameKey: { [weak registry] id in registry?.windowBecameKey(id) },
                resignedKey: { [weak registry] id in registry?.windowResignedKey(id) },
                willEnterFullScreen: { [weak self] id in self?.fullScreenEntryStarted(id) },
                fullScreenSettled: { [weak self] id in self?.fullScreenEntrySettled(id) }
            )
        )
        guard let window = controller.window else { return nil }
        // Read before binding, which seeds the flag from the new window.
        controller.entersFullScreenWhenShown = selection.isFullScreen
        // Binding applies the saved frame, so it comes before placing a
        // window that has none.
        controller.bind(WindowSyncs(
            session: session,
            selection: selection,
            registry: registry,
            window: window
        ))
        if selection.frame == nil {
            place(window, openedFrom: origin)
        }
        controllers[state.id] = controller
        return controller
    }

    /// Places a window that has no saved frame. Opened from another
    /// window, it cascades from that window's top-left, the way AppKit
    /// staggers a new document window, so the title bars all show: one
    /// step past the window opened from it last, if any, else past the
    /// window itself (`cascadeTopLeft(after:from:step:size:inside:)`). It
    /// stays inside that window's screen. Otherwise it is centered.
    private func place(_ window: NSWindow, openedFrom origin: WindowID?) {
        guard let origin, let originWindow = controllers[origin]?.window,
              let visible = originWindow.screen?.visibleFrame
        else {
            window.center()
            return
        }
        // AppKit's own step: set on the origin's top-left, the window
        // answers the point one step down and right of it.
        let originTopLeft = NSPoint(x: originWindow.frame.minX, y: originWindow.frame.maxY)
        let shifted = window.cascadeTopLeft(from: originTopLeft)
        let step = CGSize(width: shifted.x - originTopLeft.x, height: originTopLeft.y - shifted.y)
        window.setFrameTopLeftPoint(Self.cascadeTopLeft(
            after: lastCascade[origin],
            from: originTopLeft,
            step: step,
            size: window.frame.size,
            inside: visible
        ))
        window.setFrameOrigin(Self.kept(window.frame, inside: visible).origin)
        lastCascade[origin] = NSPoint(x: window.frame.minX, y: window.frame.maxY)
    }

    /// The top-left of the next window cascaded from a window whose
    /// top-left is `origin`: one `step` down and right of `previous`, the
    /// last one placed from it, else of `origin`. A step that would take
    /// the window past the right or bottom edge of `visible` starts again
    /// one step in from its top-left corner, as AppKit's cascade wraps.
    static func cascadeTopLeft(
        after previous: NSPoint?,
        from origin: NSPoint,
        step: CGSize,
        size: CGSize,
        inside visible: CGRect
    ) -> NSPoint {
        let base = previous ?? origin
        let next = NSPoint(x: base.x + step.width, y: base.y - step.height)
        let isPastAnEdge = next.x + size.width > visible.maxX || next.y - size.height < visible.minY
        guard isPastAnEdge else { return next }
        return NSPoint(x: visible.minX + step.width, y: visible.maxY - step.height)
    }

    /// `frame` moved the least it takes to lie inside `visible`, its top
    /// edge first when it is the taller of the two.
    static func kept(_ frame: CGRect, inside visible: CGRect) -> CGRect {
        var kept = frame
        kept.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        kept.origin.y = max(min(frame.minY, visible.maxY - frame.height), min(visible.minY, visible.maxY - frame.height))
        return kept
    }
}
