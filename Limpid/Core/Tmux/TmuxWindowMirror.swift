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
/// Observable for the values the pane area draws from: the cell layout, the
/// cell size, and whether the connection still carries commands. Everything
/// else is bookkeeping the view never reads.
@MainActor
@Observable
final class TmuxWindowMirror {
    let tabID: UUID
    let windowID: String
    let connection: TmuxServerConnection
    /// Names for what the user reads when tmux ends the window or the
    /// session. Kept here because the tab's title follows the focused
    /// pane's terminal title, and the window is gone by the time it is
    /// named.
    let sessionName: String
    let windowName: String

    enum ConnectionState: Equatable {
        /// Commands reach tmux, or are held until the attach completes.
        case connected
        /// The client ended. Nothing is sent from here on; the panes keep
        /// what they last showed. Final for this mirror.
        case disconnected
    }

    /// Set by `TmuxConnectionStore`, which observes the connection's
    /// state in one place for every mirror on it.
    private(set) var connectionState: ConnectionState

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
    ///
    /// A pane's screen is rebuilt from `capture-pane` whenever the surface
    /// holds a screen tmux did not draw at the surface's size: when the
    /// pane is attached, whenever tmux announces a layout for its window
    /// (the transport pauses the pane on that line; see
    /// `TmuxControlTransport`), and when its sink overflowed. libghostty reflows a resized grid by its own rules, not
    /// tmux's, and the shell's redraw after a resize reaches the surface
    /// before the surface has taken the new size, so neither can be kept.
    /// The capture waits until libghostty reports that the surface's grid
    /// is the one tmux gave the pane; only then are both drawing the same
    /// screen.
    private struct Pane {
        let tmuxPane: String
        let sink: TmuxPaneSink
        var isSecureInput = false
        /// The pane's size in tmux: its layout cell, or the whole window
        /// while tmux has it zoomed. `nil` until a layout names the pane.
        var tmuxGrid: Grid?
        /// The grid libghostty last reported for the pane's surface. `nil`
        /// until the surface exists and has started its IO; a pane of a tab
        /// that is not on screen can stay there, paused, until it is shown.
        var surfaceGrid: Grid?
        /// The sink is paused and the screen waits for a capture.
        var isStale = false
        /// A capture is on its way. At most one is, so a pane resized
        /// again meanwhile starts its next capture from this one's reply.
        var isRebuilding = false
    }

    struct Grid: Equatable {
        let columns: Int
        let rows: Int
    }

    @ObservationIgnored private let session: WindowSession
    @ObservationIgnored private let registry: any SurfaceViewProviding
    @ObservationIgnored private let secureInput: SecureInputManager?
    @ObservationIgnored private var panes: [UUID: Pane] = [:]
    @ObservationIgnored private var isStopped = false
    /// The pane area in points, from the view showing this tab. Zero while
    /// the tab is not on screen, which is also when nothing is reported.
    @ObservationIgnored private var areaSize: CGSize = .zero
    /// The grid last sent with `refresh-client -C`, so a layout pass that
    /// changes nothing sends nothing (design §8 D11).
    @ObservationIgnored private var reportedGrid: (columns: Int, rows: Int)?
    /// tmux answered a verb with `%error`; the argument is the verb's
    /// localized failure message. Set by whoever opens the mirror and owns
    /// a toast center.
    @ObservationIgnored var onCommandFailed: ((String) -> Void)?
    /// The divider drag in progress: only the newest request waits, and
    /// only one is ever outstanding (`TmuxWindowMirror+Verbs.swift`).
    @ObservationIgnored var queuedResize: PendingResize?
    @ObservationIgnored var isResizeInFlight = false
    /// The pane tmux made active and the tab has not focused yet. tmux
    /// reports a split's new pane with `%window-pane-changed`, which can
    /// arrive before the `%layout-change` that gives the pane a leaf, so
    /// the report waits here until the leaf exists (design §4 D6).
    @ObservationIgnored private var pendingActivePane: String?
    /// The tmux pane the tab's focus already stands for: the active pane
    /// tmux reported and the tab took, or the pane we asked tmux to
    /// select. A focused leaf that maps to another pane was chosen in
    /// Limpid, and only that is sent (`tabChanged`). Every write of ours
    /// that moves the tab's focus sets this first, so the `reconcile` the
    /// write triggers finds nothing to send, and tmux's announcement of
    /// our own `select-pane` finds the focus already there.
    @ObservationIgnored private var activePane: String?

    struct PendingResize {
        let paneID: UUID
        let direction: SplitDirection
        let cells: Int
    }

    init(
        tabID: UUID,
        windowID: String,
        sessionName: String,
        windowName: String,
        connection: TmuxServerConnection,
        session: WindowSession,
        registry: any SurfaceViewProviding,
        secureInput: SecureInputManager?
    ) {
        self.tabID = tabID
        self.windowID = windowID
        self.sessionName = sessionName
        self.windowName = windowName
        self.connection = connection
        if case .exited = connection.state {
            connectionState = .disconnected
        } else {
            connectionState = .connected
        }
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
        activePane = tab.splitTree.focusedLeafID.flatMap { tmuxPane(ofLeaf: $0, in: tab) }
        // The palette listed the window a while ago, so tmux is asked which
        // pane is active now. The answer is a report like any other.
        guard canSend else { return }
        connection.send("display-message -p -t \(TmuxProtocol.quote(windowID)) '#{pane_id}'") { [weak self] lines, isError in
            guard let self, !isError, let pane = lines.first else { return }
            handle(.windowPaneChanged(window: windowID, pane: pane))
        }
    }

    func sink(for paneID: UUID) -> TmuxPaneSink? {
        panes[paneID]?.sink
    }

    func shows(paneID: UUID) -> Bool {
        panes[paneID] != nil
    }

    func tmuxPane(for paneID: UUID) -> String? {
        panes[paneID]?.tmuxPane
    }

    /// Whether a command may be sent. Every outbound path checks it, so a
    /// verb that reaches a disconnected mirror by a delayed route (a paste
    /// confirmed later, a queued resize) is not sent either.
    var canSend: Bool {
        !isStopped && connectionState == .connected
    }

    /// Typed input to a disconnected mirror is dropped without a word:
    /// telling the user once per keystroke would bury the screen.
    func sendInput(_ inputs: [TmuxInput], paneID: UUID) {
        guard canSend, let pane = panes[paneID] else { return }
        connection.sendInput(inputs, pane: pane.tmuxPane)
    }

    /// Let go of a pane tmux has moved out of this window, before another
    /// mirror on the same connection attaches it. tmux answers `break-pane`
    /// before it announces our `%layout-change`, and the connection refuses
    /// a pane that still has a sink, so the newcomer could not attach it
    /// until we detach it here. Idempotent: if that notification already
    /// ran, there is nothing left to do.
    func release(paneID: UUID) {
        detach(paneID: paneID)
        registry.unregister(paneID)
        guard let tab = session.tab(tabID), tab.splitTree.contains(leafID: paneID) else { return }
        // The neighbor the tab focuses next is not the user's choice; tmux
        // names this window's active pane after the move, and that report
        // is what the focus follows.
        activePane = tab.splitTree.remove(paneID).tree.focusedLeafID.flatMap { tmuxPane(ofLeaf: $0, in: tab) }
        session.removePane(paneID, fromTab: tabID)
    }

    /// The tab changed. A focus that moved to a pane tmux does not have
    /// active was chosen in Limpid (a click, a keyboard move, a jump), so
    /// tmux is told; its keys, copy-mode, and `#{pane_active}` follow the
    /// pane the user is looking at (design §4 D6). Nothing is sent for a
    /// change that left the focus alone, and nothing while disconnected.
    func tabChanged(_ tab: Tab) {
        guard canSend, let leafID = tab.splitTree.focusedLeafID,
              let pane = tmuxPane(ofLeaf: leafID, in: tab), pane != activePane
        else { return }
        activePane = pane
        // A report still waiting for its leaf predates this command, which
        // tmux runs after it.
        pendingActivePane = nil
        connection.send("select-pane -t \(TmuxProtocol.quote(pane))")
        refreshSecureInput(paneID: leafID)
    }

    /// The connection ended. The panes stay as they are until tmux is
    /// asked whether the session survived (`TmuxConnectionStore`); there is
    /// no automatic reconnect (design §9 D14).
    func connectionEnded() {
        guard connectionState == .connected else { return }
        connectionState = .disconnected
        queuedResize = nil
        log.notice("mirror window \(self.windowID, privacy: .public) lost its connection")
    }

    /// tmux ended what this tab shows, so the tab closes without asking:
    /// the panes are already gone on tmux's side and there is nothing left
    /// to confirm (stage 11 decision 3). Nor is it kept for reopening: the
    /// window it would mirror is gone. Closing the tab is what releases
    /// this mirror and, through `reconcile`, its connection.
    func closeTab() {
        TabActions.closeTab(session, registry: registry, tabID: tabID, confirm: false, isReopenable: false)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        for pane in panes.values {
            connection.detachPane(pane.tmuxPane)
        }
        panes.removeAll()
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
        guard canSend, let cellSize else { return }
        let grid = PaneLayout.mirrorGrid(areaSize: areaSize, cellSize: cellSize, padding: .pinned)
        guard grid.columns > 0, grid.rows > 0,
              reportedGrid?.columns != grid.columns || reportedGrid?.rows != grid.rows
        else { return }
        reportedGrid = grid
        reportGrid(columns: grid.columns, rows: grid.rows)
    }

    /// Tell tmux the window's size. Until a layout has arrived, the report
    /// also asks for the layout outright: tmux 3.7c announces
    /// `%layout-change` after every `refresh-client -C`, but we do not rely
    /// on a server doing so for a window that already had this size, which
    /// would otherwise never show its other panes.
    func reportGrid(columns: Int, rows: Int) {
        guard canSend, columns > 0, rows > 0 else { return }
        log.debug("refresh-client -C \(self.windowID, privacy: .public):\(columns, privacy: .public)x\(rows, privacy: .public)")
        connection.send("refresh-client -C '\(windowID):\(columns)x\(rows)'") { [weak self] _, _ in
            guard let self, self.cellLayout == nil else { return }
            self.fetchLayout()
        }
    }

    /// The fetched reply carries the same fields as `%layout-change` and
    /// goes through `handle`, because the announcement for the same report
    /// usually arrives first: a reply applied without the visible layout
    /// and flags would give a zoomed pane its unzoomed cell again, a grid
    /// its whole-window surface never reports, and leave it paused.
    private func fetchLayout() {
        let target = TmuxProtocol.quote(windowID)
        connection.send("display-message -p -t \(target) '\(TmuxProtocol.layoutFormat)'") { [weak self] lines, isError in
            guard let self, !isError, let text = lines.first else { return }
            guard let line = TmuxProtocol.layoutChange(window: self.windowID, reply: text) else {
                log.error("unparseable layout reply for \(self.windowID, privacy: .public)")
                return
            }
            self.handle(line)
        }
    }

    // MARK: - Inbound

    func handle(_ line: TmuxControlLine) {
        guard !isStopped else { return }
        switch line {
        case let .layoutChange(window, layout, visibleLayout, flags) where window == windowID:
            applyLayout(layout, visibleLayout: visibleLayout)
            applyZoom(visibleLayout: visibleLayout, flags: flags)
            applyActivePane()
        case let .windowPaneChanged(window, pane) where window == windowID:
            pendingActivePane = pane
            applyActivePane()
        default:
            break
        }
    }

    // MARK: - Panes

    private func attach(paneID: UUID, tmuxPane: String) {
        guard panes[paneID] == nil else { return }
        do {
            // A sink that dropped output is repainted from tmux.
            let sink = try connection.attachPane(tmuxPane) { [weak self] in
                self?.markStale(paneID: paneID)
            }
            panes[paneID] = Pane(tmuxPane: tmuxPane, sink: sink)
            markStale(paneID: paneID)
            sink.setOnOutputActivity { [weak self] in self?.refreshSecureInput(paneID: paneID) }
            refreshSecureInput(paneID: paneID)
        } catch {
            log.error("attach pane \(tmuxPane, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func detach(paneID: UUID) {
        guard let pane = panes.removeValue(forKey: paneID) else { return }
        connection.detachPane(pane.tmuxPane)
    }

    /// libghostty resized the surface of `paneID` to `columns` x `rows`.
    /// Bytes written to the surface from now on are parsed at that size.
    func surfaceGridChanged(columns: Int, rows: Int, paneID: UUID) {
        guard !isStopped, let pane = panes[paneID] else { return }
        let grid = Grid(columns: columns, rows: rows)
        panes[paneID]?.surfaceGrid = grid
        let drawn = "\(columns)x\(rows)"
        let tmux = pane.tmuxGrid.map { "\($0.columns)x\($0.rows)" } ?? "?"
        log.debug("pane \(pane.tmuxPane, privacy: .public) surface \(drawn, privacy: .public); tmux \(tmux, privacy: .public)")
        rebuildIfReady(paneID: paneID)
    }

    /// The surface's screen no longer matches tmux's: hold the pane's
    /// output until a capture repaints it. Everything held back is output
    /// tmux sent before that capture, so the capture already shows it.
    private func markStale(paneID: UUID) {
        guard let pane = panes[paneID] else { return }
        panes[paneID]?.isStale = true
        pane.sink.pause()
        rebuildIfReady(paneID: paneID)
    }

    private func rebuildIfReady(paneID: UUID) {
        guard var pane = panes[paneID], pane.isStale, !pane.isRebuilding,
              let grid = pane.surfaceGrid, grid == pane.tmuxGrid
        else { return }
        pane.isStale = false
        pane.isRebuilding = true
        panes[paneID] = pane
        bootstrap(paneID: paneID, pane: pane)
    }

    /// Reproduce the pane's visible screen and terminal modes in the
    /// surface. Output is held from the pause until the rebuilt screen has
    /// been injected, so live bytes cannot interleave with the paint, and
    /// the injection happens in stream order at the capture's `%end`, so
    /// the output tmux sends after the capture follows it without a gap.
    ///
    /// The sink's rebuild number is read where the state reply sits in the
    /// stream. Every line before it has reached us by the time the reply
    /// does, so a pane made stale by one of them is not captured; a pause
    /// routed after it makes the capture reply stand aside.
    private func bootstrap(paneID: UUID, pane: Pane) {
        let tmuxPane = pane.tmuxPane
        let sink = pane.sink
        let target = TmuxProtocol.quote(tmuxPane)
        let stateArrived = Self.stateInStream(sink: sink) { [weak self] state, rebuild in
            guard let self else { return }
            guard panes[paneID]?.isStale == false else {
                finishRebuild(paneID: paneID, tmuxPane: tmuxPane, outcome: .superseded)
                return
            }
            let restore = Self.restoreInStream(sink: sink, rebuild: rebuild, state: state) { [weak self] outcome in
                self?.finishRebuild(paneID: paneID, tmuxPane: tmuxPane, outcome: outcome)
            }
            // `-N` keeps trailing spaces, so a cursor after them lands where
            // tmux has it rather than past the end of a shortened row.
            connection.sendInStream("capture-pane -p -e -N -t \(target)", completion: restore)
        }
        connection.sendInStream("display-message -p -t \(target) '\(TmuxScreenRestore.stateFormat)'", completion: stateArrived)
    }

    /// The state reply's handler, run on the routing queue (see
    /// `restoreInStream`). `finished` gets the parsed state, or `nil` when
    /// tmux refused, and the sink's rebuild at the reply.
    private nonisolated static func stateInStream(
        sink: TmuxPaneSink,
        finished: @escaping @MainActor (TmuxScreenState?, _ rebuild: Int) -> Void
    ) -> @Sendable (_ lines: [String], _ isError: Bool) -> Void {
        { lines, isError in
            let rebuild = sink.latestRebuild
            let state = isError ? nil : lines.first.flatMap(TmuxScreenRestore.parseState)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finished(state, rebuild) }
            }
        }
    }

    private enum RebuildOutcome {
        case painted(rowCount: Int)
        /// The capture failed; the pane shows live output only.
        case liveOnly
        /// The pane went stale again before the reply; it stays paused.
        case superseded
    }

    /// The capture reply's handler, run on the routing queue. Built here,
    /// outside the main actor, so Dispatch can run it there (see
    /// `TmuxPaneSink`).
    private nonisolated static func restoreInStream(
        sink: TmuxPaneSink,
        rebuild: Int,
        state: TmuxScreenState?,
        finished: @escaping @MainActor (RebuildOutcome) -> Void
    ) -> @Sendable (_ rows: [String], _ isError: Bool) -> Void {
        { rows, isError in
            let outcome: RebuildOutcome
            if !isError, let state {
                let bytes = TmuxScreenRestore.sequence(rows: rows, rowCount: rows.count, state: state)
                outcome = sink.resumeInOrder(injecting: bytes, rebuild: rebuild) ? .painted(rowCount: rows.count) : .superseded
            } else {
                outcome = sink.resumeInOrder(injecting: nil, rebuild: rebuild) ? .liveOnly : .superseded
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finished(outcome) }
            }
        }
    }

    private func finishRebuild(paneID: UUID, tmuxPane: String, outcome: RebuildOutcome) {
        switch outcome {
        case let .painted(rowCount):
            log.notice("bootstrapped \(tmuxPane, privacy: .public) rows=\(rowCount, privacy: .public)")
            refreshSecureInput(paneID: paneID)
        case .liveOnly:
            // A connection that ended fails every pending capture; only a
            // capture tmux itself refused is a fault.
            if case .exited = connection.state {
                log.notice("screen bootstrap for \(tmuxPane, privacy: .public) ended with the connection")
            } else {
                log.error("screen bootstrap for \(tmuxPane, privacy: .public) fell back to live output")
            }
        case .superseded:
            log.debug("screen bootstrap for \(tmuxPane, privacy: .public) superseded by a newer pause")
        }
        guard panes[paneID] != nil else { return }
        panes[paneID]?.isRebuilding = false
        rebuildIfReady(paneID: paneID)
    }

    // MARK: - Layout

    /// `visibleLayout` is what tmux draws, which differs from `text` only
    /// while a pane is zoomed; the zoomed pane's size comes from it.
    private func applyLayout(_ text: String, visibleLayout: String?) {
        guard let layout = TmuxLayout.parse(text) else {
            log.error("unparseable layout for \(self.windowID, privacy: .public)")
            return
        }
        // The same layout can arrive twice: once fetched, once announced.
        if layout != cellLayout {
            foldLayout(layout)
        }
        let visible = visibleLayout.flatMap(TmuxLayout.parse)?.root.paneRects ?? [:]
        applyPaneGrids(layout.root.paneRects.merging(visible) { $1 })
    }

    private func foldLayout(_ layout: TmuxLayout) {
        guard let tab = session.tab(tabID) else { return }
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
        // A pane that left took the focus with it. tmux names the pane that
        // takes over only after this layout (measured on 3.7c), so the tab
        // focuses the first pane meanwhile, and that is not the user's
        // choice to send.
        var focus = tab.splitTree.focusedLeafID
        if let focused = focus, let pane = tmuxPane(ofLeaf: focused, in: tab), !present.contains(pane) {
            let successor = layout.root.paneIDs.first
            focus = successor.flatMap { leafIDs[$0] }
            activePane = successor
        }

        guard let binding = tab.paneSources.values.lazy.compactMap({ source -> TmuxBinding? in
            if case let .tmux(ref) = source {
                return ref.binding
            }
            return nil
        }).first else { return }

        let removed = session.removePanes(fromTab: tabID) { t in
            t.splitTree = SplitTree(root: tree, focusedLeafID: focus)
            for (leafID, tmuxPane) in added {
                t.paneSources[leafID] = .tmux(TmuxPaneRef(binding: binding, windowID: windowID, paneID: tmuxPane))
            }
        }
        for leafID in removed {
            detach(paneID: leafID)
            registry.unregister(leafID)
        }
        for (leafID, tmuxPane) in added {
            attach(paneID: leafID, tmuxPane: tmuxPane)
        }
        cellLayout = layout
        let size = "\(layout.root.rect.width)x\(layout.root.rect.height)"
        log.debug("layout \(self.windowID, privacy: .public) \(size, privacy: .public) panes=\(present.count, privacy: .public)")
    }

    /// Every pane the layout names is repainted. The transport paused it
    /// on the announcement and dropped its output, which the capture
    /// restores; one whose size did not change is captured at once, one
    /// that was resized waits until its surface reports the new grid.
    private func applyPaneGrids(_ rects: [String: TmuxCellRect]) {
        for (paneID, pane) in panes {
            guard let rect = rects[pane.tmuxPane] else { continue }
            panes[paneID]?.tmuxGrid = Grid(columns: rect.width, rows: rect.height)
            markStale(paneID: paneID)
        }
    }

    /// Focus follows tmux's active pane once per change, the way an
    /// ordinary split focuses the pane it creates. A later focus move the
    /// user makes in Limpid is sent to tmux instead (`tabChanged`), so the
    /// two agree again. A report is never sent back: `activePane` is set
    /// before the focus is written.
    private func applyActivePane() {
        guard let tmuxPane = pendingActivePane, let tab = session.tab(tabID),
              let leafID = tab.paneSources.first(where: { _, source in
                  if case let .tmux(ref) = source {
                      return ref.windowID == windowID && ref.paneID == tmuxPane
                  }
                  return false
              })?.key
        else { return }
        pendingActivePane = nil
        activePane = tmuxPane
        guard tab.splitTree.focusedLeafID != leafID else { return }
        session.update(tabID) { $0.splitTree.focusedLeafID = leafID }
        refreshSecureInput(paneID: leafID)
        // The keyboard moves only from one of this tab's panes (or from
        // nowhere): the change may come from another tmux client, and must
        // not take it from a search field, review, or the palette. A
        // background tab just remembers which pane to focus when shown.
        guard session.activeTabID == tabID, let window = registry.view(for: leafID)?.window else { return }
        let responder = window.firstResponder
        let isKeyboardInTab = responder == nil || responder === window
            || tab.paneSources.keys.contains { registry.view(for: $0) === responder }
        if isKeyboardInTab {
            PaneActions.pullKeyboardFocus(to: leafID, registry: registry)
        }
    }

    /// Zoom follows tmux's window flag (`Z`), never a local toggle. The
    /// visible layout names the one pane tmux is drawing over the whole
    /// window; that leaf becomes the tab's zoomed leaf, and the pane area
    /// gives it every edge, which is exactly the size tmux gave it.
    private func applyZoom(visibleLayout: String?, flags: String?) {
        let isZoomed = flags?.contains("Z") ?? false
        var zoomedLeaf: UUID?
        if isZoomed, let visible = visibleLayout.flatMap(TmuxLayout.parse),
           case let .pane(tmuxPane, _) = visible.root
        {
            zoomedLeaf = panes.first { $0.value.tmuxPane == tmuxPane }?.key
        }
        guard let tab = session.tab(tabID), tab.zoomedLeafID != zoomedLeaf else { return }
        session.update(tabID) { $0.zoomedLeafID = zoomedLeaf }
    }

    /// The pane of this window that `leafID` shows, read from the tab
    /// rather than from `panes`: a leaf the layout just added is in the tab
    /// before it is attached.
    private func tmuxPane(ofLeaf leafID: UUID, in tab: Tab) -> String? {
        guard case let .tmux(ref) = tab.ioSource(for: leafID), ref.windowID == windowID else { return nil }
        return ref.paneID
    }

    // MARK: - Secure input

    /// Read the pane's tty, then check it. tmux announces nothing when
    /// `respawn-pane` gives a pane a new pty (measured on 3.7c), and the
    /// old pty may already belong to another pane, so no tty is kept: each
    /// check asks for it first. The sink asks on output (at the start of a
    /// burst and once more when it ends), and the pane is also checked when
    /// attached, repainted, or focused (design §11 D16). A reply for a pane
    /// that has since left, or was replaced, is dropped.
    private func refreshSecureInput(paneID: UUID) {
        guard canSend, let tmuxPane = panes[paneID]?.tmuxPane else { return }
        connection.send("display-message -p -t \(TmuxProtocol.quote(tmuxPane)) '#{pane_tty}'") { [weak self] lines, isError in
            guard let self, !isError, let tty = lines.first, tty.hasPrefix("/dev/"),
                  panes[paneID]?.tmuxPane == tmuxPane
            else { return }
            probeSecureInput(paneID: paneID, tty: tty)
        }
    }

    /// libghostty cannot see a mirror pane's pty, so the password-prompt
    /// check reads the pane's tty directly. The check after a burst ends
    /// is the one that sees `read -s` and `sudo` switch the line
    /// discipline.
    private func probeSecureInput(paneID: UUID, tty: String) {
        guard let secureInput, let pane = panes[paneID],
              let view = registry.view(for: paneID),
              let isSecure = TmuxPaneTTYProbe.isSecureInput(tty: tty),
              isSecure != pane.isSecureInput
        else { return }
        panes[paneID]?.isSecureInput = isSecure
        secureInput.set(isSecure ? .on : .off, for: view)
        log.debug("secure input \(isSecure ? "on" : "off", privacy: .public) for \(pane.tmuxPane, privacy: .public)")
    }
}
