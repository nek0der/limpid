// ReviewParsingTests.swift
// Limpid — what the review reads out of Git's patch, name, and numstat output.

import Foundation
import Testing
@testable import Limpid

struct ReviewParsingTests {
    @Test func unifiedDiffPreservesBothSides() throws {
        let patch = "@@ -2,2 +2,3 @@\n same\n-old\n+new\n+日本語\n\\ No newline at end of file\n"
        let lines = try ReviewDiffParser.parse(patch)
        try #require(lines.map(\.oldLine) == [nil, 2, 3, nil, nil, nil], "Old-side line mapping")
        #expect(lines.map(\.newLine) == [nil, 2, nil, 3, 4, nil], "New-side line mapping")
        #expect(lines[4].text == "日本語", "UTF-8 line content")
        #expect(lines[0].kind == .hunk, "Hunk header is its own kind")
    }

    @Test func fileMetadataIsSeparableFromHunkHeaders() throws {
        let metadata = try ReviewDiffParser.parse("diff --git a/a b/a\nindex 1..2 100644\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(
            metadata.map(\.kind) == [.fileHeader, .fileHeader, .hunk, .removed, .added],
            "File metadata is separable from hunk headers"
        )
    }

    @Test func malformedPatchesAreRefused() throws {
        for invalid in ["@@ -1,2 +1,2 @@\n x\n", "@@@ -1 -1 +1 @@@\n", "@@ -999999999999999999999 +1 @@\n"] {
            #expect(throws: ReviewError.self, "Malformed patch accepted") { try ReviewDiffParser.parse(invalid) }
        }
    }

    @Test func nameStatusKeepsUnusualPathsAndRenames() throws {
        let names = Data("R100\0old\tname\0new\nname\0M\0日本語\0".utf8)
        let files = try ReviewGit.parseNames(names, layer: .staged)
        try #require(files.count == 2, "NUL-delimited rename")
        #expect(files[0].oldPath == "old\tname" && files[0].path == "new\nname", "NUL-delimited rename")
        #expect(files[1].path == "日本語", "UTF-8 path")
        // The similarity score is dropped where the output is read, so nothing
        // downstream has to know that a rename's status is two fields glued
        // together.
        #expect(files[0].status == .renamed, "Rename status kept its score")
    }

    @Test func filePatchKeepsARenameApartFromAnotherFile() throws {
        let renamed = ReviewFile(path: "new name", oldPath: "old name", layer: .staged, status: .renamed)
        let combined = "diff --git a/old name b/new name\nrename from old name\nrename to new name\n"
            + "diff --git a/old name b/old name\n@@ -0,0 +1 @@\n+unrelated\n"
        let selected = try ReviewGit.filePatch(combined, file: renamed)
        #expect(!selected.contains("unrelated") && selected.contains("rename to new name"), "Rename pathspec mixed another file")
    }

    /// `--numstat -z` writes the path inline, except for renames, where the
    /// field is empty and the old and new paths follow as separate records.
    @Test func numstatParsesRenamesAndBinaryCounts() throws {
        let data = Data("3\t1\ta.swift\0-\t-\tlogo.png\0002\t0\t\0old.swift\0new.swift\0".utf8)
        let parsed = try ReviewGit.parseNumstat(data)
        try #require(parsed.count == 3, "Three numstat records")
        #expect(parsed[0].0 == "a.swift" && parsed[0].1 == ReviewFileStat(added: 3, removed: 1), "Plain record")
        #expect(parsed[1].1.isBinary, "Binary counts are not zero")
        #expect(parsed[2].0 == "new.swift" && parsed[2].1.added == 2, "Rename takes the new path")
        #expect(throws: ReviewError.self, "Malformed numstat accepted") { try ReviewGit.parseNumstat(Data("3\ta.swift\0".utf8)) }
    }
}
