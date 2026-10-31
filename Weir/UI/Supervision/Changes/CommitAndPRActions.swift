// CommitAndPRActions.swift
// Weir — what the changes panel's "Commit & PR" reads from the app and what its buttons do.

import Foundation
import WeirDomain

/// The "Commit & PR" section's way to the app: the session's Git facts, its
/// pull request, and its agents read into `CommitAndPRModel`, and the tabs
/// and the review its buttons open.
@MainActor
enum CommitAndPRActions {
    /// The command "Create PR" runs: gh fills the title and body from the
    /// commits and asks before it pushes, in a tab the person reads.
    static let createPullRequestCommand = "gh pr create --fill"

    static func model(window: ProjectWindowState, state: AppState) -> CommitAndPRModel {
        let session = state.session
        let container = window.selection.activeContainerID
        let panes = session.paneIDs(in: container)
        let items = state.attentionQueue.queue.items.filter { $0.subject.paneID.map(panes.contains) ?? false }
        let root = ChangesPanelActions.root(window: window, stores: state.changesPanelStores)
        // A worktree gone from disk has nothing to clean up here; the
        // sidebar removes its row.
        let worktree = container.projectID.flatMap { projectID in
            container.worktreeID.flatMap { session.worktree(projectID: projectID, worktreeID: $0) }
        }
        return CommitAndPRModel.make(CommitAndPRModel.Input(
            facts: state.gitFacts.facts(for: container),
            pullRequest: state.prStatusStore.info(for: container),
            hasGitHubCLI: state.prStatusStore.forge(for: container) == .gitHub,
            isWorktree: worktree.map { !$0.isMissing } ?? false,
            unviewedTurns: ChangesPanelActions.unviewedCount(window: window, stores: state.changesPanelStores),
            isWaiting: CommitAndPRModel.isWaiting(items),
            isRunning: state.attention.isAgentMidTurn(inPanes: panes),
            unviewedOutsideTurns: root.map {
                WorktreeChanges.unviewed(
                    state.worktreeChanges.outsideTurnsContents[$0] ?? [:],
                    viewed: state.viewedLines.outsideTurns[$0]
                ).count
            } ?? 0,
            externalCommand: state.settingsStore.settings.review.externalDiffCommand
        ))
    }

    static func createPullRequest(window: ProjectWindowState, state: AppState) {
        TabActions.newTab(
            state.session,
            in: window.selection.activeContainerID,
            typing: createPullRequestCommand,
            window: window.id,
            intent: .person,
            selects: true
        )
    }

    static func open(_ tool: CommitAndPRModel.ExternalTool, window: ProjectWindowState, state: AppState) {
        TabActions.newTab(
            state.session,
            in: window.selection.activeContainerID,
            typing: tool.command,
            window: window.id,
            intent: .person,
            selects: true
        )
    }

    /// "Show Current Diff": the review on what is uncommitted, staged,
    /// unstaged, and untracked, changes outside turns included,
    /// opened from the conversation the panel's filter narrows the
    /// timeline to, as its rows open theirs, so the review knows its turns
    /// and where comments go: no pane when that agent runs no more, as the
    /// rows open it, rather than another agent's. The focused pane while
    /// the panel shows every conversation.
    static func showCurrentDiff(window: ProjectWindowState, state: AppState) {
        let conversation: ConversationKey? = if case let .turns(list) = ChangesPanelActions.content(
            window: window,
            stores: state.changesPanelStores
        ) {
            list.filter
        } else {
            nil
        }
        let pane = if let conversation {
            ChangesPanelActions.pane(of: conversation, window: window, stores: state.changesPanelStores)
        } else {
            state.session.activeTab(in: window.id)?.splitTree.effectiveFocusedLeafID
        }
        Task {
            await ReviewTabActions.open(
                .uncommitted,
                agentPaneID: pane,
                conversation: conversation,
                window: window,
                stores: state.reviewTabStores
            )
        }
    }

    /// What "Clean Up Worktree…" found.
    enum CleanUp {
        /// The worktree holds work no remote has, or Git did not answer:
        /// why, in words.
        case blocked(String)
        /// Nothing stops it: the current confirmation for deleting it.
        case confirm(DeleteWorktreeTarget)
    }

    /// Reads the worktree's facts again before deciding, since what was
    /// pushed or committed since the last reading is what matters here.
    /// `nil` when the session is no worktree any more, or the person moved
    /// to another session, or closed the window, while Git answered
    /// (`WorkspaceSession.intentAfterWait(from:)`): the answer is about one they no
    /// longer look at.
    static func cleanUp(window: ProjectWindowState, state: AppState, locale: Locale) async -> CleanUp? {
        let session = state.session
        let container = window.selection.activeContainerID
        guard let projectID = container.projectID, let worktreeID = container.worktreeID,
              let worktree = session.worktree(projectID: projectID, worktreeID: worktreeID)
        else { return nil }
        let asked = session.waitOrigin(in: window.id)
        let read = await state.gitFacts.read(container, at: worktree.workingDirectory)
        guard session.intentAfterWait(from: asked) == .person else { return nil }
        let facts: GitFacts
        switch read {
        case let .facts(read):
            facts = read
        case .notWorkTree:
            return .blocked(CommitAndPRText.notWorkTree(locale: locale))
        case .unanswered:
            return .blocked(CommitAndPRText.gitDidNotAnswer(locale: locale))
        }
        if let blocker = CommitAndPRModel.cleanUpBlocker(facts) {
            return .blocked(CommitAndPRText.cleanUpBlocked(
                unpushed: blocker.unpushed,
                uncommitted: blocker.uncommitted,
                locale: locale
            ))
        }
        return .confirm(DeleteWorktreeTarget(
            projectID: projectID,
            worktreeID: worktreeID,
            label: worktree.label,
            path: worktree.workingDirectory
        ))
    }
}
