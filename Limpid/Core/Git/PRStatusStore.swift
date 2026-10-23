// PRStatusStore.swift
// Limpid — observable map of `ContainerID` → linked pull request.
//
// Lives parallel to `Worktree` rather than as a field on it so the
// session model stays unaware of external forge state. The sidebar
// and the session header read `info(for:)` during render; the syncer
// (`PRStatusSyncer`) writes via `update`. All access is @MainActor:
// the store performs no IO and schedules nothing, so there is nothing
// here to take off the main actor. Same posture as
// `NotificationHistoryStore`, minus the disk flush (PR state is reconstructible on relaunch within seconds, so we
// don't persist it).

import Foundation
import Observation

@MainActor
@Observable
final class PRStatusStore {
    /// Keyed by `ContainerID` rather than a worktree id because a
    /// Project row stands for its own main checkout, which has a
    /// branch and a request just like any worktree does.
    ///
    /// Absent entry means either "we haven't fetched yet" or "this
    /// container has no linked request". Both render the same way (no
    /// mark); what tells them apart, where an action depends on it, is
    /// `forges`, which holds an entry only once a lookup was answered.
    private(set) var perContainer: [ContainerID: PRInfo] = [:]
    /// The forge each container's remote is on, kept only when its CLI is
    /// installed: what "Create PR" needs before any request exists.
    /// Absent for no remote, an unsupported host, or no CLI.
    private(set) var forges: [ContainerID: ForgeKind] = [:]

    init() {}

    // MARK: - Mutations

    /// `update(container:info:)` with the forge the lookup found, written
    /// as idempotently.
    func update(container: ContainerID, info: PRInfo?, forge: ForgeKind?) {
        update(container: container, info: info)
        if forges[container] != forge {
            forges[container] = forge
        }
    }

    /// Idempotent write: only mutate when the new value actually
    /// differs from the stored one. Avoids Observation churn when
    /// the recurring sync tick returns the same value, which is
    /// the common case (a request rarely changes between two ticks).
    func update(container: ContainerID, info: PRInfo?) {
        if let info {
            if perContainer[container] != info {
                perContainer[container] = info
            }
        } else if perContainer[container] != nil {
            perContainer.removeValue(forKey: container)
        }
    }

    /// Forget every container outside `live`. The syncer calls this
    /// with the rows it is willing to fetch for, so hiding a worktree,
    /// closing a project, or a worktree going missing on disk drops
    /// its entry instead of stranding one nothing will ever update
    /// again. Beyond the unbounded growth,
    /// a stranded entry is read: `PRStatusSyncer.currentInterval` scans
    /// every value, so one hidden row whose last known state had checks
    /// running would hold the whole syncer at the active cadence for
    /// the rest of the session.
    func prune(keeping live: Set<ContainerID>) {
        let stale = Set(perContainer.keys).union(forges.keys).filter { !live.contains($0) }
        guard !stale.isEmpty else { return }
        for container in stale {
            perContainer.removeValue(forKey: container)
            forges.removeValue(forKey: container)
        }
    }

    // MARK: - Reads

    func info(for container: ContainerID) -> PRInfo? {
        perContainer[container]
    }

    func forge(for container: ContainerID) -> ForgeKind? {
        forges[container]
    }
}
