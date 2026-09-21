// TmuxConnectionStore.swift
// Limpid — the control-mode connections the app holds, one per tmux session, and the tabs mirroring through them.

import CoreGraphics
import Foundation
import OSLog

private let log = Logger.limpid("tmux.store")

/// Owns every `TmuxSessionConnection` and every `TmuxWindowMirror`. A
/// connection stays open exactly as long as some tab mirrors through it:
/// liveness is derived from the tabs on each `reconcile`, never counted by
/// hand, because counts leak.
///
/// Keyed by session rather than by server. A control client attaches to
/// one session and receives that session's windows; mirroring a second
/// session on the same server is a second client. The design speaks of
/// "one per server", which holds for the first version's scope of one
/// window per tab.
///
/// Observable only for `mirrors`, `tabConnections`, `tabIssues`,
/// `panesAwaitingRestoreCheck`, and `droppedInput`: the pane area draws a
/// mirror tab from its mirror, holds back the leaves whose binding is still
/// being checked, says how the tab stands with its server and tells the
/// user when their typing went nowhere, the tab's row marks the connection
/// and what its mirror warns about, and all of it can change after the tab
/// is on screen. Everything else is bookkeeping the view never reads.
@MainActor
@Observable
final class TmuxConnectionStore {
    struct Key: Hashable {
        let socketPath: String
        let sessionID: String

        init(socketPath: String, sessionID: String) {
            self.socketPath = socketPath
            self.sessionID = sessionID
        }

        init(_ binding: TmuxBinding) {
            self.init(socketPath: binding.socketPath, sessionID: binding.sessionID)
        }
    }

    /// Absolute path of the tmux executable, or `nil` when none is
    /// installed where a GUI app can see it.
    let tmuxExecutable: String?

    @ObservationIgnored private(set) var connections: [Key: TmuxSessionConnection] = [:]
    private(set) var mirrors: [UUID: TmuxWindowMirror] = [:]
    /// How each mirror tab stands with its server, by tab id. Set when a
    /// mirror is registered and when its connection ends; released on
    /// `reconcile` once the tab is gone.
    private(set) var tabConnections: [UUID: TmuxTabConnection] = [:]
    /// What each live mirror tab's row warns about, by tab id, as its
    /// mirror last reported. A tab with nothing to warn about has no entry.
    /// Forgotten when the mirror loses its connection, since nothing is
    /// repainted or resized from then on and the connection state says
    /// more, and when another mirror takes the tab over.
    private(set) var tabIssues: [UUID: TmuxTabIssues] = [:]
    /// Which panes of each connection have their output paused. A control
    /// client is fed every pane of the session; the ones no tab shows are
    /// switched off so a build in a hidden window cannot fill the pipe
    /// (design §8 D12).
    @ObservationIgnored private(set) var outputGates: [Key: TmuxOutputGate] = [:]
    /// The stream each `.tmux` or `.unavailable` leaf's surface reads, with
    /// or without a mirror feeding it: a restored tab before adoption, a
    /// tab whose server went away, and a live mirror's pane all read their
    /// leaf's channel, so a surface never has to be recreated to be fed by
    /// a later connection. A leaf without a feeding mirror shows nothing
    /// instead of spawning a shell. Released on `reconcile` once the leaf
    /// is gone; a surface or a sink still holding one keeps it open.
    @ObservationIgnored private var channels: [UUID: TmuxPaneChannel] = [:]
    /// What the surfaces of the leaves above and the pane areas of mirror
    /// tabs last reported, mirror or not. The only copy: a mirror reads it
    /// when it starts and when a report is forwarded to it. Released on
    /// `reconcile` together with the channels.
    @ObservationIgnored private(set) var surfaceReports = TmuxSurfaceReports()
    /// The colors every connection reports to its panes: those of the last
    /// config libghostty resolved, which is where a light or dark switch
    /// shows up. The first arrives while libghostty starts.
    @ObservationIgnored private(set) var terminalColors: TerminalColors?
    /// What the user is told when tmux ends a mirrored window or session,
    /// or refuses a verb a mirror sent. Set by whoever owns the toast
    /// center.
    @ObservationIgnored var onNotice: ((String) -> Void)?
    /// What the store asks about the agent runs behind its tabs
    /// (`outcome(ofEnded:)`). Without one — in a test, in a preview — an
    /// agent's tab is kept rather than closed: nothing here can say whether a
    /// conversation is left in it, and keeping the tab loses nothing.
    @ObservationIgnored var agentRuns: AgentTmuxRuns?

    typealias SessionPresenceCheck = @Sendable (
        _ tmuxPath: String,
        _ socketPath: String,
        _ sessionID: String
    ) async -> TmuxSessionPresence
    @ObservationIgnored private let sessionPresence: SessionPresenceCheck

    /// The surfaces of the window this store serves. Every mirror reaches
    /// its leaves' views through it, and a tab tmux ends is closed through
    /// it. Held here rather than passed by each caller, so a new way of
    /// opening a mirror cannot build one that reaches other surfaces.
    @ObservationIgnored let registry: any SurfaceViewProviding
    /// Where every mirror turns Secure Input on for a pane taking a
    /// password. `nil` only where nothing may change the process-wide
    /// state, such as a test that does not observe it.
    @ObservationIgnored private let secureInput: (any TmuxSecureInputSwitching)?

    init(
        registry: any SurfaceViewProviding,
        secureInput: (any TmuxSecureInputSwitching)?,
        tmuxExecutable: String? = TmuxClientProbe.locateTmux(),
        sessionPresence: @escaping SessionPresenceCheck = TmuxSessionProbe.check
    ) {
        self.registry = registry
        self.secureInput = secureInput
        self.tmuxExecutable = tmuxExecutable
        self.sessionPresence = sessionPresence
    }

    /// Leaves whose restored tmux binding is being checked against its
    /// server, from the moment the session is restored until the answer is
    /// in (`TmuxMirrorActions.reconcileRestoredBindings`). None of them can
    /// be given a surface yet: the answer decides whether the leaf becomes
    /// a mirror pane, which never starts a process, or a shell, and whether
    /// an attach is typed into that shell. A surface made in the meantime
    /// would be the wrong one either way.
    private(set) var panesAwaitingRestoreCheck: Set<UUID> = []

    /// Whether `paneID` is one of them. Read while a pane area is laid out,
    /// so the leaf gets its surface as soon as the check ends.
    func isAwaitingRestoreCheck(_ paneID: UUID) -> Bool {
        panesAwaitingRestoreCheck.contains(paneID)
    }

    func beginRestoreCheck(panes: Set<UUID>) {
        panesAwaitingRestoreCheck = panes
    }

    /// Idempotent: the check ends when its answer has been written, and
    /// again if the task that carried it was cancelled first.
    func endRestoreCheck() {
        guard !panesAwaitingRestoreCheck.isEmpty else { return }
        panesAwaitingRestoreCheck = []
    }

    /// Leaves that were an agent's mirror pane and became an ordinary
    /// terminal because their tmux went away (`becomeTerminalTab`). Their
    /// shells run agents directly rather than in tmux
    /// (`PaneShellEnvironment.agentTmuxAnswer`), which is what keeps the
    /// resume they start in the tab they are in.
    ///
    /// That holds for the leaf's whole life in this launch, so a `claude` the
    /// user types there later also runs in place; a new tab hosts its agents
    /// as usual. The set is not saved: a leaf restored after a relaunch is an
    /// ordinary pane again, and its shell is told to host like any other.
    /// Nor is it pruned when a leaf closes. Leaf ids are never reused, and a
    /// closed tab reopened with the same leaf is still the one that came back
    /// from tmux.
    ///
    /// Not observed: a leaf is added before the tab write that builds its
    /// surface, and the pane area reads it while laying out that write.
    @ObservationIgnored private(set) var leavesBackFromTmux: Set<UUID> = []

    /// Whether the shell of leaf `paneID` runs agents directly because the
    /// leaf came back from tmux.
    func runsAgentsDirectly(inPane paneID: UUID) -> Bool {
        leavesBackFromTmux.contains(paneID)
    }

    /// The channel of leaf `paneID`, opened on first use. `nil` only when
    /// no socketpair could be opened.
    func channel(paneID: UUID) -> TmuxPaneChannel? {
        if let existing = channels[paneID] {
            return existing
        }
        do {
            let channel = try TmuxPaneChannel { [weak self] data in
                self?.surfaceWrote(data, paneID: paneID)
            }
            channels[paneID] = channel
            return channel
        } catch {
            log.error("pane channel failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// What a surface wrote back (mouse and focus reports) goes to the pane
    /// through the mirror showing it, and nowhere without one.
    private func surfaceWrote(_ data: Data, paneID: UUID) {
        sendInput([.bytes(Array(data))], paneID: paneID)
    }

    /// The connection for `binding`'s session, started on first use, for a
    /// tab being opened or one being connected again alike. What a refusal
    /// of the attach does to a tab is decided by the tab, not by who asked
    /// for the connection (`connectionEnded`), so tabs of both kinds can
    /// share one connection.
    ///
    /// A connection tmux has ended is replaced rather than handed out: the
    /// palette lists what `list-windows` reaches now, which may be a new
    /// server on the same socket, and a new tab must not inherit a client
    /// that will never deliver. The ended one is only forgotten, not
    /// stopped. The mirrors of tabs that lost it still hold it and its
    /// sinks, and they release them when their tabs close or are
    /// reconnected.
    func connection(for binding: TmuxBinding) throws -> TmuxSessionConnection {
        let key = Key(binding)
        if let existing = connections[key] {
            guard case .exited = existing.state else { return existing }
            connections.removeValue(forKey: key)
            outputGates.removeValue(forKey: key)
            log.notice("replacing ended connection session=\(key.sessionID, privacy: .public)")
        }
        guard let tmuxExecutable else { throw TmuxStoreError.tmuxNotInstalled }
        let connection = TmuxSessionConnection(
            executable: tmuxExecutable,
            target: .init(socketPath: binding.socketPath, sessionID: binding.sessionID)
        )
        connection.onNotification = { [weak self, weak connection] line in
            guard let self, let connection else { return }
            dispatch(line, from: key, connection: connection)
        }
        connection.onStateChange = { [weak self, weak connection] state in
            guard let self, let connection, case .exited = state else { return }
            connectionEnded(connection)
        }
        connection.terminalColors = terminalColors
        try connection.start()
        connections[key] = connection
        outputGates[key] = TmuxOutputGate()
        // Learn every pane of the session once; notifications keep the
        // picture current from here on.
        connection.send("list-panes -s -F '#{window_id} #{pane_id}'") { [weak self] lines, isError in
            guard let self, !isError, self.connections[key] === connection else { return }
            let panes = lines.compactMap { line -> (window: String, pane: String)? in
                let fields = line.split(separator: " ")
                guard fields.count == 2 else { return nil }
                return (String(fields[0]), String(fields[1]))
            }
            self.outputGates[key]?.replaceAll(panes)
            self.gateOutput(for: key)
        }
        return connection
    }

    /// A surface reported its cell size; the mirror showing that pane lays
    /// its panes out from it. Recorded only for a leaf with a channel, the
    /// only surfaces a mirror can ever feed; a local pane reports too.
    func cellSizeChanged(_ size: CellSize, paneID: UUID) {
        guard channels[paneID] != nil else { return }
        surfaceReports.setCellSize(size, paneID: paneID)
        guard let mirror = mirrors.values.first(where: { $0.contains(paneID: paneID) }) else { return }
        mirror.cellSizeChanged(size, from: paneID)
    }

    /// A mirror surface's terminal took a new grid; the mirror showing that
    /// pane repaints it from tmux once the grid is the one tmux gave it.
    func mirrorGridResized(columns: Int, rows: Int, paneID: UUID) {
        guard channels[paneID] != nil else { return }
        surfaceReports.setGrid(TmuxWindowMirror.Grid(columns: columns, rows: rows), paneID: paneID)
        guard let mirror = mirrors.values.first(where: { $0.contains(paneID: paneID) }) else { return }
        mirror.surfaceGridChanged(paneID: paneID)
    }

    /// The pane area showing mirror tab `tabID` has `size`, having changed
    /// or come on screen; its mirror sizes the tmux window from it.
    func areaSizeChanged(_ size: CGSize, tabID: UUID) {
        guard surfaceReports.areaSizes[tabID] != size else { return }
        surfaceReports.setAreaSize(size, tabID: tabID)
        mirrors[tabID]?.areaSizeChanged()
    }

    /// The last time typing went nowhere, for the pane area to say so.
    ///
    /// A dropped keystroke is not told about once per key — that would bury
    /// the screen — so the count is what a view watches: it rises with each
    /// drop, which lets a notice already on screen stay up rather than
    /// having to be cleared and raised again, and a second burst of typing
    /// restarts the wait.
    struct DroppedInput: Equatable {
        let paneID: UUID
        /// Rises with every dropped keystroke of this run.
        let count: Int
    }

    /// Set whenever a key or text typed into a mirror pane could not be
    /// sent, and never cleared here: the view that shows it decides how long
    /// it stays, and a stale value names a pane nothing is typing into.
    private(set) var droppedInput: DroppedInput?

    /// A key typed into a mirror pane. A pane with no live mirror (dormant,
    /// or its connection gone) has nowhere to send it.
    func sendKey(_ event: TmuxKeyEvent, paneID: UUID) {
        sendInput(TmuxKeyTranslator.inputs(for: event), paneID: paneID, isTyped: true)
    }

    /// Text a binding or the surface's text entry point sent to a mirror pane.
    func sendText(_ bytes: [UInt8], paneID: UUID) {
        sendInput(TmuxKeyTranslator.inputs(forText: bytes), paneID: paneID, isTyped: true)
    }

    /// `isTyped` marks what the user meant to send. A mouse or focus report
    /// the surface wrote back goes the same way, and a dropped one is not
    /// news: nobody typed it, and saying so would raise the notice from
    /// moving the pointer over a disconnected pane.
    private func sendInput(_ inputs: [TmuxInput], paneID: UUID, isTyped: Bool = false) {
        guard !inputs.isEmpty else { return }
        guard let mirror = mirrors.values.first(where: { $0.contains(paneID: paneID) }), mirror.canSend else {
            guard isTyped else { return }
            droppedInput = DroppedInput(paneID: paneID, count: (droppedInput?.count ?? 0) + 1)
            return
        }
        mirror.sendInput(inputs, paneID: paneID)
    }

    func setTerminalColors(_ colors: TerminalColors) {
        guard colors != terminalColors else { return }
        terminalColors = colors
        for connection in connections.values {
            connection.terminalColors = colors
        }
    }

    /// The mirror behind `tabID`, connected or not. For what the tab
    /// shows (its layout, its size, its connection state); an action that
    /// sends something to tmux asks `liveMirror(for:)` instead.
    func mirror(for tabID: UUID) -> TmuxWindowMirror? {
        mirrors[tabID]
    }

    /// The mirror behind `tabID` while its connection carries commands.
    func liveMirror(for tabID: UUID) -> TmuxWindowMirror? {
        guard let mirror = mirrors[tabID], mirror.connectionState == .connected else { return nil }
        return mirror
    }

    /// The mirror already showing `windowID` of `binding`'s session over a
    /// connection that still delivers. A tmux pane feeds exactly one sink,
    /// so a second tab on the same window is never opened (design §4).
    func liveMirror(showing windowID: String, of binding: TmuxBinding) -> TmuxWindowMirror? {
        let key = Key(binding)
        return mirrors.values.first {
            $0.connectionState == .connected && Self.key(of: $0) == key && $0.windowID == windowID
        }
    }

    /// The control clients this app started, as tmux lists them. A mirror
    /// about to attach leaves these alone: they are this app's own.
    var ownControlPIDs: Set<pid_t> {
        Set(connections.values.compactMap(\.clientPID))
    }

    // swiftlint:disable function_parameter_count
    /// A mirror for tab `tabID` of `session`, fed through the leaves'
    /// channels and started from this store's reports, whether the tab is
    /// new or had a mirror before. `isNewTab` says which
    /// (`TmuxWindowMirror.isNewTab`). Not registered yet: the caller does
    /// that once it has decided the mirror goes ahead.
    func makeMirror(
        tabID: UUID,
        windowID: String,
        binding: TmuxBinding,
        names: (session: String, window: String),
        connection: TmuxSessionConnection,
        isNewTab: Bool,
        session: WindowSession
    ) -> TmuxWindowMirror {
        let mirror = TmuxWindowMirror(
            tabID: tabID,
            windowID: windowID,
            binding: binding,
            sessionName: names.session,
            windowName: names.window,
            connection: connection,
            isNewTab: isNewTab,
            session: session,
            registry: registry,
            secureInput: secureInput,
            channelForPane: { [weak self] in self?.channel(paneID: $0) },
            surfaceReports: { [weak self] in self?.surfaceReports ?? TmuxSurfaceReports() }
        )
        // tmux refused a verb (`%error`): the picture stays as it was and
        // the user reads which operation failed (design §12).
        mirror.onCommandFailed = { [weak self] message in
            self?.onNotice?(message)
        }
        return mirror
    }

    // swiftlint:enable function_parameter_count

    /// Make `mirror` the one behind its tab. A mirror the tab had before,
    /// one that lost its connection, is stopped first: its sinks are
    /// closed and whatever they still held is dropped, and from here on
    /// only `mirror` is matched by identity, so a late reply to the old
    /// one reaches nobody. The leaves' channels stay as they are, so the
    /// surfaces keep their screens and scrollback for `mirror` to feed.
    func register(_ mirror: TmuxWindowMirror) {
        if let previous = mirrors[mirror.tabID], previous !== mirror {
            previous.stop()
        }
        mirrors[mirror.tabID] = mirror
        tabConnections[mirror.tabID] = mirror.connectionState == .connected ? .live : .disconnected
        tabIssues.removeValue(forKey: mirror.tabID)
        mirror.onIssuesChanged = { [weak self, weak mirror] issues in
            guard let self, let mirror, mirrors[mirror.tabID] === mirror, mirror.connectionState == .connected else { return }
            tabIssues[mirror.tabID] = issues == TmuxTabIssues() ? nil : issues
        }
        gateOutput(for: Self.key(of: mirror))
    }

    // MARK: - Reconnect

    /// Whether tab `tabID` can be connected to its session again: its
    /// connection ended, or its server did not answer, or it is a mirror
    /// tab that never had a mirror in this run (restored, or reopened).
    /// A tab on its way, a live one, and one whose server was replaced
    /// cannot.
    func canReconnect(tabID: UUID) -> Bool {
        switch tabConnections[tabID] {
        case .disconnected, .unreachable:
            true
        case nil:
            mirrors[tabID] == nil
        case .connecting, .live, .serverReplaced:
            false
        }
    }

    /// Record how tab `tabID` stands while a reconnect decides, or when it
    /// has decided without a mirror to register. `nil` forgets the tab's
    /// state, as a tab that never had one.
    func setTabConnection(_ state: TmuxTabConnection?, tabID: UUID) {
        tabConnections[tabID] = state
    }

    /// Close the tabs whose window the session no longer has, once the
    /// reconnected client answers. The listing runs after the attach, so it
    /// describes the session the mirrors now show. A mirror that has been
    /// replaced or lost its connection meanwhile is left alone.
    func closeMirrorsOfMissingWindows(_ started: [TmuxWindowMirror], on connection: TmuxSessionConnection) {
        guard !started.isEmpty else { return }
        let target = TmuxProtocol.quote(connection.target.sessionID)
        connection.send("list-windows -t \(target) -F '#{window_id}'") { [weak self] lines, isError in
            guard let self, !isError else { return }
            let present = Set(lines)
            for mirror in started where !present.contains(mirror.windowID) {
                guard mirrors[mirror.tabID] === mirror, mirror.connectionState == .connected else { continue }
                let name = mirror.displayName
                if endTab(mirror.endedTab, route: .windowMissing) {
                    onNotice?(Self.windowClosedNotice(name: name))
                }
            }
        }
    }

    /// What the user reads when tmux closed a mirrored window. `name` is
    /// `session:window`.
    static func windowClosedNotice(name: String) -> String {
        String(localized: "The tmux window “\(name)” was closed")
    }

    /// What the user reads when tmux ended a mirrored session.
    static func sessionEndedNotice(sessionName: String) -> String {
        String(localized: "The tmux session “\(sessionName)” ended")
    }

    /// Drop mirrors whose tab is gone, then connections no mirror uses,
    /// and hand every remaining mirror its tab. Called whenever the tab
    /// list changes; idempotent.
    ///
    /// Everything here is released or forwarded, never created, so a store
    /// that holds nothing returns at once: a user who never mirrors tmux
    /// pays nothing for the title and directory updates that also write
    /// the tab list. A restored mirror tab is not "nothing": its leaves get
    /// channels as their surfaces mount, and its state is recorded by the
    /// reconnect, so both are among what is checked.
    func reconcile(tabs: [Tab]) {
        guard !holdsNothing else { return }
        let liveTabs = Set(tabs.map(\.id))
        var touchedKeys: Set<Key> = []
        // Stopped first, then dropped in one pass: a dictionary is not
        // walked while it is being written.
        for (tabID, mirror) in mirrors where !liveTabs.contains(tabID) {
            mirror.stop()
            touchedKeys.insert(Self.key(of: mirror))
        }
        mirrors = mirrors.filter { liveTabs.contains($0.key) }
        // By identity, not by key: a tab that lost its connection keeps a
        // mirror under the same key as the connection that replaced it.
        let usedKeys = Set(connections.compactMap { key, connection in
            mirrors.values.contains { $0.connection === connection } ? key : nil
        })
        for (key, connection) in connections where !usedKeys.contains(key) {
            connection.stop()
            log.notice("closed idle connection session=\(key.sessionID, privacy: .public)")
        }
        connections = connections.filter { usedKeys.contains($0.key) }
        outputGates = outputGates.filter { usedKeys.contains($0.key) }
        for key in touchedKeys where usedKeys.contains(key) {
            gateOutput(for: key)
        }
        // A focus move reaches a mirror only here: the focus lives in the
        // tab, and every write to it passes through this call.
        if !mirrors.isEmpty {
            for tab in tabs {
                mirrors[tab.id]?.tabChanged(tab)
            }
        }
        tabConnections = tabConnections.filter { liveTabs.contains($0.key) }
        tabIssues = tabIssues.filter { liveTabs.contains($0.key) }
        guard !channels.isEmpty || !surfaceReports.isEmpty else { return }
        let channelLeaves = Set(tabs.flatMap { tab in
            tab.splitTree.allLeafIDs().filter { tab.ioSource(for: $0) != .local }
        })
        channels = channels.filter { channelLeaves.contains($0.key) }
        surfaceReports.retain(leaves: channelLeaves, tabs: liveTabs)
    }

    /// No mirror, connection, channel, report, or tab state is held.
    private var holdsNothing: Bool {
        mirrors.isEmpty && connections.isEmpty && channels.isEmpty && tabConnections.isEmpty
            && tabIssues.isEmpty && outputGates.isEmpty && surfaceReports.isEmpty
    }

    /// Termination: detach every client so tmux does not keep serving a
    /// process that is about to die.
    func stopAll() {
        for mirror in mirrors.values {
            mirror.stop()
        }
        mirrors.removeAll()
        tabConnections.removeAll()
        tabIssues.removeAll()
        for connection in connections.values {
            connection.stop()
        }
        connections.removeAll()
        outputGates.removeAll()
        channels.removeAll()
        surfaceReports = TmuxSurfaceReports()
    }

    private static func key(of mirror: TmuxWindowMirror) -> Key {
        Key(socketPath: mirror.connection.target.socketPath, sessionID: mirror.connection.target.sessionID)
    }

    /// Mirrors are matched by connection, not by key, so a tab that lost
    /// its connection never reacts to the server that replaced it; a new
    /// server numbers its windows from `@0` again.
    private func dispatch(_ line: TmuxControlLine, from key: Key, connection: TmuxSessionConnection) {
        guard connections[key] === connection else { return }
        let onConnection = mirrors.values.filter { $0.connection === connection }
        for mirror in onConnection {
            mirror.handle(line)
        }
        if let window = Self.closedWindow(line) {
            for mirror in onConnection where mirror.windowID == window {
                closeAfterWindowEnd(mirror)
            }
        }
        trackPanes(line, from: key)
    }

    /// tmux ends a session by closing each of its windows and only then
    /// sending `%exit`, so a closed window alone does not say whether the
    /// session went with it. A command sent now is answered only if the
    /// session outlived the window: tmux reads it after everything it has
    /// announced, and a session that ended takes this client with it,
    /// which fails the command after the store has marked the mirror
    /// disconnected. That case is left to `sessionChecked`, which closes
    /// every tab of the session with one notice.
    private func closeAfterWindowEnd(_ mirror: TmuxWindowMirror) {
        mirror.connection.send("display-message -p ''") { [weak self, weak mirror] _, _ in
            guard let self, let mirror, mirrors[mirror.tabID] === mirror, mirror.connectionState == .connected else { return }
            let name = mirror.displayName
            if endTab(mirror.endedTab, route: .windowClosed) {
                onNotice?(Self.windowClosedNotice(name: name))
            }
        }
    }

    /// A closed window arrives under either name (`TmuxControlLine.windowClose`).
    private static func closedWindow(_ line: TmuxControlLine) -> String? {
        guard case let .windowClose(window, _) = line else { return nil }
        return window
    }

    // MARK: - Connection end

    /// The connection ended. Its mirrors stop sending at once; whether
    /// their tabs close depends on the session, which only the server can
    /// say. A connection no mirror uses ended because we stopped it, after
    /// its tabs had already gone, and needs nothing more.
    ///
    /// When tmux never attached, each tab decides by what it has shown
    /// (stage 11, "decided in this stage"). A tab opened for this attach
    /// shows nothing and closes (`attachFailed`): a session that was never
    /// reached cannot be reported as ended, and one that exists under
    /// another id would leave the tab disconnected with nothing ever shown
    /// in it. A tab that showed the session before goes through the session
    /// check, as it does after a connection that did attach: a refusal
    /// alone does not say the session is gone.
    private func connectionEnded(_ connection: TmuxSessionConnection) {
        let affected = mirrors.values.filter { $0.connection === connection }
        for mirror in affected {
            mirror.connectionEnded()
            tabConnections[mirror.tabID] = .disconnected
            tabIssues.removeValue(forKey: mirror.tabID)
        }
        let isRefused = !connection.hasAttached
        let neverShown = affected.filter { isRefused && $0.isNewTab }
        let checked = affected.filter { mirror in !neverShown.contains { $0 === mirror } }
        attachFailed(neverShown, connection: connection)
        guard !checked.isEmpty, let tmuxExecutable else { return }
        let target = connection.target
        Task { [weak self, sessionPresence] in
            let presence = await sessionPresence(tmuxExecutable, target.socketPath, target.sessionID)
            self?.sessionChecked(presence, of: checked, connection: connection)
        }
    }

    /// A session tmux confirms gone, or a server that is no longer there,
    /// ends every tab in `checked` that still shows it (`sessionEnded`).
    /// Anything else leaves the tabs disconnected: a session that still
    /// exists can be mirrored again, and one we could not ask about may
    /// still exist (stage 11 decision 2). Tabs closed or reconnected while
    /// the check ran are left alone.
    private func sessionChecked(_ presence: TmuxSessionPresence, of checked: [TmuxWindowMirror], connection: TmuxSessionConnection) {
        let session = connection.target.sessionID
        log.notice("session \(session, privacy: .public) after exit: \(String(describing: presence), privacy: .public)")
        let remaining = checked.filter { mirrors[$0.tabID] === $0 }
        guard presence == .gone, let first = remaining.first else { return }
        sessionEnded(remaining.map(\.endedTab), sessionName: first.sessionName)
    }

    /// A tab whose tmux session is gone, and the window session it is in.
    struct EndedTab {
        let tabID: UUID
        let session: WindowSession
    }

    /// Which news reached us about a mirror tab's tmux. Only the log reads
    /// it: every route ends in the same decision (`endTab`), and a report
    /// that a tab closed by itself is hard to place without it.
    enum EndRoute: String {
        /// tmux announced that the mirrored window closed.
        case windowClosed = "window closed"
        /// A reconnected client no longer lists the mirrored window.
        case windowMissing = "window missing on reconnect"
        /// The session is gone, whether its connection lost it or a
        /// reconnect found it so.
        case sessionGone = "session gone"
    }

    /// Every tab whose session tmux no longer has, whether a connection lost
    /// it or a reconnect found it gone, and whether the session ended or its
    /// whole server stopped. Each is dealt with by `endTab`, and the tabs
    /// that are worth telling the user about share one notice. A tab that is
    /// already gone is skipped.
    ///
    /// Nothing is asked before a tab closes here: there is nothing left on
    /// tmux's side to confirm, and nothing to reopen it onto.
    func sessionEnded(_ tabs: [EndedTab], sessionName: String) {
        var isWorthTelling = false
        for ended in tabs {
            isWorthTelling = endTab(ended, route: .sessionGone) || isWorthTelling
        }
        guard isWorthTelling else { return }
        onNotice?(Self.sessionEndedNotice(sessionName: sessionName))
    }

    /// What becomes of one mirror tab whose window or session tmux no longer
    /// has, whichever route brought the news. The one place that decides it,
    /// and the one place that acts on the decision; the caller only names the
    /// notice it would give.
    ///
    /// Returns whether the user is worth telling. A user's mirror tab reads
    /// its notice because they opened it themselves and what it showed is
    /// gone. An agent's tab says nothing either way: the agent finishing is
    /// what the user watched happen, and a tab that becomes a terminal is
    /// still there with the conversation in it.
    @discardableResult
    func endTab(_ ended: EndedTab, route: EndRoute) -> Bool {
        guard let tab = ended.session.tab(ended.tabID) else { return false }
        let outcome = outcome(ofEnded: tab)
        log.notice("""
        tab \(ended.tabID, privacy: .public) window \(self.mirrors[ended.tabID]?.windowID ?? "?", privacy: .public): \
        \(route.rawValue, privacy: .public) → \(String(describing: outcome), privacy: .public)
        """)
        switch outcome {
        case .close:
            TabActions.closeTab(ended.session, registry: registry, tabID: ended.tabID, confirm: false, isReopenable: false)
            return tab.mirrorOrigin == .user
        case .becomeTerminal:
            becomeTerminalTab(tab, session: ended.session)
            return false
        }
    }

    /// What becomes of one tab whose session tmux no longer has.
    enum EndedTabOutcome: Equatable {
        /// Closed without asking, and not kept for reopening.
        case close
        /// Kept as an ordinary terminal tab, on the same leaf.
        case becomeTerminal
    }

    /// Decided by who opened the tab, and for an agent's tab by whether its
    /// leaf has a conversation left to resume (design §6 decision 2).
    ///
    /// A killed server or session takes the tmux away from a run that is
    /// still going: the record says so, nothing having run to write
    /// otherwise, and the conversation is still worth having — the tab
    /// becomes a terminal and resumes it (decision 3). An agent that ended its
    /// own session, or exited before it started one (Claude Code's folder
    /// trust prompt, declined, runs no hook at all), leaves nothing to
    /// resume, and its tab closes as quietly as its agent did. A user's
    /// mirror tab closes either way, as it always has. A store with nobody
    /// to ask keeps an agent's tab, the outcome that loses nothing.
    func outcome(ofEnded tab: Tab) -> EndedTabOutcome {
        guard tab.mirrorOrigin == .agent else { return .close }
        guard let agentRuns else { return .becomeTerminal }
        // One agent, one session, one window, one leaf: the tab's only leaf
        // is the pane the agent's records name.
        guard let leaf = tab.splitTree.allLeafIDs().first,
              agentRuns.hasResumableConversation(inPane: leaf)
        else { return .close }
        return .becomeTerminal
    }

    /// Turn an agent's tab into an ordinary terminal tab on the same leaves.
    ///
    /// The leaf keeps its id, which is what the agent's records name, so the
    /// conversation's resume hint still belongs to it and the shell that
    /// starts there resumes the conversation (`AgentResumeCommandBuilder`).
    /// Two things have to happen before the tab is written, because the write
    /// is what builds the surface: the endpoint is reported gone, so the
    /// rules stop holding the conversation back from resume, and the leaves'
    /// surfaces are let go, because a surface reading a mirror channel never
    /// starts a process of its own. The leaves are also marked as back from
    /// tmux, so the shells built for them run the resume in this tab rather
    /// than handing it to tmux and a new one (`leavesBackFromTmux`).
    ///
    /// The user is told, unlike the close above. What they see here is the
    /// conversation they were reading replaced, in an instant and with no
    /// input of theirs, by a shell starting a resume — so the notice is what
    /// says the tmux went away rather than that something in the tab broke.
    private func becomeTerminalTab(_ tab: Tab, session: WindowSession) {
        for endpoint in tab.mirroredEndpoints(aliases: [:]).keys {
            agentRuns?.reportGone(endpoint)
        }
        let mirror = mirrors.removeValue(forKey: tab.id)
        mirror?.stop()
        tabConnections.removeValue(forKey: tab.id)
        tabIssues.removeValue(forKey: tab.id)
        for leafID in tab.splitTree.allLeafIDs() {
            registry.unregister(leafID)
            leavesBackFromTmux.insert(leafID)
        }
        session.update(tab.id) { t in
            t.kind = .terminal
            t.paneSources = [:]
            t.mirrorOrigin = .user
            t.mirroredAgent = nil
        }
        // The connection may still serve other tabs, and this tab's window
        // is no longer shown by any of them.
        if let mirror {
            gateOutput(for: Self.key(of: mirror))
        }
        onNotice?(Self.agentServerGoneNotice(name: Self.agentName(of: tab)))
        log.notice("agent tab \(tab.id, privacy: .public) became a terminal: its tmux is gone")
    }

    /// The tabs waiting on a connection tmux refused close, with one
    /// notice: they never showed anything, so a reconnect would have no
    /// screen to keep for them. They are not kept for reopening, which
    /// would only repeat the refusal. tmux states its reason in the attach
    /// block's `%error`; a client that could not reach the server at all
    /// ends without one.
    private func attachFailed(_ affected: [TmuxWindowMirror], connection: TmuxSessionConnection) {
        guard let first = affected.first else { return }
        var reason: String?
        if case let .exited(exitReason) = connection.state {
            reason = exitReason
        }
        log.notice("attach failed session=\(connection.target.sessionID, privacy: .public)")
        // Named while the tab is still there: an agent's tab is called after
        // its agent, and a closed tab has nothing left to read that from.
        let name = Self.noticeName(of: first.endedTab.session.tab(first.tabID), tmuxName: first.displayName)
        for mirror in affected {
            mirror.closeTab()
        }
        onNotice?(Self.openFailureNotice(name: name, reason: reason))
    }

    /// What the user reads when the tmux behind an agent's tab is gone and
    /// the tab becomes a terminal that resumes it.
    static func agentServerGoneNotice(name: String) -> String {
        String(localized: "The tmux server for “\(name)” is gone. Resuming the agent here.")
    }

    /// What to call an agent's tab in a notice: the provider the tab was
    /// opened for, which is what the tab is named after and what the user
    /// typed, and the tab's own title when this build does not know the
    /// provider.
    static func agentName(of tab: Tab) -> String {
        tab.mirroredAgent.map(AgentProviderRegistry.displayName(for:)) ?? tab.displayTitle
    }

    /// What to call a mirror tab wherever the user reads about it.
    ///
    /// A user's mirror tab is called `session:window`, the name the palette
    /// listed it under and the one they picked it by. An agent's tab is
    /// called after its agent: its session is one Limpid named
    /// (`limpid-<launch>-<leaf>`), an internal id the user never typed and
    /// could not act on, and the agent is what they started.
    ///
    /// `tmuxName` is what tmux calls it, used when the tab is a user's or is
    /// no longer in the session at all.
    static func noticeName(of tab: Tab?, tmuxName: String) -> String {
        guard let tab, tab.mirrorOrigin == .agent else { return tmuxName }
        return agentName(of: tab)
    }

    /// What the user reads when a mirror tab could not be opened. `name`
    /// is `session:window`; `reason` is tmux's own words, left untranslated.
    static func openFailureNotice(name: String, reason: String?) -> String {
        guard let reason, !reason.isEmpty else {
            return String(localized: "Couldn't open “\(name)”")
        }
        return String(localized: "Couldn't open “\(name)”: \(reason)")
    }

    // MARK: - Output gate

    /// Keep the gate's picture of the session current. `%layout-change`
    /// lists every pane of its window, so a pane created or killed anywhere
    /// in the session shows up here; a new window is asked for its panes
    /// because its first layout may have arrived before it was announced.
    /// Forgetting a window the gate never knew changes nothing.
    private func trackPanes(_ line: TmuxControlLine, from key: Key) {
        if let window = Self.closedWindow(line) {
            outputGates[key]?.removeWindow(window)
            gateOutput(for: key)
            return
        }
        switch line {
        case let .layoutChange(window, layout, _, _):
            guard let parsed = TmuxLayout.parse(layout) else { return }
            outputGates[key]?.setPanes(Set(parsed.root.paneIDs), ofWindow: window)
        case let .windowAdd(window):
            guard let connection = connections[key] else { return }
            connection.send("list-panes -t \(TmuxProtocol.quote(window)) -F '#{pane_id}'") { [weak self] lines, isError in
                guard let self, !isError, self.connections[key] === connection else { return }
                self.outputGates[key]?.setPanes(Set(lines), ofWindow: window)
                self.gateOutput(for: key)
            }
            return
        default:
            return
        }
        gateOutput(for: key)
    }

    /// Pause every pane no mirror on this connection shows, and resume the
    /// ones a mirror now shows. Only the difference is sent.
    private func gateOutput(for key: Key) {
        guard let connection = connections[key], outputGates[key] != nil else { return }
        let shown = Set(mirrors.values.filter { $0.connection === connection }.map(\.windowID))
        for command in outputGates[key]?.reconcile(shownWindows: shown) ?? [] {
            connection.send(command)
            log.debug("output gate session=\(key.sessionID, privacy: .public): \(command, privacy: .public)")
        }
    }
}

enum TmuxStoreError: Error, Equatable {
    case tmuxNotInstalled
}
