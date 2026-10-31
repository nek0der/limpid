// PullRequestCheckoutRulesTests.swift
// Weir — the pull request number as typed, and the local branch a pull request's worktree checks out.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct PullRequestCheckoutRulesTests {
    @Test(arguments: [
        ("12", 12), ("#12", 12), (" 7 ", 7), ("!34", 34),
        ("https://github.com/acme/app/pull/128", 128),
        ("https://github.com/acme/app/pull/128/files", 128),
        ("https://gitlab.com/acme/app/-/merge_requests/9", 9)
    ])
    func aNumberALinkOrAMark_readsAsTheNumber(text: String, number: Int) {
        #expect(PullRequestNumber.parse(text) == number)
    }

    @Test(arguments: ["", "#", "0", "-3", "12a", "１２", "abc", "https://github.com/acme/app/issues/5"])
    func anythingElse_readsAsNone(text: String) {
        #expect(PullRequestNumber.parse(text) == nil)
    }

    private static let head = PullRequestHead.fixture(12, branch: "fix/login", commit: "c0ffee")

    @Test func theRequestsBranchName_whenNoLocalBranchHasIt() {
        let choice = PullRequestBranchChoice.choose(for: Self.head, commit: "c0ffee", localTips: ["main": "aaa"], checkedOut: ["main"])
        #expect(choice == .newBranch("fix/login"))
    }

    @Test func aLocalBranchAtTheRequestsCommit_isReused() {
        let choice = PullRequestBranchChoice.choose(for: Self.head, commit: "c0ffee", localTips: ["fix/login": "c0ffee"], checkedOut: [])
        #expect(choice == .existingBranch("fix/login"))
    }

    @Test func aLocalBranchAtTheRequestsCommit_checkedOutElsewhere_saysSo() {
        let choice = PullRequestBranchChoice.choose(
            for: Self.head,
            commit: "c0ffee",
            localTips: ["fix/login": "c0ffee"],
            checkedOut: ["fix/login"]
        )
        #expect(choice == .checkedOut("fix/login"))
    }

    /// A fork's `main` meets the person's own `main`: that one never moves,
    /// and the request gets a branch of its own.
    @Test func aLocalBranchOfTheNameAtAnotherCommit_isLeftAlone_forPrN() {
        let fork = PullRequestHead.fixture(12, branch: "main", commit: "c0ffee", forkOwner: "alice")
        let choice = PullRequestBranchChoice.choose(for: fork, commit: "c0ffee", localTips: ["main": "aaa"], checkedOut: ["main"])
        #expect(choice == .newBranch("pr/12"))
    }

    @Test func prN_takenByAnotherCommit_movesOnToTheNextFreeName() {
        let choice = PullRequestBranchChoice.choose(
            for: Self.head,
            commit: "c0ffee",
            localTips: ["fix/login": "aaa", "pr/12": "bbb", "pr/12-2": "ccc"],
            checkedOut: []
        )
        #expect(choice == .newBranch("pr/12-3"))
    }

    @Test func prN_atTheRequestsCommit_isReused() {
        let choice = PullRequestBranchChoice.choose(
            for: Self.head,
            commit: "c0ffee",
            localTips: ["fix/login": "aaa", "pr/12": "c0ffee"],
            checkedOut: []
        )
        #expect(choice == .existingBranch("pr/12"))
    }

    /// Before the fetch, with no commit from the forge, a branch of the
    /// request's name is never taken to be at it.
    @Test func noCommitKnown_neverReusesABranch() {
        let choice = PullRequestBranchChoice.choose(
            for: PullRequestHead.fixture(12, branch: "fix/login"),
            commit: nil,
            localTips: ["fix/login": "c0ffee"],
            checkedOut: []
        )
        #expect(choice == .newBranch("pr/12"))
    }

    @Test func everyNameTaken_endsAtTheLastForGitToRefuse() {
        var tips = ["fix/login": "x", "pr/12": "x"]
        for suffix in 2...PullRequestBranchChoice.maximumSuffix {
            tips["pr/12-\(suffix)"] = "x"
        }
        let choice = PullRequestBranchChoice.choose(for: Self.head, commit: "c0ffee", localTips: tips, checkedOut: [])
        #expect(choice == .newBranch("pr/12-\(PullRequestBranchChoice.maximumSuffix)"))
    }

    /// Git keeps a branch as a file under its name: no `fix` beside
    /// `fix/login`, and no `pr/12` beside a branch `pr`.
    @Test func aNameAFolderOfBranchesStandsIn_isPassedOver() {
        let fix = PullRequestHead.fixture(12, branch: "fix", commit: "c")
        #expect(PullRequestBranchChoice.choose(for: fix, commit: "c", localTips: ["fix/login": "x"], checkedOut: []) == .newBranch("pr/12"))
        let nested = PullRequestHead.fixture(12, branch: "feat/x/y", commit: "c")
        #expect(PullRequestBranchChoice.choose(for: nested, commit: "c", localTips: ["feat/x": "x"], checkedOut: []) == .newBranch("pr/12"))
        // With `pr` taken too, every name is; the last is offered for Git
        // to refuse in its own words.
        #expect(PullRequestBranchChoice.choose(for: fix, commit: "c", localTips: ["fix/login": "x", "pr": "y"], checkedOut: [])
            == .newBranch("pr/12-\(PullRequestBranchChoice.maximumSuffix)"))
    }

    @Test func aLinksRepository_isItsHostAndPath() {
        #expect(PullRequestNumber.repository(in: "https://github.com/Acme/App/pull/12") == "github.com/acme/app")
        #expect(PullRequestNumber.repository(in: "https://gitlab.com/group/sub/app/-/merge_requests/3") == "gitlab.com/group/sub/app")
        #expect(PullRequestNumber.repository(in: "#12") == nil)
        #expect(PullRequestNumber.repository(in: "12") == nil)
    }

    @Test func aRemotesRepository_isItsHostAndPath() {
        #expect(ForgeResolver.repository(fromRemoteURL: "https://github.com/acme/app.git") == "github.com/acme/app")
        #expect(ForgeResolver.repository(fromRemoteURL: "git@github.com:acme/app") == "github.com/acme/app")
        #expect(ForgeResolver.repository(fromRemoteURL: "ssh://git@gitlab.acme.io/group/sub/app.git/") == "gitlab.acme.io/group/sub/app")
        #expect(ForgeResolver.repository(fromRemoteURL: "/srv/app.git") == nil)
    }

    @Test func theForgesRef_forEachForge() {
        #expect(ForgeKind.gitHub.headRef(of: 7) == "refs/pull/7/head")
        #expect(ForgeKind.gitLab.headRef(of: 7) == "refs/merge-requests/7/head")
    }
}
