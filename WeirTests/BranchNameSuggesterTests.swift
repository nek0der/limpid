// BranchNameSuggesterTests.swift
// Weir — the branch a new worktree gets while its field is empty: the date, never a name taken.

import Foundation
import Testing
@testable import Weir

struct BranchNameSuggesterTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// 2026-10-11 12:00 UTC.
    private static let today = Date(timeIntervalSince1970: 1_791_720_000)

    private static func suggest(taken: Set<String> = []) -> String {
        BranchNameSuggester.suggest(today: today, calendar: calendar) { taken.contains($0) }
    }

    /// The sheet takes no instruction to name a branch from: the name is
    /// the date's.
    @Test func theName_isATaskBranchOfTheDate() {
        #expect(Self.suggest() == "task/1011-1")
    }

    @Test func aNameTaken_getsTheNextNumber() {
        #expect(Self.suggest(taken: ["task/1011-1", "task/1011-2"]) == "task/1011-3")
        #expect(Self.suggest(taken: ["task/1011-2"]) == "task/1011-1")
    }

    @Test(arguments: ["feat/x", "task/1011-1", "fix_it", "release/1.2"])
    func aNameGitTakes_isValid(_ name: String) {
        #expect(BranchNameSuggester.isValid(name))
    }

    @Test(arguments: [
        "",
        "-D",
        "a b",
        "a..b",
        "x.lock",
        "x/",
        "/x",
        ".x",
        "a/.b",
        "a~b",
        "a^b",
        "a:b",
        "a?b",
        "a*b",
        "a[b",
        "a\\b",
        "a@{b",
        "x.",
        "@",
        "a//b",
        "a.lock/b",
        "HEAD"
    ])
    func aNameGitRefuses_isInvalid(_ name: String) {
        #expect(!BranchNameSuggester.isValid(name))
    }

    @Test func aBranchsFolder_hasNoSlash() {
        #expect(BranchNameSuggester.folderLeaf(of: "feat/a/b") == "feat-a-b")
    }

    @Test func branchesWithOneLastPart_getTheirOwnFolders() {
        #expect(BranchNameSuggester.folderLeaf(of: "feature/alpha") == "feature-alpha")
        #expect(BranchNameSuggester.folderLeaf(of: "fix/alpha") == "fix-alpha")
    }
}
