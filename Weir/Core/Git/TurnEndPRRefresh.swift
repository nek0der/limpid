// TurnEndPRRefresh.swift
// Weir — looks a row's pull request up when an agent's turn ends there.

import Foundation

/// A turn is often what opened or merged a row's request, and with the app in
/// front nothing else would ask until the recurring lookup comes round. Same
/// observe-and-push shape as `NotificationReadSync`.
@MainActor
final class TurnEndPRRefresh {
    private let attention: AttentionState
    private let session: WorkspaceSession
    private let refresh: @MainActor (ContainerID) -> Void
    /// The runs in a turn at the last pass, with the rows they were in, a
    /// run waiting on an answer among them, as its turn has not ended: a
    /// run that quit is gone from the attention list, its rows with it.
    private var running: [String: Set<ContainerID>] = [:]

    init(attention: AttentionState, session: WorkspaceSession, refresh: @escaping @MainActor (ContainerID) -> Void) {
        self.attention = attention
        self.session = session
        self.refresh = refresh
        // Runs already in a turn at launch end later like any other.
        running = runningNow()
        observeRepeatedly { [attention] in
            _ = attention.runtimesByKind
        } onChange: { [weak self] in
            self?.reconcile()
        }
    }

    func reconcile() {
        let now = runningNow()
        let ended = running.filter { now[$0.key] == nil }.values.reduce(into: Set<ContainerID>()) { $0.formUnion($1) }
        running = now
        ended.forEach(refresh)
    }

    private func runningNow() -> [String: Set<ContainerID>] {
        var result: [String: Set<ContainerID>] = [:]
        for runtime in attention.allRuntimes where runtime.badge.state.isMidTurn {
            result[runtime.id, default: []].formUnion(runtime.paneIDs.compactMap { session.tab(containing: $0)?.container })
        }
        return result
    }
}
