// WindowSession+Worktree.swift
// Limpid — async API for creating a new git worktree end-to-end:
// run `git worktree add`, attach the new row to the project, and
// optionally open a tab pointing at it. Lives in its own extension
// because it bridges Domain state (WindowSession) with the git CLI
// (GitProcess) and stays optional to the rest of the model.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "session.worktree")

extension Notification.Name {
    /// Posted when ⌘⌥W fires. Picked up by `ContainerSlabView` to
    /// raise the Create Worktree sheet for the active project. Lives
    /// on Notification rather than the WindowSession so the keyboard
    /// shortcut, which is wired on the App-level command tree, can
    /// reach the sidebar without a direct reference.
    static let limpidCreateWorktreeRequested = Notification.Name("dev.limpid.createWorktreeRequested")
}

/// Self-trigger the project's GitSync refetch after a Limpid-initiated
/// mutation lands. Replaces the FSEvent-driven auto refetch (which
/// raced against optimistic UI state). Always called on the MainActor
/// — the GitSyncCoordinator's notification observer hops back here
/// to start the actual refetch task.
@MainActor
private func requestSyncRefetch(projectID: UUID) {
    NotificationCenter.default.post(
        name: .limpidGitSyncRequested,
        object: projectID
    )
}

// MARK: - Synchronous worktree mutators

//
// Every worktree-touching API lives here so they're easy to grep. The
// async pipelines (`createGitWorktree`, `deleteGitWorktree`) are
// defined further down and call into the synchronous helpers below.

extension WindowSession {
    /// Append a freshly-created git worktree to a project's sidebar
    /// list. Caller is responsible for actually running `git worktree
    /// add` first — this only mutates Limpid's in-memory model.
    @discardableResult
    func attachGitWorktree(
        id: UUID = UUID(),
        projectID: UUID,
        label: String,
        workingDirectory: URL,
        branchName: String?
    ) -> Worktree? {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let wt = Worktree(
            id: id,
            label: label,
            workingDirectory: workingDirectory,
            gitRef: branchName.map { GitRef(branchName: $0, worktreePath: workingDirectory) },
            origin: .gitWorktree
        )
        projects[pi].worktrees.append(wt)
        return wt
    }

    /// Remove a worktree row AND close every tab under it. Returns the
    /// pane ids so the caller can free `SurfaceView`s. Use this when
    /// the user has committed to deleting (disk gone or about to be);
    /// `hideWorktree` is the recoverable counterpart.
    @discardableResult
    func removeWorktree(projectID: UUID, worktreeID: UUID) -> [UUID] {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return [] }
        guard projects[pi].worktrees.contains(where: { $0.id == worktreeID }) else { return [] }
        let leafIDs = closeTabs { tab in
            if case let .worktree(pid, wid) = tab.container {
                return pid == projectID && wid == worktreeID
            }
            return false
        }
        projects[pi].worktrees.removeAll { $0.id == worktreeID }
        if case let .worktree(pid, wid) = activeContainerID,
           pid == projectID, wid == worktreeID
        {
            setActiveContainer(.project(projectID))
        }
        return leafIDs
    }

    /// Filter-and-drop tabs in one pass, returning the pane ids that
    /// were freed. Shared by every "remove worktree row(s)" path so
    /// the `filter → flatMap → removeAll → activeTabID rewind` dance
    /// only lives in one spot.
    @discardableResult
    private func closeTabs(where predicate: (Tab) -> Bool) -> [UUID] {
        let leafIDs = tabs.filter(predicate).flatMap { $0.splitTree.allLeafIDs() }
        tabs.removeAll(where: predicate)
        if activeTabID != nil, tabs.first(where: { $0.id == activeTabID }) == nil {
            activeTabID = nil
        }
        // Cleanup transient per-pane search overlays for every leaf
        // that just vanished. Without this the entries leak.
        for leafID in leafIDs {
            paneSearchStates.removeValue(forKey: leafID)
        }
        return leafIDs
    }

    /// Hide a worktree from the sidebar without disk-side delete.
    /// Tabs inside are reparented to the project's general bucket so
    /// they don't strand — `Show Hidden Worktrees` brings the row
    /// back. We pick this over removal so the FS state stays intact.
    func hideWorktree(projectID: UUID, worktreeID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID })
        else { return }
        projects[pi].worktrees[wi].isHidden = true
        for ti in tabs.indices {
            if case let .worktree(pid, wid) = tabs[ti].container,
               pid == projectID, wid == worktreeID
            {
                tabs[ti].container = .project(projectID)
            }
        }
        if case let .worktree(pid, wid) = activeContainerID,
           pid == projectID, wid == worktreeID
        {
            setActiveContainer(.project(projectID))
        }
    }

    /// Flip `isHidden` back on every hidden row under a project.
    func unhideAllWorktrees(projectID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        for wi in projects[pi].worktrees.indices {
            projects[pi].worktrees[wi].isHidden = false
        }
    }

    /// Single-worktree counterpart of `unhideAllWorktrees`. Used from
    /// Project Settings to surface one hidden row at a time.
    func unhideWorktree(projectID: UUID, worktreeID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID })
        else { return }
        projects[pi].worktrees[wi].isHidden = false
    }

    /// Update the per-project worktree placement strategy. Only
    /// affects FUTURE worktree creations — existing worktrees stay
    /// where they are on disk.
    func setProjectWorktreePlacement(_ projectID: UUID, to placement: WorktreePlacement) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[pi].worktreePlacement = placement
    }

    /// Drop every worktree row currently flagged `isMissing` from a
    /// project AND close their tabs. Returns the pane ids for
    /// registry cleanup, matching the `removeWorktree` contract.
    @discardableResult
    func pruneMissingWorktrees(projectID: UUID) -> [UUID] {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return [] }
        let removedIDs = Set(projects[pi].worktrees.filter(\.isMissing).map(\.id))
        guard !removedIDs.isEmpty else { return [] }
        let leafIDs = closeTabs { tab in
            if case let .worktree(pid, wid) = tab.container {
                return pid == projectID && removedIDs.contains(wid)
            }
            return false
        }
        projects[pi].worktrees.removeAll { $0.isMissing }
        if case let .worktree(pid, wid) = activeContainerID,
           pid == projectID, removedIDs.contains(wid)
        {
            setActiveContainer(.project(projectID))
        }
        return leafIDs
    }

    func hasMissingWorktrees(projectID: UUID) -> Bool {
        guard let p = projects.first(where: { $0.id == projectID }) else { return false }
        return p.worktrees.contains(where: \.isMissing)
    }

    func hasHiddenWorktrees(projectID: UUID) -> Bool {
        guard let p = projects.first(where: { $0.id == projectID }) else { return false }
        return p.worktrees.contains(where: \.isHidden)
    }

    /// Single-step reorder within a project's worktree list.
    func moveWorktreeUp(projectID: UUID, worktreeID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID }),
              wi > 0
        else { return }
        projects[pi].worktrees.swapAt(wi, wi - 1)
    }

    func moveWorktreeDown(projectID: UUID, worktreeID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID }),
              wi < projects[pi].worktrees.count - 1
        else { return }
        projects[pi].worktrees.swapAt(wi, wi + 1)
    }

    func canMoveWorktreeUp(projectID: UUID, worktreeID: UUID) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID })
        else { return false }
        return wi > 0
    }

    func canMoveWorktreeDown(projectID: UUID, worktreeID: UUID) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID })
        else { return false }
        return wi < projects[pi].worktrees.count - 1
    }

    /// Drag-reorder a worktree within its project. Cross-project moves
    /// are rejected (worktrees are anchored to their project's repo).
    func reorderWorktree(
        projectID: UUID,
        sourceID: UUID,
        target targetID: UUID,
        position: DropPosition
    ) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        WindowSession.reorderInPlace(
            in: &projects[pi].worktrees,
            sourceID: sourceID,
            target: targetID,
            position: position
        )
    }

    /// Which project (if any) currently owns the given worktree id.
    /// Used by drop targets to reject cross-project worktree drags.
    func projectID(forWorktree worktreeID: UUID) -> UUID? {
        for project in projects {
            if project.worktrees.contains(where: { $0.id == worktreeID }) {
                return project.id
            }
        }
        return nil
    }
}

/// Append `/.worktrees/` to the repo's local exclude file
/// (`.git/info/exclude`) if it's not already covered. We use the
/// local exclude rather than `.gitignore` so the entry stays out of
/// the user's commits — `.git/info/exclude` is git's official "per
/// repo, per developer" ignore list and is never tracked. That
/// matches what OSS worktree tooling (newt et al.) does and lets us
/// stay silent without polluting the user's diff.
///
/// Wrapped in BEGIN / END markers so a future repeat call can find
/// and update its own block instead of duplicating, and so the user
/// can spot what Limpid wrote.
///
/// Best-effort: any FS error is logged and swallowed. A failed
/// exclude edit doesn't block worktree creation, and since the file
/// lives under `.git/` the user almost never notices the failure;
/// `.worktrees/<branch>/` will just show up as untracked in
/// `git status` until they ignore it themselves.
@MainActor
private func ensureLocalExcludeCoversWorktreesDir(repoRoot: URL) {
    // Resolve `.git` — usually a directory, but in submodules it's a
    // text file pointing elsewhere. Skip the gitfile case for now;
    // submodules with worktrees inside themselves are exotic enough
    // that the manual fallback is acceptable.
    let gitDir = repoRoot.appendingPathComponent(".git")
    var isDir: ObjCBool = false
    let fm = FileManager.default
    guard fm.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue else {
        return
    }
    let infoDir = gitDir.appendingPathComponent("info")
    let excludeURL = infoDir.appendingPathComponent("exclude")
    try? fm.createDirectory(at: infoDir, withIntermediateDirectories: true)

    let beginMarker = "# >>> limpid worktrees >>>"
    let endMarker = "# <<< limpid worktrees <<<"
    let block = "\(beginMarker)\n/.worktrees/\n\(endMarker)\n"

    let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
    if existing.contains(beginMarker) {
        return
    }
    var updated = existing
    if !updated.isEmpty, !updated.hasSuffix("\n") {
        updated += "\n"
    }
    updated += block
    do {
        try updated.write(to: excludeURL, atomically: true, encoding: .utf8)
    } catch {
        log
            .error(
                "Failed to update .git/info/exclude at \(excludeURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
    }
}

extension WindowSession {
    /// End-to-end "Create Worktree" pipeline. Runs `git worktree add`
    /// off the main actor, then attaches the new row and optionally
    /// opens a tab inside it. Throws on git errors so the sheet can
    /// surface the stderr.
    @discardableResult
    func createGitWorktree(
        projectID: UUID,
        path: URL,
        baseBranch: String,
        newBranchName: String?,
        openTab: Bool,
        git: any GitRunning = LiveGit()
    ) async throws -> Worktree {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw CreateWorktreeError.projectNotFound
        }
        if FileManager.default.fileExists(atPath: path.path) {
            throw CreateWorktreeError.pathAlreadyExists(path)
        }
        let repoRoot = project.rootURL
        if case .insideHidden = project.worktreePlacement {
            ensureLocalExcludeCoversWorktreesDir(repoRoot: repoRoot)
        }
        let newBranch = newBranchName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let createsNewBranch = !(newBranch?.isEmpty ?? true)

        // Mint the worktree id up-front so the eventual `attachGitWorktree`
        // call below uses the same id we hand to GitSync. Note: the
        // `withWorktreeMutationGated` wrapper around the `git` call is
        // a defense-in-depth signal only — GitSync's `inFlight` check
        // (`GitSyncCoordinator.reconcileWorktrees`) only fires for ids
        // that already live in `session.projects[*].worktrees`, and
        // `pendingID` is not appended until `attachGitWorktree` below.
        // The actual race protection is the synchronous attach-after-
        // await sequence on the MainActor: GitSync can't observe the
        // "added on disk but not in model" gap because the task
        // continuation lands before any other MainActor work runs.
        let pendingID = UUID()
        let result = try await withWorktreeMutationGated(pendingID) {
            try await git.createWorktree(
                repoRoot: repoRoot,
                path: path,
                baseBranch: baseBranch,
                newBranchName: createsNewBranch ? newBranch : nil
            )
        }
        guard result.succeeded else {
            log.error("git worktree add failed: \(result.stderr, privacy: .public)")
            throw CreateWorktreeError.gitFailed(stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The branch name we display on the row: the new branch when
        // we just created one, otherwise the base branch (which is
        // what git will have checked out into the worktree).
        let branchForRef = createsNewBranch ? newBranch! : baseBranch
        // Label = branch name (not the folder basename). With the
        // sibling-prefixed placement the folder is `<repo>-<branch>`,
        // and we don't want the `<repo>-` prefix leaking into the
        // sidebar. The branch travels in `GitRef.branchName`; this
        // is the display string only.
        guard let wt = attachGitWorktree(
            id: pendingID,
            projectID: projectID,
            label: branchForRef,
            workingDirectory: path,
            branchName: branchForRef
        ) else {
            throw CreateWorktreeError.projectNotFound
        }
        if openTab {
            setActiveContainer(.worktree(projectID: projectID, worktreeID: wt.id))
            _ = self.openTab(container: .worktree(projectID: projectID, worktreeID: wt.id))
        }
        // Ask GitSync to settle the new row's gitRef on its next pass.
        requestSyncRefetch(projectID: projectID)
        return wt
    }

    /// End-to-end "Delete Worktree" pipeline. Runs `git worktree
    /// remove`, then drops the row + closes its tabs. Returns the
    /// pane ids the caller should free from the registry. Throws on
    /// git failures so the caller can offer "Retry with Force" when
    /// the tree is dirty / locked.
    @discardableResult
    func deleteGitWorktree(
        projectID: UUID,
        worktreeID: UUID,
        force: Bool,
        git: any GitRunning = LiveGit()
    ) async throws -> [UUID] {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw DeleteWorktreeError.projectNotFound
        }
        guard let wt = project.worktrees.first(where: { $0.id == worktreeID }) else {
            throw DeleteWorktreeError.worktreeNotFound
        }
        let result = try await withWorktreeMutationGated(worktreeID) {
            try await git.removeWorktree(
                repoRoot: project.rootURL,
                path: wt.workingDirectory,
                force: force
            )
        }
        if !result.succeeded {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // "not a working tree" / "is not a working tree" — git
            // already doesn't know about this path. The on-disk state
            // matches what the user wanted ("gone"), so treat the
            // Limpid row removal as success rather than refusing.
            // This handles orphan rows where the worktree was deleted
            // outside Limpid first.
            let lower = stderr.lowercased()
            if lower.contains("not a working tree") || lower.contains("no such file or directory") {
                let ids = removeWorktree(projectID: projectID, worktreeID: worktreeID)
                requestSyncRefetch(projectID: projectID)
                return ids
            }
            // git prints something like "fatal: '<path>' contains
            // modified or untracked files, use --force to delete it"
            // when the tree is dirty. Surface that as a typed error so
            // the UI can offer a one-click Force retry.
            if !force, stderr.contains("modified") || stderr.contains("--force") || stderr.contains("locked") {
                throw DeleteWorktreeError.dirtyNeedsForce
            }
            log.error("git worktree remove failed: \(stderr, privacy: .public)")
            throw DeleteWorktreeError.gitFailed(stderr: stderr)
        }
        // On success the disk is already cleaned up; drop the row
        // and close all tabs that lived in it (per the same contract
        // as removing a group/project).
        let ids = removeWorktree(projectID: projectID, worktreeID: worktreeID)
        requestSyncRefetch(projectID: projectID)
        return ids
    }
}
