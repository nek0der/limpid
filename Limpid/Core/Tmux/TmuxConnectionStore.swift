// TmuxConnectionStore.swift
// Limpid — the control-mode connections the app holds, one per tmux session, and the tabs mirroring through them.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.store")

/// Owns every `TmuxServerConnection` and every `TmuxWindowMirror`. A
/// connection stays open exactly as long as some tab mirrors through it:
/// liveness is derived from the tabs on each `reconcile`, never counted by
/// hand, because counts leak.
///
/// Keyed by session rather than by server. A control client attaches to
/// one session and receives that session's windows; mirroring a second
/// session on the same server is a second client. The design speaks of
/// "one per server", which holds for the first version's scope of one
/// window per tab.
@MainActor
final class TmuxConnectionStore {
    struct Key: Hashable {
        let socketPath: String
        let sessionID: String
    }

    /// Absolute path of the tmux executable, or `nil` when none is
    /// installed where a GUI app can see it.
    let tmuxExecutable: String?

    private(set) var connections: [Key: TmuxServerConnection] = [:]
    private(set) var mirrors: [UUID: TmuxWindowMirror] = [:]
    /// Which panes of each connection have their output paused. A control
    /// client is fed every pane of the session; the ones no tab shows are
    /// switched off so a build in a hidden window cannot fill the pipe
    /// (design §8 D12).
    private(set) var outputGates: [Key: TmuxOutputGate] = [:]
    /// The stream each `.tmux` or `.unavailable` leaf's surface reads, with
    /// or without a mirror feeding it: a restored tab before adoption, a
    /// tab whose server went away, and a live mirror's pane all read their
    /// leaf's channel, so a surface never has to be recreated to be fed by
    /// a later connection. A leaf without a feeding mirror shows nothing
    /// instead of spawning a shell. Released on `reconcile` once the leaf
    /// is gone; a surface or a sink still holding one keeps it open.
    private var channels: [UUID: TmuxPaneChannel] = [:]
    /// The colors every connection reports to its panes: those of the last
    /// config libghostty resolved, which is where a light or dark switch
    /// shows up. The first arrives while libghostty starts.
    private(set) var terminalColors: TerminalColors?
    /// What the user is told when tmux ends a mirrored window or session.
    /// Set by whoever owns the toast center.
    var onNotice: ((String) -> Void)?

    typealias SessionPresenceCheck = @Sendable (
        _ tmuxPath: String,
        _ socketPath: String,
        _ sessionID: String
    ) async -> TmuxSessionPresence
    private let sessionPresence: SessionPresenceCheck

    init(
        tmuxExecutable: String? = TmuxClientProbe.locateTmux(),
        sessionPresence: @escaping SessionPresenceCheck = TmuxSessionProbe.check
    ) {
        self.tmuxExecutable = tmuxExecutable
        self.sessionPresence = sessionPresence
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

    /// The connection for `binding`'s session, started on first use.
    ///
    /// A connection tmux has ended is replaced rather than handed out: the
    /// palette lists what `list-windows` reaches now, which may be a new
    /// server on the same socket, and a new tab must not inherit a client
    /// that will never deliver. The ended one is only forgotten, not
    /// stopped. The mirrors of tabs that lost it still hold it and its
    /// sinks, and they release them when their tabs close.
    func connection(for binding: TmuxBinding) throws -> TmuxServerConnection {
        let key = Key(socketPath: binding.socketPath, sessionID: binding.sessionID)
        if let existing = connections[key] {
            guard case .exited = existing.state else { return existing }
            connections.removeValue(forKey: key)
            outputGates.removeValue(forKey: key)
            log.notice("replacing ended connection session=\(key.sessionID, privacy: .public)")
        }
        guard let tmuxExecutable else { throw TmuxStoreError.tmuxNotInstalled }
        let connection = TmuxServerConnection(
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
    /// its panes out from it.
    func cellSizeChanged(_ size: CellSize, paneID: UUID) {
        guard let mirror = mirrors.values.first(where: { $0.shows(paneID: paneID) }) else { return }
        mirror.cellSizeChanged(size, from: paneID)
    }

    /// A mirror surface's terminal took a new grid; the mirror showing that
    /// pane repaints it from tmux once the grid is the one tmux gave it.
    func mirrorGridResized(columns: Int, rows: Int, paneID: UUID) {
        guard let mirror = mirrors.values.first(where: { $0.shows(paneID: paneID) }) else { return }
        mirror.surfaceGridChanged(columns: columns, rows: rows, paneID: paneID)
    }

    /// A key typed into a mirror pane. A pane with no live mirror (dormant,
    /// or its connection gone) has nowhere to send it.
    func sendKey(_ event: TmuxKeyEvent, paneID: UUID) {
        sendInput(TmuxKeyTranslator.inputs(for: event), paneID: paneID)
    }

    /// Text a binding or the surface's text entry point sent to a mirror pane.
    func sendText(_ bytes: [UInt8], paneID: UUID) {
        sendInput(TmuxKeyTranslator.inputs(forText: bytes), paneID: paneID)
    }

    private func sendInput(_ inputs: [TmuxInput], paneID: UUID) {
        guard !inputs.isEmpty, let mirror = mirrors.values.first(where: { $0.shows(paneID: paneID) }) else { return }
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
        let key = Key(socketPath: binding.socketPath, sessionID: binding.sessionID)
        return mirrors.values.first {
            $0.connectionState == .connected && Self.key(of: $0) == key && $0.windowID == windowID
        }
    }

    /// The control clients this app started, as tmux lists them. A mirror
    /// about to attach leaves these alone: they are this app's own.
    var ownControlPIDs: Set<pid_t> {
        Set(connections.values.compactMap(\.clientPID))
    }

    func register(_ mirror: TmuxWindowMirror) {
        mirrors[mirror.tabID] = mirror
        gateOutput(for: Self.key(of: mirror))
    }

    /// Drop mirrors whose tab is gone, then connections no mirror uses,
    /// and hand every remaining mirror its tab. Called whenever the tab
    /// list changes; idempotent.
    func reconcile(tabs: [Tab]) {
        let liveTabs = Set(tabs.map(\.id))
        var touchedKeys: Set<Key> = []
        for (tabID, mirror) in mirrors where !liveTabs.contains(tabID) {
            mirror.stop()
            mirrors.removeValue(forKey: tabID)
            touchedKeys.insert(Self.key(of: mirror))
        }
        // By identity, not by key: a tab that lost its connection keeps a
        // mirror under the same key as the connection that replaced it.
        let usedKeys = Set(connections.compactMap { key, connection in
            mirrors.values.contains { $0.connection === connection } ? key : nil
        })
        for (key, connection) in connections where !usedKeys.contains(key) {
            connection.stop()
            connections.removeValue(forKey: key)
            outputGates.removeValue(forKey: key)
            log.notice("closed idle connection session=\(key.sessionID, privacy: .public)")
        }
        for key in touchedKeys where usedKeys.contains(key) {
            gateOutput(for: key)
        }
        // A focus move reaches a mirror only here: the focus lives in the
        // tab, and every write to it passes through this call.
        for tab in tabs {
            mirrors[tab.id]?.tabChanged(tab)
        }
        let channelLeaves = Set(tabs.flatMap { tab in
            tab.splitTree.allLeafIDs().filter { tab.ioSource(for: $0) != .local }
        })
        for paneID in channels.keys where !channelLeaves.contains(paneID) {
            channels.removeValue(forKey: paneID)
        }
    }

    /// Termination: detach every client so tmux does not keep serving a
    /// process that is about to die.
    func stopAll() {
        for mirror in mirrors.values {
            mirror.stop()
        }
        mirrors.removeAll()
        for connection in connections.values {
            connection.stop()
        }
        connections.removeAll()
        outputGates.removeAll()
        channels.removeAll()
    }

    private static func key(of mirror: TmuxWindowMirror) -> Key {
        Key(socketPath: mirror.connection.target.socketPath, sessionID: mirror.connection.target.sessionID)
    }

    /// Mirrors are matched by connection, not by key, so a tab that lost
    /// its connection never reacts to the server that replaced it; a new
    /// server numbers its windows from `@0` again.
    private func dispatch(_ line: TmuxControlLine, from key: Key, connection: TmuxServerConnection) {
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
            mirror.closeTab()
            let name = "\(mirror.sessionName):\(mirror.windowName)"
            onNotice?(String(localized: "The tmux window “\(name)” was closed"))
        }
    }

    /// A closed window arrives under either name. tmux 3.7c decides between
    /// them after the window has left the session, so killing one of the
    /// session's own windows, or exiting its last pane, is announced as
    /// `%unlinked-window-close`.
    private static func closedWindow(_ line: TmuxControlLine) -> String? {
        guard case let .notification(name, window) = line,
              name == "window-close" || name == "unlinked-window-close"
        else { return nil }
        return window
    }

    // MARK: - Connection end

    /// The connection ended. Its mirrors stop sending at once; whether
    /// their tabs close depends on the session, which only the server can
    /// say. A connection no mirror uses ended because we stopped it, after
    /// its tabs had already gone, and needs nothing more.
    ///
    /// A connection tmux never attached did not lose a session, so it
    /// skips the session check: a session that was never reached cannot
    /// be reported as ended, and one that exists under another id would
    /// leave the tabs disconnected with nothing ever shown in them.
    private func connectionEnded(_ connection: TmuxServerConnection) {
        let affected = mirrors.values.filter { $0.connection === connection }
        for mirror in affected {
            mirror.connectionEnded()
        }
        guard !affected.isEmpty else { return }
        guard connection.hasAttached else {
            attachFailed(affected, connection: connection)
            return
        }
        guard let tmuxExecutable else { return }
        let target = connection.target
        Task { [weak self, sessionPresence] in
            let presence = await sessionPresence(tmuxExecutable, target.socketPath, target.sessionID)
            self?.sessionChecked(presence, connection: connection)
        }
    }

    /// A session tmux confirms gone closes every tab that mirrored it, with
    /// one notice. Anything else leaves the tabs disconnected: a session
    /// that still exists can be mirrored again, and one we could not ask
    /// about may still exist (stage 11 decision 2). Tabs closed while the
    /// check ran are no longer among the mirrors.
    private func sessionChecked(_ presence: TmuxSessionPresence, connection: TmuxServerConnection) {
        let affected = mirrors.values.filter { $0.connection === connection }
        let session = connection.target.sessionID
        log.notice("session \(session, privacy: .public) after exit: \(String(describing: presence), privacy: .public)")
        guard presence == .gone, let first = affected.first else { return }
        for mirror in affected {
            mirror.closeTab()
        }
        onNotice?(String(localized: "The tmux session “\(first.sessionName)” ended"))
    }

    /// The tabs waiting on a connection tmux refused close, with one
    /// notice: they never showed anything, and a mirror has no reconnect
    /// that could fill them later. They are not kept for reopening, which
    /// would only repeat the refusal. tmux states its reason in the attach
    /// block's `%error`; a client that could not reach the server at all
    /// ends without one.
    private func attachFailed(_ affected: [TmuxWindowMirror], connection: TmuxServerConnection) {
        guard let first = affected.first else { return }
        var reason: String?
        if case let .exited(exitReason) = connection.state {
            reason = exitReason
        }
        log.notice("attach failed session=\(connection.target.sessionID, privacy: .public)")
        for mirror in affected {
            mirror.closeTab()
        }
        onNotice?(Self.openFailureNotice(name: "\(first.sessionName):\(first.windowName)", reason: reason))
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
        case let .notification(name, arguments) where name == "window-add":
            let window = arguments
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
