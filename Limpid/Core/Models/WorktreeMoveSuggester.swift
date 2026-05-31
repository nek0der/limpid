// WorktreeMoveSuggester.swift
// Limpid — turns a `CwdChanged` hook event into a worktree-move
// suggestion when the agent moved into a directory the pane's current
// tab doesn't own. Decision flow:
//
//   1. Case A — newCwd is inside a registered worktree of the source
//      project. Two sub-outcomes:
//        a. source tab already lives in that worktree → no-op
//        b. source tab lives elsewhere → reparent the source tab
//      Either way, case A is exhaustive: we do NOT fall to case B.
//      Conflating these two with a single `nil` is what produced the
//      duplicate-worktree-row regression in an earlier draft.
//   2. Case B — newCwd is not inside any registered worktree, but
//      `git worktree list` proves it is a worktree of a project we
//      track. Attach the row, then reparent.
//   3. Otherwise (not a worktree path, no matching project, etc.)
//      a no-op.
//
// Per-pane dismissals are remembered for the lifetime of the run so a
// "Cancel" doesn't keep re-prompting on later `cd`s into the same dir.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "worktree.move.suggester")

@MainActor
@Observable
final class WorktreeMoveSuggester {
    /// Currently visible suggestion, if any. A SwiftUI banner observes
    /// this and binds OK/Cancel back to `accept()` / `dismiss()`.
    var current: WorktreeMoveSuggestion?

    private weak var session: WindowSession?
    /// Per-(pane, path) keys the user has actively dismissed. We keep
    /// these for the rest of the run so a Cancel sticks across more
    /// `cd`s into the same dir.
    private var suppressed: Set<SuppressionKey> = []
    /// Coalesce concurrent resolves on the same key. Without this a
    /// burst of two CwdChanged events (rapid `cd a && cd b && cd a`)
    /// could file two suggestions for the same path.
    private var inFlight: Set<SuppressionKey> = []
    /// Suggestions parked because the source tab wasn't active when
    /// the cd landed. Keyed by source tab id — the agent only ever
    /// lives in one cwd at a time, so a newer cd in the same tab
    /// supersedes any older one parked here.
    /// Surfaces on the next `activeTabDidChange` for that tab id.
    private var pending: [UUID: WorktreeMoveSuggestion] = [:]

    private struct SuppressionKey: Hashable {
        let paneID: UUID
        let path: String
    }

    func bind(session: WindowSession) {
        self.session = session
    }

    // MARK: - Entry point

    /// Called by `CwdEventTracker` for every fresh hook record. Runs
    /// the cheap matchers on the MainActor, then hops off-actor for the
    /// `git worktree list` shell-out before publishing the suggestion.
    func handleEvent(_ record: CwdEventRecord) {
        guard let session,
              let paneID = UUID(uuidString: record.paneId),
              !record.newCwd.isEmpty
        else { return }
        let newCwd = record.newCwd
        let key = SuppressionKey(paneID: paneID, path: newCwd)
        guard !suppressed.contains(key), !inFlight.contains(key) else { return }

        guard let resolved = resolveSourceTab(paneID: paneID, in: session) else { return }
        let (sourceTab, sourceProjectID) = resolved
        guard let sourceProject = session.projects.first(where: { $0.id == sourceProjectID }) else { return }
        let sourceTabID = sourceTab.id

        // Case A: cheap in-memory match against the active project's
        // registered worktrees. The 3-state result tells handleEvent
        // whether case B is even allowed to run — a registered match
        // (with or without an action) ends the lookup here.
        switch Self.matchRegisteredWorktree(
            newCwd: newCwd,
            sourceTab: sourceTab,
            sourceProject: sourceProject
        ) {
        case .alreadyInsideSourceWorktree:
            return
        case let .reparentTo(kind):
            let suggestion = WorktreeMoveSuggestion(
                paneID: paneID,
                newCwd: URL(fileURLWithPath: newCwd),
                kind: kind
            )
            queueOrSurface(suggestion, sourceTabID: sourceTabID, in: session)
            return
        case .noRegisteredWorktreeContains:
            break
        }

        // Case B: shell out to discover unregistered worktrees. The
        // newCwd may not be a git path at all — that path returns
        // nothing and the suggestion stays nil.
        inFlight.insert(key)
        let projectsSnapshot = session.projects.map { ($0.id, $0.rootURL) }
        Task { [weak self] in
            let suggestion = await Self.resolveUnregisteredWorktree(
                paneID: paneID,
                newCwd: newCwd,
                projects: projectsSnapshot
            )
            await MainActor.run {
                guard let self else { return }
                self.inFlight.remove(key)
                guard let suggestion, let session = self.session else { return }
                self.queueOrSurface(suggestion, sourceTabID: sourceTabID, in: session)
            }
        }
    }

    /// Show the suggestion immediately when its source tab is what
    /// the user is currently looking at; otherwise park it under
    /// `pending` so an `activeTabDidChange` for that source tab can
    /// surface it later. A suggestion already on `current` is left
    /// alone — the user is reading it, and a fresh park supersedes
    /// any older one for the same source tab.
    private func queueOrSurface(
        _ suggestion: WorktreeMoveSuggestion,
        sourceTabID: UUID,
        in session: WindowSession
    ) {
        if session.activeTabID == sourceTabID, current == nil {
            current = suggestion
        } else {
            pending[sourceTabID] = suggestion
        }
    }

    /// Called by `WorktreeMoveSuggestionHost` on every `activeTabID`
    /// change. Three-step:
    ///   1. If a visible suggestion's source tab is not the new
    ///      active tab, re-park it. Leaving it visible would re-open
    ///      the "which tab is this about?" ambiguity the gating was
    ///      meant to fix.
    ///   2. If `current` is now empty and the new active tab has a
    ///      parked suggestion, surface it.
    ///   3. Drop parked entries whose source tab no longer exists.
    ///      `closeTab` doesn't notify the suggester (parked entries
    ///      are keyed by tab id, not pane id) so the cleanup rides
    ///      this signal instead.
    func activeTabDidChange(to tabID: UUID?) {
        if let visible = current,
           let session,
           let srcTab = session.tab(containing: visible.paneID),
           srcTab.id != tabID
        {
            pending[srcTab.id] = visible
            current = nil
        }
        if current == nil, let tabID, let parked = pending.removeValue(forKey: tabID) {
            // Drop the parked entry if its source pane has since died —
            // the cd is moot if the agent that triggered it is gone.
            if let session, session.tab(containing: parked.paneID) != nil {
                current = parked
            }
        }
        if let session {
            pending = pending.filter { session.tab($0.key) != nil }
        }
    }

    // MARK: - User actions

    /// User clicked OK. Reclassifies the source pane's tab to the
    /// target worktree container so the running Claude session
    /// follows the cwd change without a pty respawn. Empty
    /// auto-spawned tabs that already lived in the target container
    /// are left alone — the user can close them manually if they
    /// don't want the extra slot.
    func accept() {
        guard let suggestion = current, let session else { return }
        current = nil
        guard let sourceTab = session.tab(containing: suggestion.paneID) else { return }
        let target: (projectID: UUID, worktreeID: UUID)
        switch suggestion.kind {
        case let .reparentToRegistered(pid, wid, _):
            target = (pid, wid)
        case let .reparentAfterAttach(pid, path, branchName, label):
            guard let wt = session.attachGitWorktree(
                projectID: pid,
                label: label,
                workingDirectory: path,
                branchName: branchName
            ) else { return }
            target = (pid, wt.id)
        }
        let newContainer: ContainerID = .worktree(
            projectID: target.projectID,
            worktreeID: target.worktreeID
        )
        // Reparent the source tab. The Claude pane keeps its pty (the
        // SurfaceView in the registry is keyed by paneID, not by
        // tabID, so a container swap doesn't tear it down).
        session.update(sourceTab.id) { $0.container = newContainer }
        session.setActiveContainer(newContainer)
        session.setActiveTab(sourceTab.id)
    }

    /// User clicked Cancel. Suppress further suggestions for the same
    /// (pane, path) pair until the app relaunches.
    func dismiss() {
        guard let suggestion = current else { return }
        suppressed.insert(SuppressionKey(
            paneID: suggestion.paneID,
            path: suggestion.newCwd.path
        ))
        current = nil
    }

    // MARK: - Synchronous matchers

    /// Walk every tab to locate the pane's owning tab, plus the project
    /// id the tab points at. We can't suggest anything when the tab
    /// isn't tied to a project (loose tabs, plain groups).
    private func resolveSourceTab(
        paneID: UUID,
        in session: WindowSession
    ) -> (Tab, UUID)? {
        for tab in session.tabs where tab.splitTree.allLeafIDs().contains(paneID) {
            guard let projectID = tab.container.projectID else { return nil }
            return (tab, projectID)
        }
        return nil
    }

    /// Outcome of the case A matcher. The three states let
    /// `handleEvent` decide both whether to surface a banner AND
    /// whether case B is still appropriate. Conflating "no match" with
    /// "matched, source already there" used to land case B with the
    /// path of a registered worktree and produce duplicate rows in
    /// `attachGitWorktree`.
    enum RegisteredMatch: Equatable {
        /// No registered worktree of the project contains `newCwd`.
        /// Case B may run.
        case noRegisteredWorktreeContains
        /// `newCwd` is inside the worktree the source tab already
        /// owns. No banner, and case B must NOT run (the path is
        /// already covered by a registered row).
        case alreadyInsideSourceWorktree
        /// `newCwd` is inside a registered worktree other than the
        /// source tab's container. Surface the carried kind.
        case reparentTo(WorktreeMoveSuggestion.Kind)
    }

    /// Case A matcher. Picks the longest-prefix registered worktree
    /// whose path contains `newCwd`, then classifies the outcome.
    static func matchRegisteredWorktree(
        newCwd: String,
        sourceTab: Tab,
        sourceProject: Project
    ) -> RegisteredMatch {
        // Pick the worktree whose path is the longest prefix of newCwd
        // so a nested worktree wins over its parent main clone.
        var bestMatch: Worktree?
        var bestLength = 0
        for wt in sourceProject.worktrees where !wt.isHidden {
            let wtPath = wt.workingDirectory.path
            if pathIsInsideStatic(newCwd, of: wtPath), wtPath.count > bestLength {
                bestMatch = wt
                bestLength = wtPath.count
            }
        }
        guard let target = bestMatch else { return .noRegisteredWorktreeContains }
        if case let .worktree(_, wid) = sourceTab.container, wid == target.id {
            return .alreadyInsideSourceWorktree
        }
        return .reparentTo(.reparentToRegistered(
            projectID: sourceProject.id,
            worktreeID: target.id,
            label: target.label
        ))
    }

    // MARK: - Async (case B) resolution

    /// Run `git worktree list --porcelain` against `newCwd`. The
    /// porcelain output's first block is always the main worktree, so
    /// matching its path against the registered projects tells us which
    /// project owns `newCwd`. Nonisolated so it can run off the
    /// MainActor without capturing UI state.
    private static func resolveUnregisteredWorktree(
        paneID: UUID,
        newCwd: String,
        projects: [(UUID, URL)]
    ) async -> WorktreeMoveSuggestion? {
        let url = URL(fileURLWithPath: newCwd)
        let list: [GitWorktreeInfo]
        do {
            list = try await GitWorktreeList.fetch(repoRoot: url)
        } catch {
            log.debug("git worktree list failed at \(newCwd, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
        guard !list.isEmpty else { return nil }
        // Main worktree is the first entry; match it against the
        // registered project rootURLs.
        let mainPath = standardize(list[0].path.path)
        guard let project = projects.first(where: { standardize($0.1.path) == mainPath }) else {
            return nil
        }
        // Locate the worktree entry that contains newCwd (longest
        // prefix wins for the same nesting reason as case A).
        var bestMatch: GitWorktreeInfo?
        var bestLength = 0
        for info in list {
            let p = info.path.path
            if pathIsInsideStatic(newCwd, of: p), p.count > bestLength {
                bestMatch = info
                bestLength = p.count
            }
        }
        guard let info = bestMatch else { return nil }
        // The main worktree is the project root — moving into it isn't
        // a "worktree" suggestion (the project already owns it). The
        // existing PWD action surfaces the cwd there.
        if standardize(info.path.path) == mainPath {
            return nil
        }
        let label = info.branch ?? info.path.lastPathComponent
        return WorktreeMoveSuggestion(
            paneID: paneID,
            newCwd: url,
            kind: .reparentAfterAttach(
                projectID: project.0,
                path: info.path,
                branchName: info.branch,
                label: label
            )
        )
    }

    // MARK: - Path helpers

    private func pathIsInside(_ child: String, of parent: String) -> Bool {
        Self.pathIsInsideStatic(child, of: parent)
    }

    private static func pathIsInsideStatic(_ child: String, of parent: String) -> Bool {
        let c = standardize(child)
        let p = standardize(parent)
        if c == p { return true }
        return c.hasPrefix(p + "/")
    }

    /// Trim a trailing slash so `/a` and `/a/` compare equal. We do
    /// not resolve symlinks — the hook reports paths the agent sees,
    /// and resolving would force a stat on every event.
    private static func standardize(_ path: String) -> String {
        var s = path
        while s.count > 1, s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
