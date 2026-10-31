// GitSyncCoordinator.swift
// Limpid — keeps `Project.worktrees` synchronized with the real
// `git worktree list` output, each row's `GitRef` taken from it.
//
// Lifecycle:
//   - Watches `WorkspaceSession.projects` (via `observeRepeatedly`) and
//     installs/removes a per-Project sync as projects come and go.
//   - Each per-Project sync runs an initial fetch, then re-fetches on
//     demand (`ProjectSync.start` lists the triggers).
//   - When `git worktree list` reports a worktree set that differs
//     from what's stored, we reconcile: keep user-pinned items
//     untouched, add new git-detected worktrees, drop ones that no
//     longer exist. Tabs whose `ownerWorktreeID` points at a removed
//     worktree are migrated to "Project direct" so the user's work
//     isn't lost.

import AppKit
import Foundation
import OSLog

private let log = Logger.limpid("git.sync")

extension Notification.Name {
    /// Posted by UI (e.g. Project header context menu "Sync
    /// Worktrees") to force `GitSyncCoordinator` to re-run
    /// `git worktree list` immediately. `object` may be a UUID
    /// project id (sync just that project) or nil (sync all).
    static let limpidGitSyncRequested = Notification.Name("dev.limpid.gitSyncRequested")
}

/// Lists a repository's worktrees: `git worktree list`, or a test's own.
typealias WorktreeLister = @Sendable (URL) async throws -> [GitWorktreeInfo]

@MainActor
final class GitSyncCoordinator {
    private weak var session: WorkspaceSession?
    private var perProject: [UUID: ProjectSync] = [:]
    private let listWorktrees: WorktreeLister
    /// The person's home folder, under which Codex keeps the worktrees it
    /// makes (`WorktreeAdmissionRule.Facts.homePath`). A test passes its own.
    private let homePath: String

    // `deinit` is nonisolated, but `NSObjectProtocol?` is non-Sendable,
    // so accessing these tokens to remove the observers needs the
    // `nonisolated(unsafe)` escape hatch. The mutation sites all live
    // on @MainActor (init / handleSyncRequest paths), so the unsafety
    // is only paid at teardown.
    private nonisolated(unsafe) var syncRequestObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var activateObserver: (any NSObjectProtocol)?

    init(
        session: WorkspaceSession,
        listWorktrees: @escaping WorktreeLister = { try await GitWorktreeList.fetch(repoRoot: $0) },
        homePath: String = NSHomeDirectory()
    ) {
        self.session = session
        self.listWorktrees = listWorktrees
        self.homePath = homePath
        observeRepeatedly { [weak self] in
            guard let self, let session = self.session else { return }
            // Touch the list of projects so the runtime re-arms on
            // add/remove. We deliberately don't touch worktrees here
            // — re-running on every worktree mutation would loop
            // (we *cause* those mutations from the sync).
            _ = session.projects.map(\.id)
        } onChange: { [weak self] in
            self?.reconcileSyncs()
        }
        reconcileSyncs()
        // Manual sync trigger from the UI. The `object` field is
        // optional — UUID = single project, nil = sync everything.
        syncRequestObserver = NotificationCenter.default.addObserver(
            forName: .limpidGitSyncRequested,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = note.object as? UUID
            MainActor.assumeIsolated {
                self?.handleSyncRequest(pid)
            }
        }
        // Window focus refresh — many users tab out to delete a
        // worktree in Terminal, then come back expecting Limpid to
        // notice. NSApplication's didBecomeActive fires every time
        // the app gains focus.
        activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSyncRequest(nil)
            }
        }
    }

    deinit {
        if let s = syncRequestObserver {
            NotificationCenter.default.removeObserver(s)
        }
        if let a = activateObserver {
            NotificationCenter.default.removeObserver(a)
        }
    }

    private func handleSyncRequest(_ projectID: UUID?) {
        if let pid = projectID {
            perProject[pid]?.scheduleRefetchPublic()
        } else {
            for sync in perProject.values {
                sync.scheduleRefetchPublic()
            }
        }
    }

    private func reconcileSyncs() {
        guard let session else { return }
        let liveIDs = Set(session.projects.map(\.id))
        // Drop syncs for projects that no longer exist.
        for (id, sync) in perProject where !liveIDs.contains(id) {
            sync.stop()
            perProject.removeValue(forKey: id)
        }
        // Spin up syncs for any new project rooted in a git repo.
        for project in session.projects where perProject[project.id] == nil {
            let sync = ProjectSync(projectID: project.id, session: session, listWorktrees: listWorktrees, homePath: homePath)
            perProject[project.id] = sync
            sync.start()
        }
    }
}

// MARK: - Per-Project sync

@MainActor
private final class ProjectSync {
    let projectID: UUID
    weak var session: WorkspaceSession?
    private var refetchTask: Task<Void, Never>?
    private let listWorktrees: WorktreeLister
    private let homePath: String
    /// Counts the syncs started. Canceling one does not stop the `git` it
    /// awaits, so a sync that a later one replaced can still return, with an
    /// older picture of the repository, after the later one wrote its own.
    /// It writes only while it is still the latest.
    private var generation: UInt = 0

    init(projectID: UUID, session: WorkspaceSession, listWorktrees: @escaping WorktreeLister, homePath: String) {
        self.projectID = projectID
        self.session = session
        self.listWorktrees = listWorktrees
        self.homePath = homePath
    }

    func start() {
        // Initial fetch only. We deliberately do NOT install a
        // FSEvents watcher on `.git` — sub-second auto refetches
        // triggered by Limpid's own git CLI calls (rename/delete/
        // create) would clobber the optimistic in-memory state and
        // produce a long tail of race conditions. The refetch triggers are:
        //   1. App focus (didBecomeActiveNotification, GitSyncCoordinator init)
        //   2. Manual `Sync Worktrees` (limpidGitSyncRequested)
        //   3. Self-triggered — `WorkspaceSession+Worktree` posts the
        //      same notification at the end of each mutation.
        scheduleRefetch()
    }

    func stop() {
        refetchTask?.cancel()
    }

    private func currentProject() -> Project? {
        session?.projects.first(where: { $0.id == projectID })
    }

    /// External entry point. Exposes `scheduleRefetch` so the
    /// coordinator's notification handlers can force a sync without
    /// needing access to the private member.
    func scheduleRefetchPublic() {
        scheduleRefetch()
    }

    private func scheduleRefetch() {
        refetchTask?.cancel()
        refetchTask = Task { @MainActor [weak self] in
            await self?.refetch()
        }
    }

    private func refetch() async {
        generation &+= 1
        let started = generation
        guard let project = currentProject() else { return }
        let root = project.rootURL
        // `git worktree list` already filters to actual checkouts —
        // for non-git folders it returns nothing and we leave the
        // user-pinned items alone.
        let infos: [GitWorktreeInfo]
        do {
            infos = try await listWorktrees(root)
        } catch {
            log.error("worktree list failed: \(String(describing: error), privacy: .private)")
            return
        }

        // One listing, no `git status` per worktree: the listing names each
        // one's branch and HEAD, and nothing reads the dirty flag or the
        // ahead and behind counts a status gave. Run on every activation,
        // a status per worktree made a new row wait for all of them.
        guard started == generation, !Task.isCancelled else { return }
        guard let session else { return }
        guard let pIdx = session.projects.firstIndex(where: { $0.id == projectID }) else { return }

        let projectRoot = project.rootURL.standardizedFileURL
        // Main checkout entry is captured separately for the project's
        // `mainBranchName`; per-worktree entries skip it because the
        // project's own folder already stands for the main checkout.
        let mainInfo = infos.first(where: { $0.path.standardizedFileURL == projectRoot })
        let liveInfos = infos.filter { $0.path.standardizedFileURL != projectRoot }

        let merged = admitUnadmitted(
            buildReconciledList(session: session, pIdx: pIdx, liveInfos: liveInfos),
            session: session,
            projectID: projectID
        )
        writeBackIfChanged(session: session, pIdx: pIdx, merged: merged)
        updateMainBranch(session: session, pIdx: pIdx, mainInfo: mainInfo)
    }

    // MARK: - refetch sub-steps

    //
    // Splitting refetch's body into three named pieces makes the
    // reconcile/write/branch-update phases independently readable and
    // testable. Each step is pure-ish: they read the session and
    // return a value or apply a narrow mutation.

    /// Walk the user's existing rows in order, match each against the
    /// fresh git output (preferring path, falling back to branch for
    /// rename races), append brand-new rows at the end, and skip
    /// anything the user deleted while our awaits were in flight.
    private func buildReconciledList(
        session: WorkspaceSession,
        pIdx: Int,
        liveInfos: [GitWorktreeInfo]
    ) -> [Worktree] {
        let userPinned = session.projects[pIdx].worktrees.filter { $0.origin == .userPinned }
        let oldGitWorktrees = session.projects[pIdx].worktrees.filter { $0.origin == .gitWorktree }

        var infosByPath: [URL: GitWorktreeInfo] = [:]
        for info in liveInfos {
            infosByPath[info.path.standardizedFileURL] = info
        }
        // Branch-name fallback index. `git worktree move` changes the
        // path mid-flight, so a race between the move and our model
        // update can leave us seeing an old path locally and the new
        // path in `git worktree list`. Branch is stable across
        // renames, so falling back to it keeps the UUID in place.
        var infosByBranch: [String: GitWorktreeInfo] = [:]
        for info in liveInfos {
            if let b = info.branch, !b.isEmpty, infosByBranch[b] == nil {
                infosByBranch[b] = info
            }
        }

        let inFlight = session.worktreeMutationsInFlight
        var result: [Worktree] = []
        var consumedPaths: Set<URL> = []

        for old in oldGitWorktrees {
            // In-flight mutation: trust the user's optimistic state
            // verbatim. Read the CURRENT session value (not our
            // captured snapshot) so an optimistic label update
            // landing between refetch start and now isn't clobbered.
            if inFlight.contains(old.id) {
                let current = session.projects[pIdx].worktrees.first(where: { $0.id == old.id })
                let kept = current ?? old
                result.append(kept)
                consumedPaths.insert(kept.workingDirectory.standardizedFileURL)
                continue
            }
            let oldPath = old.workingDirectory.standardizedFileURL
            let resolved: GitWorktreeInfo? = {
                if let info = infosByPath[oldPath], !consumedPaths.contains(info.path.standardizedFileURL) {
                    return info
                }
                if let branch = old.gitRef?.branchName,
                   let info = infosByBranch[branch],
                   !consumedPaths.contains(info.path.standardizedFileURL)
                {
                    return info
                }
                return nil
            }()
            if let info = resolved {
                var fresh = mergeWorktree(existing: old, info: info)
                fresh.missingSince = nil
                result.append(fresh)
                consumedPaths.insert(info.path.standardizedFileURL)
            } else {
                // External deletion: keep the row but mark missing so
                // the UI dims it + warns rather than silently dropping
                // user state.
                var stale = old
                stale.missingSince = old.missingSince ?? Date()
                result.append(stale)
            }
        }
        for info in liveInfos {
            let path = info.path.standardizedFileURL
            if consumedPaths.contains(path) {
                continue
            }
            result.append(mergeWorktree(existing: nil, info: info))
        }

        // Filter out anything the user explicitly removed during our
        // awaits (Delete Worktree / Remove Missing / Hide row).
        let initialUUIDs = Set(oldGitWorktrees.map(\.id))
        let currentUUIDs = Set(session.projects[pIdx].worktrees.map(\.id))
        let droppedDuringAwait = initialUUIDs.subtracting(currentUUIDs)
        return (userPinned + result).filter { !droppedDuringAwait.contains($0.id) }
    }

    /// Materialize a `Worktree` from a `GitWorktreeInfo`, optionally
    /// inheriting metadata (label, UUID) from the previous row at the
    /// same path/branch.
    private func mergeWorktree(
        existing: Worktree?,
        info: GitWorktreeInfo
    ) -> Worktree {
        let path = info.path.standardizedFileURL
        let gitRef = GitRef(
            branchName: info.branch,
            worktreePath: path,
            headSHA: info.headSHA,
            lastFetched: Date()
        )
        // Fall back through branch → folder basename → a literal
        // marker so we never write a blank label even if both upstream
        // sources happen to be empty (e.g. a freshly initialized
        // worktree at the filesystem root).
        let candidate = gitRef.branchName ?? path.lastPathComponent
        let autoLabel = candidate.isEmpty ? "(unnamed)" : candidate
        if var updated = existing {
            // Refresh the label to track whatever the upstream branch
            // is currently called. Since rename is no longer exposed,
            // labels are always machine-derived (branch name with a
            // folder-basename fallback) and we can write through
            // unconditionally.
            updated.label = autoLabel
            updated.workingDirectory = path
            updated.gitRef = gitRef
            return updated
        }
        // A worktree Git reports first was made outside Limpid, by an agent
        // or by hand: it waits among the other worktrees until the person
        // opens it. One Limpid makes is attached as its own before
        // this sync sees it (`attachGitWorktree`).
        return Worktree(
            label: autoLabel,
            workingDirectory: path,
            gitRef: gitRef,
            origin: .gitWorktree,
            admission: .discovered
        )
    }

    /// Admits each row a `state.json` from before admissions holds with
    /// none, once, by its use and then its path (`WorktreeAdmissionRule`);
    /// `writeBackIfChanged` saves the result with the sync's. A pinned row
    /// is the person's own. A row being changed is left as the change has
    /// it, as the reconcile leaves it.
    private func admitUnadmitted(_ rows: [Worktree], session: WorkspaceSession, projectID: UUID) -> [Worktree] {
        let inFlight = session.worktreeMutationsInFlight
        return rows.map { row in
            guard row.admission == nil, !inFlight.contains(row.id) else { return row }
            var admitted = row
            if row.origin == .userPinned {
                admitted.admission = .opened
                return admitted
            }
            let container = ContainerID.worktree(projectID: projectID, worktreeID: row.id)
            admitted.admission = WorktreeAdmissionRule.classify(WorktreeAdmissionRule.Facts(
                hasTabs: !session.tabs(in: container).isEmpty,
                hasLastActiveTab: row.lastActiveTabID != nil,
                isSelected: session.holdsSelection(of: container),
                path: row.workingDirectory.standardizedFileURL.path,
                // A row Git reported with no branch has its HEAD detached.
                isDetached: row.gitRef != nil && row.gitRef?.branchName == nil,
                homePath: homePath
            ))
            return admitted
        }
    }

    /// Write the reconciled list back to the session only when it
    /// actually differs — avoids Observation churn that would
    /// re-render the sidebar on every focus refetch.
    private func writeBackIfChanged(
        session: WorkspaceSession,
        pIdx: Int,
        merged: [Worktree]
    ) {
        if session.projects[pIdx].worktrees != merged {
            session.projects[pIdx].worktrees = merged
            log.notice("synced project \(self.projectID, privacy: .public): \(merged.count, privacy: .public) worktree rows")
        }
    }

    /// Update the project's `mainBranchName` and `mainHeadSHA` from the
    /// main checkout entry. The branch names the main folder's checkout
    /// wherever Limpid names one (`CheckoutName`); the commit says it is a
    /// repository when a detached HEAD leaves it no branch.
    private func updateMainBranch(
        session: WorkspaceSession,
        pIdx: Int,
        mainInfo: GitWorktreeInfo?
    ) {
        let mainBranch = mainInfo?.branch
        if session.projects[pIdx].mainBranchName != mainBranch {
            session.projects[pIdx].mainBranchName = mainBranch
        }
        let mainHead = mainInfo?.headSHA
        if session.projects[pIdx].mainHeadSHA != mainHead {
            session.projects[pIdx].mainHeadSHA = mainHead
        }
    }
}
