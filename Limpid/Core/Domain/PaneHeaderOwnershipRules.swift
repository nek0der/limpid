// PaneHeaderOwnershipRules.swift
// Limpid — which visible invocation supplies a pane header's agent settings.

import Foundation

/// We select owners from facts rather than display stores so invocation
/// ordering and parent fallback do not depend on a window or actor.
enum PaneHeaderOwnershipRules {
    struct Endpoint: Hashable, Sendable {
        let socketPath: String
        let serverPID: String
        let serverStartedAt: String
        let paneID: String
    }

    struct Run: Equatable, Sendable {
        /// The provider-qualified identity returned to the caller.
        let id: String
        /// Parent references use the invocation ID, not the display identity.
        let runID: String
        /// Absent for a root invocation or a record without parent evidence.
        var parentRunID: String?
        /// Absent for a terminal outside tmux, where boot-scoped order is not used.
        var endpoint: Endpoint?
        var isKnown = true
        var isVisible = true
        var isActive = true
        var runsWithoutAsking = false
        let updatedAt: Date
        /// Older records may lack a session start and use the update date instead.
        var sessionStartedAt: Date?
        /// Older invocations may lack a monotonic launch stamp.
        var launchOrder: UInt64?
        /// Absent until an own-settings report has a monotonic observation.
        var observedOrder: UInt64?
    }

    struct Selection: Equatable, Sendable {
        /// Nil when no known visible owner can supply settings.
        let ownerID: String?
        let isAmbiguous: Bool
    }

    /// We first resolve successive roots and nested activity at each
    /// endpoint. Only then do visible splits compete for the shared header,
    /// retaining a warning even when another split has input focus.
    static func select(from runs: [Run]) -> Selection {
        let groups = Dictionary(grouping: runs, by: \.endpoint)
        var owners: [Run] = []
        var isAmbiguous = false
        for (endpoint, group) in groups {
            let selected = endpoint == nil
                ? newestRun(group, comparesLaunchOrder: false)
                : tmuxOwner(group)
            if let owner = selected.runtime {
                owners.append(owner)
            }
            if selected.isAmbiguous {
                isAmbiguous = isAmbiguous || (group.first?.isVisible ?? true)
            }
        }
        let owner = owners.filter { $0.isKnown && $0.isVisible }.max { left, right in
            if left.runsWithoutAsking != right.runsWithoutAsking {
                return !left.runsWithoutAsking
            }
            if left.isActive != right.isActive {
                return !left.isActive
            }
            return left.updatedAt < right.updatedAt
        }
        return Selection(ownerID: owner?.id, isAmbiguous: isAmbiguous)
    }

    private static func tmuxOwner(_ group: [Run]) -> (runtime: Run?, isAmbiguous: Bool) {
        let byID = Dictionary(grouping: group, by: \.runID)
        guard byID.values.allSatisfy({ $0.count == 1 }) else { return (nil, true) }
        let runs = byID.compactMapValues(\.first)
        var families: [String: [Run]] = [:]
        for run in group {
            guard let root = rootInvocation(of: run, among: runs) else { return (nil, true) }
            families[root.runID, default: []].append(run)
        }
        let roots = families.keys.compactMap { runs[$0] }
        let selected = newestRun(roots, comparesLaunchOrder: true)
        guard !selected.isAmbiguous, let root = selected.runtime else { return selected }
        let family = families[root.runID] ?? [root]
        let active = newestActivity(family)
        guard !active.isAmbiguous, var owner = active.runtime else { return active }
        // A child whose run has ended can still have the latest report. Its explicit
        // parent relationship identifies where control returns; an unrelated
        // older root is never used as the fallback.
        while !owner.isKnown,
              let parentID = owner.parentRunID,
              let parent = runs[parentID]
        {
            owner = parent
        }
        return (owner, false)
    }

    private static func rootInvocation(
        of run: Run,
        among runs: [String: Run]
    ) -> Run? {
        var current = run
        var visited: Set<String> = []
        while visited.insert(current.runID).inserted {
            guard let parentID = current.parentRunID, let parent = runs[parentID] else { return current }
            current = parent
        }
        return nil
    }

    private static func newestRun(
        _ candidates: [Run],
        comparesLaunchOrder: Bool
    ) -> (runtime: Run?, isAmbiguous: Bool) {
        var latest: Run?
        var isAmbiguous = false
        for run in candidates {
            guard let current = latest else {
                latest = run
                continue
            }
            let comparison: ComparisonResult
            if comparesLaunchOrder, run.launchOrder != nil || current.launchOrder != nil {
                comparison = compareOrder(run.launchOrder, current.launchOrder)
            } else {
                let start = run.sessionStartedAt ?? run.updatedAt
                let currentStart = current.sessionStartedAt ?? current.updatedAt
                comparison = start == currentStart ? run.updatedAt.compare(current.updatedAt) : start.compare(currentStart)
            }
            if comparison == .orderedDescending {
                latest = run
                isAmbiguous = false
            }
            if comparison == .orderedSame, run.id != current.id {
                isAmbiguous = true
            }
        }
        return (latest, isAmbiguous)
    }

    private static func newestActivity(
        _ candidates: [Run]
    ) -> (runtime: Run?, isAmbiguous: Bool) {
        var latest: Run?
        var isAmbiguous = false
        for run in candidates {
            guard let current = latest else {
                latest = run
                continue
            }
            let order = run.observedOrder ?? run.launchOrder
            let currentOrder = current.observedOrder ?? current.launchOrder
            let comparison = order != nil || currentOrder != nil
                ? compareOrder(order, currentOrder)
                : run.updatedAt.compare(current.updatedAt)
            if comparison == .orderedDescending {
                latest = run
                isAmbiguous = false
            }
            if comparison == .orderedSame, run.id != current.id {
                isAmbiguous = true
            }
        }
        return (latest, isAmbiguous)
    }

    private static func compareOrder(_ order: UInt64?, _ other: UInt64?) -> ComparisonResult {
        switch (order, other) {
        case let (.some(left), .some(right)):
            left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case (.some, .none): .orderedDescending
        case (.none, .some): .orderedAscending
        case (.none, .none): .orderedSame
        }
    }

}
