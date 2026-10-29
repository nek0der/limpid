// DemoSceneTests.swift
// Limpid — the demo's scene as the attention list and the sidebar build it: six items, and each row's state.

import Foundation
import Testing
@testable import Limpid

/// The fixture is put together the way the app puts it together at launch
/// (stand-in runtimes, staged turns, staged viewed lines, Git facts, pull
/// requests), and what the hero shows is read back through the same rules
/// the windows use. A change to those rules that would change the hero fails
/// here before the image does.
@MainActor
struct DemoSceneTests {
    private static let english = Locale(identifier: "en")

    /// What the scene is built from.
    private struct Scene {
        let session: WorkspaceSession
        let runtimes: [AgentRuntimePresentation]
        let queue: AttentionQueue

        /// The sidebar's rows for one of the snapshot's projects.
        @MainActor func rows(_ projectID: UUID) throws -> [SessionSidebarModel.Row] {
            let project = try #require(session.project(projectID))
            return SessionSidebarModel(
                project: project,
                session: session,
                queue: queue,
                runtimes: runtimes,
                approvals: ApprovalLedger(),
                pullRequest: { DemoFixture.prStatus[$0] },
                gitFacts: { DemoFixture.gitFacts[$0] },
                locale: DemoSceneTests.english
            ).rows
        }
    }

    private static func scene() -> Scene {
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        let staged = DemoFixture.stagedProjection
        let attention = AttentionState()
        AgentProjectionAdapter.seedRuntimes(fromBadgesIn: session, into: attention, conversation: staged.conversation)
        // A demo run's store, which writes nothing wherever it is pointed.
        let lines = ViewedLineStore(directory: FileManager.default.temporaryDirectory, writesFiles: false)
        staged.markViewedLines(in: lines)
        let history = Dictionary(uniqueKeysWithValues: staged.turns.map { ($0.key, $0.turns) })
        let runtimes = attention.allRuntimes
        let unread = UnreadTurnRules.byRuntime(runtimes.map(UnreadTurnRules.Run.init), history: history) { lines.isViewed($0) }
        let input = AttentionQueueStore.makeInput(
            runtimes: runtimes,
            isRead: { attention.isViewed($0) },
            unreadTurns: unread,
            approvals: [],
            session: session,
            isApprovalServiceRunning: false
        )
        return Scene(session: session, runtimes: runtimes, queue: AttentionQueueReducer.reduce(AttentionQueue(), input: input).0)
    }

    /// "Needs Attention 6": two approvals at an agent's own prompt, one stop,
    /// and three unread items, in amber since some of them block. An
    /// approval Limpid does not hold is counted with the held ones.
    @Test func theScene_needsAttentionSix_twoPromptsOneStopThreeUnread() {
        let counts = Self.scene().queue.counts()
        #expect(counts == AttentionCounts(approvals: 2, questions: 0, prompts: 0, stops: 1, unread: 3))
        #expect(counts.total == 6)
        #expect(NeedsAttentionPillModel(counts).style == .blocking)
        #expect(AttentionSummaryText.breakdown(counts, locale: Self.english) == ["2 Approvals", "1 Stopped", "3 Unread"])
    }

    /// In order of arrival: the review's answer, the stop, the reminders'
    /// turns (when T4 ended), pdf-worker's wait, Codex's turn in the
    /// reminders worktree, then the tax-rounding wait.
    @Test func theItems_areInOrderOfArrival() {
        let panes = Self.scene().queue.items.map(\.subject.paneID)
        #expect(panes == [
            DemoFixture.Slot.prReview.paneID,
            DemoFixture.Slot.webhook.paneID,
            DemoFixture.Slot.reminders.paneID,
            DemoFixture.Slot.pageBreaks.paneID,
            DemoFixture.Slot.remindersCodex.paneID,
            DemoFixture.Slot.taxRounding.paneID
        ])
    }

    /// The decision bar's receipt: T4–T5, four files, +136 −13, and the last
    /// check of the range, T5's, passing on filtered tests.
    @Test func theSelectedAgentsItem_isT4ToT5_withItsChangesSummed_andT5sPassingCheck() throws {
        let item = try #require(Self.scene().queue.items.first { $0.subject.paneID == DemoFixture.Slot.reminders.paneID })
        guard case let .unread(turn) = item.kind else {
            Issue.record("expected the reminders agent's turns, not \(item.kind)")
            return
        }
        #expect(turn.numbers == 4...5)
        #expect(turn.changes == .changed(files: 4, added: 136, removed: 13))
        #expect(turn.check?.exitCode == 0)
        #expect(turn.check?.isFiltered == true)
        #expect(turn.conversation == DemoFixture.remindersConversation)
    }

    /// The review's item is its second answer alone; its first is viewed.
    @Test func theReviewsItem_isItsSecondAnswer() throws {
        let item = try #require(Self.scene().queue.items.first { $0.subject.paneID == DemoFixture.Slot.prReview.paneID })
        guard case let .unread(turn) = item.kind else {
            Issue.record("expected the review's answer, not \(item.kind)")
            return
        }
        #expect(turn.numbers == 2...2)
        #expect(turn.changes == .unchanged)
    }

    /// duesmith's sidebar: each working row's name, state, and second line.
    @Test func duesmithsRows_readAsTheSceneSays() throws {
        let rows = try Self.scene().rows(DemoFixture.duesmithProjectID).filter { $0.section == .working }
        // The working worktrees, then the folder, which the review is in.
        #expect(rows.map(\.name) == [
            "feat/overdue-reminders",
            "fix/tax-rounding",
            "feat/proration",
            "fix/webhook-timeout",
            "docs/invoices-api",
            "main"
        ])
        // Each is named by its branch, not by a label the person gave, so
        // no second line starts with the row's branch.
        #expect(rows.allSatisfy { $0.checkout == nil })
        #expect(rows.map(\.factText) == [
            "Unread · 4 files changed",
            "Waiting for approval: tsc",
            "Bash: pnpm test src/billing",
            "Stopped: API Error: Request timed out.",
            "PR #324 · Open",
            "Unread · No file changes"
        ])
        #expect(rows.map(\.fact.glyph) == [.unread, .needsApproval, .running, .stopped, .idle, .unread])
        let agents: [AgentKind] = [.claude, .codex, .claude, .claude, .codex, .codex]
        #expect(rows.map(\.fact.badge) == agents.map(SessionRowFact.Badge.agent))
        #expect(rows.map(\.fact.fact) == [
            .unread(.changed(files: 4, added: 136, removed: 13)),
            .prompt(PromptWait(detail: "Bash: tsc")),
            .running("Bash: pnpm test src/billing"),
            .stopped(.error("API Error: Request timed out.")),
            .pullRequest(number: 324, state: .open, isDraft: false),
            .unread(.unchanged)
        ])
        #expect(rows.map(\.isActive) == [true, false, false, false, false, false])
        // The marks on the right: the running agent's draft beside its
        // action, and the open request that is the docs row's second line.
        #expect(rows.map(\.fact.pullRequest) == [
            nil,
            nil,
            SessionRowFact.PullRequest(number: 326, state: .open, isDraft: true),
            nil,
            SessionRowFact.PullRequest(number: 324, state: .open, isDraft: false),
            nil
        ])
    }

    /// Under duesmith's working rows: the merged worktree with nothing open,
    /// ready to clean up, then the agents' own worktrees, one with a closed
    /// request, and the detached one, which goes by its folder.
    @Test func duesmithsFoldedSections_holdTheMergedWorktree_andTheOthers() throws {
        let rows = try Self.scene().rows(DemoFixture.duesmithProjectID).filter { $0.section != .working }
        #expect(rows.map(\.section) == [.cleanable, .other, .other, .other, .other, .other])
        #expect(rows.map(\.name) == [
            "fix/csv-export",
            "worktree-agent-3f2a91", "worktree-agent-7c0d44", "worktree-agent-a19e5b", "worktree-agent-e62b07",
            "duesmith-bisect"
        ])
        #expect(rows.first?.factText == "PR #311 · Merged")
        // The closed request stays folded with its agent's worktree.
        #expect(rows.map { $0.fact.pullRequest?.state } == [.merged, nil, nil, .closed, nil, nil])
    }

    /// The window folds pdf-worker, whose header then carries the wait in
    /// it, and keeps the order the projects were opened in.
    @Test func theWindow_foldsPdfWorker_withItsWaitOnTheHeader() throws {
        let window = try #require(DemoFixture.snapshot.windows.first)
        #expect(window.sidebar?.projectOrder == [
            DemoFixture.duesmithProjectID, DemoFixture.pdfWorkerProjectID, DemoFixture.dotfilesProjectID
        ])
        #expect(window.sidebar?.collapsedProjects == [DemoFixture.pdfWorkerProjectID])
        #expect(window.sidebar?.openSections.isEmpty == true)
        let pdf = try Self.scene().rows(DemoFixture.pdfWorkerProjectID)
        #expect(pdf.contains { $0.fact.glyph == .needsApproval })
    }

    /// pdf-worker's and dotfiles' rows: a wait, an idle agent with a merged
    /// request, and the folder's shell; and dotfiles' shell alone.
    @Test func theOtherProjectsRows_readAsTheSceneSays() throws {
        let scene = Self.scene()
        let pdf = try scene.rows(DemoFixture.pdfWorkerProjectID)
        #expect(pdf.map(\.name) == ["fix/page-breaks", "feat/batch-render", "main"])
        #expect(pdf.map(\.fact.glyph) == [.needsApproval, .idle, .shell])
        #expect(pdf.map(\.factText) == ["Waiting for approval: cargo test -p layout", "PR #57 · Merged", "Folder"])
        #expect(pdf.allSatisfy { $0.checkout == nil })
        let dotfiles = try scene.rows(DemoFixture.dotfilesProjectID)
        #expect(dotfiles.map(\.name) == ["main"])
        #expect(dotfiles.map(\.fact.glyph) == [.shell])
    }
}
