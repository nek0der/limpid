// PaneHostView.swift
// Limpid — NSViewRepresentable that wires one pane-leaf id to a
// SurfaceView, reusing instances through SurfaceRegistry so split-tree
// mutations or tab switches don't destroy the libghostty surface.

import AppKit
import SwiftUI

/// SwiftUI shim that measures the available size via `GeometryReader`
/// and forwards it into the NSViewRepresentable. Pre-C1 the
/// representable relied solely on AppKit's frame-change cascade —
/// adding a SwiftUI-driven push gives us a second channel that fires
/// when the layout system *knows* a size but AppKit hasn't reflected
/// it yet (mostly during live window resize).
struct PaneHostView: View {
    let paneID: UUID
    let ghosttyApp: GhosttyApp
    @Environment(\.surfaceRegistry) private var registry
    @Environment(WindowSession.self) private var session

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                PaneHostRepresentable(
                    paneID: paneID,
                    ghosttyApp: ghosttyApp,
                    registry: registry,
                    session: session,
                    size: geo.size
                )
                if let state = session.paneSearchStates[paneID],
                   let surfaceView = registry.view(for: paneID)
                {
                    PaneSearchOverlay(
                        paneID: paneID,
                        state: state,
                        surfaceView: surfaceView,
                        onClose: {
                            SessionActions.endSearch(
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
        }
    }
}

private struct PaneHostRepresentable: NSViewRepresentable {
    let paneID: UUID
    let ghosttyApp: GhosttyApp
    let registry: any SurfaceViewProviding
    let session: WindowSession
    let size: CGSize

    func makeNSView(context: Context) -> SurfaceView {
        let view: SurfaceView
        if let existing = registry.view(for: paneID) {
            view = existing
        } else {
            view = SurfaceView(ghosttyApp: ghosttyApp)
            let owningTab = session.tab(containing: paneID)
            view.initialWorkingDirectory = owningTab?.workingDirectory
            view.initialCommand = Self.resolveInitialCommand(
                tab: owningTab,
                paneID: paneID
            )
            // Wire the Claude shim into every pty: prepends our
            // bundled shim dir to PATH, exports LIMPID_PANE_ID (=
            // this split leaf's UUID, so two panes in one tab keep
            // independent sessions), and points the hook at our
            // sessions directory. Done unconditionally — if the
            // user never runs `claude`, these vars are inert.
            view.extraEnvironment = ClaudeShimLocator.environment(forPaneID: paneID)
            stageScrollback(for: view, tab: owningTab, paneID: paneID)
            registry.register(view, for: paneID)
        }
        let paneID = paneID
        view.onUserAcknowledge = { [weak session] in
            session?.clearUnread(paneID: paneID)
        }
        view.applyExpectedSize(size)
        return view
    }

    func updateNSView(_ nsView: SurfaceView, context: Context) {
        let paneID = paneID
        nsView.onUserAcknowledge = { [weak session] in
            session?.clearUnread(paneID: paneID)
        }
        nsView.applyExpectedSize(size)
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
        return ClaudeResumeCommandBuilder.initialCommand(for: tab, paneID: paneID)
    }

    /// Stage the saved scrollback path for replay and clear it from the
    /// model so a later split / re-mount doesn't replay it again.
    /// Split out of `makeNSView` to keep the chained optional binding +
    /// `session.update` closure out of an NSViewRepresentable body
    /// (the type checker doesn't like that combination).
    private func stageScrollback(
        for view: SurfaceView,
        tab: Tab?,
        paneID: UUID
    ) {
        guard let tab else { return }
        guard let path = tab.scrollbackPaths[paneID], !path.isEmpty else { return }
        view.initialScrollbackPath = path
        let tabID = tab.id
        session.update(tabID) { tab in
            tab.scrollbackPaths.removeValue(forKey: paneID)
        }
    }
}
