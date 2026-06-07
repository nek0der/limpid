// GitStatusParserTests.swift
// Limpid — Swift Testing coverage for the `GitStatus` porcelain v2 parser.
// Reference template for new tests: `@Suite` struct, `@Test`, `#expect`,
// `@Test(arguments:)` for parameterization, and smoke tests gated by
// `RepoFixture.hasLocalRepo` + `.tags(.smoke)`.

import Testing
@testable import Limpid

@Suite("GitStatus parser")
struct GitStatusParserTests {

    /// Exercises `parse` over hand-crafted porcelain v2 fragments — no IO.
    @Test(
        "parses branch + ahead/behind metadata",
        arguments: [
            // (porcelain, branch, ahead, behind, isDirty)
            (
                """
                # branch.oid abc
                # branch.head main
                # branch.upstream origin/main
                # branch.ab +0 -0
                """,
                "main", 0, 0, false
            ),
            (
                """
                # branch.oid aaa
                # branch.head feat
                # branch.upstream origin/feat
                # branch.ab +3 -2
                """,
                "feat", 3, 2, false
            ),
            (
                """
                # branch.oid bbb
                # branch.head dev
                # branch.ab +0 -5
                1 .M N... 100644 100644 100644 aaa bbb file.swift
                """,
                "dev", 0, 5, true
            )
        ]
    )
    func parse_porcelainV2_extractsBranchAndStatus(
        porcelain: String,
        expectedBranch: String,
        expectedAhead: Int,
        expectedBehind: Int,
        expectedDirty: Bool
    ) {
        let status = GitStatus.parse(porcelain)
        #expect(status.branch == expectedBranch)
        #expect(status.ahead == expectedAhead)
        #expect(status.behind == expectedBehind)
        #expect(status.isDirty == expectedDirty)
    }

    @Test("dirty flag toggles on tracked file modification")
    func parse_withTrackedModification_marksDirty() {
        let porcelain = """
        # branch.oid aaa
        # branch.head main
        1 .M N... 100644 100644 100644 aaa bbb path/to/file.swift
        """
        #expect(GitStatus.parse(porcelain).isDirty)
    }

    @Test("dirty flag toggles on untracked file")
    func parse_withUntrackedFile_marksDirty() {
        let porcelain = """
        # branch.oid aaa
        # branch.head main
        ? newfile.txt
        """
        #expect(GitStatus.parse(porcelain).isDirty)
    }

    @Test("empty input yields no branch and no SHA")
    func parse_emptyInput_returnsEmptyStatus() {
        let status = GitStatus.parse("")
        #expect(status.branch == nil)
        #expect(status.headSHA == nil)
    }

    /// Smoke test against a freshly-initialized git repo. Skipped when
    /// `git` is unavailable or `RepoFixture.hasLocalRepo` is false.
    @Test(.tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func fetch_freshTempRepo_reportsMainBranchAndCleanTree() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let status = try await GitStatus.fetch(workingDirectory: repo.url)
        try #require(status != nil)
        #expect(status?.branch == "main")
        #expect(status?.isDirty == false)
    }
}
