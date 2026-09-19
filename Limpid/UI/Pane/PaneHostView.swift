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
    /// Padding the layout pinned for this leaf; handed to the surface in
    /// `updateNSView` because SwiftUI's body must not mutate AppKit.
    var paddingOverride: PaddingOverride?
    @Environment(\.surfaceRegistry) private var registry
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(AttentionState.self) private var attention
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(LimpidDragState.self) private var dragState
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @Environment(\.tmuxConnectionStore) private var tmuxStore

    /// A pane whose source this build cannot read runs nothing, so it says
    /// so instead of sitting empty.
    private var hasUnavailableSource: Bool {
        session.tab(containing: paneID)?.paneSources[paneID] == .unavailable
    }

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
                    reviewPresentation: reviewPresentation,
                    tmuxStore: tmuxStore,
                    size: geo.size,
                    paddingOverride: paddingOverride
                )
                if surfaceView.creationFailed {
                    PaneCreationFailureCard(surfaceView: surfaceView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.55))
                } else if hasUnavailableSource {
                    UnavailablePaneCard()
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
            .animation(.easeInOut(duration: 0.18), value: isBeingDragged)
        }
    }
}

/// Shown inside a pane whose backing libghostty surface failed to
/// allocate (`ghostty_surface_new` returned NULL). One Retry button so
/// the user is not trapped staring at a black rectangle — a successful
/// re-run clears `creationFailed` and the card vanishes on the next
/// SwiftUI tick.
private struct PaneCreationFailureCard: View {
    let surfaceView: SurfaceView

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(LimpidColor.warning)
                .accessibilityHidden(true)
            Text("Terminal failed to start", comment: "Pane surface NULL recovery title")
                .font(LimpidFont.headline)
                .foregroundStyle(LimpidColor.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(
                "libghostty couldn't allocate this pane. Retry to try again.",
                comment: "Pane surface NULL recovery body"
            )
            .font(LimpidFont.bodySecondary)
            .foregroundStyle(LimpidColor.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)
            Button {
                surfaceView.createSurface()
            } label: {
                Text("Retry", comment: "Pane surface NULL recovery retry button")
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        // The same treatment `UnavailablePaneCard` carries: both are laid
        // over a pane that shows nothing, and two cards in the same place
        // reading as two different surfaces was the older of the two
        // drifting, not a distinction.
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: LimpidLayout.paneBannerCornerRadius, style: .continuous)
        )
        .pointerStyle(.default)
        .accessibilityElement(children: .contain)
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
    let session: WindowSession
    let settings: SettingsStore
    let attention: AttentionState
    let toastCenter: ToastCenter
    let dragState: LimpidDragState
    let reviewPresentation: ReviewPresentation
    /// The tmux store, when the app has one. Deliberately absent from `==`
    /// below with the other environment references: it is an AppState-lifetime
    /// singleton, so its identity never changes across renders.
    let tmuxStore: TmuxConnectionStore?
    let size: CGSize
    let paddingOverride: PaddingOverride?

    /// SwiftUI honors `Equatable` on representables and skips
    /// `updateNSView` when equal. `PaneHostView`'s body re-runs on
    /// every `@Observable` mutation that touches `WindowSession`
    /// (paneSearchStates, paneTransients on each keystroke), and the
    /// default no-`Equatable` shape re-wires ~11 closure properties
    /// on `SurfaceView` per call — hundreds of pointless heap blocks
    /// per second of typing on a ten-pane workspace. The cheap-to-
    /// compare props (paneID, the surface AppKit reference, the
    /// requested size) fully determine whether `updateNSView` would
    /// have any work to do; the four environment references are
    /// AppState-lifetime singletons so their identity never changes.
    nonisolated static func == (lhs: PaneHostRepresentable, rhs: PaneHostRepresentable) -> Bool {
        // `paneID` and `size` are value-typed and safe to read off-actor;
        // `surfaceView ===` only compares the pointer, which is also
        // safe without crossing the actor boundary.
        lhs.paneID == rhs.paneID
            && lhs.surfaceView === rhs.surfaceView
            && lhs.size == rhs.size
            && lhs.paddingOverride == rhs.paddingOverride
    }

    func makeNSView(context: Context) -> PaneContainerNSView {
        let container = PaneContainerNSView(frame: NSRect(origin: .zero, size: size))
        wireCallbacks(on: surfaceView)
        container.mount(surfaceView)
        container.applyExpectedSize(size)
        // Placed before `createSurface` runs so the pin is already there
        // when the surface appears; `createSurface` re-applies it then.
        surfaceView.paddingOverride = paddingOverride
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
        // Idempotent: the surface only talks to libghostty when the value
        // actually changed, so a resize re-running this costs nothing.
        surfaceView.paddingOverride = paddingOverride
        // Defensive retry — `SurfaceView.viewDidMoveToWindow` early-
        // returns when `window == nil`, so `createSurface()` never runs
        // if AppKit ferries the view through a detached mount. This
        // catches the case where the deferred call from `makeNSView`
        // missed the window (divider drag, rapid split).
        if surfaceView.window != nil, surfaceView.surface == nil {
            surfaceView.createSurface()
        }
    }

    /// How a new surface for a leaf is driven. Only a local pane may start
    /// a process of its own; any other source either gets a descriptor
    /// that stands in for the pty or no surface at all, never a shell in a
    /// place that promised something else.
    enum SurfaceBacking: Equatable {
        case ownProcess
        /// The leaf's stream, read in place of a pty. Compared by identity:
        /// two channels are the same stream only if they are one object.
        case channel(TmuxPaneChannel)
        /// Nothing can drive the pane, so no surface is made for it. The
        /// leaf keeps its place in the tree and the container draws an empty
        /// placeholder there: transparent, focusable by a click, and hidden
        /// from VoiceOver, since it has nothing to read out
        /// (`SplitContainerView.leaf`, `ResolvedSplitNode.build`).
        case noSurface

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.ownProcess, .ownProcess), (.noSurface, .noSurface):
                true
            case let (.channel(left), .channel(right)):
                left === right
            default:
                false
            }
        }
    }

    /// Decided per source with an exhaustive switch, so a source added
    /// later cannot fall through to a login shell until someone chooses
    /// what it gets. A pane that is not local reads its leaf's channel,
    /// which is the same whether a mirror feeds it now, later, or never
    /// (a restored tab, a source this build cannot read). Without a store
    /// (Previews) or when the channel cannot be opened there is no stream
    /// to hand over, and we mount nothing rather than a shell.
    @MainActor
    static func surfaceBacking(
        for source: PaneIOSource,
        paneID: UUID,
        tmuxStore: TmuxConnectionStore?
    ) -> SurfaceBacking {
        switch source {
        case .local:
            return .ownProcess
        case .tmux, .unavailable:
            guard let tmuxStore, let channel = tmuxStore.channel(paneID: paneID) else { return .noSurface }
            return .channel(channel)
        }
    }

    /// Whether a leaf's surface waits for the answer that fixes its shell's
    /// environment (`PaneShellEnvironment.agentTmuxAnswer`). Only a pane
    /// that starts a process of its own has an environment: a mirror pane
    /// reads a channel and waits for nothing. Like a leaf whose restored
    /// binding is being checked, the leaf keeps its place in the layout and
    /// gets its surface when the answer is in, a moment after launch.
    nonisolated static func waitsForShellEnvironment(
        backing: SurfaceBacking,
        agentTmux: PaneShellEnvironment.AgentTmuxAnswer
    ) -> Bool {
        backing == .ownProcess && agentTmux == .pending
    }

    @MainActor
    // swiftlint:disable:next function_parameter_count
    static func resolveOrCreateSurfaceView(
        paneID: UUID,
        ghosttyApp: GhosttyApp,
        registry: any SurfaceViewProviding,
        session: WindowSession,
        agentTmux: PaneShellEnvironment.AgentTmuxAnswer,
        tmuxStore: TmuxConnectionStore?
    ) -> SurfaceView? {
        if let existing = registry.view(for: paneID) {
            return existing
        }
        // A leaf whose restored tmux binding is still being checked has no
        // surface yet: the answer decides whether it becomes a mirror pane
        // or a shell, and which command that shell is given
        // (`TmuxMirrorActions.reconcileRestoredBindings`). The layout keeps
        // the leaf's place, and the check ends a moment after launch.
        if tmuxStore?.isAwaitingRestoreCheck(paneID) == true {
            return nil
        }
        let owningTab = session.tab(containing: paneID)
        let backing = owningTab.map {
            surfaceBacking(for: $0.ioSource(for: paneID), paneID: paneID, tmuxStore: tmuxStore)
        } ?? .noSurface
        if backing == .noSurface || waitsForShellEnvironment(backing: backing, agentTmux: agentTmux) {
            return nil
        }
        let view = SurfaceView(ghosttyApp: ghosttyApp)
        view.isScrollbarEnabled = ghosttyApp.isScrollbarEnabled
        if case let .channel(channel) = backing {
            // The channel stands in for the pty, so no command, cwd,
            // environment, or scrollback replay applies.
            view.mirrorChannel = channel
            registry.register(view, for: paneID)
            return view
        }
        view.initialWorkingDirectory = owningTab?.workingDirectory
        view.initialCommand = Self.resolveInitialCommand(
            tab: owningTab,
            paneID: paneID
        )
        // Four layers over one pty: what every pane gets, then each
        // agent's own directories, then the flags that hand Codex our
        // hooks. The agent layers are inert when the user never runs the
        // matching CLI; injecting unconditionally keeps spawn paths
        // uniform across panes.
        var env = PaneShellEnvironment.resolved(
            forPaneID: paneID,
            agentTmux: agentTmux.host
        )
        for (k, v) in ClaudeShimLocator.environment(forPaneID: paneID) {
            env[k] = v
        }
        for (k, v) in CodexShimLocator.environment() {
            env[k] = v
        }
        for (k, v) in CodexHookInstaller.shared.environment() {
            env[k] = v
        }
        if DemoFixture.isDemoActive {
            // Stop the demo shell prompt from baking a real user@host into
            // the hero screenshot. zsh expands %n@%m via getpwuid/gethostname,
            // so USER/HOSTNAME alone don't mask it — set PROMPT/PS1 outright.
            env["USER"] = "demo"
            env["HOSTNAME"] = "limpid"
            env["HOST"] = "limpid"
            env["PROMPT"] = "demo@limpid %1~ %% "
            env["PS1"] = "demo@limpid \\W $ "
        }
        view.extraEnvironment = env
        Self.stageScrollback(view: view, session: session, tab: owningTab, paneID: paneID)
        registry.register(view, for: paneID)
        return view
    }

    @MainActor
    private func wireCallbacks(on view: SurfaceView) {
        let paneID = paneID
        view.onUserAcknowledge = { [weak session] in
            session?.clearUnread(paneID: paneID)
        }
        // Single source of truth for "attention focus moved": fires
        // whenever this pane gains focus (mount/restore, click, ⌘J, tab
        // switch, arrow). `markViewed` fades the arrived pane's finished
        // turn — viewing isn't completing. Covers the launch-focused
        // pane that no explicit navigation ever touched.
        view.onFocusEntry = { [weak session, attention] in
            guard let session else { return }
            attention.focusMoved(to: paneID, in: session)
        }
        view.shouldFocusOnMount = { [weak session, weak reviewPresentation] in
            // While review is open the origin pane is mounted below the review
            // surface. Letting it grab the keyboard on mount would send the
            // reviewer's keystrokes to the agent they are reviewing. A click
            // still focuses it, which is the deliberate act this is not.
            if reviewPresentation?.isPresented == true {
                return false
            }
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
    /// ignorant of `WindowSession` and the surface registry — same
    /// pattern as `onUserAcknowledge`. Re-applied on every wire pass so
    /// a recycled view from the registry doesn't keep a stale pointer
    /// to a previous tab's dragState.
    @MainActor
    private func wireContextMenuCallbacks(on view: SurfaceView) {
        let registry = registry
        let paneID = paneID
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
        view.onRequestSplit = { [weak session, registry, settings, toastCenter, tmuxStore] direction in
            guard let session else { return }
            PaneActions.split(
                session,
                direction: direction,
                registry: registry,
                minPaneSize: settings.settings.terminal.minPaneSize,
                toastCenter: toastCenter,
                tmuxStore: tmuxStore
            )
        }
        view.onRequestCloseActivePane = { [weak session] in
            guard let session else { return }
            PaneActions.closeActivePaneOrTab(
                session,
                registry: registry,
                source: .mouse
            )
        }
        view.onRequestBeginSearch = { [weak session] in
            guard let session else { return }
            SearchActions.beginSearch(session)
        }
        view.onRequestMoveToNewTab = { [weak session, toastCenter, tmuxStore] in
            guard let session else { return }
            // A mirror pane leaves through `break-pane`; the ordinary path
            // still handles every other tab.
            TmuxMirrorActions.movePaneToNewTab(
                session,
                paneID: paneID,
                store: tmuxStore,
                toastCenter: toastCenter
            )
        }
        view.canMoveToNewTab = { [weak session] in
            guard let session else { return false }
            guard let tab = session.tab(containing: paneID) else { return false }
            return tab.splitTree.allLeafIDs().count > 1
        }
        view.tabCapabilities = { [weak session] in
            session?.tab(containing: paneID)?.capabilities
        }
        // The item runs `closeActivePaneOrTab`, which acts on the active
        // tab, so we ask about that tab; a pane the user can right-click is
        // on screen, which only the active tab's panes are.
        view.canClosePaneOrTab = { [weak session] in
            PaneActions.canClosePaneOrTab(session?.activeTab)
        }
    }

    /// Pick the initial shell command for a freshly-created surface.
    /// Prefers the user-staged command in `tab.initialCommands[paneID]`
    /// (demo mode, future "new tab running X" actions). When that slot
    /// is empty, falls back to a Claude resume command if the tab has
    /// a remembered session id. Split out of the NSViewRepresentable
    /// body — the chained optionals + nil-coalescing + flatMap version
    /// inline blew up Swift 6's SwiftUI type checker into a
    /// multi-minute compile.
    /// Internal rather than private so the precedence between the four
    /// sources can be pinned directly. Getting that order wrong is the
    /// failure this whole path exists to avoid: a pane that reattaches
    /// *and* resumes ends up with two agent processes against one
    /// session id.
    static func resolveInitialCommand(
        tab: Tab?,
        paneID: UUID
    ) -> String? {
        if let staged = tab?.initialCommands[paneID], !staged.isEmpty {
            return staged
        }
        guard let tab else { return nil }
        // Above the agent builders: a pane that was inside tmux has its
        // agent running in there too, so reattaching restores the live
        // session rather than starting a second one against the same
        // session id. Below `initialCommands`, which is the override
        // `DemoFixture` stages through and is never clobbered.
        if let tmux = TmuxReattachCommandBuilder.initialCommand(for: tab, paneID: paneID) {
            return tmux
        }
        if let claude = ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: paneID) {
            return claude
        }
        return CodexResumeCommandBuilder.initialCommand(for: tab, paneID: paneID)
    }

    /// Stage the saved scrollback path for replay and clear it from the
    /// model so a later split / re-mount doesn't replay it again.
    @MainActor
    private static func stageScrollback(
        view: SurfaceView,
        session: WindowSession,
        tab: Tab?,
        paneID: UUID
    ) {
        guard let tab else { return }
        guard let rawPath = tab.scrollbackPaths[paneID], !rawPath.isEmpty else { return }
        // Only replay a `.vt` file we wrote; a tampered state.json could
        // otherwise point this at an arbitrary file for libghostty to read.
        if let path = WindowSession.validatedScrollbackPath(rawPath) {
            view.initialScrollbackPath = path
        }
        let tabID = tab.id
        session.update(tabID) { tab in
            tab.scrollbackPaths.removeValue(forKey: paneID)
        }
    }
}
