// SessionHeaderModelTests.swift
// Weir — what the session header says.

import Foundation
import Testing
@testable import Weir

@MainActor
struct SessionHeaderModelTests {
    @Test func aSessionThatIsOneShellTab_isHeadedLikeAnyOther() {
        let english = Locale(identifier: "en")
        func row(agents: [SessionRowFact.Agent]) -> SessionSidebarModel.Row {
            .test(.test(container: .loose, fact: .init(agents: agents)))
        }
        let shell = row(agents: [])
        let agent = row(agents: [.init(provider: .claude, state: .idle, detail: nil)])

        // The header shows for every session: one shell tab gets the
        // same name and chips an agent's session does.
        for row in [shell, agent] {
            let withPullRequest = SessionHeaderModel(row: row, pullRequestNumber: 128, locale: english)
            #expect(withPullRequest.gitChips.map(\.text) == ["PR #128"])
            #expect(withPullRequest.name == "main")
        }
    }

    @Test func theGitChips_readPullRequest_thenCommits_thenUncommittedFiles() {
        let english = Locale(identifier: "en")
        let row = SessionSidebarModel.Row.test(.test(container: .loose))
        let facts = GitFactsFixture.make(commits: 1, unpushed: 1, uncommitted: 2)
        let model = SessionHeaderModel(row: row, pullRequestNumber: 128, gitFacts: facts, locale: english)
        #expect(model.gitChips.map(\.text) == ["PR #128", "+1 commit", "2 files uncommitted"])

        // A count of nothing is no chip.
        var clean = facts
        clean.commitsNotOnBase = 0
        clean.uncommittedFiles = 0
        let japanese = SessionHeaderModel(row: row, pullRequestNumber: nil, gitFacts: facts, locale: Locale(identifier: "ja"))
        #expect(SessionHeaderModel(row: row, pullRequestNumber: nil, gitFacts: clean, locale: english).gitChips.isEmpty)
        #expect(japanese.gitChips.map(\.text) == ["+1 コミット", "未コミット 2 ファイル"])
        // A chip keeps its identity as its count changes.
        #expect(model.gitChips.map(\.id) == ["pullRequest", "commits", "uncommitted"])

        // A squash merge leaves the commits off the default branch; once
        // the request is merged they are not work still to propose.
        let merged = SessionHeaderModel(
            row: row,
            pullRequestNumber: 128,
            pullRequestState: .merged,
            gitFacts: facts,
            locale: english
        )
        #expect(merged.gitChips.map(\.text) == ["PR #128", "2 files uncommitted"])

        // On the default branch, its own commits ahead of origin are no
        // proposal.
        var onMain = facts
        onMain.branch = "main"
        #expect(SessionHeaderModel(row: row, pullRequestNumber: nil, gitFacts: onMain, locale: english)
            .gitChips.map(\.text) == ["2 files uncommitted"])
    }

    @Test func theScratchHeader_isNamedScratch_whateverItsTabsAreCalled() {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { $0.titleOverride = "notes" }
        session.setActiveTab(tab.id)

        let row = SessionSidebarModel(
            activeIn: session,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: nil,
            gitFacts: nil,
            locale: Locale(identifier: "en")
        ).rows.first
        #expect(row?.name == "Scratch")
        #expect(row?.id == .loose)
    }

    @Test func theHeader_isOfTheSessionTheWindowShows() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        session.openTab(container: .project(project.id))
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.openTab(container: .loose, in: other)

        let row = SessionSidebarModel(
            activeIn: session,
            window: other,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: nil,
            gitFacts: nil,
            locale: Locale(identifier: "en")
        ).rows.first
        #expect(row?.id == .loose)
        #expect(session.primarySelection.activeContainerID == .project(project.id))
    }
}
