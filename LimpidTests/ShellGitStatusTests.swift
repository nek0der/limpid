// ShellGitStatusTests.swift
// Limpid — parser + smoke coverage for `ShellGit.status` (conflict
// detection, spec §10 step 1 / §11). The parser handles the `git status
// --porcelain=v1 -z` shapes that silently regress: NUL-separated paths
// with spaces / non-ASCII / newlines, rename old+new pairs, and
// untracked files.

import Foundation
import Testing
@testable import Limpid

@Suite("ShellGit status parser")
struct ShellGitStatusTests {

    // MARK: - Pure parser

    @Test("staged add: index column marks the entry staged")
    func parse_stagedAdd_isStaged() {
        let entries = ShellGit.parse("A  tracked.txt\0")
        #expect(entries.count == 1)
        #expect(entries[0].path == "tracked.txt")
        #expect(entries[0].renamedFrom == nil)
        #expect(entries[0].staged == true)
    }

    @Test("worktree-only modification is not staged")
    func parse_worktreeModified_notStaged() {
        let entries = ShellGit.parse(" M file.swift\0")
        #expect(entries.count == 1)
        #expect(entries[0].path == "file.swift")
        #expect(entries[0].staged == false)
    }

    @Test("untracked file: parsed, never staged")
    func parse_untracked_notStaged() {
        let entries = ShellGit.parse("?? newfile.txt\0")
        #expect(entries.count == 1)
        #expect(entries[0].path == "newfile.txt")
        #expect(entries[0].staged == false)
    }

    @Test("path containing spaces survives verbatim")
    func parse_pathWithSpaces() {
        let entries = ShellGit.parse(" M path with spaces.txt\0")
        #expect(entries.count == 1)
        #expect(entries[0].path == "path with spaces.txt")
    }

    @Test("non-ASCII (Japanese) path survives verbatim")
    func parse_japanesePath() {
        let entries = ShellGit.parse(" M ソース/メイン.swift\0")
        #expect(entries.count == 1)
        #expect(entries[0].path == "ソース/メイン.swift")
    }

    @Test("newline inside a path is preserved (NUL is the only delimiter)")
    func parse_pathWithNewline() {
        let entries = ShellGit.parse(" M with\nnewline.txt\0")
        #expect(entries.count == 1)
        #expect(entries[0].path == "with\nnewline.txt")
    }

    @Test("rename: new path on the record, old path in the next field")
    func parse_rename_capturesBothPaths() {
        // `R  <new>\0<old>\0` — the destination is on the status line,
        // the original is the following NUL-separated token.
        let entries = ShellGit.parse("R  新しい 名前.txt\0old name.txt\0")
        #expect(entries.count == 1)
        #expect(entries[0].path == "新しい 名前.txt")
        #expect(entries[0].renamedFrom == "old name.txt")
        #expect(entries[0].staged == true)
    }

    @Test("copy: also carries the original path")
    func parse_copy_capturesOriginal() {
        let entries = ShellGit.parse("C  copy.txt\0orig.txt\0")
        #expect(entries.count == 1)
        #expect(entries[0].path == "copy.txt")
        #expect(entries[0].renamedFrom == "orig.txt")
    }

    @Test("mixed stream: rename's extra field doesn't desync later records")
    func parse_mixedStream_advancesPastRenameField() {
        let entries = ShellGit.parse("A  a.txt\0R  b new.txt\0b old.txt\0?? c.txt\0")
        #expect(entries.count == 3)
        #expect(entries[0].path == "a.txt")
        #expect(entries[0].renamedFrom == nil)
        #expect(entries[1].path == "b new.txt")
        #expect(entries[1].renamedFrom == "b old.txt")
        #expect(entries[2].path == "c.txt")
        #expect(entries[2].staged == false)
    }

    @Test("empty input yields no entries")
    func parse_empty_returnsNothing() {
        #expect(ShellGit.parse("").isEmpty)
    }

    // MARK: - Smoke (real git)

    /// End-to-end against a real repo: stage one add, leave one
    /// untracked, and rename a committed file. Verifies the live
    /// `git status --porcelain=v1 -z` output flows through the parser.
    @Test(.tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func status_realRepo_reportsStagedUntrackedAndRename() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }

        // A committed file we can rename so `R` appears in the output.
        let original = repo.url.appendingPathComponent("original.txt")
        try "hello".write(to: original, atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(["add", "-A"], cwd: repo.url)
        _ = try await GitProcess.run(["commit", "-m", "add original"], cwd: repo.url)
        _ = try await GitProcess.run(
            ["mv", "original.txt", "renamed.txt"],
            cwd: repo.url
        )

        // A staged new file and an untracked one.
        try "x".write(
            to: repo.url.appendingPathComponent("staged.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await GitProcess.run(["add", "staged.txt"], cwd: repo.url)
        try "y".write(
            to: repo.url.appendingPathComponent("loose.txt"),
            atomically: true,
            encoding: .utf8
        )

        let entries = try await ShellGit().status(at: repo.url)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })

        #expect(byPath["staged.txt"]?.staged == true)
        #expect(byPath["loose.txt"]?.staged == false)
        let rename = byPath["renamed.txt"]
        #expect(rename != nil)
        #expect(rename?.renamedFrom == "original.txt")
    }
}
