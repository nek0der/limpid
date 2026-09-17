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
    /// Panes that mirror on paper but have no connection behind them: a
    /// restored tab before adoption, or a tab whose server went away.
    /// Each holds a descriptor that never delivers, so the surface shows
    /// nothing instead of spawning a shell. Released on `reconcile`.
    private var dormantSinks: [UUID: TmuxPaneSink] = [:]
    private let dormantQueue = DispatchQueue(label: "dev.limpid.tmux.dormant")

    init(tmuxExecutable: String? = TmuxClientProbe.locateTmux()) {
        self.tmuxExecutable = tmuxExecutable
    }

    /// The windows the palette can offer right now. Synchronous: one
    /// `list-windows` per socket, each bounded by `TmuxCommand`'s timeout.
    func availableTargets() -> [TmuxMirrorTarget] {
        guard let tmuxExecutable else { return [] }
        return TmuxMirrorTargetLister.targets(tmuxPath: tmuxExecutable)
    }

    func dormantSink(paneID: UUID) -> TmuxPaneSink? {
        if let existing = dormantSinks[paneID] {
            return existing
        }
        do {
            let sink = try TmuxPaneSink(queue: dormantQueue, onSurfaceOutput: { _ in }, onOverflow: {})
            dormantSinks[paneID] = sink
            return sink
        } catch {
            log.error("dormant sink failed: \(String(describing: error), privacy: .public)")
            return nil
        }
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

    func mirror(for tabID: UUID) -> TmuxWindowMirror? {
        mirrors[tabID]
    }

    /// The sink feeding `paneID` of `tabID`, if that tab mirrors and the
    /// pane is attached. `PaneHostView` hands its descriptor to the surface.
    func sink(tabID: UUID, paneID: UUID) -> TmuxPaneSink? {
        mirrors[tabID]?.sink(for: paneID)
    }

    /// The mirror already showing `windowID` of `binding`'s session over a
    /// connection that still delivers. A tmux pane feeds exactly one sink,
    /// so a second tab on the same window is never opened (design §4).
    func liveMirror(showing windowID: String, of binding: TmuxBinding) -> TmuxWindowMirror? {
        let key = Key(socketPath: binding.socketPath, sessionID: binding.sessionID)
        guard let connection = connections[key] else { return nil }
        if case .exited = connection.state {
            return nil
        }
        return mirrors.values.first { $0.connection === connection && $0.windowID == windowID }
    }

    func register(_ mirror: TmuxWindowMirror) {
        mirrors[mirror.tabID] = mirror
        gateOutput(for: Self.key(of: mirror))
    }

    /// Drop mirrors whose tab is gone, then connections no mirror uses.
    /// Called whenever the tab list changes; idempotent.
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
        let livePanes = Set(tabs.flatMap { $0.splitTree.allLeafIDs() })
        for (paneID, sink) in dormantSinks where !livePanes.contains(paneID) {
            sink.close()
            dormantSinks.removeValue(forKey: paneID)
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
        for sink in dormantSinks.values {
            sink.close()
        }
        dormantSinks.removeAll()
    }

    private static func key(of mirror: TmuxWindowMirror) -> Key {
        Key(socketPath: mirror.connection.target.socketPath, sessionID: mirror.connection.target.sessionID)
    }

    /// Mirrors are matched by connection, not by key, so a tab that lost
    /// its connection never reacts to the server that replaced it; a new
    /// server numbers its windows from `@0` again.
    private func dispatch(_ line: TmuxControlLine, from key: Key, connection: TmuxServerConnection) {
        guard connections[key] === connection else { return }
        for mirror in mirrors.values where mirror.connection === connection {
            mirror.handle(line)
        }
        trackPanes(line, from: key)
    }

    // MARK: - Output gate

    /// Keep the gate's picture of the session current. `%layout-change`
    /// lists every pane of its window, so a pane created or killed anywhere
    /// in the session shows up here; a new window is asked for its panes
    /// because its first layout may have arrived before it was announced.
    ///
    /// A closed window arrives under either name. tmux 3.7c decides between
    /// them after the window has left the session, so killing one of the
    /// session's own windows is announced as `%unlinked-window-close`.
    /// Forgetting a window the gate never knew changes nothing.
    private func trackPanes(_ line: TmuxControlLine, from key: Key) {
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
        case let .notification(name, arguments) where name == "window-close" || name == "unlinked-window-close":
            outputGates[key]?.removeWindow(arguments)
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
