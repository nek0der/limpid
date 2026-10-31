// CommitAndPRModelTests.swift
// Weir — "Commit & PR": what it says of the branch, when "Create PR" can be pressed, and the moves after a request.

import Foundation
import Testing
@testable import Weir

struct CommitAndPRModelTests {
    private typealias Fixture = GitFactsFixture
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test func theLines_sayWhereTheBranchStands_orThatNothingDiffers() {
        let all = CommitAndPRModel.make(Fixture.input(Fixture.make(commits: 3, unpushed: 1, uncommitted: 2)))
        #expect(all.lines == [.notOnBase(base: "main", commits: 3), .unpushed(commits: 1), .uncommitted(files: 2)])
        #expect(all.lines.map { CommitAndPRText.line($0, locale: Self.english) }
            == ["3 commits not in main", "1 unpushed commit", "2 uncommitted files"])
        #expect(all.lines.map { CommitAndPRText.line($0, locale: Self.japanese) }
            == ["main にないコミット 3", "プッシュしていないコミット 1", "未コミット 2 ファイル"])
        #expect(CommitAndPRText.line(.notOnBase(base: "main", commits: 1), locale: Self.english) == "1 commit not in main")

        let none = CommitAndPRModel.make(Fixture.input(Fixture.make(commits: 0)))
        #expect(none.lines == [.noDifference(base: "main")])
        #expect(CommitAndPRText.line(.noDifference(base: "main"), locale: Self.english) == "No changes from main")
        #expect(CommitAndPRText.line(.noDifference(base: "main"), locale: Self.japanese) == "main との差分はありません")
    }

    @Test func createPRsWait_namesEveryWaitItWaitsFor() {
        // A response wait (`.prompt`) holds the PR as the approval and the
        // question do, and the sentence names it.
        #expect(CommitAndPRText.blocker(.waiting, locale: Self.english)
            == "An agent is waiting for approval, an answer, or a response, or has stopped.")
        #expect(CommitAndPRText.blocker(.waiting, locale: Self.japanese)
            == "承認待ち、回答待ち、応答待ち、または停止したエージェントがあります。")

        // And the sentence says what the blocker reads: every one of these.
        let key = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
        let approval = ApprovalFact(key: key, provider: .claude, isQuestion: false, supportsNativeAnswer: true, state: .held, deadline: nil)
        let question = ApprovalFact(key: key, provider: .claude, isQuestion: true, supportsNativeAnswer: true, state: .held, deadline: nil)
        func items(_ kind: AttentionItemKind) -> [AttentionItem] {
            var queue = AttentionQueue()
            queue.insert(
                id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
                kind: kind,
                subject: .runtime(id: "r", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
                arrivedAt: Date(timeIntervalSince1970: 0)
            )
            return queue.items
        }
        #expect(CommitAndPRModel.isWaiting(items(.approval(approval))))
        #expect(CommitAndPRModel.isWaiting(items(.question(question))))
        #expect(CommitAndPRModel.isWaiting(items(.prompt(PromptWait(detail: "Allow network access?")))))
        #expect(CommitAndPRModel.isWaiting(items(.stop(.processExited))))
        #expect(!CommitAndPRModel.isWaiting(items(.unread(UnreadTurn(turnID: TurnID("t"), changes: .unchanged)))))
    }

    @Test func theLines_leaveOutCommitsThatProposeNothing() {
        // On main, commits ahead of origin are not "not in main".
        let onMain = CommitAndPRModel.make(Fixture.input(Fixture.make(branch: "main", commits: 2, unpushed: 2)))
        #expect(onMain.lines == [.unpushed(commits: 2)])
        // Merged: the commits are in, however the merge left them.
        let merged = CommitAndPRModel.make(Fixture.input(pullRequest: PRInfoFixture.make(state: .merged)))
        #expect(merged.lines == [.noDifference(base: "main")])
        // No base: nothing to count against, and nothing said of it.
        #expect(CommitAndPRModel.make(Fixture.input(Fixture.make(base: nil))).lines.isEmpty)
        #expect(CommitAndPRModel.make(Fixture.input(nil)).lines.isEmpty)
    }

    @Test func cleaningUp_isOfferedForAMergedRequestsWorktree_andStopsOnWorkNoRemoteHas() {
        let merged = PRInfoFixture.make(state: .merged)
        #expect(CommitAndPRModel.make(Fixture.input(pullRequest: merged)).offersCleanUp)
        var folder = Fixture.input(pullRequest: merged)
        folder.isWorktree = false
        #expect(!CommitAndPRModel.make(folder).offersCleanUp)
        #expect(!CommitAndPRModel.make(Fixture.input(pullRequest: PRInfoFixture.make(state: .open))).offersCleanUp)

        let blocker = CommitAndPRModel.cleanUpBlocker(Fixture.make(unpushed: 2, uncommitted: 1))
        #expect(blocker?.unpushed == 2)
        #expect(blocker?.uncommitted == 1)
        #expect(CommitAndPRModel.cleanUpBlocker(Fixture.make(unpushed: 0)) == nil)
        // The upstream deleted as the request merged: not known, not a stop.
        #expect(CommitAndPRModel.cleanUpBlocker(Fixture.make(unpushed: nil)) == nil)
        #expect(CommitAndPRText.cleanUpBlocked(unpushed: 2, uncommitted: 1, locale: Self.english) == """
        This worktree has work that isn’t on a remote:
        2 unpushed commits
        1 uncommitted file
        Commit and push it first, or use Delete Worktree… in the sidebar.
        """)
        #expect(CommitAndPRText.cleanUpBlocked(unpushed: 0, uncommitted: 3, locale: Self.japanese) == """
        このワークツリーには、リモートにない作業があります。
        未コミット 3 ファイル
        先にコミットしてプッシュするか、サイドバーの「ワークツリーを削除…」で削除してください。
        """)
    }

    @Test func theExternalTool_isNamedByTheProgramItRuns_andHiddenWhenUnset() {
        var input = Fixture.input()
        #expect(CommitAndPRModel.make(input).externalTool == nil)
        input.externalCommand = "   "
        #expect(CommitAndPRModel.make(input).externalTool == nil)
        input.externalCommand = " /opt/homebrew/bin/tig --all "
        #expect(CommitAndPRModel.make(input).externalTool
            == CommitAndPRModel.ExternalTool(name: "tig", command: "/opt/homebrew/bin/tig --all"))
        input.externalCommand = "env PAGER=less TERM=xterm tig"
        #expect(CommitAndPRModel.make(input).externalTool?.name == "tig")
        input.externalCommand = "env -i tig"
        #expect(CommitAndPRModel.make(input).externalTool?.name == "tig")
    }

    @Test func theFootAction_isTheOutsideChanges_thenCreatePR_thenTheRequest() {
        let closed = PRInfoFixture.make(state: .closed)
        var input = Fixture.input(pullRequest: closed)
        input.unviewedOutsideTurns = 2
        // Changes outside turns first, whatever else is offered; the rest
        // stay above the bar.
        let outside = CommitAndPRModel.make(input)
        #expect(outside.footAction == .showCurrentDiff)
        #expect(outside.offersCreateAboveFoot)
        #expect(outside.offersOpenAboveFoot)

        // Then "Create PR", pressable or not, with a closed request's
        // "Open on GitHub" above it.
        input.unviewedOutsideTurns = 0
        let create = CommitAndPRModel.make(input)
        #expect(create.footAction == .createPullRequest(.available([])))
        #expect(!create.offersCreateAboveFoot)
        #expect(create.offersOpenAboveFoot)
        input.unviewedTurns = 2
        #expect(CommitAndPRModel.make(input).footAction == .createPullRequest(.blocked(.unviewedTurns(2))))

        // Then the request, open or merged, where "Create PR" is not
        // offered; "Clean Up Worktree…" stays above.
        let open = PRInfoFixture.make(state: .open)
        let opened = CommitAndPRModel.make(Fixture.input(pullRequest: open))
        #expect(opened.footAction == .openPullRequest(open))
        #expect(!opened.offersOpenAboveFoot)
        #expect(!opened.offersCreateAboveFoot)
        let merged = PRInfoFixture.make(state: .merged)
        let afterMerge = CommitAndPRModel.make(Fixture.input(pullRequest: merged))
        #expect(afterMerge.footAction == .openPullRequest(merged))
        #expect(afterMerge.offersCleanUp)

        #expect(!afterMerge.offersExternalToolAboveFoot)

        // Then the person's own tool, with no gh and no request; with a
        // request, the tool stays above.
        var noGh = Fixture.input()
        noGh.hasGitHubCLI = false
        noGh.externalCommand = "tig"
        let tool = CommitAndPRModel.make(noGh)
        #expect(tool.footAction == .openExternalTool(CommitAndPRModel.ExternalTool(name: "tig", command: "tig")))
        #expect(!tool.offersExternalToolAboveFoot)
        var openWithTool = Fixture.input(pullRequest: open)
        openWithTool.externalCommand = "tig"
        #expect(CommitAndPRModel.make(openWithTool).offersExternalToolAboveFoot)

        // Nothing for the bar: no gh, no request, and no tool.
        noGh.externalCommand = ""
        #expect(CommitAndPRModel.make(noGh).footAction == nil)
    }

    @Test func theFootBar_hearsAPressOnlyOnceItsButtonHasStoodAMoment() {
        let start = SuspendingClock.Instant.now
        let delay = CommitAndPRFootGate.minimumSettle
        var gate = CommitAndPRFootGate()
        // Nothing shown yet: nothing is pressed.
        #expect(!gate.accepts(.showCurrentDiff, at: start, settle: delay))

        gate.noteShown(.showCurrentDiff, at: start)
        #expect(!gate.accepts(.showCurrentDiff, at: start + .milliseconds(100), settle: delay))
        #expect(gate.accepts(.showCurrentDiff, at: start + delay, settle: delay))

        // "Create PR" takes its place under the pointer: the second press of
        // a double press, meant for the button before, does nothing.
        let swapped = start + .seconds(5)
        gate.noteShown(.createPullRequest, at: swapped)
        #expect(!gate.accepts(.showCurrentDiff, at: swapped + .milliseconds(100), settle: delay))
        #expect(!gate.accepts(.createPullRequest, at: swapped + .milliseconds(100), settle: delay))
        #expect(!gate.accepts(.createPullRequest, at: swapped + delay - .milliseconds(1), settle: delay))
        #expect(gate.accepts(.createPullRequest, at: swapped + delay, settle: delay))

        // The same move shown again keeps its time: "Create PR" turning
        // pressable is no new button.
        gate.noteShown(.createPullRequest, at: swapped + .seconds(3))
        #expect(gate.accepts(.createPullRequest, at: swapped + .seconds(3), settle: delay))

        // An empty bar, then a button again: that button waits anew.
        let later = swapped + .seconds(10)
        gate.noteShown(nil, at: later)
        gate.noteShown(.openPullRequest, at: later + .seconds(1))
        #expect(!gate.accepts(.openPullRequest, at: later + .seconds(1) + .milliseconds(100), settle: delay))
        #expect(gate.accepts(.openPullRequest, at: later + .seconds(1) + delay, settle: delay))
    }

    @Test func theFootBarsWait_followsASlowDoubleClick() {
        // Never under half a second, however quick the double click is set.
        #expect(CommitAndPRFootGate.settle(doubleClickInterval: 0.25) == .milliseconds(500))
        #expect(CommitAndPRFootGate.settle(doubleClickInterval: 0.5) == .milliseconds(500))
        // A slower hand's setting stretches it.
        let slow = CommitAndPRFootGate.settle(doubleClickInterval: 2)
        #expect(slow == .seconds(2))

        let start = SuspendingClock.Instant.now
        var gate = CommitAndPRFootGate()
        gate.noteShown(.createPullRequest, at: start)
        // A second press 1.5s after the swap is still the slow double click's.
        #expect(!gate.accepts(.createPullRequest, at: start + .milliseconds(1500), settle: slow))
        #expect(gate.accepts(.createPullRequest, at: start + .milliseconds(1500), settle: CommitAndPRFootGate.minimumSettle))
        #expect(gate.accepts(.createPullRequest, at: start + slow, settle: slow))
    }

    @Test func theRequestAndTheOutsideNotice_readAsTheRowAndTheSpecSay() {
        let request = PRInfoFixture.make(number: 128, state: .open, checks: .success, counts: PRChecks.Counts(passed: 4, total: 4))
        #expect(CommitAndPRText.pullRequest(request, locale: Self.english) == "PR #128 · Open · Checks passed (4/4)")
        #expect(CommitAndPRText.outsideTurns(1, locale: Self.english)
            == "1 file changed outside turns (unviewed). Check the current diff before creating a PR.")
        #expect(CommitAndPRText.outsideTurns(3, locale: Self.japanese)
            == "ターン外の変更が 3 ファイルあります（未確認）。PR を作成する前に、現在の差分を確認してください。")
    }

    // MARK: - When "Create PR" can be pressed

    private static func create(_ input: CommitAndPRModel.Input) -> CommitAndPRModel.Create? {
        CommitAndPRModel.make(input).create
    }

    @Test func aBranchWithCommitsNotOnTheDefaultBranch_canCreateAPullRequest() {
        #expect(Self.create(Fixture.input()) == .available([]))
        // Pushing is not asked first: gh offers it.
        #expect(Self.create(Fixture.input(Fixture.make(unpushed: 2))) == .available([.unpushedWillBePushed]))
        #expect(Self.create(Fixture.input(Fixture.make(unpushed: 1, uncommitted: 3)))
            == .available([.unpushedWillBePushed, .uncommittedNotIncluded]))
    }

    @Test func whatTheBranchHolds_decidesBeforeTheAgents() {
        // Commits ahead of origin on main itself are no proposal.
        var onMain = Fixture.input(Fixture.make(branch: "main", commits: 2))
        onMain.isRunning = true
        #expect(Self.create(onMain) == .blocked(.defaultBranch))
        #expect(Self.create(Fixture.input(Fixture.make(branch: nil))) == .blocked(.detachedHead))
        #expect(Self.create(Fixture.input(Fixture.make(commits: 0, uncommitted: 2))) == .blocked(.uncommittedOnly))
        #expect(Self.create(Fixture.input(Fixture.make(commits: 0))) == .blocked(.nothingToPropose))
    }

    @Test func anAgentWaiting_thenOneRunning_thenUnviewedTurns_eachBlockOnTheirOwn() {
        var input = Fixture.input()
        input.isWaiting = true
        input.isRunning = true
        input.unviewedTurns = 2
        #expect(Self.create(input) == .blocked(.waiting))
        input.isWaiting = false
        #expect(Self.create(input) == .blocked(.running))
        input.isRunning = false
        #expect(Self.create(input) == .blocked(.unviewedTurns(2)))
        input.unviewedTurns = 0
        // Changes outside turns are pointed out, but stop nothing.
        input.unviewedOutsideTurns = 3
        #expect(Self.create(input) == .available([]))
        #expect(CommitAndPRModel.make(input).unviewedOutsideTurns == 3)
    }

    @Test func createPR_isNotOffered_withoutGh_aBase_orTheBranchRead_norWithAnOpenOrMergedRequest() {
        var noGh = Fixture.input()
        noGh.hasGitHubCLI = false
        #expect(Self.create(noGh) == nil)
        #expect(Self.create(Fixture.input(Fixture.make(base: nil))) == nil)
        #expect(Self.create(Fixture.input(nil)) == nil)
        #expect(Self.create(Fixture.input(pullRequest: PRInfoFixture.make(state: .open))) == nil)
        #expect(Self.create(Fixture.input(pullRequest: PRInfoFixture.make(state: .open, isDraft: true))) == nil)
        #expect(Self.create(Fixture.input(pullRequest: PRInfoFixture.make(state: .merged))) == nil)
        // A closed request may be proposed again.
        #expect(Self.create(Fixture.input(pullRequest: PRInfoFixture.make(state: .closed))) == .available([]))
    }

    @Test func eachReason_readsInBothLanguages() {
        #expect(CommitAndPRText.blocker(.unviewedTurns(1), locale: Self.english) == "1 turn is unviewed. View it before creating a PR.")
        #expect(CommitAndPRText.blocker(.unviewedTurns(2), locale: Self.japanese)
            == "未確認のターンが 2 件あります。PR を作成する前に確認してください。")
        #expect(CommitAndPRText.blocker(.defaultBranch, locale: Self.japanese) == "デフォルトのブランチからは PR を作成できません。")
        #expect(CommitAndPRText.blocker(.detachedHead, locale: Self.japanese) == "PR を作成するには、ブランチに切り替えてください。")
        #expect(CommitAndPRText.blocker(.running, locale: Self.japanese) == "エージェントの実行中は PR を作成できません。")
        #expect(CommitAndPRText.blocker(.nothingToPropose, locale: Self.english) == "There are no commits for a PR.")
        #expect(CommitAndPRText.note(.unpushedWillBePushed, locale: Self.english) == "gh asks before pushing unpushed commits.")
        #expect(CommitAndPRText.note(.unpushedWillBePushed, locale: Self.japanese)
            == "プッシュしていないコミットは、gh が確認したうえでプッシュします。")
    }
}
