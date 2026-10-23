// PaneHostView.swift
// Limpid — `NSViewRepresentable` that mounts one pane leaf's
// `SurfaceView` into the SwiftUI tree.
//
// The `SurfaceView` itself is owned by `SurfaceRegistry` and survives
// split-tree mutations / tab switches, so libghostty doesn't restart
// the shell on every revisit. But SwiftUI's representable contract
// assumes `makeNSView` hands back a brand-new view it can graft into
// the view tree freely; returning the same long-lived `SurfaceView` on
// every remount caused a race on fast tab switches where SwiftUI would
// update its own view graph faster than AppKit could reparent the
// shared view, leaving a leaf detached from any superview (visible as
// a blank pane).
//
// The fix: hand SwiftUI a short-lived `PaneContainerNSView` on every
// `makeNSView`, and have the container re-attach the persistent
// `SurfaceView` as its sole subview at AppKit level. SwiftUI owns the
// container; AppKit owns the surface reparent. The two layers stop
// fighting.

import AppKit
import SwiftUI

/// Measures the available size via `GeometryReader` and pushes it
/// into the `NSViewRepresentable`. Second size channel alongside
/// AppKit's frame-change cascade — fires when the layout system
/// already knows the new size but AppKit hasn't reflected it yet,
/// mostly during live window resize.
struct PaneHostView: View {
    let paneID: UUID
    /// Resolved by `PaneAreaView` up the tree, so SwiftUI's diff sees
    /// the same AppKit reference across consecutive renders. See
    /// `ResolvedSplitNode`.
    let surfaceView: SurfaceView
    @Environment(\.surfaceRegistry) private var registry
    @Environment(WorkspaceSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(AttentionState.self) private var attention
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(LimpidDragState.self) private var dragState
    @Environment(PaneRenamePresentation.self) private var renamePresentation
    @Environment(\.primaryActionHandler) private var primaryActionHandler
    /// The window this pane is drawn in, which its right-click actions act
    /// in. Panes are drawn only inside `PaneContainerView`, in a main window.
    @Environment(ProjectWindowState.self) private var window

    private var isBeingDragged: Bool {
        dragState.current == .pane && dragState.currentSourceID == paneID.uuidString
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                PaneHostRepresentable(
                    surfaceView: surfaceView,
                    paneID: paneID,
                    registry: registry,
                    session: session,
                    settings: settings,
                    attention: attention,
                    toastCenter: toastCenter,
                    dragState: dragState,
                    renamePresentation: renamePresentation,
                    primaryActionHandler: primaryActionHandler,
                    window: window.id,
                    size: geo.size
                )
                if surfaceView.creationFailed {
                    PaneCreationFailureCard(surfaceView: surfaceView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.55))
                }
                // Drag-source veil: while this pane is the one being
                // ⌥⌘-dragged, lay a translucent white sheet over the
                // surface so the user can tell at a glance which pane
                // has been lifted. Hit testing stays off so libghostty
                // still gets the live mouse stream up until the AppKit
                // drag session takes over.
                if isBeingDragged {
                    Color.white.opacity(0.25)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(LimpidMotion.paneLift, value: isBeingDragged)
        }
    }
}

/// Shown inside a pane whose backing libghostty surface failed to
/// allocate (`ghostty_surface_new` returned NULL). One Retry button so
/// the user is not trapped staring at a black rectangle — a successful
/// re-run clears `creationFailed` and the card vanishes on the next
/// SwiftUI tick. The quick terminal shows the same card over its panel.
struct PaneCreationFailureCard: View {
    let surfaceView: SurfaceView

    var body: some View {
        VStack(spacing: LimpidLayout.Supervision.spaceM) {
            // A pane that cannot start has failed, so it wears the stopped
            // glyph. The title says what happened, so the glyph is not
            // read.
            StateGlyph(kind: .stopped, size: LimpidLayout.paneFailureGlyphSize)
                .accessibilityHidden(true)
            Text("Couldn’t Start the Terminal", comment: "Pane surface NULL recovery title")
                .font(.supervision(.icon, weight: .semibold))
            Text(
                "libghostty couldn’t allocate this pane. Choose Retry to try again.",
                comment: "Pane surface NULL recovery body"
            )
            .font(.supervision(.row))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
            Button {
                surfaceView.createSurface()
            } label: {
                Text("Retry", comment: "Pane surface NULL recovery retry button")
            }
            .controlSize(.small)
        }
        .padding(LimpidLayout.Supervision.spaceXL)
        .pointerStyle(.default)
    }
}

/// Short-lived wrapper that SwiftUI owns through `NSViewRepresentable`.
/// Hosts the persistent, registry-owned surface through a native scroll host.
/// We resize the host with the pane; the host sizes the surface from its
/// viewport so scrollback growth cannot change the terminal's dimensions.
final class PaneContainerNSView: NSView {
    private(set) var surfaceView: SurfaceView?
    private var scrollHost: TerminalScrollView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Mount a scroll host around the supplied persistent surface. AppKit
    /// reparents the surface when we move it from a previous host.
    func mount(_ view: SurfaceView) {
        guard surfaceView !== view else { return }
        scrollHost?.removeFromSuperview()
        surfaceView = view
        let scrollHost = TerminalScrollView(surfaceView: view)
        self.scrollHost = scrollHost
        scrollHost.frame = bounds
        scrollHost.autoresizingMask = [.width, .height]
        addSubview(scrollHost)
    }

    func applyExpectedSize(_ size: CGSize) {
        scrollHost?.applyExpectedSize(size)
    }
}

struct PaneHostRepresentable: NSViewRepresentable, Equatable {
    /// The persistent surface — resolved in `PaneHostView.body` so SwiftUI
    /// sees the same AppKit reference across consecutive representable
    /// values. SwiftUI hosts the wrapper, the wrapper hosts the
    /// long-lived surface, and SwiftUI's lifecycle never touches the
    /// surface itself.
    let surfaceView: SurfaceView
    let paneID: UUID
    let registry: any SurfaceViewProviding
    let session: WorkspaceSession
    let settings: SettingsStore
    let attention: AttentionState
    let toastCenter: ToastCenter
    let dragState: LimpidDragState
    let renamePresentation: PaneRenamePresentation
    let primaryActionHandler: PrimaryActionHandler?
    /// The window the pane is drawn in, where its right-click actions act.
    /// Named here rather than found from the tabs each window shows, so
    /// the actions never land in another window that shows the same tab.
    let window: WindowID
    let size: CGSize

    /// SwiftUI honors `Equatable` on representables and skips
    /// `updateNSView` when equal. `PaneHostView`'s body re-runs on
    /// every `@Observable` mutation that touches `WorkspaceSession`
    /// (paneSearchStates, paneTransients on each keystroke), and the
    /// default no-`Equatable` shape re-wires ~11 closure properties
    /// on `SurfaceView` per call — hundreds of pointless heap blocks
    /// per second of typing on a ten-pane workspace. The cheap-to-
    /// compare props (paneID, the surface AppKit reference, the
    /// requested size) fully determine whether `updateNSView` would
    /// have any work to do. The app-wide environment references are
    /// AppState-lifetime singletons, so their identity never changes; the
    /// per-window one (`renamePresentation`) changes only with the window,
    /// so comparing `window` keeps it in step too.
    nonisolated static func == (lhs: PaneHostRepresentable, rhs: PaneHostRepresentable) -> Bool {
        // `paneID` and `size` are value-typed and safe to read off-actor;
        // `surfaceView ===` only compares the pointer, which is also
        // safe without crossing the actor boundary.
        // The handler compares by window, so a pane moved to another
        // window sends ⌘⏎ to that window's bars; the window itself, so its
        // right-click actions act there.
        lhs.paneID == rhs.paneID
            && lhs.surfaceView === rhs.surfaceView
            && lhs.size == rhs.size
            && lhs.primaryActionHandler == rhs.primaryActionHandler
            && lhs.window == rhs.window
    }

    func makeNSView(context: Context) -> PaneContainerNSView {
        let container = PaneContainerNSView(frame: NSRect(origin: .zero, size: size))
        wireCallbacks(on: surfaceView)
        container.mount(surfaceView)
        container.applyExpectedSize(size)
        // Defer createSurface to the next run-loop tick so the wrapper
        // is fully attached to its window first. Without this, the first
        // mount can land `viewDidMoveToWindow` with `window == nil`, the
        // early-return there leaves `surface == nil`, and the pane stays
        // blank until some later update kicks the retry below.
        DispatchQueue.main.async { [surfaceView] in
            if surfaceView.surface == nil, surfaceView.window != nil {
                surfaceView.createSurface()
            }
        }
        return container
    }

    func updateNSView(_ container: PaneContainerNSView, context: Context) {
        wireCallbacks(on: surfaceView)
        // Re-mount whenever SwiftUI hands us back the container — if the
        // surface was just reparented from another container on a fast
        // tab switch this picks it back up; otherwise it's a no-op.
        container.mount(surfaceView)
        container.applyExpectedSize(size)
        // Defensive retry — `SurfaceView.viewDidMoveToWindow` early-
        // returns when `window == nil`, so `createSurface()` never runs
        // if AppKit ferries the view through a detached mount. This
        // catches the case where the deferred call from `makeNSView`
        // missed the window (divider drag, rapid split).
        if surfaceView.window != nil, surfaceView.surface == nil {
            surfaceView.createSurface()
        }
    }

    /// `stopLedger` is told of the resume typed into a restored pane;
    /// `nil` where no ledger watches (the quick terminal, tests).
    @MainActor
    static func resolveOrCreateSurfaceView(
        paneID: UUID,
        ghosttyApp: GhosttyApp,
        registry: any SurfaceViewProviding,
        session: WorkspaceSession,
        hostsAgentsInTmux: Bool,
        stopLedger: StopLedgerStore? = nil
    ) -> SurfaceView {
        if let existing = registry.view(for: paneID) {
            return existing
        }
        // Four layers over one pty: what every pane gets, then each
        // agent's own directories, then the flags that hand Codex our
        // hooks. The agent layers are inert when the user never runs the
        // matching CLI; injecting unconditionally keeps spawn paths
        // uniform across panes.
        var env = PaneShellEnvironment.resolved(
            forPaneID: paneID,
            hostsAgentsInTmux: hostsAgentsInTmux,
            recordsPanePath: session.writesUserFiles,
            projectID: session.tab(containing: paneID)?.container.projectID
        )
        for (k, v) in ClaudeShimLocator.environment(forPaneID: paneID, writesRecords: session.writesUserFiles) {
            env[k] = v
        }
        for (k, v) in CodexShimLocator.environment() {
            env[k] = v
        }
        for (k, v) in CodexHookInstaller.shared.environment(writesRecords: session.writesUserFiles) {
            env[k] = v
        }
        let launch = Self.launch(session: session, paneID: paneID)
        // The first instruction's file and the agent's executable, which
        // only a staged launch has: a restored pane gets neither.
        for (k, v) in launch.staged?.environment ?? [:] {
            env[k] = v
        }
        let view = Self.makeSurfaceView(ghosttyApp: ghosttyApp, environment: env)
        let owningTab = session.tab(containing: paneID)
        view.initialWorkingDirectory = owningTab?.newPaneWorkingDirectory
        view.initialCommand = launch.command
        if launch.staged != nil {
            // This runs while a body is evaluated; the session changes
            // once that is over. The registry already holds the view, so
            // nothing reads the staged launch again before then.
            DispatchQueue.main.async {
                session.clearStagedLaunch(paneID: paneID)
            }
        } else if let stopLedger, let resume = Self.resolveRestoredResume(tab: owningTab, paneID: paneID) {
            // The ledger watches the resume typed into the pane from
            // the moment the terminal types it, which is long after this
            // body and may never come (no surface, a switch away before
            // one was made).
            view.onInitialCommandTyped = { typedAt in
                stopLedger.markResumingAtLaunch(
                    paneID: paneID, provider: resume.provider, sessionID: resume.sessionID, cwd: resume.cwd, now: typedAt
                )
            }
        }
        Self.stageScrollback(view: view, session: session, tab: owningTab, paneID: paneID)
        registry.register(view, for: paneID)
        return view
    }

    /// A fresh surface view with the configuration every terminal shares,
    /// panes and the quick terminal alike: the scrollbar preference from
    /// the live config and the demo-mode prompt mask over `environment`.
    @MainActor
    static func makeSurfaceView(
        ghosttyApp: GhosttyApp,
        environment: [String: String]
    ) -> SurfaceView {
        let view = SurfaceView(ghosttyApp: ghosttyApp)
        view.isScrollbarEnabled = ghosttyApp.isScrollbarEnabled
        var env = environment
        if DemoFixture.isDemoActive {
            // Stop the demo shell prompt from baking a real user@host into
            // the hero screenshot. PROMPT/PS1 replace the default prompt;
            // HOST/HOSTNAME cover a prompt the user's own shell config builds
            // from them, since zsh's %m reads HOST. They are "localhost"
            // rather than a made-up name because the shell integration also
            // sends them as the host of its OSC 7 working-directory reports,
            // and libghostty drops a report whose host is neither this
            // machine's name nor "localhost" — every demo pane then had no
            // working directory.
            env["USER"] = "demo"
            env["HOSTNAME"] = "localhost"
            env["HOST"] = "localhost"
            env["PROMPT"] = "demo@limpid %1~ %% "
            env["PS1"] = "demo@limpid \\W $ "
        }
        view.extraEnvironment = env
        return view
    }

    @MainActor
    private func wireCallbacks(on view: SurfaceView) {
        let paneID = paneID
        view.onUserAcknowledge = { [weak session] in
            session?.clearUnread(paneID: paneID)
        }
        view.onGridSizeChange = { [weak session] in
            session?.terminalGridGeneration &+= 1
        }
        // Single source of truth for "attention focus moved": fires
        // whenever this pane gains focus (mount/restore, click, ⌘J, tab
        // switch, arrow). `focusMoved` records the arrived pane's finished
        // agent episode as viewed — viewing isn't completing. Covers the launch-focused
        // pane that no explicit navigation ever touched.
        view.onFocusEntry = { [weak session, attention] in
            guard let session else { return }
            attention.focusMoved(to: paneID, in: session)
        }
        // The review tab covers no terminal: a pane on screen is one the
        // person moved to, so it may take the keyboard as it mounts.
        view.shouldFocusOnMount = { [weak session] in
            guard let tab = session?.tab(containing: paneID) else { return false }
            // Fall back to the first leaf when focus is unset, so a
            // multi-pane tab never grabs the keyboard in every pane at once
            // (which would render an active cursor in all of them).
            return tab.splitTree.effectiveFocusedLeafID == paneID
        }
        wireContextMenuCallbacks(on: view)
    }

    /// Bridge the right-click menu's Focus / Split / Close / Find items
    /// to `TabActions`. The callbacks let `SurfaceView` stay
    /// ignorant of `WorkspaceSession` and the surface registry — same
    /// pattern as `onUserAcknowledge`. Re-applied on every wire pass so
    /// a recycled view from the registry doesn't keep a stale pointer
    /// to a previous tab's dragState.
    @MainActor
    private func wireContextMenuCallbacks(on view: SurfaceView) {
        let registry = registry
        let paneID = paneID
        let window = window
        view.paneID = paneID
        view.dragState = dragState
        view.ownerTabIDForLogging = { [weak session] in
            session?.tab(containing: paneID)?.id.uuidString ?? "?"
        }
        view.onRequestFocus = { [weak session] in
            guard let session else { return }
            guard let tab = session.tab(containing: paneID) else { return }
            guard tab.splitTree.focusedLeafID != paneID else { return }
            session.update(tab.id) { t in
                t.splitTree.focusedLeafID = paneID
            }
        }
        view.onRequestSplit = { [weak session, registry, settings, toastCenter] direction in
            guard let session else { return }
            PaneActions.split(
                session,
                direction: direction,
                registry: registry,
                minPaneSize: settings.settings.terminal.paneMinimumSize,
                toastCenter: toastCenter,
                in: window
            )
        }
        view.onRequestCloseActivePane = { [weak session] in
            guard let session else { return }
            PaneActions.closeActivePaneOrTab(
                session,
                registry: registry,
                source: .mouse,
                in: window
            )
        }
        view.onRequestBeginSearch = { [weak session] in
            guard let session else { return }
            SearchActions.beginSearch(session, in: window)
        }
        view.onRequestMoveToNewTab = { [weak session] in
            guard let session else { return }
            TabActions.movePaneToNewTab(session, paneID: paneID, in: window, intent: .person)
        }
        view.canMoveToNewTab = { [weak session] in
            guard let session else { return false }
            guard let tab = session.tab(containing: paneID) else { return false }
            return tab.splitTree.allLeafIDs().count > 1
        }
        view.canRenamePane = { [weak session, settings] in
            guard let session else { return false }
            return PaneHeaderRules.showsHeader(
                in: session.tab(containing: paneID),
                isEnabled: settings.settings.terminal.showsSplitPaneHeaders
            )
        }
        view.onRequestRenamePane = { [weak renamePresentation] in
            renamePresentation?.requestRename(paneID: paneID)
        }
        view.keyboardSettings = { [settings] in
            settings.settings.keyboard
        }
        view.appLocale = { [settings] in
            settings.appLocale
        }
        if let handler = primaryActionHandler {
            view.primaryActionHandler = { @MainActor press in handler.handle(press, paneID) }
        } else {
            view.primaryActionHandler = nil
        }
        wireZoomItem(on: view)
    }

    /// The right-click menu's "Zoom Pane" item, which flips the way the
    /// header's does. Split out of `wireContextMenuCallbacks` to keep that
    /// under the complexity cap.
    @MainActor
    private func wireZoomItem(on view: SurfaceView) {
        let paneID = paneID
        let window = window
        view.paneZoomAction = { [weak session] in
            guard let session else { return nil }
            return PaneHeaderRules.menuZoomAction(for: paneID, in: session.tab(containing: paneID))
        }
        view.onRequestZoomAction = { [weak session] in
            guard let session, let tab = session.tab(containing: paneID) else { return }
            switch PaneHeaderRules.menuZoomAction(for: paneID, in: tab) {
            // The right-click already focused this pane, so it is the one
            // `toggleZoom` zooms.
            case .zoom: PaneActions.toggleZoom(session, in: window)
            case .unzoom: PaneActions.unzoom(session, tabID: tab.id, in: window, intent: .person)
            case nil: break
            }
        }
    }

    /// How a freshly made surface starts: the launch staged for it, which
    /// the caller clears, else the command that restores it.
    struct Launch: Equatable {
        let staged: WorkspaceSession.StagedLaunch?
        let restored: String?

        var command: String? {
            staged?.command ?? restored
        }
    }

    /// The first command of a freshly made surface: the one staged for the
    /// pane (demo mode, the pane strip's "+", a new session), with its
    /// first instruction's file, and otherwise what `resolveInitialCommand`
    /// restores. Internal rather than private so the precedence between
    /// the four sources can be pinned directly. Getting that order wrong is
    /// the failure this whole path exists to avoid: a pane that reattaches
    /// *and* resumes ends up with two agent processes against one session
    /// id.
    @MainActor
    static func launch(session: WorkspaceSession, paneID: UUID) -> Launch {
        if let staged = session.stagedLaunch(paneID: paneID) {
            return Launch(staged: staged, restored: nil)
        }
        return Launch(staged: nil, restored: resolveInitialCommand(tab: session.tab(containing: paneID), paneID: paneID))
    }

    /// What a restored pane runs once nothing is staged for it: its tmux
    /// reattach, else its Claude resume, else its Codex resume. Split out
    /// of the NSViewRepresentable body — the chained optionals +
    /// nil-coalescing + flatMap version inline blew up Swift 6's SwiftUI
    /// type checker into a multi-minute compile.
    static func resolveInitialCommand(
        tab: Tab?,
        paneID: UUID
    ) -> String? {
        guard let tab else { return nil }
        // Above the agent builders: a pane that was inside tmux has its
        // agent running in there too, so reattaching restores the live
        // session rather than starting a second one against the same
        // session id.
        if let tmux = TmuxReattachCommandBuilder.initialCommand(for: tab, paneID: paneID) {
            return tmux
        }
        return resolveRestoredResume(tab: tab, paneID: paneID)?.command
    }

    /// The agent resume a restored pane runs, when that is what it runs
    /// (`resolveInitialCommand`): what the stop ledger watches. `nil` for a
    /// pane reattaching to tmux, whose agent is already running in there.
    static func resolveRestoredResume(tab: Tab?, paneID: UUID) -> AgentResume? {
        guard let tab, TmuxReattachCommandBuilder.initialCommand(for: tab, paneID: paneID) == nil else { return nil }
        if let claude = ClaudeResumeCommandBuilder.resume(for: tab, paneID: paneID) {
            return claude
        }
        return CodexResumeCommandBuilder.resume(for: tab, paneID: paneID)
    }

    /// Stage the saved scrollback path for replay and clear it from the
    /// model so a later split / re-mount doesn't replay it again.
    @MainActor
    private static func stageScrollback(
        view: SurfaceView,
        session: WorkspaceSession,
        tab: Tab?,
        paneID: UUID
    ) {
        guard let tab else { return }
        guard let rawPath = tab.scrollbackPaths[paneID], !rawPath.isEmpty else { return }
        // Only replay a `.vt` file we wrote; a tampered state.json could
        // otherwise point this at an arbitrary file for libghostty to read.
        if let path = session.scrollbackFiles?.validatedPath(rawPath) {
            view.initialScrollbackPath = path
        }
        let tabID = tab.id
        session.update(tabID) { tab in
            tab.scrollbackPaths.removeValue(forKey: paneID)
        }
    }
}
