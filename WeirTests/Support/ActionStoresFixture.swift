// ActionStoresFixture.swift
// Weir — the stores the changes panel's and the review tab's actions are handed, made of test doubles.

import Foundation
@testable import Weir

/// One project's window and the stores its changes panel and review tab
/// read, none of which reads Git or writes a file: each folder is its own
/// top level (`RepositoryRoots.staged`), the worktree counts are inert, and
/// the lines and drafts stay in memory. What the actions would open in the
/// review is recorded rather than opened.
@MainActor
final class ActionStoresFixture {
    let session: WorkspaceSession
    let project: Project
    let windows: WindowRegistry
    let repositoryRoots: RepositoryRoots
    let worktreeChanges = WorktreeChanges(git: .inert(counts: nil))
    let turnHistory = TurnHistory()
    let viewedLines = ViewedLineStore(directory: URL(fileURLWithPath: "/nonexistent"), writesFiles: false)
    let attention = AttentionState()
    let attentionQueue = AttentionQueueStore()
    let toasts = ToastCenter()
    /// The colors, read from this fixture's own stores, with no turn
    /// restored.
    lazy var conversationIdentities = ConversationIdentityStore(
        paletteCount: SupervisionTokens.conversationIdentity.count,
        sources: ConversationIdentityStore.Sources(
            session: session,
            repositoryRoots: repositoryRoots,
            turnHistory: turnHistory,
            viewedLines: viewedLines,
            attention: attention,
            restoredTurnIDs: { [] }
        )
    )
    let registry = RecordingSurfaceRegistry()
    let reviewWriters = ReviewDraftWriterPool(shouldPersist: false)
    let restores = RestoreCoordinator(stateDirectories: [])
    let laterTurns = ReviewLaterTurns()
    /// Whether Weir is in front.
    var isAppActive = true
    /// One open the review was asked for.
    struct Opened {
        let request: ReviewTabRequest
        let pane: UUID?
        let conversation: ConversationKey?
    }

    /// What the review was asked to open, in order.
    private(set) var opened: [Opened] = []
    /// The Git top level of a folder: the folder itself, unless a test says
    /// otherwise.
    var gitRoot: (URL) async throws -> URL = { $0 }

    /// `opensTab`: whether the project's folder has a tab open, which the
    /// panel's turns do not need but the panes its actions find do.
    /// `repositoryRoots` answers each folder's top level: the folder
    /// itself unless a test hands one that says otherwise.
    init(opensTab: Bool = true, repositoryRoots: RepositoryRoots = .staged()) {
        self.repositoryRoots = repositoryRoots
        let (session, project) = WorkspaceSessionFixture.withProject()
        self.session = session
        self.project = project
        session.setActiveContainer(.project(project.id))
        if opensTab {
            _ = session.openTab(container: .project(project.id))
        }
        windows = WindowRegistry(primary: session.primarySelection, worktreePaths: WorktreePathResolver(resolveLinks: { $0 }))
    }

    var window: ProjectWindowState {
        windows.primary
    }

    /// The project's folder, which is its own top level here.
    var root: String {
        project.rootURL.path
    }

    var changes: ChangesPanelStores {
        ChangesPanelStores(
            session: session,
            repositoryRoots: repositoryRoots,
            worktreeChanges: worktreeChanges,
            turnHistory: turnHistory,
            viewedLines: viewedLines,
            attention: attention,
            attentionQueue: attentionQueue,
            toasts: toasts,
            conversationIdentities: conversationIdentities,
            isAppActive: { [unowned self] in isAppActive },
            restoredTurnIDs: { [] },
            restoreGateLookup: { RestoreGateLookup(tabs: [], runtimes: [], waitingPanes: [], isBusy: { _ in false }) },
            restoreRecord: { _ in nil },
            openReview: { [unowned self] request, pane, conversation, _ in
                opened.append(Opened(request: request, pane: pane, conversation: conversation))
            },
            registry: registry,
            paneVisibility: { _ in PaneVisibilityReporter() }
        )
    }

    var review: ReviewTabStores {
        ReviewTabStores(
            changes: changes,
            windows: windows,
            registry: registry,
            reviewWriters: reviewWriters,
            primaryKeyHint: PrimaryKeyHint(defaults: nil),
            locale: { Locale(identifier: "en") },
            gitRoot: { [unowned self] in try await gitRoot($0) },
            hunks: ReviewHunkDiscardStores(
                session: session,
                windows: windows,
                toasts: toasts,
                turnHistory: turnHistory,
                worktreePaths: WorktreePathResolver(resolveLinks: { $0 }),
                restores: restores,
                restoreGateInput: { RestoreGate.Input(turn: $0, agents: [], isWaiting: false, isRestoring: false) },
                laterTurns: laterTurns
            )
        )
    }

    /// A finished turn of `conversation` recorded in the project's folder,
    /// with its trees there.
    func turn(_ id: String, number: Int, conversation: String = "s1", startedAt: String) throws -> TurnSummary {
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = conversation
        extras.startedAt = startedAt
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("b", number), root: root)
        return try TurnSummaryFixture.turn(
            id,
            changes: TurnSummaryFixture.changedFiles,
            number: number,
            endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", number), root: root),
            extras: extras
        )
    }

    /// The turns the projection reports, each conversation's in order.
    func record(_ turns: [TurnSummary]) {
        let byConversation = Dictionary(grouping: turns, by: \.conversation)
        turnHistory.replace(with: byConversation.map { ConversationTurns(key: $0.key, turns: $0.value) })
    }
}
