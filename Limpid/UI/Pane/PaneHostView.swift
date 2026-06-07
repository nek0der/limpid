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
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(AttentionState.self) private var attention
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(LimpidDragState.self) private var dragState

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
                // Reuse the resolved `surfaceView` property —
                // `PaneAreaView.resolveOrCreateSurfaceView` already
                // registered it before passing it down, so the registry
                // lookup would re-resolve the same reference at the
                // cost of a per-render hashmap probe and a local
                // shadow that hides the invariant.
                if let state = session.paneSearchStates[paneID] {
                    let surfaceView = self.surfaceView
                    PaneSearchOverlay(
                        paneID: paneID,
                        state: state,
                        surfaceView: surfaceView,
                        onClose: {
                            SearchActions.endSearch(
                                session,
                                registry: registry,
                                paneID: paneID
                            )
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: session.paneSearchStates[paneID] != nil)
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
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.yellow)
            Text("Terminal failed to start", comment: "Pane surface NULL recovery title")
                .font(.system(size: 14, weight: .semibold))
            Text(
                "libghostty could not allocate this pane. Retry to try again.",
                comment: "Pane surface NULL recovery body"
            )
            .font(.system(size: 12))
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
        .padding(20)
    }
}

/// Short-lived wrapper that SwiftUI owns through `NSViewRepresentable`.
/// Hosts the persistent, registry-owned `SurfaceView` as its only
/// subview. Pinning the surface to `bounds` via autoresizing keeps it
/// sized through divider drags and window resizes without needing to
/// observe layout ourselves.
final class PaneContainerNSView: NSView {
    private(set) var surfaceView: SurfaceView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Attach (or re-attach) the supplied `SurfaceView` as the sole subview.
    /// If the surface is currently parented by a different container (it was
    /// just lifted out of an old `PaneContainerNSView`), AppKit's
    /// `addSubview` quietly removes it from the previous superview first.
    func mount(_ view: SurfaceView) {
        guard surfaceView !== view else { return }
        surfaceView?.removeFromSuperview()
        surfaceView = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
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
    let size: CGSize

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
    }

    func makeNSView(context: Context) -> PaneContainerNSView {
        let container = PaneContainerNSView(frame: NSRect(origin: .zero, size: size))
        wireCallbacks(on: surfaceView)
        surfaceView.applyExpectedSize(size)
        container.mount(surfaceView)
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
        surfaceView.applyExpectedSize(size)
        // Re-mount whenever SwiftUI hands us back the container — if the
        // surface was just reparented from another container on a fast
        // tab switch this picks it back up; otherwise it's a no-op.
        container.mount(surfaceView)
        // Defensive retry — `SurfaceView.viewDidMoveToWindow` early-
        // returns when `window == nil`, so `createSurface()` never runs
        // if AppKit ferries the view through a detached mount. This
        // catches the case where the deferred call from `makeNSView`
        // missed the window (divider drag, rapid split).
        if surfaceView.window != nil, surfaceView.surface == nil {
            surfaceView.createSurface()
        }
    }

    @MainActor
    static func resolveOrCreateSurfaceView(
        paneID: UUID,
        ghosttyApp: GhosttyApp,
        registry: any SurfaceViewProviding,
        session: WindowSession
    ) -> SurfaceView {
        if let existing = registry.view(for: paneID) {
            return existing
        }
        let view = SurfaceView(ghosttyApp: ghosttyApp)
        let owningTab = session.tab(containing: paneID)
        view.initialWorkingDirectory = owningTab?.workingDirectory
        view.initialCommand = Self.resolveInitialCommand(
            tab: owningTab,
            paneID: paneID
        )
        // Wire the Claude shim + Codex shadow CODEX_HOME into every
        // pty. Both layers are inert when the user never runs the
        // matching CLI; injecting unconditionally keeps spawn paths
        // uniform across panes.
        var env = ClaudeShimLocator.environment(forPaneID: paneID)
        for (k, v) in CodexHomeRedirector.shared.environment(forPaneID: paneID) {
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
        view.onRequestSplit = { [weak session, registry, settings, toastCenter] direction in
            guard let session else { return }
            PaneActions.split(
                session,
                direction: direction,
                registry: registry,
                minPaneSize: settings.settings.terminal.minPaneSize,
                toastCenter: toastCenter
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
        view.onRequestMoveToNewTab = { [weak session] in
            guard let session else { return }
            TabActions.movePaneToNewTab(session, paneID: paneID)
        }
        view.canMoveToNewTab = { [weak session] in
            guard let session else { return false }
            guard let tab = session.tab(containing: paneID) else { return false }
            return tab.splitTree.allLeafIDs().count > 1
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
    private static func resolveInitialCommand(
        tab: Tab?,
        paneID: UUID
    ) -> String? {
        if let staged = tab?.initialCommands[paneID], !staged.isEmpty {
            return staged
        }
        guard let tab else { return nil }
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
