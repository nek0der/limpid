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
    func connection(for binding: TmuxBinding) throws -> TmuxServerConnection {
        let key = Key(socketPath: binding.socketPath, sessionID: binding.sessionID)
        if let existing = connections[key] {
            return existing
        }
        guard let tmuxExecutable else { throw TmuxStoreError.tmuxNotInstalled }
        let connection = TmuxServerConnection(
            executable: tmuxExecutable,
            target: .init(socketPath: binding.socketPath, sessionID: binding.sessionID)
        )
        connection.onNotification = { [weak self] line in
            self?.dispatch(line, from: key)
        }
        try connection.start()
        connections[key] = connection
        return connection
    }

    func mirror(for tabID: UUID) -> TmuxWindowMirror? {
        mirrors[tabID]
    }

    /// The sink feeding `paneID` of `tabID`, if that tab mirrors and the
    /// pane is attached. `PaneHostView` hands its descriptor to the surface.
    func sink(tabID: UUID, paneID: UUID) -> TmuxPaneSink? {
        mirrors[tabID]?.sink(for: paneID)
    }

    func register(_ mirror: TmuxWindowMirror) {
        mirrors[mirror.tabID] = mirror
    }

    /// Drop mirrors whose tab is gone, then connections no mirror uses.
    /// Called whenever the tab list changes; idempotent.
    func reconcile(tabs: [Tab]) {
        let liveTabs = Set(tabs.map(\.id))
        for (tabID, mirror) in mirrors where !liveTabs.contains(tabID) {
            mirror.stop()
            mirrors.removeValue(forKey: tabID)
        }
        let usedKeys = Set(mirrors.values
            .map { Key(socketPath: $0.connection.target.socketPath, sessionID: $0.connection.target.sessionID) })
        for (key, connection) in connections where !usedKeys.contains(key) {
            connection.stop()
            connections.removeValue(forKey: key)
            log.notice("closed idle connection session=\(key.sessionID, privacy: .public)")
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
        for sink in dormantSinks.values {
            sink.close()
        }
        dormantSinks.removeAll()
    }

    private func dispatch(_ line: TmuxControlLine, from key: Key) {
        for mirror in mirrors.values
            where mirror.connection.target.socketPath == key.socketPath
            && mirror.connection.target.sessionID == key.sessionID
        {
            mirror.handle(line)
        }
    }
}

enum TmuxStoreError: Error, Equatable {
    case tmuxNotInstalled
}
