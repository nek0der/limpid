// DemoFixtureTests.swift
// Limpid — CI guard for the fixed demo session that powers the hero screenshot.
//
// We don't anchor on every pane's text (that drifts with copy edits), only on
// the structure the screenshot pipeline and AGENTS.md promise: three
// projects, the selected worktree and tab, the window's layout, rows named by
// their agents' tabs, the shell directory the script starts in, the pull
// requests, the staged turns, the schema version, and a clean JSON round-trip.

import Foundation
import Testing
@testable import Limpid

@Suite("DemoFixture")
@MainActor
struct DemoFixtureTests {
    @Test("snapshot encodes at the current schema version")
    func snapshot_versionMatchesCurrent() {
        #expect(DemoFixture.snapshot.version == SessionSnapshot.currentVersion)
    }

    @Test func snapshot_hasThreeProjects_andTheirWorktrees_inTheDocumentedOrder() throws {
        let snap = DemoFixture.snapshot
        #expect(snap.projects.map(\.name) == ["duesmith", "pdf-worker", "dotfiles"])
        let duesmith = try #require(snap.projects.first)
        #expect(duesmith.worktrees.map(\.label) == [
            "feat/overdue-reminders", "fix/tax-rounding", "feat/proration", "fix/webhook-timeout", "docs/invoices-api",
            "fix/csv-export", "agent-3f2a91", "agent-7c0d44", "agent-a19e5b", "agent-e62b07", "duesmith-bisect"
        ])
        #expect(snap.projects[1].worktrees.map(\.label) == ["fix/page-breaks", "feat/batch-render"])
        // Each project's main folder is a row too: ten working rows, one
        // ready to clean up, and five other worktrees.
        #expect(snap.projects.reduce(0) { $0 + 1 + $1.worktrees.count } == 16)
        // Limpid made the working ones; Git only reported the agents' and
        // the detached one.
        #expect(duesmith.worktrees.map(\.admission) == Array(repeating: .created, count: 6) + Array(repeating: .discovered, count: 5))
        #expect(duesmith.worktrees.last?.gitRef?.branchName == nil, "the detached one has no branch")
        // Pinned, so a scan of folders that do not exist leaves them alone.
        #expect(snap.projects.flatMap(\.worktrees).allSatisfy { $0.origin == .userPinned })
        #expect(snap.recentProjectPaths == snap.projects.map(\.rootURL))
    }

    @Test func theWindow_showsTheRemindersAgent_inTheStrip_withTheChangesPanelOpen() throws {
        let window = try #require(DemoFixture.snapshot.windows.first)
        #expect(DemoFixture.snapshot.windows.count == 1)
        #expect(window.projectID == DemoFixture.duesmithProjectID)
        #expect(window.activeContainerID == DemoFixture.remindersContainer)
        #expect(window.activeTabID == DemoFixture.Slot.reminders.tabID)
        #expect(window.frame == WindowFrame(CGRect(x: 16, y: 16, width: 1440, height: 900)))
        #expect(window.sidebarWidth == 264)
        #expect(!window.sidebarHidden)
        #expect(window.isChangesPanelPresented)
        #expect(window.changesPanelWidth == 312)
        #expect(window.isFront)
    }

    /// The agent's pane is not split: the 100-column rule for opening the
    /// changes panel beside the terminal measures that pane. Codex's tab
    /// beside it shares the worktree, so the panel's timeline shows two
    /// conversations.
    @Test func theSelectedWorktree_isTheAgentsTab_thenCodexs_thenDevAndGit() throws {
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        let tabs = session.tabs(in: DemoFixture.remindersContainer)
        #expect(tabs.map(\.id) == [DemoFixture.Slot.reminders, .remindersCodex, .dev, .git].map(\.tabID))
        // The pane strip shows the conversations' titles and the shells'
        // last ones, none of them a name the person gave.
        #expect(tabs.map(\.displayTitle) == ["Send overdue invoice reminders", "Migrate the reminder schedules", "dev", "git"])
        #expect(tabs.allSatisfy { $0.titleOverride == nil })
        let agent = try #require(tabs.first)
        #expect(agent.splitTree.allLeafIDs() == [DemoFixture.Slot.reminders.paneID])
        #expect(agent.agentBadges[.claude]?[DemoFixture.Slot.reminders.paneID]?.state == .finished)
        #expect(tabs[1].agentBadges[.codex]?[DemoFixture.Slot.remindersCodex.paneID]?.state == .finished)
    }

    /// A row is named by its branch, never by a name the person gave,
    /// which would put the row's folder on its second line. A worktree with
    /// an agent leads with the agent's tab, which holds that conversation's
    /// name and shows it in the pane strip, and one with shells alone holds
    /// none. The worktrees folded away (the merged one, the agents', the
    /// detached one) have no tab: a tab would make them working rows.
    @Test func everyWorktree_isNamedByItsBranch_andAnAgentsTabByItsConversation() {
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        var agentWorktrees = 0
        var emptyRows: [ContainerID] = []
        for project in session.projects {
            for container in SessionSidebarModel.containers(of: project) {
                let tabs = session.tabs(in: container)
                let first = tabs.first
                let isAgents = first.map { !$0.agentBadges.values.allSatisfy(\.isEmpty) } ?? false
                #expect(tabs.allSatisfy { $0.titleOverride == nil }, "\(container)")
                let name = session.rowName(of: container)
                if let branch = CheckoutName.knownBranch(of: container, in: session) {
                    #expect(name == RowName(text: branch, source: .branch), "\(container)")
                }
                if isAgents {
                    agentWorktrees += 1
                    #expect(first?.conversationName != nil, "\(container)")
                    #expect(first?.displayTitle == first?.conversationName?.name, "\(container)")
                } else {
                    #expect(tabs.allSatisfy { $0.conversationName == nil }, "\(container)")
                    #expect(name?.source != .conversation, "\(container)")
                }
                #expect(session.rowCheckout(of: container) == nil, "\(container)")
                if tabs.isEmpty {
                    emptyRows.append(container)
                }
            }
        }
        #expect(agentWorktrees == 8)
        let folded = [DemoFixture.csvExportWorktreeID] + DemoFixture.agentWorktreeIDs + [DemoFixture.bisectWorktreeID]
        #expect(emptyRows == folded.map { .worktree(projectID: DemoFixture.duesmithProjectID, worktreeID: $0) })
        #expect(session.tabs(in: .loose).count == 1)
    }

    /// Every pane prints its scene with the colors written as text: an
    /// escape character typed into the shell would reach zsh's line editor
    /// as a key. An agent's scene sets the terminal's title to its
    /// conversation's, which the tab shows, and holds the screen with its
    /// cursor hidden.
    @Test func everyPanesCommand_typesNoEscapeCharacter_andAnAgentsHoldsTheScreen() {
        for tab in DemoFixture.snapshot.tabs {
            for (pane, command) in tab.initialCommands {
                #expect(!command.contains("\u{1B}"), "\(pane)")
                #expect(!command.contains("\n"), "\(pane)")
            }
        }
        let reminders = DemoFixture.transcript(for: .reminders)
        #expect(reminders.contains("&& clear && printf '\\033]2;%s\\007' 'Send overdue invoice reminders' && "))
        // Every agent's scene that holds the screen titles the terminal by
        // the conversation that names its tab, so the two cannot drift.
        for tab in DemoFixture.snapshot.tabs {
            guard let name = tab.conversationName, let command = tab.initialCommands[name.paneID] else { continue }
            #expect(DemoFixture.Slot.allCases.contains { DemoFixture.conversationTitle(of: $0) == name.name }, "\(tab.id)")
            if command.contains("read -r") {
                #expect(command.contains("printf '\\033]2;%s\\007' '\(name.name)'"), "\(tab.id)")
            }
        }
        #expect(reminders.contains("printf '\\033[?25l%b'"))
        #expect(reminders.hasSuffix("&& read -r; printf '\\033[?25h'"))
        #expect(reminders.contains("\\033[36m"))
    }

    /// The scene's text is typed between single quotes: a quote in it closes
    /// and reopens them rather than ending the argument.
    @Test func aScenesQuote_isClosedEscapedAndReopened() {
        let command = DemoFixture.scene([DemoFixture.Line(.plain, "don't")], prompt: "p", end: .prompt)
        #expect(command == "PS1='p \\$ ' PROMPT='p %% ' && clear && printf '%b\\n' 'don'\\''t'")
    }

    /// The script starts the demo shells in this folder under its isolated
    /// home, and the footer and headers read it: the two have to agree.
    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no source tree"))
    func theScreenshotScript_startsShellsInTheSelectedWorktreesFolder() throws {
        let root = try #require(RepoFixture.limpidRoot)
        let script = try String(contentsOf: root.appendingPathComponent("scripts/screenshot.sh"), encoding: .utf8)
        let relative = DemoFixture.selectedWorktreeHomeRelativePath
        #expect(DemoFixture.selectedWorktreeRoot.path == "/Users/demo/\(relative)")
        #expect(script.contains("DEMO_SHELL_DIR=\"${CAPTURE_HOME}/\(relative)\""))
        #expect(script.contains("let expectedPoints = CGSize(width: 1440, height: 900)"))
    }

    @Test("snapshot survives a JSON round-trip without losing state")
    func snapshot_jsonRoundTrip() throws {
        let original = DemoFixture.snapshot
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let restored = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: encoder.encode(original)
        )
        #expect(restored.version == original.version)
        #expect(restored.projects.count == original.projects.count)
        #expect(restored.tabs.count == original.tabs.count)
        #expect(restored.windows == original.windows)
        #expect(restored.projectViews == original.projectViews)
    }

    /// Switched to pdf-worker, the window comes back on its waiting agent.
    @Test func pdfWorkersView_opensOnItsWaitingAgent() throws {
        let views = DemoFixture.snapshot.projectViews
        let pdf = try #require(views.first { $0.projectID == DemoFixture.pdfWorkerProjectID })
        #expect(pdf.activeContainerID == DemoFixture.pageBreaksContainer)
        #expect(pdf.activeTabID == DemoFixture.Slot.pageBreaks.tabID)
    }

    /// The demo request marks are keyed by hand-written `ContainerID`
    /// values, so nothing but this connects them to the containers in
    /// the snapshot. Change one ID and `make screenshot` silently produces
    /// a hero image with the marks missing — exactly the class of breakage
    /// this suite exists to catch.
    @Test("every demo pull request is keyed to a container in the snapshot")
    func prStatus_keysResolveToSnapshotContainers() throws {
        let snap = DemoFixture.snapshot
        #expect(DemoFixture.prStatus.values.map(\.number).sorted() == [57, 311, 317, 324, 326])
        for container in DemoFixture.prStatus.keys {
            switch container {
            case let .project(id):
                #expect(snap.projects.contains { $0.id == id })
            case let .worktree(projectID, worktreeID):
                let project = try #require(snap.projects.first { $0.id == projectID })
                #expect(project.worktrees.contains { $0.id == worktreeID })
            case .loose:
                Issue.record("the scratch row has no branch to carry a request")
            }
        }
    }

    /// The Git facts are keyed the same way, so this connects them too.
    @Test func everyStagedGitFact_isKeyedToAWorktreeInTheSnapshot() {
        let snap = DemoFixture.snapshot
        let workspaces = Set(snap.projects.flatMap(SessionSidebarModel.containers(of:)))
        #expect(!DemoFixture.gitFacts.isEmpty)
        #expect(Set(DemoFixture.gitFacts.keys).isSubset(of: workspaces))
        let reminders = DemoFixture.gitFacts[DemoFixture.remindersContainer]
        #expect(reminders?.proposedCommits == 2)
        #expect(reminders?.uncommittedFiles == 5, "what Claude's T4 and T5 and Codex's T1 changed")
    }

    /// Demo mode hands the fixture's requests to the syncer at
    /// construction (`PRStatusSource.fixture`), and the syncer shows them
    /// as they are: it reads no demo flag (false in the test runner) and
    /// asks no CLI, not even for the row's "Refresh".
    @Test func demoPRStatus_comesFromFixtureSource() {
        #expect(!DemoFixture.isDemoActive)
        if case .fixture = AppState.prStatusSource {
            Issue.record("a run that is not the demo reads the forge CLIs")
        }
        #expect(AppState.stagedGitFacts == nil)

        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        let store = PRStatusStore()
        let syncer = PRStatusSyncer(session: session, store: store, source: .fixture(DemoFixture.prStatus))
        syncer.start()

        #expect(store.perContainer == DemoFixture.prStatus)
        for container in DemoFixture.prStatus.keys {
            #expect(store.forge(for: container) == nil)
            syncer.refreshNow(container: container)
        }
        #expect(store.perContainer == DemoFixture.prStatus)
    }

    /// A real `github.com/<name>` is somebody's account, and the demo
    /// hands its link to anyone who clicks. RFC 2606 reserves
    /// `.invalid` so it can never resolve to one.
    @Test("demo request links point at a reserved, non-resolving host")
    func prStatus_urlsUseAReservedHost() {
        for info in DemoFixture.prStatus.values {
            #expect(info.url.host()?.hasSuffix(".invalid") == true)
        }
    }

    // MARK: - Staged turns

    private static func turns(of conversation: ConversationKey, now: Date = Date()) throws -> [TurnSummary] {
        try #require(DemoFixture.conversations(now: now).first { $0.key == conversation }?.turns)
    }

    /// The selected workspace's conversation: five turns in its worktree,
    /// T3 an answer and the others with changes, T4's check failing and
    /// T5's passing.
    @Test func theRemindersTurns_areOneConversation_inTheSelectedWorktree() throws {
        let turns = try Self.turns(of: DemoFixture.remindersConversation)
        #expect(turns.map(\.displayNumber) == [1, 2, 3, 4, 5])
        #expect(turns.allSatisfy { $0.phase == .finished && $0.endTree?.root == DemoFixture.selectedWorktreeRoot.path })
        #expect(turns.allSatisfy { $0.paneID == DemoFixture.Slot.reminders.paneID.uuidString })
        #expect(turns.filter(\.changes.mayHaveChangedFiles).map(\.displayNumber) == [1, 2, 4, 5])
        #expect(turns[3].lastCheck?.exitCode == 1)
        #expect(turns[4].lastCheck == CheckSummary(command: "pnpm test src/reminders", isFiltered: true, exitCode: 0, earlierFailures: 2))
    }

    /// The other staged conversations: the review's two answers, and the
    /// stopped agent's interrupted turn with what it had changed.
    @Test func theOtherConversations_areTheReviewsAnswers_andTheStoppedAgentsTurn() throws {
        let review = try Self.turns(of: DemoFixture.prReviewConversation)
        #expect(review.map(\.changes) == [.unchanged, .unchanged])
        #expect(review.allSatisfy { $0.conversation.provider == .codex })
        let webhook = try Self.turns(of: DemoFixture.webhookConversation)
        #expect(webhook.map(\.phase) == [.interrupted])
        #expect(webhook.first?.changes == .changed(files: 2, added: 18, removed: 3))
        #expect(DemoFixture.conversations().count == 4)
    }

    /// Codex's turn in the selected worktree: one turn with changes, begun
    /// after Claude's T4 and before T5, so the timeline reads T4, Codex's
    /// T1, T5.
    @Test func theCodexTurn_isInTheSelectedWorktree_betweenT4AndT5() throws {
        let now = Date()
        let codex = try Self.turns(of: DemoFixture.remindersCodexConversation, now: now)
        let reminders = try Self.turns(of: DemoFixture.remindersConversation, now: now)
        #expect(codex.map(\.displayNumber) == [1])
        #expect(codex.first?.conversation.provider == .codex)
        #expect(codex.first?.changes == .changed(files: 1, added: 24, removed: 0))
        #expect(codex.first?.endTree?.root == DemoFixture.selectedWorktreeRoot.path)
        #expect(codex.first?.paneID == DemoFixture.Slot.remindersCodex.paneID.uuidString)
        let timeline = ChangesPanelModel.timeline(reminders + codex)
        #expect(timeline.map(\.turnID) == (reminders.prefix(4) + codex + reminders.suffix(1)).map(\.turnID))
        guard case let .range(range) = ReviewScopeCatalog.unviewedTurns(turns: timeline, isViewed: { _ in false }) else {
            Issue.record("expected the worktree's unviewed range")
            return
        }
        #expect(ChangesPanelModel.comparison(range).begin == reminders.first?.beginTree?.tree)
        #expect(ChangesPanelModel.comparison(range).end == reminders.last?.endTree?.tree)
    }

    /// Every staged turn has ended, and each conversation's last one when its
    /// agent's badge says it did.
    @Test func everyConversation_endedBeforeNow_itsLastTurnAsItsBadgeSays() throws {
        let now = Date()
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        let format = ISO8601DateFormatter()
        for conversation in DemoFixture.conversations(now: now) {
            let ends = conversation.turns.compactMap { $0.finishedAt.flatMap(format.date(from:)) }
            #expect(ends.count == conversation.turns.count)
            #expect(ends.allSatisfy { $0 <= now })
            let pane = try #require(conversation.turns.last.flatMap { UUID(uuidString: $0.paneID) })
            #expect(DemoFixture.conversation(forPane: pane) == conversation.key)
            let badge = try #require(session.tab(containing: pane)?.agentBadges[conversation.key.provider]?[pane])
            let last = try #require(ends.last)
            #expect(abs(badge.updatedAt.timeIntervalSince(last)) < 2)
            #expect(badge.lastPrompt == conversation.turns.last?.promptHead)
        }
    }

    /// Each staged conversation is called one name everywhere, as a real
    /// run's is: its tab, its badge's conversation and title as the
    /// provider keeps it, its pane header, every turn's recorded title, and
    /// the changes panel, which names it from those turns.
    @Test func everyStagedConversation_isCalledOneName() throws {
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        for conversation in DemoFixture.conversations() {
            let pane = try #require(conversation.turns.last.flatMap { UUID(uuidString: $0.paneID) })
            let tab = try #require(session.tab(containing: pane))
            let badge = try #require(tab.agentBadges[conversation.key.provider]?[pane])
            let name = tab.title

            #expect(badge.conversationID == conversation.key.conversationID)
            #expect(PaneHeaderRules.agentTitle(for: badge) == name)
            #expect(tab.conversationName?.name == name)
            #expect(conversation.turns.allSatisfy { $0.conversationTitle == name }, "\(name)")
            let agent = ChangesPanelModel.Agent(conversation: conversation.key, turns: conversation.turns)
            #expect(ChangesPanelModel.title(of: agent, liveTab: nil, rememberedTabName: nil) == name)
        }
    }
}
