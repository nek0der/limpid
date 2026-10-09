// QuickTerminalController.swift
// Limpid — shows and hides the quick terminal panel and owns the one
// shell it runs.
//
// The show / hide choreography (raise the panel above the menu bar while
// it slides, drop it to the floating level once it lands, take key status
// with a short retry, hand activation back before sliding out) follows
// the approach of Ghostty's macOS quick terminal (MIT, see
// THIRD-PARTY-NOTICES).

import AppKit
import OSLog
import SwiftUI

private let log = Logger.limpid("quick-terminal")

@MainActor
@Observable
final class QuickTerminalController {
    /// True from the start of a show until the start of a hide.
    private(set) var isVisible = false

    /// True while the panel, or a sheet attached to it, is the key window.
    /// Menu commands read it: while the panel has the keyboard, commands
    /// that act on the main window's session are disabled, and Close Pane
    /// hides the panel instead.
    private(set) var isPanelKey = false

    @ObservationIgnored let panel: QuickTerminalPanel
    @ObservationIgnored private let rootView: QuickTerminalRootView
    @ObservationIgnored private let content: QuickTerminalContentModel
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let secureInputManager: SecureInputManager
    @ObservationIgnored private let surfaceFactory: @MainActor () -> SurfaceView?

    /// Set for the length of a show or hide animation. Toggles that arrive
    /// meanwhile are ignored, and the `panelDidResignKey()` that activating
    /// the previous app fires during a hide is a no-op.
    @ObservationIgnored private var isAnimating = false

    /// A shell exit that arrived while the panel was sliding in. The hide
    /// has to wait for the show to finish.
    @ObservationIgnored private var isHidePendingAfterShow = false

    /// The app that was frontmost when the panel was summoned; it gets
    /// activation back on hide. `nil` when Limpid itself was frontmost, or
    /// once focus has moved to another Limpid window.
    @ObservationIgnored private var previousApp: NSRunningApplication?

    /// Follows `creationFailed` on the current surface so the panel can
    /// show the failure card. Dropped with the surface.
    @ObservationIgnored private var creationObservation: NSKeyValueObservation?

    /// Position the panel was shown at. A settings change while the panel
    /// is up must not make it slide out toward a different edge.
    @ObservationIgnored private var shownPosition: QuickTerminalPosition = .top

    /// Notification tokens, removed in `deinit`. `nonisolated(unsafe)`
    /// only so the deinit can hand them back to `NotificationCenter`.
    @ObservationIgnored private nonisolated(unsafe) var observers: [any NSObjectProtocol] = []

    /// Current shell's view, if one is running.
    var surfaceView: SurfaceView? {
        content.surfaceView
    }

    init(
        settingsStore: SettingsStore,
        reduceTransparencyResolver: ReduceTransparencyResolver,
        clipboard: ClipboardConfirmationCoordinator,
        secureInputManager: SecureInputManager,
        surfaceFactory: @escaping @MainActor () -> SurfaceView?
    ) {
        self.settingsStore = settingsStore
        self.secureInputManager = secureInputManager
        self.surfaceFactory = surfaceFactory
        let panel = QuickTerminalPanel()
        let content = QuickTerminalContentModel(
            settingsStore: settingsStore,
            reduceTransparencyResolver: reduceTransparencyResolver,
            clipboard: clipboard
        )
        content.panel = panel
        let hostingView = NSHostingView(rootView: QuickTerminalContent(model: content))
        // The frame is ours to set; letting SwiftUI publish size
        // constraints would fight the slide animation.
        hostingView.sizingOptions = []
        let rootView = QuickTerminalRootView(content: hostingView)
        panel.contentView = rootView
        self.panel = panel
        self.rootView = rootView
        self.content = content
        installWindowObservers()
        observeScreenChanges()
        observeClipboard(clipboard)
        observeLayoutSettings()
        observeAppLocale()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Whether `request` belongs to the panel, so the main window leaves
    /// it to the panel's own sheet.
    func ownsClipboardRequest(_ request: PendingClipboardRequest) -> Bool {
        request.view?.window === panel
    }

    // MARK: - Toggle

    /// Hotkey entry point.
    func toggle() {
        guard !isAnimating else { return }
        guard isVisible else {
            show()
            return
        }
        // Without hide-on-focus-loss the panel can stay on screen behind other
        // windows. Pressing the hotkey then brings it back to the
        // keyboard rather than putting it away.
        if !settingsStore.settings.quickTerminal.hidesOnFocusLoss, !panel.isKeyWindow {
            rememberPreviousApp()
            focusPanel(retries: Self.keyRetryCount)
            return
        }
        hide()
    }

    // MARK: - Show

    func show() {
        guard !isVisible, !isAnimating else { return }
        guard let screen = Self.screenUnderMouse() else {
            log.error("show skipped: no screen")
            return
        }
        rememberPreviousApp()
        let settings = settingsStore.settings.quickTerminal
        shownPosition = settings.position
        let target = QuickTerminalLayout.targetFrame(
            position: settings.position,
            sizePercent: settings.sizePercent,
            visibleFrame: screen.visibleFrame
        )
        let start = QuickTerminalLayout.animationFrame(
            position: settings.position,
            target: target,
            otherScreenFrames: Self.frames(ofScreensOtherThan: screen)
        )
        isVisible = true
        content.isPanelVisible = true
        isAnimating = true
        isHidePendingAfterShow = false

        // Order the invisible panel in at its final frame before the
        // surface mounts, so libghostty reads the target screen's backing
        // scale when it creates the surface. Only then move it past the
        // edge to slide from. `.popUpMenu` lets it draw over the menu bar
        // while it slides in from the top.
        panel.level = .popUpMenu
        panel.alphaValue = 0
        rootView.setRoundedCorners(QuickTerminalLayout.roundedCorners(for: settings.position))
        panel.setFrame(target, display: false)
        panel.orderFrontRegardless()
        prepareSurface()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setFrame(start, display: false)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.didFinishShowing()
            }
        }
    }

    private func didFinishShowing() {
        isAnimating = false
        guard isVisible else { return }
        if isHidePendingAfterShow {
            isHidePendingAfterShow = false
            hide()
            return
        }
        // Back below `.popUpMenu` so IME candidate windows, which open at
        // a lower level, are not hidden behind the panel.
        panel.level = .floating
        // The shadow was computed while the panel was transparent and
        // moving; recompute it from the rounded mask at the final frame.
        panel.invalidateShadow()
        focusPanel(retries: 0)
        // On a display without another Limpid window, key status can take
        // a few run-loop turns to stick.
        DispatchQueue.main.async { [weak self] in
            guard let self, !panel.isKeyWindow else { return }
            focusPanel(retries: Self.keyRetryCount)
        }
    }

    private func focusPanel(retries: Int) {
        guard isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        if let surfaceView, surfaceView.window === panel {
            panel.makeFirstResponder(surfaceView)
        }
        // Activate after the panel is key: activating first would bring
        // another Limpid window forward. The cooperative `activate()` can be
        // refused while another app is frontmost, so we ask to ignore it.
        // `NSApp.isActive` cannot gate this: keying a non-activating panel
        // makes it report true while the system still has the previous app
        // frontmost, so the activation would be skipped and the menu bar
        // (and ⌘V) would stay with that app.
        if !Self.isFrontmost {
            NSApp.activate(ignoringOtherApps: true)
        }
        guard !panel.isKeyWindow, retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            self?.focusPanel(retries: retries - 1)
        }
    }

    // MARK: - Hide

    func hide() {
        guard isVisible, !isAnimating else { return }
        // First, so the `panelDidResignKey()` that activating the previous
        // app fires below is ignored.
        isAnimating = true
        isVisible = false
        content.isPanelVisible = false

        // Hand activation back before sliding out; once the panel is gone
        // macOS would bring another Limpid window forward instead. Only
        // while Limpid is still active: if the user clicked a third app,
        // that app is already frontmost and must stay so. macOS 14 made
        // activation cooperative, so we yield before asking.
        if let previousApp, !previousApp.isTerminated, NSApp.isActive {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(options: [])
        }
        previousApp = nil

        if let surfaceView {
            // A prompt left up would hold libghostty's request with nobody
            // to answer it, and block every later prompt in the app.
            content.clipboard.cancelPending(for: surfaceView)
            // A half-typed IME composition would otherwise greet the next
            // show as stale preedit.
            surfaceView.inputContext?.discardMarkedText()
            surfaceView.unmarkText()
        }

        let end = QuickTerminalLayout.animationFrame(
            position: shownPosition,
            target: panel.frame,
            otherScreenFrames: Self.frames(ofScreensOtherThan: panel.screen)
        )
        panel.level = .popUpMenu
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.didFinishHiding()
            }
        }
    }

    private func didFinishHiding() {
        panel.orderOut(nil)
        isAnimating = false
    }

    // MARK: - Surface lifecycle

    /// Libghostty reported that `view`'s shell exited or asked to close
    /// it. Returns `false` when `view` is not the quick terminal's, so the
    /// caller can route it to the pane path.
    @discardableResult
    func handleSurfaceExit(_ view: SurfaceView) -> Bool {
        guard view === content.surfaceView else { return false }
        if isVisible {
            if isAnimating {
                isHidePendingAfterShow = true
            } else {
                hide()
            }
        }
        // Publish first so SwiftUI dismantles the representable and the
        // view leaves the hierarchy; the controller's own reference is the
        // last to go. The next show starts a fresh shell.
        content.surfaceView = nil
        creationObservation = nil
        content.isSurfaceCreationFailed = false
        content.clipboard.cancelPending(for: view)
        view.onSecureInputFocusChange = nil
        secureInputManager.remove(view)
        log.notice("quick terminal shell exited")
        return true
    }

    /// Create and mount the shell's view if there is none. Called by
    /// `show()` once the panel is on the target screen; internal so the
    /// lifecycle can be exercised without putting the panel on screen.
    func prepareSurface() {
        // A surface libghostty failed to allocate would otherwise come back
        // as the same empty panel on every summon; try it again instead.
        if let existing = content.surfaceView, existing.creationFailed, existing.window != nil {
            existing.createSurface()
        }
        guard content.surfaceView == nil else { return }
        guard let view = surfaceFactory() else {
            log.fault("quick terminal surface could not be created")
            return
        }
        // Panes get this wiring from `SurfaceRegistry.register`; the quick
        // terminal stays out of the registry, whose reconcile and occlusion
        // passes only know about panes.
        view.onSecureInputFocusChange = { [weak secureInputManager, weak view] isFocused in
            guard let view else { return }
            secureInputManager?.focusDidChange(for: view, isFocused: isFocused)
        }
        view.appLocale = { [settingsStore] in
            settingsStore.appLocale
        }
        content.surfaceView = view
        // `creationFailed` is set on the main thread by `createSurface`,
        // which is where KVO delivers the change.
        creationObservation = view.observe(\.creationFailed, options: [.initial, .new]) { [weak content] view, _ in
            MainActor.assumeIsolated {
                content?.isSurfaceCreationFailed = view.creationFailed
            }
        }
    }

    // MARK: - Observation

    private func installWindowObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                self?.windowDidBecomeKey(window)
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panelDidResignKey()
            }
        })
    }

    private func windowDidBecomeKey(_ window: NSWindow?) {
        guard let window else { return }
        isPanelKey = window === panel || window.sheetParent === panel
    }

    private func panelDidResignKey() {
        // A sheet on the panel takes key status but still belongs to it.
        isPanelKey = panel.attachedSheet != nil
        guard isVisible, !isAnimating else { return }
        // Keep the panel while one of our own alerts is up: the attached
        // clipboard sheet (set by `beginSheet` before the sheet becomes
        // key, whereas `NSApp.keyWindow` is still nil at this point), or an
        // app-modal alert such as the quit confirmation.
        guard panel.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        // Still active means focus moved to another Limpid window; that
        // window keeps focus, so there is no app to hand activation back to.
        if NSApp.isActive {
            previousApp = nil
        }
        if settingsStore.settings.quickTerminal.hidesOnFocusLoss {
            hide()
        }
    }

    /// Deny, rather than leave pending, a clipboard request from a process
    /// still running in the hidden panel: nothing presents it, and the
    /// single pending slot would auto-deny every later prompt in the app.
    private func observeClipboard(_ clipboard: ClipboardConfirmationCoordinator) {
        observeRepeatedly {
            _ = clipboard.pending
        } onChange: { [weak self, weak clipboard] in
            guard let self, let clipboard,
                  let request = clipboard.pending,
                  let surfaceView,
                  request.view === surfaceView,
                  !isVisible
            else { return }
            log.notice("clipboard request from the hidden quick terminal denied")
            clipboard.deny()
        }
    }

    /// With hide-on-focus-loss off the panel can be up while Settings is used, so a
    /// new position or size applies at once, without animation.
    /// The panel's title is read by assistive technologies whether or not
    /// the panel is on screen, so it follows the app locale as it changes.
    private func observeAppLocale() {
        panel.applyTitle(locale: settingsStore.appLocale)
        observeRepeatedly { [weak self] in
            _ = self?.settingsStore.appLocale
        } onChange: { [weak self] in
            guard let self else { return }
            panel.applyTitle(locale: settingsStore.appLocale)
        }
    }

    private func observeLayoutSettings() {
        observeRepeatedly { [weak self] in
            _ = self?.settingsStore.settings.quickTerminal.position
            _ = self?.settingsStore.settings.quickTerminal.sizePercent
        } onChange: { [weak self] in
            self?.relayoutIfVisible()
        }
    }

    /// A display being attached, removed, or rearranged, or the Dock or
    /// menu bar changing size, moves the visible frame the panel was laid
    /// out against.
    private func observeScreenChanges() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relayoutIfVisible()
            }
        })
    }

    private func relayoutIfVisible() {
        guard isVisible, !isAnimating else { return }
        // When the panel's display was removed, AppKit may still report it
        // (or none) until the window is moved; the display under the mouse
        // is where the user is looking.
        let panelScreen = panel.screen.flatMap { screen in
            NSScreen.screens.contains(screen) ? screen : nil
        }
        guard let screen = panelScreen ?? Self.screenUnderMouse() else { return }
        let settings = settingsStore.settings.quickTerminal
        shownPosition = settings.position
        rootView.setRoundedCorners(QuickTerminalLayout.roundedCorners(for: settings.position))
        panel.setFrame(
            QuickTerminalLayout.targetFrame(
                position: settings.position,
                sizePercent: settings.sizePercent,
                visibleFrame: screen.visibleFrame
            ),
            display: true
        )
        panel.invalidateShadow()
    }

    // MARK: - Helpers

    private func rememberPreviousApp() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            previousApp = nil
            return
        }
        previousApp = front
    }

    private static let keyRetryCount = 10

    /// Whether the system has Limpid frontmost. We ask `NSWorkspace`
    /// rather than `NSApp.isActive`, which a key non-activating panel
    /// reports as true while another app still owns the menu bar.
    private static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
    }

    private static var animationDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
    }

    private static func frames(ofScreensOtherThan screen: NSScreen?) -> [CGRect] {
        NSScreen.screens.filter { $0 != screen }.map(\.frame)
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
