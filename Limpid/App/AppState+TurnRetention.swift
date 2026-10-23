// AppState+TurnRetention.swift
// Limpid — tells the retention sweep which turns a person may still need, and forgets what is kept of turns and worktrees gone.

import Foundation
import OSLog

private let log = Logger.limpid("turn.retention")

/// The count last logged, so a pass every few seconds logs it once.
@MainActor private var loggedUnreadPastAge = 0

extension AppState {
    /// Hands the projection the turns no retention limit may take and
    /// what to do once turns are gone. Here rather than in a store because
    /// what protects a turn spans Core (the read marks, the viewed lines)
    /// and Presentation (the reviews the windows have open); the decisions
    /// themselves are `TurnProtection`'s.
    func connectTurnRetention() {
        agentProjection.turnProtection = { [weak self] in self?.turnProtection() }
        agentProjection.onTurnsDeleted = { [weak self] gone, remaining in
            self?.forgetDeletedTurns(gone, remaining: remaining)
        }
        agentProjection.onTurnsDeletedIn = { [weak self] spans in
            await self?.viewedLines.noteDeletedTurns(spans) ?? false
        }
        // A project or worktree removed: what was counted of its changes
        // outside turns goes with it (`WorktreeChanges.forgetRoots`).
        knownSessionFolders = sessionFolders()
        observeRepeatedly { [weak self] in
            for project in self?.session.projects ?? [] {
                _ = project.worktrees
            }
        } onChange: { [weak self] in
            self?.forgetRemovedWorktreeChanges()
        }
        // The days and turns the person chose (Advanced), from now on
        // and whenever they change; the next pass keeps within them.
        agentProjection.turnRetention = settingsStore.settings.advanced.turnRetention.limits
        observeRepeatedly { [weak self] in
            _ = self?.settingsStore.settings.advanced.turnRetention
        } onChange: { [weak self] in
            self?.applyTurnRetention()
        }
    }

    /// Hands the chosen limits to the projection. A change that widens
    /// both takes at once; one that narrows either waits, whole, until the
    /// person has stopped changing them for `retentionNarrowingDelay`,
    /// since what it removes cannot come back: a stepper clicked once too
    /// often, or held, then turned back, removes nothing. The limits handed
    /// over are the ones scheduled; a later change cancels them and waits
    /// again. Quitting meanwhile drops the wait, and the next launch hands
    /// over what was saved, the last value the person left.
    private func applyTurnRetention() {
        pendingRetention?.cancel()
        let limits = settingsStore.settings.advanced.turnRetention.limits
        guard agentProjection.turnRetention != limits else { return }
        if TurnRetentionLimits.isNarrowing(from: agentProjection.turnRetention, to: limits) {
            pendingRetention = Task { [weak self] in
                try? await Task.sleep(for: Self.retentionNarrowingDelay)
                guard !Task.isCancelled, let self else { return }
                agentProjection.turnRetention = limits
            }
        } else {
            agentProjection.turnRetention = limits
        }
    }

    /// How long a narrower turn limit waits for the person to stop.
    static let retentionNarrowingDelay: Duration = .seconds(5)

    /// How many records `limits` would delete beyond what the saved limits
    /// do, for Advanced's confirmation (`TurnRetentionCut`), or `nil` when
    /// the rules could not say. The sweep counts them itself, so the number
    /// asked with is the one it deletes. Measured from the saved limits, not
    /// the ones the projection has yet, so a narrowing the person already
    /// confirmed is not counted again.
    func turnsRemoved(by limits: TurnRetentionLimits) async -> Int? {
        await agentProjection.turnsTaken(from: settingsStore.settings.advanced.turnRetention.limits, to: limits)
    }

    /// `nil` until a pass has reported the turns: before then no turn is
    /// known to be read, and the sweep must wait rather than guess.
    func turnProtection() -> TurnProtection? {
        // The ranges each review tab names, a closed window's kept tab
        // among them, and every range an open review has read or keeps
        // comments for (`ReviewDraftWriter.turnRanges`). A draft whose
        // review is closed is not read here: its comments say their
        // snapshots are gone if the sweep took them.
        let ranges = reviewWriters.openTurnRanges() + windowRegistry.reviewTurnRanges(in: session)
        let panes = session.tabs.flatMap { $0.splitTree.allLeafIDs() }
        let shown = Set(panes.compactMap { attention.headerRuntime(inPane: $0)?.conversation })
        let history = agentProjection.turnHistory
        let protection = TurnProtection.of(TurnProtection.Sources(
            hasLoaded: history.hasLoaded,
            history: history.conversations,
            isRead: { [self, restored = restoredTurnIDs()] in isTurnRead($0, restored: restored) },
            readAt: { [turnReads] in turnReads.reads[$0.rawValue] },
            lineMovedAt: { [viewedLines] in viewedLines.line(of: $0)?.history.last?.at },
            ranges: ranges,
            shownConversations: shown,
            openPanes: Set(panes.map(\.uuidString))
        ), now: Date())
        if let count = protection?.unreadPastAge, count != loggedUnreadPastAge {
            loggedUnreadPastAge = count
            if count > 0 {
                log.info("\(count, privacy: .public) unread turns of open sessions are past 90 days and may go")
            }
        }
        return protection
    }

    /// The read marks of deleted turns go with them, and so does the viewed
    /// line of a conversation left with no turns, with its ref.
    func forgetDeletedTurns(_ gone: [TurnID: ConversationKey?], remaining: Set<ConversationKey>) {
        turnReads.forget(gone.keys)
        worktreeChanges.forget(turns: gone.keys)
        viewedLines.forget(TurnProtection.conversationsEmptied(
            by: gone,
            remaining: remaining,
            history: agentProjection.turnHistory.conversations
        ))
    }

    /// Keeps the changes outside turns counted only for the top levels of
    /// the folders the projects hold now, hidden worktrees included, and of
    /// the reviews open, which may read a folder of no project.
    private func forgetRemovedWorktreeChanges() {
        var live = Set(windowRegistry.windows.compactMap(\.review?.root))
        for project in session.projects {
            let folders = [project.rootURL] + project.worktrees.map(\.workingDirectory)
            for folder in folders {
                if case let .repository(path) = repositoryRoots.answer(for: folder) {
                    live.insert(path)
                }
            }
        }
        worktreeChanges.forgetRoots(except: live)
        forgetRemovedWorktreeSpans()
    }

    /// Lets go of the deleted turns' spans of the worktrees the person
    /// removed since the last change, with their project or alone. Only
    /// a removal does: a worktree merely missing keeps its row, and its
    /// spans with it (`ViewedLineStore.forgetDeletedTurns(where:)`).
    private func forgetRemovedWorktreeSpans() {
        let folders = sessionFolders()
        let removed = knownSessionFolders.subtracting(folders)
        knownSessionFolders = folders
        guard !removed.isEmpty else { return }
        viewedLines.forgetDeletedTurns { [worktreePaths] spelled in
            Self.isRemovedRoot(worktreePaths.resolved(spelled), removed: removed, kept: folders)
        }
    }

    /// Whether the worktree at `root` went with the folders `removed`: it
    /// is one of them, in one, or holds one, and holds none of `kept`. One
    /// inside a project folder still kept goes all the same, as a
    /// project's worktrees often live in its folder.
    static func isRemovedRoot(_ root: String, removed: Set<String>, kept: Set<String>) -> Bool {
        removed.contains { RepositoryPath.overlaps(root, $0) }
            && !kept.contains { RepositoryPath.contains(root, $0) }
    }

    /// Returns every project's folder and its worktrees', hidden ones
    /// included, spelled with their links resolved.
    private func sessionFolders() -> Set<String> {
        Set(session.projects.flatMap { [$0.rootURL] + $0.worktrees.map(\.workingDirectory) }.map {
            worktreePaths.resolved($0.path)
        })
    }
}
