// WorktreeDropdownTextTests.swift
// Limpid — the worktree dropdown: the sidebar's names and order, each folder's line, and VoiceOver.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct WorktreeDropdownTextTests {
    @Test func aWorktreesFolderLine_countsItsAgents_onlyWhenMoreThanOne() {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        func detail(_ count: Int, _ locale: Locale) -> String {
            WorktreeDropdownText.detail(name: "main", branch: "main", folder: "~/code/limpid", agentCount: count, locale: locale)
        }
        #expect(detail(0, english) == "~/code/limpid")
        #expect(detail(1, english) == "~/code/limpid")
        #expect(detail(2, english) == "~/code/limpid · Agents 2")
        #expect(detail(2, japanese) == "~/code/limpid · エージェント 2")
    }

    /// A row named by a conversation or by the person still says which
    /// branch it is, under the name; a row named by its branch does not
    /// say it twice, and one with no branch (detached) says only its folder.
    @Test func aNameThatIsNotTheBranch_hasTheBranchUnderIt() {
        let english = Locale(identifier: "en")
        #expect(WorktreeDropdownText.detail(name: "Fix login", branch: "feat/login", folder: "~/w/login", agentCount: 0, locale: english)
            == "feat/login · ~/w/login")
        #expect(WorktreeDropdownText.detail(name: "feat/login", branch: "feat/login", folder: "~/w/login", agentCount: 0, locale: english)
            == "~/w/login")
        #expect(WorktreeDropdownText.detail(name: "login", branch: "", folder: "~/w/login", agentCount: 2, locale: english)
            == "~/w/login · Agents 2")
    }

    /// A checkout with a pull request reads its state, then the request,
    /// its state, and its checks, as its sidebar row does, whatever
    /// the state. One without reads its state's name alone.
    @Test func aCheckoutWithAPullRequest_readsItsStateThenTheRequest() {
        let english = Locale(identifier: "en")
        func row(_ fact: SessionRowFact.Input) -> SessionSidebarModel.Row {
            var input = SessionSidebarModel.RowInput.test(name: "feat/turns", fact: fact)
            input.pullRequestChecks = (PRChecks(conclusion: .success, counts: .init(passed: 4, total: 4)), .gitHub)
            return .test(input)
        }
        let marked = row(.init(
            agents: [.init(provider: .claude, state: .idle, detail: nil)],
            pullRequest: .init(number: 128, state: .open, isDraft: false)
        ))
        #expect(marked.fact.glyph == .idle)
        #expect(WorktreeDropdownText.spokenLabel(name: "feat/turns", row: marked, detail: "~/code/limpid", locale: english)
            == "feat/turns, Idle, PR #128, Open, Checks passed, 4 of 4, ~/code/limpid")

        let runningWithRequest = row(.init(
            agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")],
            pullRequest: .init(number: 128, state: .open, isDraft: false)
        ))
        #expect(WorktreeDropdownText.spokenLabel(name: "feat/turns", row: runningWithRequest, detail: "~/code/limpid", locale: english)
            == "feat/turns, Running, PR #128, Open, Checks passed, 4 of 4, ~/code/limpid")

        let running = row(.init(agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")]))
        #expect(WorktreeDropdownText.spokenLabel(name: "feat/turns", row: running, detail: "~/code/limpid", locale: english)
            == "feat/turns, Running, ~/code/limpid")
    }

    /// The ▾ lists the checkouts as the sidebar does: the folder, the
    /// working worktrees after it, then the other worktrees; a
    /// hidden one not at all. Each goes by its row's name, its branch while
    /// the sidebar has no row for it.
    @Test func theEntries_followTheSidebarsOrder_andItsNames() {
        let rootURL = URL(fileURLWithPath: "/tmp/alpha")
        let working = Worktree(label: "feat/a", workingDirectory: URL(fileURLWithPath: "/tmp/alpha-a"), origin: .gitWorktree)
        let other = Worktree(
            label: "agent-1",
            workingDirectory: URL(fileURLWithPath: "/tmp/alpha/.claude/worktrees/agent-1"),
            origin: .gitWorktree
        )
        let hidden = Worktree(label: "old", workingDirectory: URL(fileURLWithPath: "/tmp/alpha-old"), origin: .gitWorktree, isHidden: true)
        let merged = Worktree(label: "fix/done", workingDirectory: URL(fileURLWithPath: "/tmp/alpha-done"), origin: .gitWorktree)
        let project = Project(name: "alpha", rootURL: rootURL, worktrees: [other, merged, working, hidden])
        let mergedRow = ContainerID.worktree(projectID: project.id, worktreeID: merged.id)
        let otherRow = ContainerID.worktree(projectID: project.id, worktreeID: other.id)
        let workingRow = ContainerID.worktree(projectID: project.id, worktreeID: working.id)
        let sections = SidebarPresentedSections(sections: [
            otherRow: .other, mergedRow: .cleanable, workingRow: .working, .project(project.id): .working
        ])
        let named = SessionSidebarModel.Row.test(.test(container: workingRow, name: "Fix login"))

        let entries = WorktreeDropdownEntry.entries(of: project, in: sections, rows: [workingRow: named])

        #expect(entries.map(\.container) == [.project(project.id), workingRow, mergedRow, otherRow])
        #expect(entries.map(\.name) == [CheckoutName.label(of: project), "Fix login", "fix/done", "agent-1"])
        #expect(entries.first { $0.container == workingRow }?.branch == "feat/a")
    }
}
