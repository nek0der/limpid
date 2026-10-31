// GitStatusParserTests.swift
// Weir — Swift Testing coverage for the `GitStatus` porcelain v2 parser.

import Testing
@testable import Weir

@Suite("GitStatus parser")
struct GitStatusParserTests {

    /// Exercises `parse` over hand-crafted porcelain v2 fragments — no IO.
    @Test(
        "parses the branch and counts the changed entries",
        arguments: [
            // (porcelain, branch, changedEntries)
            (
                """
                # branch.oid abc
                # branch.head main
                # branch.upstream origin/main
                # branch.ab +0 -0
                """,
                "main", 0
            ),
            (
                """
                # branch.oid bbb
                # branch.head dev
                1 .M N... 100644 100644 100644 aaa bbb file.swift
                """,
                "dev", 1
            ),
            (
                """
                # branch.oid aaa
                # branch.head main
                ? newfile.txt
                """,
                "main", 1
            )
        ]
    )
    func parse_porcelainV2_extractsBranchAndStatus(
        porcelain: String,
        expectedBranch: String,
        expectedChanged: Int
    ) {
        let status = GitStatus.parse(porcelain)
        #expect(status.branch == expectedBranch)
        #expect(status.changedEntries == expectedChanged)
    }

    @Test func parse_countsEachChangedRenamedUnmergedAndUntrackedEntry_butNotIgnoredOnes() {
        let porcelain = """
        # branch.oid aaa
        # branch.head main
        1 .M N... 100644 100644 100644 aaa bbb changed.swift
        2 R. N... 100644 100644 100644 aaa bbb R100 new.swift\told.swift
        u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.swift
        ? untracked.txt
        ! ignored.log
        """
        #expect(GitStatus.parse(porcelain).changedEntries == 4)
        #expect(GitStatus.parse("# branch.oid aaa\n# branch.head main").changedEntries == 0)
    }

    @Test func parse_tellsAnUpstreamWithCountsFromOneGoneFromTheRemote() {
        let tracked = GitStatus.parse("""
        # branch.head feat
        # branch.upstream origin/feat
        # branch.ab +2 -0
        """)
        #expect(tracked.hasAheadBehind)

        // Git reports the upstream but no counts once its branch is gone.
        let gone = GitStatus.parse("""
        # branch.head feat
        # branch.upstream origin/feat
        """)
        #expect(gone.upstream == "origin/feat")
        #expect(!gone.hasAheadBehind)
    }

    @Test("a detached HEAD names no branch")
    func parse_detachedHead_hasNoBranch() {
        #expect(GitStatus.parse("# branch.oid aaa\n# branch.head (detached)").branch == nil)
    }

    @Test("empty input yields the empty status")
    func parse_emptyInput_returnsEmptyStatus() {
        #expect(GitStatus.parse("") == GitWorktreeStatus())
    }
}
