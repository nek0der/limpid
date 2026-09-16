// TmuxWindowMirror.swift
// Limpid — one tab showing one tmux window: pane sinks, screen bootstrap, layout changes, size reports.

import CoreGraphics
import Foundation
import OSLog

private let log = Logger.limpid("tmux.mirror")

/// Keeps a mirror tab in step with the tmux window it shows. tmux owns the
/// layout: every `%layout-change` for the window is folded onto the tab's
/// split tree, reusing each pane's leaf id so its surface, scrollback, and
/// search state survive. Limpid only ever sends the window size and, later,
/// the verbs the user performs; it never writes the tree on its own.
///
/// Observable for the two values the pane area draws from: the cell layout
/// and the cell size. Everything else is bookkeeping the view never reads.
@MainActor
@Observable
final class TmuxWindowMirror {
    let tabID: UUID
    let windowID: String
    let connection: TmuxServerConnection

    /// The window as tmux last described it, in cells. `nil` until tmux has
    /// answered once; the tab is drawn from its stored ratios until then.
    private(set) var cellLayout: TmuxLayout?
    /// One cell in points, as this tab's surfaces report it. Every pane of a
    /// mirror tab shares one grid (design §2 D2), so one report stands for
    /// all of them; a pane that disagrees is logged, not honored.
    private(set) var cellSize: CellSize?

    /// What the mirror knows about one leaf. Kept here rather than read
    /// back from the tab, because the tab is already gone by the time a
    /// closed mirror is stopped and its panes must still be detached.
    private struct Pane {
        let tmuxPane: String
        let sink: TmuxPaneSink
        var tty: String?
        var isSecureInput = false
    }

    @ObservationIgnored private let session: WindowSession
    @ObservationIgnored private let registry: any SurfaceViewProviding
    @ObservationIgnored private let secureInput: SecureInputManager?
    @ObservationIgnored private var panes: [UUID: Pane] = [:]
    /// Panes attached before the window had a size. Their screens are
    /// rebuilt once tmux has been told the size, so the capture is taken
    /// at the size the surface will draw it in.
    @ObservationIgnored private var awaitingGrid: Set<UUID> = []
    @ObservationIgnored private var hasReportedGrid = false
    @ObservationIgnored private var isStopped = false
    /// The pane area in points, from the view showing this tab. Zero while
    /// the tab is not on screen, which is also when nothing is reported.
    @ObservationIgnored private var areaSize: CGSize = .zero
    /// The grid last sent with `refresh-client -C`, so a layout pass that
    /// changes nothing sends nothing (design §8 D11).
    @ObservationIgnored private var reportedGrid: (columns: Int, rows: Int)?

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

    func shows(paneID: UUID) -> Bool {
        panes[paneID] != nil
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        for pane in panes.values {
            connection.detachPane(pane.tmuxPane)
        }
        panes.removeAll()
        awaitingGrid.removeAll()
    }

    // MARK: - Window size

    /// The pane area showing this tab changed size, or came on screen.
    func areaSizeChanged(_ size: CGSize) {
        guard size != areaSize else { return }
        areaSize = size
        reportGridIfChanged()
    }

    /// A surface of this tab reported its cell size. The first report seeds
    /// the value; after that only the focused pane can change it. A font
    /// shortcut reaches every pane, the focused one included, so it still
    /// lands; a pane that appears later with the default size does not
    /// drag the whole tab back to it (inheriting the size at creation is
    /// still open, see the implementation log).
    func cellSizeChanged(_ size: CellSize, from paneID: UUID) {
        guard size != cellSize else { return }
        if cellSize != nil, session.tab(tabID)?.splitTree.effectiveFocusedLeafID != paneID {
            log.notice("pane \(self.panes[paneID]?.tmuxPane ?? "?", privacy: .public) reports a different cell size; keeping the tab's")
            return
        }
        cellSize = size
        reportGridIfChanged()
    }

    /// The window is as many whole cells as fit in the area minus its
    /// padding. tmux answers with `%layout-change`, which is the authority;
    /// it runs commands in order, so a screen captured after this report is
    /// captured at the new size. Sent only when the value moved, because
    /// `%layout-change` → padding → `CELL_SIZE` → report would otherwise
    /// close a loop.
    private func reportGridIfChanged() {
        guard !isStopped, let cellSize else { return }
        let grid = PaneLayout.mirrorGrid(areaSize: areaSize, cellSize: cellSize, padding: .pinned)
        guard grid.columns > 0, grid.rows > 0,
              reportedGrid?.columns != grid.columns || reportedGrid?.rows != grid.rows
        else { return }
        reportedGrid = grid
        reportGrid(columns: grid.columns, rows: grid.rows)
    }

    /// Tell tmux the window's size. The first report also asks for the
    /// layout outright: tmux only announces `%layout-change` when something
    /// changed, and a window that already had this size would otherwise
    /// never show its other panes.
    func reportGrid(columns: Int, rows: Int) {
        guard !isStopped, columns > 0, rows > 0 else { return }
        log.debug("refresh-client -C \(self.windowID, privacy: .public):\(columns, privacy: .public)x\(rows, privacy: .public)")
        connection.send("refresh-client -C '\(windowID):\(columns)x\(rows)'") { [weak self] _, _ in
            guard let self, self.cellLayout == nil else { return }
            self.fetchLayout()
        }
        hasReportedGrid = true
        let pending = awaitingGrid
        awaitingGrid.removeAll()
        for paneID in pending {
            bootstrap(paneID: paneID)
        }
    }

    private func fetchLayout() {
        let target = TmuxProtocol.quote(windowID)
        connection.send("display-message -p -t \(target) '#{window_layout}'") { [weak self] lines, isError in
            guard let self, !isError, let text = lines.first else { return }
            self.applyLayout(text)
        }
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
        // The same layout can arrive twice: once fetched, once announced.
        guard layout != cellLayout else { return }
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
        cellLayout = layout
        let size = "\(layout.root.rect.width)x\(layout.root.rect.height)"
        log.debug("layout \(self.windowID, privacy: .public) \(size, privacy: .public) panes=\(present.count, privacy: .public)")
        scheduleGridCheck(layout)
    }

    /// Read each surface's grid back once the layout has had time to
    /// land and compare it with the cells tmux gave the pane (design §8
    /// D11). A mismatch is logged, not corrected: the arithmetic is meant
    /// to make them agree by construction, so a difference is a bug to
    /// find, not a state to patch over.
    private func scheduleGridCheck(_ layout: TmuxLayout) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, !self.isStopped, self.cellLayout == layout else { return }
            self.checkGrids(layout.root)
        }
    }

    private func checkGrids(_ node: TmuxLayoutNode) {
        switch node {
        case let .pane(tmuxPane, rect):
            guard let (paneID, _) = panes.first(where: { $0.value.tmuxPane == tmuxPane }),
                  let drawn = registry.view(for: paneID)?.drawnGrid
            else { return }
            let drawnText = "\(drawn.columns)x\(drawn.rows)"
            let tmuxText = "\(rect.width)x\(rect.height)"
            if drawn.columns != rect.width || drawn.rows != rect.height {
                log.notice("pane \(tmuxPane, privacy: .public) draws \(drawnText, privacy: .public); tmux \(tmuxText, privacy: .public)")
            } else {
                log.debug("pane \(tmuxPane, privacy: .public) grid matches \(tmuxText, privacy: .public)")
            }
        case let .sideBySide(_, children), let .stacked(_, children):
            for child in children {
                checkGrids(child)
            }
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
