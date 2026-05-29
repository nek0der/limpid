// ConflictDetector.swift
// Limpid — the single cross-worktree overseer (spec §5). Each watcher
// owns one worktree's changes; the detector is the only thing that sees
// them all at once, which is the whole point of the feature: a CLI
// living inside one worktree structurally cannot.
//
// L1 (checklist §10-4): intersect change sets, aggregate overlaps into
// pair-level Conflicts, dedup by `ConflictID`, preserve a user's
// "ignore". Plus (§10-5) the staleness filter that drops old edits and
// the grace period that stops the ⚠️ from flickering. L2 (merge-tree
// line-level confirmation) is a later step.
//
// `@Observable` (not `ObservableObject`) to match the codebase idiom —
// `WindowSession` and the spec's own §12.4 `ActivityTracker` both use it.

import Foundation
import Observation

struct DetectorConfig {
    /// Changes older than this are dropped from L1 (step 5).
    var stalenessWindow: TimeInterval = 600
    /// Escalate L1 potentials to L2 line-level checks. Pre-alpha: off.
    var escalateToL2: Bool = false
    var minPartiesForConflict: Int = 2
    /// Grace before a vanished conflict is resolved for good (step 5).
    var gracePeriod: TimeInterval = 12
    /// Bar-summary file-name threshold before collapsing to a count
    /// (step 6, UI).
    var barFileCountThreshold: Int = 1
}

@MainActor
@Observable
final class ConflictDetector {
    private(set) var conflicts: [Conflict] = []

    private let config: DetectorConfig
    private let now: @MainActor () -> Date
    /// Supplies the current per-worktree snapshots. The registry wires
    /// this to its live watchers in a later step; tests inject a stub.
    private let snapshotProvider: @Sendable () async -> [WorktreeSnapshot]

    init(
        config: DetectorConfig = DetectorConfig(),
        now: @escaping @MainActor () -> Date = Date.init,
        snapshotProvider: @escaping @Sendable () async -> [WorktreeSnapshot]
    ) {
        self.config = config
        self.now = now
        self.snapshotProvider = snapshotProvider
    }

    /// Re-derive the conflict set from the latest worktree snapshots.
    func reevaluate() async {
        let snapshots = await snapshotProvider()
        conflicts = Self.detect(
            snapshots,
            existing: conflicts,
            now: now(),
            config: config
        )
    }

    // MARK: - Read API (for the UI)

    /// Conflicts worth surfacing: active, or fading out within the grace
    /// window. Ignored and resolved are hidden. The sidebar / bar / modal
    /// all read through here so they share one notion of "visible".
    var visibleConflicts: [Conflict] {
        conflicts.filter { conflict in
            switch conflict.status {
            case .active, .resolving: true
            case .ignored, .resolved: false
            }
        }
    }

    /// Visible conflicts the given worktree participates in.
    func conflicts(involving id: WorktreeID) -> [Conflict] {
        visibleConflicts.filter { conflict in
            conflict.parties.contains { $0.workTreeID == id }
        }
    }

    /// Whether the worktree is a party in any visible conflict — drives
    /// the bright sidebar ⚠ and the party bar.
    func isParty(_ id: WorktreeID) -> Bool {
        !conflicts(involving: id).isEmpty
    }

    /// Ignored conflicts the worktree is a party in. These are silenced
    /// (no bar, excluded from `visibleConflicts`) but we still surface a
    /// muted sidebar ⚠ so the user can reopen the modal and un-ignore —
    /// otherwise ignoring would be a one-way trap.
    func ignoredConflicts(involving id: WorktreeID) -> [Conflict] {
        conflicts.filter { conflict in
            conflict.status == .ignored && conflict.parties.contains { $0.workTreeID == id }
        }
    }

    /// First conflict the worktree is a party in that is still worth
    /// opening — visible OR ignored, but not resolved. The re-entry
    /// point for both the bright and muted ⚠ taps.
    func anyOpenableConflict(involving id: WorktreeID) -> Conflict? {
        conflicts.first { conflict in
            conflict.status != .resolved && conflict.parties.contains { $0.workTreeID == id }
        }
    }

    /// File-count threshold the party bar uses before collapsing file
    /// names to a count (spec §8.x). Exposed from config so the bar
    /// doesn't hard-code it.
    var barFileCountThreshold: Int {
        config.barFileCountThreshold
    }

    // MARK: - User actions

    /// Ignore a conflict (pair-level, per spec §2 — one ignore covers
    /// the pair, and stays put as new overlapping files appear).
    func ignore(_ id: ConflictID) {
        setStatus(id, to: .ignored)
    }

    func unignore(_ id: ConflictID) {
        setStatus(id, to: .active)
    }

    private func setStatus(_ id: ConflictID, to status: ConflictStatus) {
        guard let index = conflicts.firstIndex(where: { $0.id == id }) else { return }
        conflicts[index].status = status
    }

    // MARK: - Detection (pure)

    /// The L1 algorithm as a pure function (spec §5). Deterministic given
    /// `now`, so the staleness window and grace period are unit-testable
    /// without real timers.
    ///
    /// 1. Reverse-index path → which worktrees touched it, dropping
    ///    touches older than `stalenessWindow` (freshness filter — the
    ///    single most important guard against crying wolf, §5 step 2).
    /// 2. Keep paths shared by `minPartiesForConflict`+ fresh worktrees.
    /// 3. Group those paths by their exact worktree set; each set is one
    ///    Conflict (the aggregation that prevents duplicates).
    /// 4. Merge with the prior result under hysteresis (§5 steps 6–7):
    ///    re-detected `.ignored` stays ignored; a vanished `.active`
    ///    enters a grace period as `.resolving` instead of disappearing
    ///    (so the ⚠️ doesn't flicker on save → momentarily-clean →
    ///    save); `.resolving` past `gracePeriod` is dropped for good, and
    ///    `.resolving` re-detected within grace snaps back to `.active`.
    nonisolated static func detect(
        _ snapshots: [WorktreeSnapshot],
        existing: [Conflict],
        now: Date,
        config: DetectorConfig
    ) -> [Conflict] {
        let metaByID = Dictionary(
            snapshots.map { ($0.worktree.id, $0.worktree) },
            uniquingKeysWith: { first, _ in first }
        )
        let stalenessFloor = now.addingTimeInterval(-config.stalenessWindow)

        // (project, path) → (worktreeID → freshest touch). Keying by
        // project — not bare path — scopes overlaps to a single repo:
        // two unrelated projects both editing `src/main.swift` are not a
        // conflict (different repos, different files). Stale touches are
        // excluded so an old edit can't keep a warning alive.
        var owners: [ScopedPath: [WorktreeID: Date]] = [:]
        for snapshot in snapshots {
            let changeSet = snapshot.changeSet
            let project = snapshot.worktree.projectID
            for path in changeSet.changedPaths {
                let touched = changeSet.lastTouched[path] ?? changeSet.capturedAt
                guard touched >= stalenessFloor else { continue }
                owners[ScopedPath(project: project, path: path), default: [:]][changeSet.workTreeID] = touched
            }
        }

        // Group shared paths by their exact owner set.
        var groups: [ConflictID: PathGroup] = [:]
        for (scoped, perWorktree) in owners {
            guard perWorktree.count >= config.minPartiesForConflict else { continue }
            let members = Set(perWorktree.keys)
            let id = ConflictID(members: members)
            let pathTouched = perWorktree.values.max() ?? now
            groups[id, default: PathGroup(members: members)]
                .add(path: scoped.path, touched: pathTouched, perWorktree: perWorktree)
        }

        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Freshly detected conflicts.
        var result: [Conflict] = groups.map { id, group in
            let parties = group.members
                .sorted { $0.raw < $1.raw }
                .map { member in
                    ConflictParty(
                        workTreeID: member,
                        branch: metaByID[member]?.branch ?? "",
                        rootURL: metaByID[member]?.rootURL ?? URL(fileURLWithPath: "/"),
                        lastTouched: group.partyTouched[member] ?? now,
                        agentLabel: nil,
                        taskLabel: nil
                    )
                }
            // Freshest files first so the modal shows recent activity on
            // top.
            let paths = group.paths.sorted { $0.lastTouched > $1.lastTouched }

            let prior = existingByID[id]
            // Re-detection: keep an ignore; otherwise (new, was-active, or
            // was-resolving) the conflict is live → active.
            let status: ConflictStatus = prior?.status == .ignored ? .ignored : .active
            return Conflict(
                id: id,
                parties: parties,
                paths: paths,
                detectedAt: prior?.detectedAt ?? now,
                status: status
            )
        }

        // Hysteresis for conflicts that vanished this pass.
        let detectedIDs = Set(result.map(\.id))
        for prior in existing where !detectedIDs.contains(prior.id) {
            switch prior.status {
            case .active:
                // Just disappeared — hold it in grace rather than yank it.
                var resolving = prior
                resolving.status = .resolving(since: now)
                result.append(resolving)
            case let .resolving(since):
                // Still gone; keep waiting until the grace window elapses.
                if now.timeIntervalSince(since) < config.gracePeriod {
                    result.append(prior)
                }
            // .ignored: nothing was being shown, so no flicker to absorb —
            // drop it. .resolved: already terminal. Both fall through to
            // removal.
            case .ignored, .resolved:
                break
            }
        }

        // Stable display order: oldest-detected first.
        return result.sorted { $0.detectedAt < $1.detectedAt }
    }
}

/// A changed path scoped to its project, so overlap detection never
/// crosses repo boundaries (a relative path means different files in
/// different repos).
private struct ScopedPath: Hashable {
    let project: ProjectID
    let path: String
}

/// Mutable accumulator while grouping a worktree set's overlapping
/// files. `partyTouched` tracks each worktree's freshest touch across
/// all the group's files (the party's lastTouched).
private struct PathGroup {
    let members: Set<WorktreeID>
    var paths: [ConflictPath] = []
    var partyTouched: [WorktreeID: Date] = [:]

    mutating func add(
        path: String,
        touched: Date,
        perWorktree: [WorktreeID: Date]
    ) {
        paths.append(ConflictPath(path: path, level: .potential, lastTouched: touched))
        for (worktree, time) in perWorktree {
            if let current = partyTouched[worktree] {
                partyTouched[worktree] = max(current, time)
            } else {
                partyTouched[worktree] = time
            }
        }
    }
}
