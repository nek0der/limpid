// TmuxWindowMirror.swift
// Limpid — one tab showing one tmux window: pane sinks, screen bootstrap, layout changes, size reports.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.mirror")

/// Keeps a mirror tab in step with the tmux window it shows. tmux owns the
/// layout: every `%layout-change` for the window is folded onto the tab's
/// split tree, reusing each pane's leaf id so its surface, scrollback, and
/// search state survive. Limpid only ever sends the window size and, later,
/// the verbs the user performs; it never writes the tree on its own.
@MainActor
final class TmuxWindowMirror {
    let tabID: UUID
    let windowID: String
    let connection: TmuxServerConnection

    /// What the mirror knows about one leaf. Kept here rather than read
    /// back from the tab, because the tab is already gone by the time a
    /// closed mirror is stopped and its panes must still be detached.
    private struct Pane {
        let tmuxPane: String
        let sink: TmuxPaneSink
        var tty: String?
        var isSecureInput = false
    }

    private let session: WindowSession
    private let registry: any SurfaceViewProviding
    private let secureInput: SecureInputManager?
    private var panes: [UUID: Pane] = [:]
    /// Panes attached before the surface reported a grid. Their screens
    /// are rebuilt once tmux has been told the size, so the capture is
    /// taken at the size the surface will draw it in.
    private var awaitingGrid: Set<UUID> = []
    private var hasReportedGrid = false
    private var isStopped = false

    init(
        tabID: UUID,
        windowID: String,
        connection: TmuxServerConnection,
        session: WindowSession,
        registry: any SurfaceViewProviding,
        secureInput: SecureInputManager?
    ) {
        self.tabID = tabID
        self.windowID = windowID
        self.connection = connection
        self.session = session
        self.registry = registry
        self.secureInput = secureInput
    }

    /// Attach a sink for every tmux pane the tab already lists. Sinks
    /// exist before any surface does, which is what lets `PaneHostView`
    /// hand the descriptor over at creation.
    func start() {
        guard let tab = session.tab(tabID) else { return }
        for (paneID, source) in tab.paneSources {
            guard case let .tmux(ref) = source, ref.windowID == windowID else { continue }
            attach(paneID: paneID, tmuxPane: ref.paneID)
        }
        connection.onPaneOverflow = { [weak self] tmuxPane in
            self?.rebuildScreen(tmuxPane: tmuxPane)
        }
    }

    func sink(for paneID: UUID) -> TmuxPaneSink? {
        panes[paneID]?.sink
    }

    /// The grid the pane's surface is drawing. With one pane it is the
    /// window; tmux answers with `%layout-change`, which is the authority.
    /// tmux runs commands in order, so a screen captured after this
    /// report is captured at the new size.
    func reportGrid(columns: Int, rows: Int) {
        guard !isStopped, columns > 0, rows > 0 else { return }
        connection.send("refresh-client -C '\(windowID):\(columns)x\(rows)'")
        hasReportedGrid = true
        let pending = awaitingGrid
        awaitingGrid.removeAll()
        for paneID in pending {
            bootstrap(paneID: paneID)
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        for (paneID, pane) in panes {
            registry.view(for: paneID)?.onGridChange = nil
            connection.detachPane(pane.tmuxPane)
        }
        panes.removeAll()
        awaitingGrid.removeAll()
    }

    // MARK: - Inbound

    func handle(_ line: TmuxControlLine) {
        guard !isStopped else { return }
        switch line {
        case let .layoutChange(window, layout, _, _) where window == windowID:
            applyLayout(layout)
        case .exit:
            // The connection is gone; the panes stay as dormant surfaces
            // until the user reconnects (no automatic reconnect by design).
            log.notice("mirror window \(self.windowID, privacy: .public) lost its connection")
        default:
            break
        }
    }

    // MARK: - Panes

    private func attach(paneID: UUID, tmuxPane: String) {
        guard panes[paneID] == nil else { return }
        do {
            let sink = try connection.attachPane(tmuxPane)
            panes[paneID] = Pane(tmuxPane: tmuxPane, sink: sink)
            sink.pause()
            sink.setOnOutputActivity { [weak self] in self?.probeSecureInput(paneID: paneID) }
            let target = TmuxProtocol.quote(tmuxPane)
            connection.send("display-message -p -t \(target) '#{pane_tty}'") { [weak self] lines, isError in
                guard !isError, let tty = lines.first, tty.hasPrefix("/dev/") else { return }
                self?.panes[paneID]?.tty = tty
            }
            if hasReportedGrid {
                bootstrap(paneID: paneID)
            } else {
                awaitingGrid.insert(paneID)
            }
        } catch {
            log.error("attach pane \(tmuxPane, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func detach(paneID: UUID) {
        guard let pane = panes.removeValue(forKey: paneID) else { return }
        registry.view(for: paneID)?.onGridChange = nil
        connection.detachPane(pane.tmuxPane)
        awaitingGrid.remove(paneID)
    }

    /// Reproduce the pane's visible screen and terminal modes in the fresh
    /// surface. Output is held from attach until the rebuilt screen has
    /// been injected, so live bytes cannot interleave with the paint.
    private func bootstrap(paneID: UUID) {
        guard let pane = panes[paneID] else { return }
        let tmuxPane = pane.tmuxPane
        let sink = pane.sink
        let target = TmuxProtocol.quote(tmuxPane)
        connection.send("display-message -p -t \(target) '\(TmuxScreenRestore.stateFormat)'") { [weak self] lines, isError in
            guard let self else { return }
            let state = isError ? nil : lines.first.flatMap(TmuxScreenRestore.parseState)
            self.connection.send("capture-pane -p -e -t \(target)") { [weak self] rows, rowsError in
                guard let self else { return }
                guard !rowsError, let state else {
                    sink.resume()
                    log.error("screen bootstrap for \(tmuxPane, privacy: .public) fell back to live output")
                    return
                }
                let bytes = TmuxScreenRestore.sequence(rows: rows, rowCount: rows.count, state: state)
                sink.resume(afterInjecting: bytes)
                log.notice("bootstrapped \(tmuxPane, privacy: .public) rows=\(rows.count, privacy: .public)")
                self.probeSecureInput(paneID: paneID)
            }
        }
    }

    /// A sink dropped output: hold the pane and paint it again from tmux.
    private func rebuildScreen(tmuxPane: String) {
        guard let (paneID, pane) = panes.first(where: { $0.value.tmuxPane == tmuxPane }) else { return }
        pane.sink.pause()
        bootstrap(paneID: paneID)
    }

    // MARK: - Layout

    private func applyLayout(_ text: String) {
        guard let layout = TmuxLayout.parse(text), let tab = session.tab(tabID) else {
            log.error("unparseable layout for \(self.windowID, privacy: .public)")
            return
        }
        // Reverse map first, so a pane that is still here keeps its leaf id
        // and therefore its surface, scrollback, and search state.
        var leafIDs: [String: UUID] = [:]
        for (paneID, source) in tab.paneSources {
            if case let .tmux(ref) = source, ref.windowID == windowID {
                leafIDs[ref.paneID] = paneID
            }
        }
        var added: [(UUID, String)] = []
        let tree = layout.paneNode { tmuxPane in
            if let existing = leafIDs[tmuxPane] {
                return existing
            }
            let fresh = UUID()
            leafIDs[tmuxPane] = fresh
            added.append((fresh, tmuxPane))
            return fresh
        }
        let present = Set(layout.root.paneIDs)
        let removed = leafIDs.filter { !present.contains($0.key) }

        guard let binding = tab.paneSources.values.lazy.compactMap({ source -> TmuxBinding? in
            if case let .tmux(ref) = source {
                return ref.binding
            }
            return nil
        }).first else { return }

        session.update(tabID) { t in
            let focused = t.splitTree.focusedLeafID
            t.splitTree = SplitTree(root: tree, focusedLeafID: focused)
            for (leafID, tmuxPane) in added {
                t.paneSources[leafID] = .tmux(TmuxPaneRef(binding: binding, windowID: windowID, paneID: tmuxPane))
            }
            for (_, leafID) in removed {
                t.paneSources.removeValue(forKey: leafID)
            }
            if let focused, !t.splitTree.contains(leafID: focused) {
                t.splitTree.focusedLeafID = t.splitTree.allLeafIDs().first
            }
        }
        for (_, leafID) in removed {
            detach(paneID: leafID)
            registry.unregister(leafID)
        }
        for (leafID, tmuxPane) in added {
            attach(paneID: leafID, tmuxPane: tmuxPane)
        }
    }

    // MARK: - Secure input

    /// libghostty cannot see a mirror pane's pty, so the password-prompt
    /// check reads the pane's tty directly. The sink calls this on output
    /// and once more when a burst ends, which is when `read -s` and
    /// `sudo` have switched the line discipline.
    private func probeSecureInput(paneID: UUID) {
        guard let secureInput, let pane = panes[paneID], let tty = pane.tty,
              let view = registry.view(for: paneID),
              let isSecure = TmuxPaneTTYProbe.isSecureInput(tty: tty),
              isSecure != pane.isSecureInput
        else { return }
        panes[paneID]?.isSecureInput = isSecure
        secureInput.set(isSecure ? .on : .off, for: view)
        log.debug("secure input \(isSecure ? "on" : "off", privacy: .public) for \(pane.tmuxPane, privacy: .public)")
    }
}
