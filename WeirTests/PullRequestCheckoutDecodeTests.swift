// PullRequestCheckoutDecodeTests.swift
// Weir — reading gh's and glab's answers about one pull request and the open ones, for a worktree made from one.

import Foundation
import Testing
@testable import Weir

struct PullRequestCheckoutDecodeTests {
    @Test func gh_aRequestOfTheRepositoryItself() throws {
        let json = """
        {"number":12,"title":"Fix login","state":"OPEN","headRefName":"fix/login",
         "headRefOid":"c0ffee","isCrossRepository":false,"headRepositoryOwner":{"login":"acme"}}
        """
        let head = try #require(ForgePullRequests.decode(stdout: json, forge: .gitHub))
        #expect(head == PullRequestHead(
            number: 12,
            title: "Fix login",
            state: .open,
            headBranch: "fix/login",
            headCommit: "c0ffee",
            forkOwner: nil
        ))
    }

    @Test func gh_aRequestFromAFork_namesItsOwner_andAClosedOneReadsClosed() throws {
        let json = """
        {"number":3,"title":"Typo","state":"CLOSED","headRefName":"main",
         "headRefOid":"abc","isCrossRepository":true,"headRepositoryOwner":{"login":"alice"}}
        """
        let head = try #require(ForgePullRequests.decode(stdout: json, forge: .gitHub))
        #expect(head.forkOwner == "alice")
        #expect(head.isFromFork)
        #expect(head.state == .closed)
    }

    @Test func glab_aRequestFromAFork_isOneWhoseSourceProjectIsAnother() throws {
        let json = """
        {"iid":9,"title":"Docs","state":"merged","source_branch":"docs","sha":"def",
         "source_project_id":2,"target_project_id":1,"author":{"username":"bob"},"web_url":"https://gitlab.com/x/-/merge_requests/9"}
        """
        let head = try #require(ForgePullRequests.decode(stdout: json, forge: .gitLab))
        #expect(head.number == 9)
        #expect(head.headBranch == "docs")
        #expect(head.headCommit == "def")
        #expect(head.forkOwner == "bob")
        #expect(head.state == .merged)
    }

    @Test func glab_aRequestOfTheProjectItself_hasNoFork() throws {
        let json = #"{"iid":4,"title":"t","state":"opened","source_branch":"b","source_project_id":1,"target_project_id":1}"#
        let head = try #require(ForgePullRequests.decode(stdout: json, forge: .gitLab))
        #expect(head.forkOwner == nil)
        #expect(head.state == .open)
    }

    @Test func aList_readsEachRequest_andALineBeforeItIsLeftOut() {
        let stdout = """
        A new release of gh is available
        [{"number":1,"title":"a","state":"OPEN","headRefName":"a","isCrossRepository":false},
         {"number":2,"title":"b","state":"OPEN","headRefName":"b","isCrossRepository":true,"headRepositoryOwner":{"login":"c"}}]
        """
        let heads = ForgePullRequests.decodeList(stdout: stdout, forge: .gitHub)
        #expect(heads.map(\.number) == [1, 2])
        #expect(heads[1].forkOwner == "c")
        #expect(ForgePullRequests.decodeList(stdout: "not json", forge: .gitHub).isEmpty)
    }

    @Test func aFailureThatSaysNoSuchRequest_isNotFound_andAnyOtherSaysItsWords() {
        let gone = ToolResult(exitCode: 1, stdout: "", stderr: "GraphQL: Could not resolve to a PullRequest with the number of 99.")
        #expect(ForgePullRequests.lookup(gone, number: 99, forge: .gitHub) == .notFound(99))
        let glabGone = ToolResult(exitCode: 1, stdout: "", stderr: "ERROR: 404 Not Found")
        #expect(ForgePullRequests.lookup(glabGone, number: 5, forge: .gitLab) == .notFound(5))
        let offline = ToolResult(exitCode: 1, stdout: "", stderr: "error connecting to api.github.com\n")
        #expect(ForgePullRequests.lookup(offline, number: 5, forge: .gitHub) == .failed("error connecting to api.github.com"))
        #expect(ForgePullRequests.lookup(nil, number: 5, forge: .gitHub) == .failed(""))
        let unreadable = ToolResult(exitCode: 0, stdout: "{}", stderr: "")
        #expect(ForgePullRequests.lookup(unreadable, number: 5, forge: .gitHub) == .failed(""))
    }
}
