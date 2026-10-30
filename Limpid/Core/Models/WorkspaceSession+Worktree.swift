// WorkspaceSession+Worktree.swift
// Limpid — async API for creating a new git worktree end-to-end:
// run `git worktree add`, attach the new row to the project, and
// optionally open a tab pointing at it. Lives in its own extension
// because it bridges Domain state (WorkspaceSession) with the git CLI
// (GitProcess) and stays optional to the rest of the model.

import Foundation
import OSLog

private let log = Logger.limpid("session.worktree")

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

extension WorkspaceSession {
    /// Replace the per-project bootstrap list. Wired from
    /// `ContainerSettingsSheet`'s editor (and `state.json` hand-edits
    /// pick up the new value on next decode).
    @MainActor
    func setProjectBootstrap(_ projectID: UUID, to items: [BootstrapItem]) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard projects[pi].bootstrap != items else { return }
        projects[pi].bootstrap = items
    }

    /// Sets the commands that count as the project's checks; nil restores
    /// the defaults. The hook reads them from the routing file written with
    /// the session.
    func setProjectCheckCommands(_ projectID: UUID, to commands: [String]?) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard projects[pi].checkCommands != commands else { return }
        projects[pi].checkCommands = commands
    }

    /// Sets the files Git ignores that new worktrees get a copy of; nil
    /// copies none.
    func setProjectIgnoredFilesToCopy(_ projectID: UUID, to patterns: [String]?) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard projects[pi].ignoredFilesToCopy != patterns else { return }
        projects[pi].ignoredFilesToCopy = patterns
    }

    /// Flip the per-project "route Claude's `git worktree add`" toggle.
    /// The hook receiver reads the saved value from `state.json`; flipping
    /// to false makes future Claude `git worktree add` invocations
    /// passthrough (Claude lands worktrees at its own default path
    /// instead of our placement-derived one).
    @MainActor
    func setProjectRouteClaudeWorktrees(_ projectID: UUID, to enabled: Bool) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard projects[pi].routeClaudeWorktrees != enabled else { return }
        projects[pi].routeClaudeWorktrees = enabled
    }

    /// Codex-side mirror of `setProjectRouteClaudeWorktrees`. Each
    /// agent has its own toggle so a user can route one CLI but not
    /// the other.
    @MainActor
    func setProjectRouteCodexWorktrees(_ projectID: UUID, to enabled: Bool) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard projects[pi].routeCodexWorktrees != enabled else { return }
        projects[pi].routeCodexWorktrees = enabled
    }

    /// Append a freshly-created git worktree to a project's sidebar
    /// list. Caller is responsible for actually running `git worktree
    /// add` first — this only mutates Limpid's in-memory model.
    ///
    /// Both callers add a row Limpid stands behind: New Worktree… made it,
    /// or the move suggestion adds it as the person moves a tab there, so
    /// the row is admitted as Limpid's (`WorktreeAdmission.created`). A row already kept for the same
    /// folder (one whose folder went missing and was made again, or one Git
    /// sync added first) is taken over rather than doubled: raised to
    /// Limpid's, shown again if it was hidden, and returned with its own id.
    @discardableResult
    func attachGitWorktree(
        id: UUID = UUID(),
        projectID: UUID,
        label: String,
        workingDirectory: URL,
        branchName: String?
    ) -> Worktree? {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let folder = workingDirectory.standardizedFileURL
        if let wi = projects[pi].worktrees.firstIndex(where: {
            $0.origin == .gitWorktree && $0.workingDirectory.standardizedFileURL == folder
        }) {
            projects[pi].worktrees[wi].admission = .created
            projects[pi].worktrees[wi].isHidden = false
            // It is there again, on the branch just made: not drawn as gone
            // until the next sync says so.
            projects[pi].worktrees[wi].missingSince = nil
            projects[pi].worktrees[wi].label = label
            // A name the person gave the row was for the work that was
            // there before; the row now holds a new branch, which names it.
            projects[pi].worktrees[wi].displayName = nil
            projects[pi].worktrees[wi].gitRef = branchName.map { GitRef(branchName: $0, worktreePath: workingDirectory) }
            return projects[pi].worktrees[wi]
        }
        let wt = Worktree(
            id: id,
            label: label,
            workingDirectory: workingDirectory,
            gitRef: branchName.map { GitRef(branchName: $0, worktreePath: workingDirectory) },
            origin: .gitWorktree,
            admission: .created
        )
        projects[pi].worktrees.append(wt)
        return wt
    }

    /// Admits a worktree Git only reported as one the person opened:
    /// they chose its row or opened a tab in it, so it stays among their
    /// working rows from now on, across launches. A row Limpid made, or one
    /// already opened, keeps what it has.
    func admitWorktree(projectID: UUID, worktreeID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID }),
              projects[pi].worktrees[wi].admission != .created,
              projects[pi].worktrees[wi].admission != .opened
        else { return }
        projects[pi].worktrees[wi].admission = .opened
    }

    /// Admits the worktree `container` names, when it is one and the person
    /// chose it (`admitWorktree`). Only the person's choice admits: a row
    /// moved to because another went away, or work finishing behind them,
    /// was not opened by anyone.
    func admitWorktree(_ container: ContainerID, intent: SelectionIntent) {
        guard intent == .person, case let .worktree(projectID, worktreeID) = container else { return }
        admitWorktree(projectID: projectID, worktreeID: worktreeID)
    }

    /// Move to Other Worktrees: a worktree Limpid made or the person opened
    /// goes back among the other worktrees, as one Git only reported, so a
    /// repository with no pull requests does not keep every worktree it
    /// ever made among the working rows. Its folder, branch, and tabs are
    /// left alone; a row with a tab open stays a working one regardless.
    /// Returns what it had, which Undo puts back (`readmitWorktree`); `nil`
    /// when it was not one to take out.
    @discardableResult
    func releaseWorktree(projectID: UUID, worktreeID: UUID) -> WorktreeRelease? {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID }),
              projects[pi].worktrees[wi].admission != .discovered
        else { return nil }
        let previous = projects[pi].worktrees[wi].admission
        projects[pi].worktrees[wi].admission = .discovered
        return WorktreeRelease(previous: previous)
    }

    /// Puts back the admission `releaseWorktree` took (its Undo); `nil` for a
    /// row that was not admitted yet, which the next sync admits again.
    func readmitWorktree(projectID: UUID, worktreeID: UUID, as admission: WorktreeAdmission?) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeID })
        else { return }
        projects[pi].worktrees[wi].admission = admission
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
        leaveWorktree(projectID: projectID) { $0 == worktreeID }
        return leafIDs
    }

    /// Moves every window on one of the project's worktrees that `isGone`
    /// names to the project itself: moved on, not chosen for. So does the
    /// project's view while no window shows it, which would otherwise open
    /// on a row that is gone.
    private func leaveWorktree(projectID: UUID, isGone: (UUID) -> Bool) {
        let targets = selectionTargets { container, _ in
            if case let .worktree(pid, wid) = container {
                return pid == projectID && isGone(wid)
            }
            return false
        }
        for target in targets {
            setActiveContainer(.project(projectID), at: target, intent: .repair)
        }
    }

    /// Filter-and-drop tabs in one pass, returning the pane ids that
    /// were freed. Shared by every "remove worktree row(s)" path so
    /// the `filter → flatMap → removeAll → activeTabID rewind` dance
    /// only lives in one spot.
    @discardableResult
    private func closeTabs(where predicate: (Tab) -> Bool) -> [UUID] {
        let leafIDs = tabs.filter(predicate).flatMap { $0.splitTree.allLeafIDs() }
        tabs.removeAll(where: predicate)
        for selection in selections.values {
            if let active = selection.activeTabID, !tabs.contains(where: { $0.id == active }) {
                selection.activeTabID = nil
            }
        }
        // Cleanup transient per-pane search overlays for every leaf
        // that just vanished. Without this the entries leak.
        for leafID in leafIDs {
            paneSearchStates.removeValue(forKey: leafID)
            paneTransients.removeValue(forKey: leafID)
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
        leaveWorktree(projectID: projectID) { $0 == worktreeID }
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
        leaveWorktree(projectID: projectID) { removedIDs.contains($0) }
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

    /// Whether dropping the worktree `sourceID` on worktree `worktreeID`'s
    /// row would change nothing: it is that row, already next to it on that
    /// side, or another project's (worktrees stay with their repository). The
    /// sidebar asks this before it shows a drop as possible.
    func isNoOpDrop(of sourceID: UUID, onWorktree worktreeID: UUID, projectID: UUID, position: DropPosition) -> Bool {
        guard let sourceProjectID = self.projectID(forWorktree: sourceID) else { return false }
        guard sourceProjectID == projectID else { return true }
        guard sourceID != worktreeID else { return true }
        guard let worktrees = project(projectID)?.worktrees,
              let from = worktrees.firstIndex(where: { $0.id == sourceID }),
              let to = worktrees.firstIndex(where: { $0.id == worktreeID })
        else { return false }
        switch position {
        case .before: return from == to - 1
        case .after: return from == to + 1
        }
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
        WorkspaceSession.reorderInPlace(
            in: &projects[pi].worktrees,
            sourceID: sourceID,
            target: targetID,
            position: position
        )
    }

    /// Which project (if any) currently owns the given worktree id.
    /// Used by drop targets to reject cross-project worktree drags.
    func projectID(forWorktree worktreeID: UUID) -> UUID? {
        for project in projects where project.worktrees.contains(where: { $0.id == worktreeID }) {
            return project.id
        }
        return nil
    }
}

/// Append `/.worktrees/` to the repo's local exclude file
/// (`.git/info/exclude`) if it's not already covered. We use the
/// local exclude rather than `.gitignore` so the entry stays out of
/// the user's commits — `.git/info/exclude` is git's official "per
/// repo, per developer" ignore list and is never tracked, so we can
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
    // Require BOTH markers — a half-written block (begin without
    // end) would otherwise read as "already wrote it" and leave
    // the worktrees dir un-ignored forever. `String.write(atomically:
    // true)` makes a torn write rare, but the symmetric check costs
    // nothing and matches what a future reader expects when they
    // see the paired markers a few lines above.
    if existing.contains(beginMarker), existing.contains(endMarker) {
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
                """
                Failed to update .git/info/exclude at \
                \(excludeURL.path, privacy: .private): \
                \(error.localizedDescription, privacy: .private)
                """
            )
    }
}

extension WorkspaceSession {
    /// End-to-end "Create Worktree" pipeline, the first stage of a new
    /// session: makes the new branch, adds the worktree on it off the
    /// main actor, attaches the new row and optionally opens a tab inside
    /// it, selected in `window` for `intent`. The setup is the
    /// next stage, `runSetup`, which the caller runs once the row is there,
    /// so it can show the stage and stop or skip it.
    /// Throws `CreateWorktreeError` at the worktree stage: a branch that
    /// could not be made (the name taken, a bad base) is `gitFailed`; a
    /// worktree that could not be added on the branch it made is
    /// `gitFailedLeavingBranch`, which a retry uses as an existing branch.
    ///
    /// The window and the intent stay two arguments, as in every selection:
    /// one value for both would hide the intent at the call site.
    /// `intent` is the ask's. The person's lands as theirs only while
    /// `window` still shows the row it showed when they asked: git takes a
    /// while, and one who moved to another row meanwhile, even of the same
    /// project, is left there, the new row opening behind them
    /// (`intentAfterWait`).
    @discardableResult
    func createGitWorktree( // swiftlint:disable:this function_parameter_count
        projectID: UUID,
        path: URL,
        baseBranch: String,
        newBranchName: String?,
        openTab: Bool,
        in window: WindowID,
        intent: SelectionIntent,
        git: any GitRunning = LiveGit()
    ) async throws -> Worktree {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw CreateWorktreeError.projectNotFound
        }
        if FileManager.default.fileExists(atPath: path.path) {
            throw CreateWorktreeError.pathAlreadyExists(path)
        }
        let trimmed = newBranchName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newBranch = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        if let newBranch, newBranch.hasPrefix("-") {
            throw CreateWorktreeError.invalidBranchName(newBranch)
        }
        let repoRoot = project.rootURL
        let asked = waitOrigin(in: window)
        if case .insideHidden = project.worktreePlacement {
            ensureLocalExcludeCoversWorktreesDir(repoRoot: repoRoot)
        }

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
        // The branch first, on its own: whether it was made is then known,
        // not guessed from a `-b` that may have made it before failing.
        if let newBranch {
            let branched = try await gitResult {
                try await git.createBranch(repoRoot: repoRoot, name: newBranch, startPoint: baseBranch)
            }
            guard branched.succeeded else {
                log.error("git branch failed: \(branched.stderr, privacy: .private)")
                throw CreateWorktreeError.gitFailed(stderr: CreateWorktreeError.tail(branched.stderr))
            }
        }
        let checkout = newBranch ?? baseBranch
        let result: GitResult
        do {
            result = try await withWorktreeMutationGated(pendingID) {
                try await gitResult(leavingBranch: newBranch, keeping: path) {
                    try await git.createWorktree(repoRoot: repoRoot, path: path, baseBranch: checkout, newBranchName: nil)
                }
            }
        } catch let CreateWorktreeError.timedOut(seconds, branch, kept) {
            // Something git started outlived the run and may still write in the
            // folder: it stays, and a retry stops on it rather than making a
            // new worktree that process would write into.
            if let kept {
                throw CreateWorktreeError.timedOut(seconds: seconds, branch: branch, leftover: kept)
            }
            // Stopped part way, git leaves a folder and maybe a worktree it
            // registered; a retry would stop on the folder.
            let leftover = await removeHalfMadeWorktree(at: path, repoRoot: repoRoot, git: git)
            throw CreateWorktreeError.timedOut(seconds: seconds, branch: branch, leftover: leftover)
        }
        guard result.succeeded else {
            log.error("git worktree add failed: \(result.stderr, privacy: .private)")
            let stderr = CreateWorktreeError.tail(result.stderr)
            if let newBranch {
                throw CreateWorktreeError.gitFailedLeavingBranch(stderr: stderr, branch: newBranch)
            }
            throw CreateWorktreeError.gitFailed(stderr: stderr)
        }

        // The row shows the branch checked out: the new one, or the base.
        // Label = branch name (not the folder basename). With the
        // sibling-prefixed placement the folder is `<repo>-<branch>`,
        // and we don't want the `<repo>-` prefix leaking into the
        // sidebar. The branch travels in `GitRef.branchName`; this
        // is the display string only.
        guard let wt = attachGitWorktree(
            id: pendingID,
            projectID: projectID,
            label: checkout,
            workingDirectory: path,
            branchName: checkout
        ) else {
            throw CreateWorktreeError.projectNotFound
        }
        if openTab {
            let intent = intent == .person ? intentAfterWait(from: asked) : intent
            let row = ContainerID.worktree(projectID: projectID, worktreeID: wt.id)
            setActiveContainer(row, in: window, intent: intent)
            _ = self.openTab(container: row, in: window, intent: intent, selects: true)
        }
        // Ask GitSync to settle the new row's gitRef on its next pass.
        requestSyncRefetch(projectID: projectID)
        return wt
    }

    /// Clears what a stopped `git worktree add` made at `path`: the worktree
    /// git may have registered (`git worktree remove --force`), then the
    /// folder itself if git did not know it, then git's record of a worktree
    /// whose folder is gone (`git worktree prune`). The folder can be
    /// removed outright: nothing was there before the add, which refuses a
    /// path that exists. Returns the folder when it is still there.
    private func removeHalfMadeWorktree(at path: URL, repoRoot: URL, git: any GitRunning) async -> URL? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path.path) {
            // Best effort: a folder git never registered fails here and is
            // removed below.
            _ = try? await git.removeWorktree(repoRoot: repoRoot, path: path, force: true)
        }
        if fileManager.fileExists(atPath: path.path) {
            do {
                try fileManager.removeItem(at: path)
            } catch {
                log.error("half-made worktree not removed: \(String(describing: error), privacy: .private)")
            }
        }
        // Best effort: an entry left over is pruned by git on its own later.
        _ = try? await git.pruneWorktrees(repoRoot: repoRoot)
        return fileManager.fileExists(atPath: path.path) ? path : nil
    }

    /// Runs a git call whose own failure to run (git not launched) reads as
    /// a failed run, so every failure of the worktree stage says its stage.
    /// One past its deadline says so (`CreateWorktreeError.timedOut`), with
    /// the branch made for it, which stays: it is not git's own failure,
    /// and the hooks are what to look at. When something git started
    /// outlived it, the folder at `path`, if there is one, is the leftover:
    /// it is not ours to remove while that may still write in it.
    private func gitResult(
        leavingBranch branch: String? = nil,
        keeping path: URL? = nil,
        _ run: () async throws -> GitResult
    ) async throws -> GitResult {
        do {
            return try await run()
        } catch let GitProcessError.timedOut(seconds, hasProcessesLeft) {
            let kept = path.flatMap { hasProcessesLeft && FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            throw CreateWorktreeError.timedOut(seconds: seconds, branch: branch, leftover: kept)
        } catch {
            return GitResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
    }

    /// The worktrees the sidebar shows, of every project: a new session's
    /// launch lives only while its row does (`SessionLaunchStore.prune`).
    var visibleWorktreeIDs: Set<UUID> {
        Set(projects.flatMap { $0.worktrees.filter { !$0.isHidden }.map(\.id) })
    }

    /// The setup stage: the project's bootstrap commands, run in the
    /// worktree in order from `stepIndex`, stopping at the first that
    /// fails (`WorktreeSetup`). Waited for, so an agent is not started in
    /// a tree its setup has not finished, and canceled with the task that
    /// waits, which stops the step that runs. "Retry" runs it again from
    /// the failed step, in the worktree already made; skipping the setup
    /// is not calling this. `stepIndex` counts in the project's commands
    /// as they are now; `onStep` is told the index of each as it starts.
    func runSetup(
        projectID: UUID,
        worktreeID: UUID,
        from stepIndex: Int = 0,
        path: WorktreeSetup.PathSource = WorktreeSetup.loginShellPath,
        runningSteps: WorktreeSetup.RunningSteps = WorktreeSetup.RunningSteps(),
        onStep: @escaping @MainActor @Sendable (Int) -> Void = { _ in }
    ) async throws {
        guard let project = project(projectID), let worktree = worktree(projectID: projectID, worktreeID: worktreeID) else {
            throw CreateWorktreeError.projectNotFound
        }
        let items = project.bootstrap
        guard items.indices.contains(stepIndex) else { return }
        let steps = Array(items[stepIndex...])
        let resolvedPath = try await path()
        let failure = try await WorktreeSetup.run(steps, in: worktree.workingDirectory, path: resolvedPath, steps: runningSteps) { offset in
            await onStep(stepIndex + offset)
        }
        guard let failure else { return }
        let index = stepIndex + failure.offset
        switch failure.reason {
        case let .exited(logTail):
            throw CreateWorktreeError.setupFailed(worktreeID: worktreeID, stepIndex: index, command: failure.command, logTail: logTail)
        case let .directoryOutsideWorktree(cwd):
            throw CreateWorktreeError.setupDirectoryOutsideWorktree(worktreeID: worktreeID, stepIndex: index, cwd: cwd)
        }
    }

    /// End-to-end "Delete Worktree" pipeline. Runs `git worktree
    /// remove`, then drops the row + closes its tabs. Returns the
    /// pane ids the caller should free from the registry. Throws on
    /// git failures so the caller can offer "Retry with Force" when
    /// the tree is dirty, locked, or contains initialized submodules.
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
                // The draft goes with it here too. Git having lost the
                // worktree first does not make the comments about it any more
                // current, and a new worktree at the same path would open
                // holding them.
                ReviewDraftWriter.removeDraft(root: wt.workingDirectory)
                let ids = removeWorktree(projectID: projectID, worktreeID: worktreeID)
                requestSyncRefetch(projectID: projectID)
                return ids
            }
            if !force {
                // Git protects initialized submodules even when the worktree
                // is otherwise clean. Keep that reason distinct so the Force
                // confirmation accurately describes what will be removed.
                if lower.contains("working trees containing submodules") {
                    throw DeleteWorktreeError.submodulesNeedForce
                }
                // Git prints something like "fatal: '<path>' contains
                // modified or untracked files, use --force to delete it"
                // when the tree is dirty. Surface that as a typed error so
                // the UI can offer a one-click Force retry.
                if lower.contains("modified") || lower.contains("--force") || lower.contains("locked") {
                    throw DeleteWorktreeError.dirtyNeedsForce
                }
            }
            log.error("git worktree remove failed: \(stderr, privacy: .private)")
            throw DeleteWorktreeError.gitFailed(stderr: stderr)
        }
        // On success the disk is already cleaned up; drop the row
        // and close all tabs that lived in it (per the same contract
        // as removing a project).
        let ids = removeWorktree(projectID: projectID, worktreeID: worktreeID)
        // And the review draft written against it. Kept for a worktree that is
        // merely unreachable — an unmounted volume comes back and its comments
        // should come back with it — but a deleted one is gone, and a new
        // worktree made at the same path would otherwise open holding comments
        // about code that no longer exists.
        ReviewDraftWriter.removeDraft(root: wt.workingDirectory)
        requestSyncRefetch(projectID: projectID)
        return ids
    }
}
