// WindowChromeHost.swift
// Limpid — the overlays, sheets, and alerts every main window carries around its root.

import AppKit
import SwiftUI

/// What every main window carries around its root: the overlays (toasts,
/// the worktree suggestion, the PR card, floating panels, notification
/// history, the approval card, the palette dropdown), the handlers for the
/// palette's rows and the history's toggle (`WindowCommand`) and for the
/// Settings notification, the keyboard shortcuts panel, the clipboard sheet, the
/// session-restore alert, and the transparent title bar.
///
/// Each overlay draws this window's own: its toast,
/// approval card, floating panels, history, the suggestion for a pane it
/// shows, its palette, and its keyboard shortcuts panel. The clipboard
/// confirmation shows in the window of the pane that asked, the approval
/// service's alert and the alert that settings are not being saved in the
/// window last used, and the session-restore alert in the first window to
/// appear.
struct WindowChromeHost: ViewModifier {
    let state: AppState
    /// The window this chrome belongs to. The palette's dropdown and the
    /// rows it runs are this window's only when the palette opened here.
    let window: ProjectWindowState
    @State private var loadIssue: SessionLoadIssue?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pending clipboard request when this window asks it
    /// (`AppState.clipboardRequestPlacement`): the shown window that drew
    /// the pane it came from as it arrived, else the shown window last
    /// used. Not one from the quick terminal, which presents its own on
    /// the panel; never in every window at once.
    private var mainWindowClipboardRequest: PendingClipboardRequest? {
        guard let request = state.clipboardConfirmation.pending,
              !state.quickTerminal.ownsClipboardRequest(request),
              state.clipboardRequestPlacement == ClipboardRequestPlacement(requestID: request.id, window: window.id)
        else { return nil }
        return request
    }

    /// Whether app-wide news (the approval service's trouble) is told here,
    /// so it shows once (`AppState.serviceIssueWindowID`).
    private var isAppNewsWindow: Bool {
        state.serviceIssueWindowID == window.id
    }

    /// Carries out the commands for the window's chrome: a row its palette
    /// committed, and its notification history's toggle. Says whether
    /// `command` was one.
    private func takeCommand(_ command: WindowCommand) -> Bool {
        switch command {
        case let .runPaletteRow(execution):
            CommandPaletteActions.executeCommandPaletteAction(
                execution.action,
                session: state.session,
                attention: state.attention,
                registry: state.registry,
                commands: state.windowRegistry,
                frecencyStore: state.frecencyStore,
                toastCenter: state.toastCenter,
                minPaneSize: state.settingsStore.settings.terminal.paneMinimumSize,
                agentProjection: state.agentProjection,
                window: window.id,
                runsInWindow: { action in
                    SupervisionWindowActions.runPaletteAction(
                        action,
                        in: window,
                        state: state,
                        opensInNewWindow: execution.opensInNewWindow
                    )
                }
            )
        case .toggleNotificationHistory:
            toggleNotificationHistory(window.notificationHistory, session: state.session)
        default:
            return false
        }
        return true
    }

    /// The window's content as an overlay leaves it. While a sheet, the
    /// all projects sheet, or the keyboard shortcuts panel lies over the
    /// window, nothing under it reacts to
    /// the pointer: once here, for every control under every overlay,
    /// rather than in each control's hover. The overlays laid on it after
    /// are outside this, so they still do.
    private func covered(_ content: Content) -> some View {
        content
            .allowsHitTesting(!window.isContentCovered)
            .background { AttachedSheetObserver(window: window) }
            // While a panel lies over the whole window, VoiceOver reads the
            // panel alone.
            .accessibilityHidden(window.isWindowOverlayPresented)
    }

    /// The surfaces laid over the window's content, in the order they
    /// stack. Apart from `body`, whose chain the compiler could no longer
    /// type-check in reasonable time with them in it.
    private func layered(_ content: Content) -> some View {
        covered(content)
            .overlay(alignment: .bottom) {
                // Lifted over the status bar and the decision bar, so a
                // toast never covers the bar's "Done" line and its Undo.
                ToastHost(
                    bottomInset: LimpidLayout.Supervision.statusBarHeight + LimpidLayout.Supervision.decisionBarHeight
                        + LimpidLayout.Supervision.toastGap
                )
            }
            .overlay(alignment: .bottom) {
                WorktreeMoveSuggestionHost()
            }
            .overlay { PRHoverCardHost() }
            .overlay { FloatingPanelLayer() }
            .overlay { NotificationHistoryOverlay(state: state) }
            // Under the approval card, which an "Answer…" on it opens.
            .overlay { AllProjectsOverlay(state: state) }
            // A pending OSC 52 confirmation always wins: the panel closes
            // the moment a request arrives.
            .overlay { KeyboardShortcutOverlay(state: state, yieldsToOtherModal: mainWindowClipboardRequest != nil) }
            .overlay { ApprovalCardHost() }
    }

    func body(content: Content) -> some View {
        layered(content)
            .overlay {
                if let paletteState = state.session.commandPaletteState,
                   paletteState.windowID == window.id,
                   window.paletteFieldFrame.width > 0
                {
                    GeometryReader { overlayGeo in
                        let overlayOrigin = overlayGeo.frame(in: .global).origin
                        let fieldFrame = window.paletteFieldFrame
                        // Centered under the field, and held inside the
                        // window when the field sits near one of its sides.
                        let dropX = PaletteDropdownPlacement.originX(
                            fieldMidX: fieldFrame.midX - overlayOrigin.x,
                            width: LimpidLayout.Supervision.paletteDropdownWidth,
                            containerWidth: overlayGeo.size.width,
                            margin: LimpidLayout.floatingPanelWindowMargin
                        )
                        let dropY = fieldFrame.maxY - overlayOrigin.y + LimpidLayout.Supervision.paletteDropdownGap

                        Color.clear
                            .contentShape(Rectangle())
                            .pointerStyle(.default)
                            .onTapGesture {
                                CommandPaletteActions.closeCommandPalette(state.session)
                            }
                        CommandPaletteDropdown(
                            state: paletteState,
                            onDismiss: {
                                CommandPaletteActions.closeCommandPalette(state.session)
                            }
                        )
                        .frame(width: LimpidLayout.Supervision.paletteDropdownWidth)
                        .frame(maxHeight: LimpidLayout.Supervision.paletteDropdownMaxHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: dropX, y: dropY)
                    }
                    .ignoresSafeArea()
                    .modalTransition(.floatingPanel, reduceMotion: reduceMotion)
                    .zIndex(100)
                }
            }
            .animation(
                ModalMotion.floatingPanel.animation(reduceMotion: reduceMotion),
                value: state.session.commandPaletteState != nil
            )
            // The palette's rows and the notification history of this
            // window: each window has its own.
            .onWindowCommand(of: window, takeCommand)
            .onReceive(NotificationCenter.default.publisher(for: .limpidOpenSettings)) { _ in
                openWindow(id: LimpidApp.settingsWindowID)
            }
            .sheet(item: Binding(
                get: { mainWindowClipboardRequest },
                set: { newValue in
                    // The system also drives this binding to nil when the
                    // sheet is dismissed via Esc / clicking outside; treat
                    // that as a Deny so libghostty always receives a
                    // completion (otherwise the surface request stays open
                    // forever and the embedded shell can't proceed).
                    if newValue == nil, mainWindowClipboardRequest != nil {
                        state.clipboardConfirmation.deny()
                    }
                }
            )) { request in
                ClipboardConfirmationSheet(
                    request: request,
                    onAllow: { state.clipboardConfirmation.allow() },
                    onDeny: { state.clipboardConfirmation.deny() }
                )
                .environment(\.locale, state.settingsStore.appLocale)
                .limpidAccentPropagated(
                    LimpidColor.accent(for: state.settingsStore.settings.appearance.accentColor)
                )
            }
            // The traffic lights center on the title bar.
            .limpidWindowToolbar(stripHeight: LimpidLayout.Supervision.titleBarHeight)
            // Surface session-restore failures the first time the window
            // comes up. Pulling the issue off AppState clears it so a
            // dismiss closes the alert for the rest of the session.
            .task {
                if let issue = state.sessionLoadIssue {
                    state.sessionLoadIssue = nil
                    loadIssue = issue
                }
            }
            .alert(
                Text(loadIssue?.title ?? ""),
                isPresented: Binding(
                    get: { loadIssue != nil },
                    set: {
                        if !$0 {
                            loadIssue = nil
                        }
                    }
                ),
                presenting: loadIssue
            ) { _ in
                Button("OK", role: .cancel) { loadIssue = nil }
            } message: { issue in
                Text(verbatim: SavingSuspendedText.loadIssueMessage(
                    detail: issue.detail.resolved(in: state.settingsStore.appLocale),
                    isSessionSavingSuspended: state.isSessionSavingSuspended,
                    locale: state.settingsStore.appLocale
                ))
            }
            .agentIntegrationServiceAlert(state.agentIntegrationServiceRegistrar, isShown: isAppNewsWindow)
            .savingSuspendedAlert(state: state, isShown: state.savingNoticeWindowID == window.id)
    }
}

/// Tells the window's state whether a system sheet is attached to its
/// window. Any sheet: the ones SwiftUI presents from views all over the
/// window (new worktree, project settings, the clipboard
/// confirmation) and AppKit's alerts, none of which the
/// window's state otherwise knows of.
private struct AttachedSheetObserver: NSViewRepresentable {
    let window: ProjectWindowState

    func makeCoordinator() -> Coordinator {
        Coordinator(window: window)
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] nsWindow in
            coordinator?.observe(nsWindow)
        }
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        context.coordinator.window = window
    }

    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        coordinator.observe(nil)
    }

    @MainActor
    final class HostView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        var window: ProjectWindowState
        private var tokens: [any NSObjectProtocol] = []
        /// When the window last had its sheets read on an update, so the
        /// read on every pass of the event loop is held to a few a second.
        private var lastUpdateRead: ContinuousClock.Instant?

        /// How often an update of the window reads its sheets again.
        static let updateReadInterval: Duration = .milliseconds(250)

        init(window: ProjectWindowState) {
            self.window = window
        }

        func observe(_ nsWindow: NSWindow?) {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
            tokens = []
            guard let nsWindow else {
                // Gone from its window: nothing is attached to a window it
                // is not in, and a cover left on would keep the window from
                // the pointer for good.
                if window.hasAttachedSheet {
                    window.hasAttachedSheet = false
                }
                return
            }
            // Read after the sheet has begun and after it has ended, from
            // the window itself, so a sheet that replaces another leaves
            // the window covered.
            for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
                let token = NotificationCenter.default.addObserver(forName: name, object: nsWindow, queue: .main) { [weak self] note in
                    let sheetParent = note.object as? NSWindow
                    MainActor.assumeIsolated {
                        self?.update(sheetParent)
                    }
                    // Once more after AppKit has finished taking the sheet
                    // off: during the notification the window may still
                    // report it as attached.
                    Task { @MainActor [weak self, weak sheetParent] in
                        self?.update(sheetParent)
                    }
                }
                tokens.append(token)
            }
            // A safety net under the two above, should a sheet end without
            // saying so: the window becoming key again (it does as its
            // sheet goes), and its updates, read a few times a second.
            let becameKey = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nsWindow,
                queue: .main
            ) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    self?.update(window)
                }
            }
            let updated = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: nsWindow,
                queue: .main
            ) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    self?.updateNowAndThen(window)
                }
            }
            tokens += [becameKey, updated]
            update(nsWindow)
        }

        private func updateNowAndThen(_ nsWindow: NSWindow?) {
            let now = ContinuousClock.now
            if let last = lastUpdateRead, now - last < Self.updateReadInterval {
                return
            }
            lastUpdateRead = now
            update(nsWindow)
        }

        private func update(_ nsWindow: NSWindow?) {
            let hasSheet = nsWindow?.attachedSheet != nil || nsWindow?.sheets.isEmpty == false
            if window.hasAttachedSheet != hasSheet {
                window.hasAttachedSheet = hasSheet
            }
        }
    }
}

/// Where the palette's dropdown starts across the window.
enum PaletteDropdownPlacement {
    /// Returns the left edge for a dropdown `width` wide, centered on the field's
    /// middle, moved in as a floating panel is to keep `margin` from either
    /// side of a container `containerWidth` wide
    /// (`FloatingPanelPlacement.clampX`). Only the clamp is shared: the
    /// dropdown hangs from the field and closes on a click outside it
    /// through its own overlay, not through a floating panel's placement
    /// and event monitor.
    static func originX(fieldMidX: CGFloat, width: CGFloat, containerWidth: CGFloat, margin: CGFloat) -> CGFloat {
        FloatingPanelPlacement.clampX(
            preferredX: fieldMidX - width / 2,
            panelWidth: width,
            containerWidth: containerWidth,
            margin: margin
        )
    }
}
