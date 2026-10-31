// SessionSidebarModelTests.swift
// Weir — the sidebar's rows: their order, names, words, and the rows ⌃⌘n and ⌘[ ⌘] open.

import AppKit
import Foundation
import Observation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct SessionSidebarModelTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    private static func project() -> (session: WorkspaceSession, project: Project) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let index = session.projects.firstIndex { $0.id == project.id } ?? 0
        session.projects[index].mainBranchName = "main"
        session.projects[index].worktrees = [
            Worktree(
                label: "spike",
                workingDirectory: URL(fileURLWithPath: "/tmp/spike"),
                gitRef: GitRef(branchName: "feat/spike"),
                origin: .gitWorktree
            ),
            Worktree(label: "old", workingDirectory: URL(fileURLWithPath: "/tmp/old"), origin: .gitWorktree, isHidden: true),
            Worktree(
                label: "gone",
                workingDirectory: URL(fileURLWithPath: "/tmp/gone"),
                origin: .gitWorktree,
                missingSince: Date(timeIntervalSince1970: 0)
            )
        ]
        return (session, session.projects[index])
    }

    /// The project with no branch known for its folder, so the folder's
    /// row is named by its conversation, as a detached HEAD's is.
    private static func unbranchedProject() -> (session: WorkspaceSession, project: Project) {
        let (session, project) = project()
        let index = session.projects.firstIndex { $0.id == project.id } ?? 0
        session.projects[index].mainBranchName = nil
        return (session, session.projects[index])
    }

    private static func model(
        _ session: WorkspaceSession,
        _ project: Project,
        locale: Locale = english,
        gitFacts: @escaping (ContainerID) -> GitFacts? = { _ in nil }
    ) -> SessionSidebarModel {
        SessionSidebarModel(
            project: project,
            session: session,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: gitFacts,
            locale: locale
        )
    }

    @Test func rows_areTheFolder_thenTheShownWorktreesInTheOrderTheyWereMade() {
        let (session, project) = Self.project()
        let rows = Self.model(session, project).rows

        // The missing worktree is listed under its own line, after the
        // working rows.
        #expect(rows.map(\.name) == ["main", "feat/spike", "gone"])
        #expect(rows.map(\.isMainFolder) == [true, false, false])
        #expect(rows.map(\.isMissing) == [false, false, true])
    }

    @Test func aRowsName_isTheNameAPersonGave_beforeTheBranch() {
        let (session, project) = Self.project()
        let tab = session.openTab(container: .project(project.id))
        session.update(tab.id) { $0.titleOverride = "Release prep" }

        let rows = Self.model(session, project).rows

        #expect(rows.first { $0.isMainFolder }?.name == "Release prep")
        #expect(rows.first { $0.isMainFolder }?.isActive == true)
    }

    // MARK: - Names

    private static func conversation(
        _ name: String,
        startedAt seconds: TimeInterval?,
        provider: AgentKind = .claude
    ) -> ConversationName {
        ConversationName(
            name: name,
            provider: provider,
            paneID: UUID(),
            conversationID: UUID().uuidString,
            startedAt: seconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    @Test func aRowsName_doesNotFollowItsTabsTitle() {
        let (session, project) = Self.unbranchedProject()
        let tab = session.openTab(container: .project(project.id))
        session.update(tab.id) {
            $0.conversationName = Self.conversation("Append a line to notes.txt", startedAt: 0)
            $0.title = "claude --continue"
        }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Append a line to notes.txt")

        // The agent, then the shell it leaves, set the title again (OSC 2).
        for title in ["✳ Appending", "…/demo-repos/alpha", "zsh"] {
            session.update(tab.id) { $0.title = title }
            #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Append a line to notes.txt")
        }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.nameTruncation == .name)
    }

    /// A row stands for its worktree: its branch names it even while an
    /// agent's conversation runs there, which the pane strip names.
    @Test func aRowWithAConversation_isNamedByItsBranch() {
        let (session, project) = Self.project()
        let tab = session.openTab(container: .project(project.id))
        session.update(tab.id) { $0.conversationName = Self.conversation("Add tests", startedAt: 0) }

        let row = Self.model(session, project).rows.first { $0.isMainFolder }
        #expect(row?.name == "main")
        #expect(row?.nameTruncation == .branch)
    }

    @Test func aRowWithoutAConversation_isNamedByItsBranch_whateverItsTabsAreCalled() {
        let (session, project) = Self.project()
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        let tab = session.openTab(container: spike)
        session.update(tab.id) { $0.title = "claude --continue" }

        let row = Self.model(session, project).rows[1]

        #expect(row.name == "feat/spike")
        // A branch differs from its neighbors at its end.
        #expect(row.nameTruncation == .branch)
    }

    @Test func aFolderWithoutABranch_isNamedByItsFolder_asAName() throws {
        let (session, project) = Self.project()
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].mainBranchName = nil
        let unbranched = session.projects[index]

        let row = try #require(Self.model(session, unbranched).rows.first { $0.isMainFolder })

        #expect(row.name == unbranched.rootURL.lastPathComponent)
        #expect(row.nameTruncation == .name)
        // A worktree whose branch is not known yet is named by its label,
        // as a name; one with a known branch by the branch.
        let rows = Self.model(session, unbranched).rows
        #expect(rows.map(\.name) == [unbranched.rootURL.lastPathComponent, "feat/spike", "gone"])
        #expect(rows.map(\.nameTruncation) == [.name, .branch, .name])
    }

    @Test func anEmptyNameAPersonGave_handsTheRowToItsConversation() {
        let (session, project) = Self.unbranchedProject()
        let cleared = session.openTab(container: .project(project.id))
        let named = session.openTab(container: .project(project.id))
        session.update(cleared.id) { $0.titleOverride = "" }
        session.update(named.id) { $0.conversationName = Self.conversation("Add tests", startedAt: 0) }

        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Add tests")

        session.update(named.id) { $0.conversationName = nil }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == project.rootURL.lastPathComponent)
    }

    @Test func theHeaderAndTheCard_cutTheNameAsTheRowDoes() throws {
        let (session, project) = Self.unbranchedProject()
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        _ = session.openTab(container: spike)
        let named = session.openTab(container: .project(project.id))
        session.update(named.id) { $0.conversationName = Self.conversation("Add tests", startedAt: 0) }
        let rows = Self.model(session, project).rows
        let folder = try #require(rows.first { $0.isMainFolder })

        #expect(SessionHeaderModel(row: folder, pullRequestNumber: nil, locale: Self.english).nameTruncation == .name)
        let spikeRow = try #require(rows.first { $0.id == spike })
        #expect(SessionHeaderModel(row: spikeRow, pullRequestNumber: nil, locale: Self.english).nameTruncation == .branch)

        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        let cards = AllProjectsModel.cards(AllProjectsModel.Sources(
            session: session, window: session.primaryWindowID, registry: registry, queue: AttentionQueue(),
            runtimes: [], approvals: ApprovalLedger(), pullRequest: { _ in nil }, gitFacts: { _ in nil },
            locale: Self.english
        ))
        #expect(cards.map(\.name) == ["Add tests", "feat/spike"])
        #expect(cards.map(\.nameTruncation) == [.name, .branch])
    }

    @Test func aRowKeepsItsConversationsName_afterTheAgentLeaves() throws {
        let (session, project) = Self.unbranchedProject()
        let tab = session.openTab(container: .project(project.id))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let running = AgentBadge(
            state: .running,
            updatedAt: Date(),
            firstPrompt: "Run sleep 15 with a timer",
            conversationID: "thread",
            sessionStartedAt: Date(timeIntervalSince1970: 0)
        )
        session.update(tab.id) {
            $0.agentBadges[.codex] = [pane: running]
            $0.rememberConversationName()
        }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Run sleep 15 with a timer")

        // The run is gone, and the shell names the tab by its folder.
        session.update(tab.id) {
            $0.agentBadges = [:]
            $0.title = "~/projects/sample-reviews/demo-repos/alpha"
            $0.rememberConversationName()
        }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Run sleep 15 with a timer")
    }

    @Test func aRowWithSeveralConversations_isNamedByTheFirstToStart() {
        let (session, project) = Self.unbranchedProject()
        let shell = session.openTab(container: .project(project.id))
        let later = session.openTab(container: .project(project.id))
        let earlier = session.openTab(container: .project(project.id))
        session.update(shell.id) { $0.title = "zsh" }
        session.update(later.id) { $0.conversationName = Self.conversation("Write the release notes", startedAt: 200) }
        session.update(earlier.id) {
            $0.conversationName = Self.conversation("Review the store", startedAt: 100, provider: .codex)
        }

        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Review the store")

        // A name the person gave still comes first.
        session.update(later.id) { $0.titleOverride = "Release prep" }
        #expect(Self.model(session, project).rows.first { $0.isMainFolder }?.name == "Release prep")
    }

    @Test func aRowAtRest_readsIdle_asAShell_inTheWindowsLanguage() {
        let (session, project) = Self.project()

        let english = Self.model(session, project).rows[0]
        #expect(english.factText == "Idle")
        #expect(english.fact.badge == .shell)
        #expect(english.tone == .muted)
        #expect(english.lastActivity == nil)
        #expect(Self.model(session, project, locale: Self.japanese).rows[0].factText == "待機中")
    }

    @Test func aRowAtRest_statesItsFoldersGitFacts_eachRowItsOwn() throws {
        let (session, project) = Self.project()
        let facts = GitFactsFixture.make(branch: "main", commits: nil, unpushed: nil, uncommitted: 2, base: nil)
        let rows = Self.model(session, project) { $0 == .project(project.id) ? facts : nil }.rows
        let folder = try #require(rows.first { $0.isMainFolder })

        #expect(folder.factText == "2 files uncommitted")
        #expect(rows.first { !$0.isMainFolder }?.factText == "Idle")
    }

    @Test func anApprovalsCommand_isFoundInItsLine_whateverTheLanguage() throws {
        let approval = ApprovalFact.test()
        let items = Self.items([.approval(approval)])
        func row(isCommand: Bool, locale: Locale) -> SessionSidebarModel.Row {
            var input = SessionSidebarModel.RowInput.test(fact: .init(items: items, requestText: [approval.key: "swift test"]))
            input.commandRequests = isCommand ? [approval.key] : []
            return .test(input, locale: locale)
        }
        for locale in [Self.english, Self.japanese] {
            let command = row(isCommand: true, locale: locale)
            let range = try #require(SessionRowFactText.commandRange(in: command.factText, for: command))
            #expect(command.factText[range] == "swift test")
        }
        // A request that is not a command, and a row at rest, keep the line's own face.
        let summary = row(isCommand: false, locale: Self.english)
        #expect(SessionRowFactText.commandRange(in: summary.factText, for: summary) == nil)
        let idle = Self.row([])
        #expect(SessionRowFactText.commandRange(in: idle.factText, for: idle) == nil)
    }

    @Test func aWaitWeirDoesNotHold_setsItsCommand_asAHeldOnesIs() throws {
        func row(_ wait: PromptWait, locale: Locale) -> SessionSidebarModel.Row {
            .test(.test(fact: .init(items: Self.items([.prompt(wait)]))), locale: locale)
        }
        for locale in [Self.english, Self.japanese] {
            let command = row(PromptWait(detail: "Bash: swift test", kind: .approval, tool: "Bash"), locale: locale)
            #expect(command.isFactCommand)
            let range = try #require(SessionRowFactText.commandRange(in: command.factText, for: command))
            #expect(command.factText[range] == "swift test")
        }
        // A file, a tool alone, and a wait for an answer keep the line's face.
        for wait in [
            PromptWait(detail: "Write: /repo/notes.txt"),
            PromptWait(detail: "Bash"),
            PromptWait(detail: "Which color?")
        ] {
            let other = row(wait, locale: Self.english)
            #expect(!other.isFactCommand)
            #expect(SessionRowFactText.commandRange(in: other.factText, for: other) == nil)
        }
    }

    @Test func theTooltip_namesTheBranch_unlessTheRowIsNamedByIt() {
        func row(name: String, branch: String) -> SessionSidebarModel.Row {
            var input = SessionSidebarModel.RowInput.test(name: name)
            input.branch = branch
            return .test(input)
        }

        #expect(SessionRowFactText.tooltip(for: row(name: "Release prep", branch: "feat/release"), now: .now, locale: Self.english)
            == "Release prep · feat/release")
        #expect(SessionRowFactText.tooltip(for: row(name: "main", branch: "main"), now: .now, locale: Self.english) == "main")
    }

    @Test func aRowCountsItsAgents() {
        let agents = SessionSidebarModel.Row.test(.test(fact: .init(agents: [
            .init(provider: .claude, state: .running, detail: nil),
            .init(provider: .codex, state: .idle, detail: nil)
        ])))

        #expect(agents.agentCount == 2)
        #expect(SessionSidebarModel.Row.test(.test(name: "shell")).agentCount == 0)
    }

    private static func items(_ kinds: [AttentionItemKind]) -> [AttentionItem] {
        AttentionItem.testList(kinds)
    }

    private static func row(
        _ items: [AttentionItem],
        requestText: [ApprovalKey: String] = [:],
        lastActivity: Date? = nil,
        agents: [SessionRowFact.Input] = []
    ) -> SessionSidebarModel.Row {
        var input = SessionSidebarModel.RowInput.test(fact: .init(items: items, requestText: requestText), lastActivity: lastActivity)
        input.agents = agents
        return .test(input)
    }

    @Test func aRowOffersAnswer_onlyForARequestWeirCanStillAnswer() {
        let approval = ApprovalFact.test()
        let held = Self.row(Self.items([.approval(approval)]), requestText: [approval.key: "swift test"])
        #expect(held.answerKey == approval.key)
        #expect(held.tone == .waiting)
        #expect(held.factText == "Waiting for approval: swift test")

        // Codex's questions are answered in the TUI.
        let codex = ApprovalFact.test(isQuestion: true, provider: .codex, supportsNativeAnswer: false)
        #expect(Self.row(Self.items([.question(codex)])).answerKey == nil)
    }

    /// A row waiting on a request Weir does not hold offers no "Answer…";
    /// choosing the row goes to the pane, which its tooltip says.
    @Test func aRowWaitingOnTheTerminal_saysToOpenThePane_inItsTooltip() {
        let waits: [AttentionItemKind] = [
            .prompt(PromptWait(detail: "Edit: /repo/App.swift")),
            .approval(ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now))),
            .approval(ApprovalFact.test(state: .timedOut)),
            .question(ApprovalFact.test(isQuestion: true, provider: .codex))
        ]
        let now = Date(timeIntervalSince1970: 600)
        for kind in waits {
            let row = Self.row(Self.items([kind]), lastActivity: Date(timeIntervalSince1970: 0))
            #expect(row.answerKey == nil)
            #expect(row.requiresTerminalAnswer)
            // A line of its own after the facts, not one of them.
            #expect(SessionRowFactText.tooltip(for: row, now: now, locale: Self.english)
                == "main · 10 min since last activity\nOpen the pane to answer in the terminal")
            #expect(SessionRowFactText.tooltip(for: row, now: now, locale: Locale(identifier: "ja"))
                .hasSuffix("\nペインを開いてターミナルで回答"))
        }

        // One Weir holds is answered from the row's own "Answer…".
        let held = Self.row(Self.items([.approval(ApprovalFact.test())]))
        #expect(!held.requiresTerminalAnswer)
        #expect(SessionRowFactText.tooltip(for: held, now: .now, locale: Self.english) == "main")
    }

    /// The row open in the window, with the waiting pane in the tab it
    /// shows: the person sees the prompt already, so the tooltip does not
    /// send them there. The same row with its pane out of view does.
    @Test func aRowWhosePaneIsInView_doesNotSayToOpenIt() throws {
        let container = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let items = Self.items([.prompt(PromptWait(detail: nil))])
        let paneID = try #require(items[0].subject.paneID)
        var input = SessionSidebarModel.RowInput.test(container: container, fact: .init(items: items))
        input.leadPaneID = paneID
        let model = { (active: ContainerID, shown: Set<UUID>) in
            SessionSidebarModel.Row.test(input, activeContainer: active, shownPanes: shown)
        }

        let inView = model(container, [paneID])
        #expect(inView.requiresTerminalAnswer)
        #expect(SessionRowFactText.tooltip(for: inView, now: .now, locale: Self.english) == "main")
        // Another tab of the same row shown, or another row open.
        #expect(SessionRowFactText.tooltip(for: model(container, [UUID()]), now: .now, locale: Self.english)
            == "main\nOpen the pane to answer in the terminal")
        #expect(model(.loose, [paneID]).suggestsOpeningPane)
    }

    /// The panes in view are those of the tab the window shows.
    @Test @MainActor func theWindowsShownTab_putsTheRowsPaneInView() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let tab = session.openTab(container: .project(project.id))
        session.setActiveContainer(.project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        var queue = AttentionQueue()
        queue.insert(
            id: .prompt(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .prompt(PromptWait(detail: nil)),
            subject: .runtime(id: "r", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let row = try #require(SessionSidebarModel(
            project: project, session: session, queue: queue, runtimes: [], approvals: ApprovalLedger(),
            pullRequest: { _ in nil }, gitFacts: { _ in nil }, locale: Self.english
        ).rows.first)

        #expect(row.isActive)
        #expect(row.isLeadPaneShown)
        #expect(!row.suggestsOpeningPane)
    }

    @Test func aStop_isRed_andUnreadTurnsAreCounted() {
        let unread = AttentionItemKind.unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown))
        let row = Self.row(Self.items([unread, .stop(.processExited), unread]))
        #expect(row.tone == .stopped)
        #expect(row.unreadCount == 2)
        #expect(SessionRowFactText.tooltip(for: row, now: .now, locale: Self.english) == "main · 2 unread turns")
    }

    @Test func aRowWithTwoAgents_namesEachInItsTooltip() {
        let row = Self.row([], agents: [
            .init(agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")]),
            .init(agents: [.init(provider: .codex, state: .idle, detail: nil)])
        ])
        // A slash between agents, as a fact may hold a dot of its own.
        #expect(row.agentSummary == "Claude: Bash: swift test / Codex: Idle")
        #expect(Self.row([]).agentSummary == nil)
    }

    @Test func voiceOver_readsState_name_project_fact_agent_andTime() {
        let now = Date(timeIntervalSince1970: 10000)
        let row = SessionSidebarModel.Row.test(.test(
            name: "Release prep",
            fact: .init(agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")]),
            lastActivity: now.addingTimeInterval(-12 * 60)
        ))

        #expect(SessionRowFactText.spokenLabel(for: row, projectName: "weir", now: now, locale: Self.english)
            == "Running, Release prep, weir, Bash: swift test, Claude, 12 min since last activity")
        // The row's column says "12m"; VoiceOver and the tooltip say the
        // minutes in words.
        #expect(SessionRowFactText.elapsed(since: now.addingTimeInterval(-12 * 60), now: now, locale: Self.english) == "12m")
    }

    @Test func aPullRequestRow_readsItsState_thenTheRequestAndItsChecks_inWords() {
        let checks = PRChecks(conclusion: .failure, counts: .init(passed: 3, total: 4))
        func checkedRow(_ fact: SessionRowFact.Input) -> SessionSidebarModel.Row {
            var input = SessionSidebarModel.RowInput.test(fact: fact)
            input.pullRequestChecks = (checks, .gitHub)
            return .test(input)
        }
        let row = checkedRow(.init(pullRequest: .init(number: 128, state: .open, isDraft: false)))

        #expect(row.fact.glyph == .shell, "a row with no agent keeps the shell glyph")
        #expect(row.checksText == "Checks failed, 3 of 4 passed", "VoiceOver reads 3/4 as a date")
        #expect(
            SessionRowFactText.spokenLabel(for: row, projectName: "weir", now: .now, locale: Self.english)
                == "Shell, main, weir, PR #128, Open, Checks failed, 3 of 4 passed",
            "a shell says Shell once"
        )

        let agentRow = checkedRow(.init(
            agents: [.init(provider: .claude, state: .idle, detail: nil)],
            pullRequest: .init(number: 128, state: .open, isDraft: false)
        ))
        #expect(agentRow.fact.glyph == .idle)
        #expect(SessionRowFactText.spokenLabel(for: agentRow, projectName: "weir", now: .now, locale: Self.english)
            == "Idle, main, weir, PR #128, Open, Checks failed, 3 of 4 passed, Claude")
    }

    @Test func sessionKeys_openRows_andSkipHiddenWorktrees() {
        let (session, project) = Self.project()
        let window = ProjectWindowState(selection: session.primarySelection)
        session.primarySelection.projectID = project.id

        let sections = SidebarPresentedSections()

        // The folder opens the working rows, so ⌃⌘1 is always it.
        SessionRowNavigation.activate(at: 0, in: window, session: session, sections: sections)
        #expect(session.primarySelection.activeContainerID == .project(project.id))
        SessionRowNavigation.cycle(forward: true, in: window, session: session, sections: sections)
        #expect(session.primarySelection.activeContainerID == .worktree(projectID: project.id, worktreeID: project.worktrees[0].id))
        SessionRowNavigation.cycle(forward: true, in: window, session: session, sections: sections)
        // The hidden worktree is not a row; the missing one is. Scratch
        // comes after the working rows.
        #expect(session.primarySelection.activeContainerID == .worktree(projectID: project.id, worktreeID: project.worktrees[2].id))
        SessionRowNavigation.cycle(forward: true, in: window, session: session, sections: sections)
        #expect(session.primarySelection.activeContainerID == .loose)
        // ⌃⌘n counts the working rows only, not scratch.
        SessionRowNavigation.activate(at: 3, in: window, session: session, sections: sections)
        #expect(session.primarySelection.activeContainerID == .loose, "past the last row nothing happens")
    }

    /// ⌃⌘n and ⌘[ ⌘] count the rows the sidebar shows, in the sections it
    /// shows them in: a row folded away is skipped, and one held among the
    /// working rows while its section changed is counted where it is seen.
    @Test func sessionKeys_countTheWorkingRowsTheSidebarShows() {
        let (session, project) = Self.project()
        let window = ProjectWindowState(selection: session.primarySelection)
        session.primarySelection.projectID = project.id
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        let gone = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[2].id)
        let folded = SidebarPresentedSections(sections: [spike: .other, gone: .working, .project(project.id): .working])

        #expect(SessionRowNavigation.rows(in: window, session: session, sections: folded) == [.project(project.id), gone, .loose])
        SessionRowNavigation.activate(at: 1, in: window, session: session, sections: folded)
        #expect(session.primarySelection.activeContainerID == gone)

        // Held where it was drawn while it would now fold away.
        window.present(SidebarPresentedSections(sections: [spike: .working, gone: .working, .project(project.id): .working]))
        window.isPointerInSidebar = true
        let held = window.presentedSections(computed: folded, isDragging: false)
        SessionRowNavigation.activate(at: 1, in: window, session: session, sections: held)
        #expect(session.primarySelection.activeContainerID == spike)
    }

    /// The menus that count the working rows follow the rows the sidebar
    /// drew among them (`presentedWorkingRows`, which they observe), and a
    /// drawing that moves no row in or out leaves the value as it was.
    @Test func theDrawnWorkingRows_followARowMovingInOrOut() {
        let (session, project) = Self.project()
        let window = ProjectWindowState(selection: session.primarySelection)
        session.primarySelection.projectID = project.id
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        let folder = ContainerID.project(project.id)

        window.present(SidebarPresentedSections(sections: [spike: .other, folder: .working]))
        #expect(window.presentedWorkingRows == [folder])
        #expect(
            SessionRowNavigation.workingRows(in: window, session: session, sections: window.presentedSections).count == 2,
            "and the missing worktree, which the drawing does not name"
        )

        window.present(SidebarPresentedSections(sections: [spike: .working, folder: .working]))
        #expect(window.presentedWorkingRows == [spike, folder])
        #expect(SessionRowNavigation.workingRows(in: window, session: session, sections: window.presentedSections).count == 3)
        #expect(SessionRowNavigation.hasRow(number: 3, workingRowCount: 3))

        // The same rows drawn again move none in or out: no menu rebuilds.
        let notified = Recorded(false)
        withObservationTracking {
            _ = window.presentedWorkingRows
        } onChange: {
            notified.value = true
        }
        window.present(SidebarPresentedSections(sections: [spike: .working, folder: .working]))
        #expect(!notified.value)

        // Control: the tracking is live, so a row moving out is heard.
        window.present(SidebarPresentedSections(sections: [spike: .other, folder: .working]))
        #expect(notified.value)
    }

    @Test func theActiveRow_isTheOneOfTheWindowDrawingTheSidebar() {
        let (session, project) = Self.project()
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: project.worktrees[0].id)
        // The primary shows no project, so another window can show this one.
        session.showProject(nil, in: session.primaryWindowID, intent: .person, reason: .person)

        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveContainer(spike, in: other)

        let model = SessionSidebarModel(
            project: project,
            session: session,
            window: other,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: Self.english
        )

        #expect(model.rows.filter(\.isActive).map(\.name) == ["feat/spike"])
        // The primary, on the scratch row, has no row of the project active.
        #expect(Self.model(session, project).rows.filter(\.isActive).isEmpty)
    }

    // MARK: - A row's lead

    @Test func aRowsLeadAgent_isTheFirstRunning_elseTheFirst() {
        func lead(_ states: [AgentState]) -> Int? {
            SessionRowFact.leadAgentIndex(of: states.map { SessionRowFact.Agent(provider: .claude, state: $0, detail: nil) })
        }
        #expect(lead([.idle, .running]) == 1)
        #expect(lead([.idle, .compacting, .running]) == 1)
        #expect(lead([.idle, .unknown]) == 0)
        #expect(lead([]) == nil)
    }

    @Test func aFolderWithNothingOpen_isARowWithoutTabs_andItsTabsPaneLeads() {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let empty = SessionSidebarModel(
            project: project, session: session, queue: AttentionQueue(), runtimes: [], approvals: ApprovalLedger(),
            pullRequest: { _ in nil }, gitFacts: { _ in nil }, locale: Locale(identifier: "en")
        )
        #expect(empty.rows.first?.hasTabs == false)
        #expect(empty.rows.first?.leadPaneID == nil)

        let tab = session.openTab(container: .project(project.id))
        let opened = SessionSidebarModel(
            project: project, session: session, queue: AttentionQueue(), runtimes: [], approvals: ApprovalLedger(),
            pullRequest: { _ in nil }, gitFacts: { _ in nil }, locale: Locale(identifier: "en")
        )
        #expect(opened.rows.first?.hasTabs == true)
        #expect(opened.rows.first?.leadPaneID == tab.splitTree.effectiveFocusedLeafID)
        #expect(opened.rows.first?.leadItemID == nil)
    }
}

extension SessionSidebarModelTests {
    /// A worktree deleted outside Weir stops its row, which says why.
    @Test func aMissingWorktreesRow_saysItsWorktreeIsNotFound() throws {
        let (session, project) = Self.project()
        let input = AttentionQueueStore.makeInput(
            runtimes: [],
            isRead: { _ in false },
            approvals: [],
            session: session,
            isApprovalServiceRunning: false
        )
        let (queue, _) = AttentionQueueReducer.reduce(AttentionQueue(), input: input)
        let model = SessionSidebarModel(
            project: project,
            session: session,
            queue: queue,
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: Self.english
        )
        let gone = try #require(model.rows.first { $0.isMissing })
        #expect(gone.name == "gone")
        #expect(gone.factText == "Stopped: Worktree not found.")
        // The hidden one is not listed, nor are the ones that are there.
        #expect(queue.items.count == 1)
    }
}

// MARK: - Sections

extension SessionSidebarModelTests {
    /// A project with a worktree for each section: one with a tab, one
    /// Weir made whose request is merged, two agents' worktrees nobody
    /// opened, and the folder.
    struct SectionedRows {
        let working: ContainerID
        let merged: ContainerID
        let agentA: ContainerID
        let agentB: ContainerID
        let folder: ContainerID

        var all: Set<ContainerID> {
            [working, merged, agentA, agentB, folder]
        }
    }

    // swiftlint:disable:next large_tuple
    private static func sectionedProject() throws -> (session: WorkspaceSession, project: Project, ids: SectionedRows) {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let working = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let merged = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let agentA = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let agentB = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let row = { (worktree: Worktree) in ContainerID.worktree(projectID: project.id, worktreeID: worktree.id) }
        session.openTab(container: row(working), in: session.primaryWindowID, intent: .repair, selects: false)
        let ids = SectionedRows(
            working: row(working),
            merged: row(merged),
            agentA: row(agentA),
            agentB: row(agentB),
            folder: .project(project.id)
        )
        return try (session, #require(session.project(project.id)), ids)
    }

    private static func sectionedModel(
        _ session: WorkspaceSession,
        _ project: Project,
        merged: ContainerID,
        open: Set<SidebarSection>
    ) -> SessionSidebarModel {
        let pullRequest = { (row: ContainerID) in row == merged ? PRInfoFixture.make(number: 127, state: .merged) : nil }
        let sections = SidebarPresentedSections.computed(
            project: project,
            session: session,
            window: session.primaryWindowID,
            queue: AttentionQueue(),
            pullRequest: pullRequest,
            gitFacts: { _ in nil }
        )
        return SessionSidebarModel(
            project: project,
            session: session,
            window: session.primaryWindowID,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: pullRequest,
            gitFacts: { _ in nil },
            locale: english,
            layout: .init(sections: sections, openSections: open)
        )
    }

    /// The working rows, then a line for each folded list that holds a row,
    /// whose rows are not built while it is folded.
    @Test func theRows_areTheWorkingOnes_thenAFoldLineForEachList_whoseRowsAreNotBuilt() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let model = Self.sectionedModel(session, project, merged: ids.merged, open: [])

        #expect(model.rows.map(\.id) == [ids.folder, ids.working])
        #expect(model.items.map(\.id) == [
            .row(ids.folder),
            .row(ids.working),
            .fold(project.id, .cleanable),
            .fold(project.id, .other)
        ])
        let folds = model.items.compactMap { item -> SessionSidebarModel.Fold? in
            if case let .fold(fold) = item {
                fold
            } else {
                nil
            }
        }
        #expect(folds.map(\.count) == [1, 2])
        #expect(folds.allSatisfy { !$0.isOpen })
    }

    /// An open list's rows follow its line, each in its section, and the
    /// row ready to clean up says its request first.
    @Test func anOpenList_listsItsRowsUnderItsLine() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let merged = ids.merged
        let model = Self.sectionedModel(session, project, merged: merged, open: [.cleanable, .other])

        #expect(model.items.map(\.id) == [
            .row(ids.folder),
            .row(ids.working),
            .fold(project.id, .cleanable),
            .row(merged),
            .fold(project.id, .other),
            .row(ids.agentA),
            .row(ids.agentB)
        ])
        let cleanable = try #require(model.rows.first { $0.id == merged })
        #expect(cleanable.section == .cleanable)
        #expect(cleanable.factText == "PR #127 · Merged")
        #expect(model.rows.first { $0.id == ids.agentA }?.section == .other)
    }

    /// A worktree whose folder is gone folds under its own line, before the
    /// rows ready to clean up, and comes out of it once a tab opens there.
    @Test func aMissingWorktree_foldsUnderItsOwnLine_untilATabOpensThere() throws {
        let (session, project) = Self.project()
        let spikeID = try #require(project.worktrees.first?.id)
        let goneID = try #require(project.worktrees.last?.id)
        let spike = ContainerID.worktree(projectID: project.id, worktreeID: spikeID)
        let gone = ContainerID.worktree(projectID: project.id, worktreeID: goneID)
        let folded = Self.sectionedModel(session, project, merged: .loose, open: [])
        let expected: [SidebarItemID] = [.row(.project(project.id)), .row(spike), .fold(project.id, .missing)]
        #expect(folded.items.map(\.id) == expected)

        let opened = Self.sectionedModel(session, project, merged: .loose, open: [.missing])
        #expect(opened.items.last?.id == .row(gone))
        #expect(opened.rows.first { $0.id == gone }?.section == .missing)

        _ = session.openTab(container: gone)
        session.setActiveContainer(.project(project.id))
        let withTab = Self.sectionedModel(session, project, merged: .loose, open: [])
        #expect(withTab.rows.first { $0.id == gone }?.section == .working)
    }

    /// A list with no row has no line.
    @Test func aListWithNoRow_hasNoLine() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let model = Self.sectionedModel(session, project, merged: .loose, open: [])
        #expect(model.items.map(\.id) == [.row(.project(project.id))])
    }

    /// Without the window's layout (the worktree menu, all projects), every
    /// row is built, each in the section it is placed in now.
    @Test func withoutAWindowsLayout_everyRowIsBuilt() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let rows = Self.model(session, project).rows
        #expect(Set(rows.map(\.id)) == ids.all)
        #expect(rows.first { $0.id == ids.agentA }?.section == .other)
    }

    /// The selected row stays a working one, so choosing a row never hides
    /// it.
    @Test func theSelectedRow_isAWorkingRow() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let agent = ids.agentA
        // Moved there, not chosen: a choice would admit the row.
        session.setActiveContainer(.project(project.id))
        session.setActiveContainer(agent, in: session.primaryWindowID, intent: .repair)
        let agentID = try #require(agent.worktreeID)
        #expect(session.worktree(projectID: project.id, worktreeID: agentID)?.admission == .discovered)
        let model = Self.sectionedModel(session, project, merged: ids.merged, open: [])
        #expect(model.rows.first { $0.id == agent }?.section == .working)
        #expect(model.rows.first { $0.id == agent }?.isActive == true)
    }

    /// An item on a row's pane keeps the row working, found through the
    /// pane's tab; one for a session that stopped before its pane opened,
    /// through the row's folder.
    @Test func anItemForARow_keepsItWorking() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let agentA = ids.agentA
        let root = try #require(session.rootDirectory(of: agentA))
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .sessionRow(worktreeRoot: root), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .sessionRow(projectID: project.id, worktreeRoot: root),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let sections = SidebarPresentedSections.computed(
            project: project,
            session: session,
            window: session.primaryWindowID,
            queue: queue,
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        #expect(sections.section(of: agentA) == .working)
        #expect(sections.section(of: ids.agentB) == .other)
    }

    /// One of the other worktrees says it is not a working row and how it becomes one,
    /// and VoiceOver names its list, which on screen only the line above says.
    @Test func anOtherWorktree_saysOpeningItMakesItAWorkingRow() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let model = Self.sectionedModel(session, project, merged: ids.merged, open: [.other])
        let row = try #require(model.rows.first { $0.id == ids.agentA })

        let tooltip = SessionRowFactText.tooltip(for: row, now: .now, locale: Self.english)
        #expect(tooltip.hasSuffix("\nNot among the worktrees above. Opening it adds it there."), "\(tooltip)")
        let spoken = SessionRowFactText.spokenLabel(for: row, projectName: "weir", now: .now, locale: Self.english)
        #expect(spoken.contains(", weir, Other Worktrees, "), "\(spoken)")
        let working = try #require(model.rows.first { $0.id == ids.working })
        #expect(!SessionRowFactText.tooltip(for: working, now: .now, locale: Self.english).contains("Not among the worktrees above"))
    }

    /// Move to Other Worktrees is offered only where it would move the row: not
    /// on the selected row, one with a tab, one already among the others,
    /// a pinned folder, or one whose folder is gone.
    @Test func removeFromWorking_isOfferedOnlyWhereItMovesTheRow() throws {
        let (session, project, ids) = try Self.sectionedProject()
        let model = Self.sectionedModel(session, project, merged: ids.merged, open: [.other])
        let made = ids.merged
        // One of the other worktrees has nowhere further to go.
        let other = try #require(model.rows.first { $0.id == ids.agentA })
        let otherWorktree = try #require(project.worktrees
            .first { ContainerID.worktree(projectID: project.id, worktreeID: $0.id) == ids.agentA })
        #expect(!SessionSidebarModel.offersRemoveFromWorking(other, worktree: otherWorktree, hasTabs: false))

        // Without its merged request, the row Weir made is a working one.
        let working = Self.sectionedModel(session, project, merged: .loose, open: [])
        let madeRow = try #require(working.rows.first { $0.id == made })
        let madeWorktree = try #require(project.worktrees.first { ContainerID.worktree(projectID: project.id, worktreeID: $0.id) == made })
        #expect(SessionSidebarModel.offersRemoveFromWorking(madeRow, worktree: madeWorktree, hasTabs: false))
        #expect(!SessionSidebarModel.offersRemoveFromWorking(madeRow, worktree: madeWorktree, hasTabs: true))
        var pinned = madeWorktree
        pinned.origin = .userPinned
        #expect(!SessionSidebarModel.offersRemoveFromWorking(madeRow, worktree: pinned, hasTabs: false))
        var gone = madeWorktree
        gone.missingSince = Date(timeIntervalSince1970: 0)
        #expect(!SessionSidebarModel.offersRemoveFromWorking(madeRow, worktree: gone, hasTabs: false))

        session.setActiveContainer(made, in: session.primaryWindowID, intent: .person)
        let selected = try Self.sectionedModel(session, #require(session.project(project.id)), merged: .loose, open: [])
        let selectedRow = try #require(selected.rows.first { $0.id == made })
        #expect(!SessionSidebarModel.offersRemoveFromWorking(selectedRow, worktree: madeWorktree, hasTabs: false))
    }

    /// The folder's row is named as any row is, and its tooltip and VoiceOver
    /// say in words that it is the repository. Its line at rest
    /// states its Git facts, as any row's does.
    @Test func theFoldersRow_saysItIsTheRepository() throws {
        let (session, project) = Self.project()
        let folder = try #require(Self.model(session, project).rows.first { $0.isMainFolder })

        #expect(folder.factText == "Idle")
        #expect(SessionRowFactText.tooltip(for: folder, now: .now, locale: Self.english) == "main · Repository folder")
        let spoken = SessionRowFactText.spokenLabel(for: folder, projectName: "weir", now: .now, locale: Self.english)
        #expect(spoken == "Shell, main, weir, Repository folder, Idle", "\(spoken); a shell says Shell once")
        let clean = GitFactsFixture.make(branch: "main", commits: nil, unpushed: nil, uncommitted: 0, base: nil)
        let read = try #require(Self.model(session, project) { _ in clean }.rows.first { $0.isMainFolder })
        #expect(read.factText == "No changes")
        // A worktree's row at rest is idle.
        #expect(Self.model(session, project).rows.first { !$0.isMainFolder }?.factText == "Idle")
    }

    /// A detached worktree has no branch: its folder names it.
    @Test func aDetachedWorktree_isNamedByItsFolder() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "alpha")
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].worktrees = [Worktree(
            label: "(unnamed)",
            workingDirectory: URL(fileURLWithPath: "/tmp/alpha-detached"),
            gitRef: GitRef(branchName: nil, headSHA: "abc"),
            origin: .gitWorktree,
            admission: .opened
        )]
        let row = try #require(Self.model(session, session.projects[index]).rows.first { !$0.isMainFolder })
        #expect(row.name == "alpha-detached")
        #expect(row.nameTruncation == .name)
    }

    /// Opening one of the other worktrees makes it a working row for good:
    /// it stays one after the person moves to another row.
    @Test func anOtherWorktreeThePersonOpens_staysAWorkingRow() throws {
        let (session, project, ids) = try Self.sectionedProject()
        session.setActiveContainer(ids.agentA, in: session.primaryWindowID, intent: .person)
        session.setActiveContainer(ids.folder, in: session.primaryWindowID, intent: .person)

        let model = try Self.sectionedModel(session, #require(session.project(project.id)), merged: ids.merged, open: [])
        #expect(model.rows.first { $0.id == ids.agentA }?.section == .working)
        #expect(!model.rows.contains { $0.id == ids.agentB })
    }
}

/// A row whose second line states something other than its request still
/// shows the request's mark, so VoiceOver reads the request too.
struct SessionRowAttachedPullRequestTests {
    private static let english = Locale(identifier: "en")

    @Test func aStoppedRow_readsTheStop_thenItsPullRequest() {
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .runtime(id: "r", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        var input = SessionSidebarModel.RowInput.test(fact: .init(
            items: queue.items,
            agents: [.init(provider: .claude, state: .error, detail: nil)],
            pullRequest: .init(number: 128, state: .open, isDraft: false)
        ))
        input.pullRequestChecks = (PRChecks(conclusion: .failure, counts: .init(passed: 3, total: 4)), .gitHub)
        let row = SessionSidebarModel.Row.test(input)
        #expect(row.fact.glyph == .stopped)
        #expect(row.pullRequestText == "PR #128 · Open")
        let spoken = SessionRowFactText.spokenLabel(for: row, projectName: "weir", now: .now, locale: Self.english)
        #expect(spoken.hasPrefix("Stopped, main, weir, "), "\(spoken)")
        #expect(spoken.hasSuffix(", PR #128, Open, Checks failed, 3 of 4 passed, Claude"), "\(spoken)")
    }
}
