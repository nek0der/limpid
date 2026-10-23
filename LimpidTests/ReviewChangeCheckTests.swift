// ReviewChangeCheckTests.swift
// Limpid — what the review tab's change check reads of a real repository: the index, stats, hashes, and links.

import CryptoKit
import Foundation
import Testing
@testable import Limpid

@Suite("Review change check")
struct ReviewChangeCheckTests {
    /// Git's own id for a blob of `data`, to check `hash-object` against.
    private static func blobID(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\u{0}".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What the change check sees in a real repository.
    @Test(.tags(.smoke)) func readStates_seeWhatChangesAFilesDiff_andNotATouch() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let git = LiveReviewRepository()
        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: repo.url.appendingPathComponent(path))
        }
        func run(_ arguments: [String]) async throws {
            _ = try await GitProcess.run(arguments, cwd: repo.url)
        }
        func changed(_ states: [String: ReviewReadState], _ path: String) async -> Bool {
            // A path with no state, or an index that cannot be read, reads as
            // unchanged here: it fails the checks that expect a change.
            guard let state = states[path] else { return false }
            return await ReviewChangeCheck.anyChanged([(path, state)], git: git, root: repo.url, scope: .uncommitted) ?? false
        }
        try write("a.swift", "let a = 1\n")
        try write("gone.swift", "let gone = 1\n")
        try write("c.txt", "base\n")
        try await run(["add", "."])
        try await run(["commit", "-m", "files"])
        try write("a.swift", "let a = 2\n")
        let paths: Set = ["a.swift", "gone.swift", "c.txt"]
        var states = await ReviewChangeCheck.take(paths, git: git, root: repo.url, scope: .uncommitted)

        #expect(await !changed(states, "a.swift"))
        let file = repo.url.appendingPathComponent("a.swift")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: file.path)
        #expect(await !changed(states, "a.swift"), "a touch leaves the content as it was")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(await changed(states, "a.swift"), "a mode is diffed")

        states = await ReviewChangeCheck.take(paths, git: git, root: repo.url, scope: .uncommitted)
        // `cp -p`: the same size and modification time, other bytes.
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
        try write("a.swift", "let a = 3\n")
        try FileManager.default.setAttributes([.modificationDate: modified as Any], ofItemAtPath: file.path)
        #expect(await changed(states, "a.swift"))

        states = await ReviewChangeCheck.take(paths, git: git, root: repo.url, scope: .uncommitted)
        try await run(["add", "a.swift"])
        #expect(await changed(states, "a.swift"), "a stage")

        states = await ReviewChangeCheck.take(paths, git: git, root: repo.url, scope: .uncommitted)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("gone.swift"))
        #expect(await changed(states, "gone.swift"), "a tracked file deleted")

        // A conflict, then its resolution.
        try await run(["checkout", "-q", "-b", "other"])
        try write("c.txt", "other\n")
        try await run(["commit", "-qam", "other"])
        try await run(["checkout", "-q", "main"])
        try write("c.txt", "main\n")
        try await run(["commit", "-qam", "main"])
        try await run(["merge", "other"])
        states = await ReviewChangeCheck.take(paths, git: git, root: repo.url, scope: .uncommitted)
        #expect(states["c.txt"]?.index?.split(separator: ";").count == 3, "three stages")
        try write("c.txt", "resolved\n")
        try await run(["add", "c.txt"])
        #expect(await changed(states, "c.txt"))

        states = await ReviewChangeCheck.take(paths, git: git, root: repo.url, scope: .uncommitted)
        try await run(["commit", "-qm", "merged"])
        #expect(await changed(states, "c.txt"), "HEAD moved")
    }

    @Test(.tags(.smoke)) func contentHashes_handOverManyPathsOnStdin_quotingTheOddOnes() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let folder = String(repeating: "d", count: 100)
        try FileManager.default.createDirectory(at: repo.url.appendingPathComponent(folder), withIntermediateDirectories: true)
        // Past one batch, and more than a pipe holds (64 KB) at once.
        var paths = (0..<501).map { "\(folder)/\(String(repeating: "f", count: 40))\($0).txt" }
        paths += ["\"quoted.txt", "line\nbreak.txt", "carriage.txt\r", "back\\slash.txt"]
        var expected: [String: String] = [:]
        for (index, path) in paths.enumerated() {
            let data = Data("content \(index)\n".utf8)
            try data.write(to: repo.url.appendingPathComponent(path))
            expected[path] = Self.blobID(data)
        }
        #expect(paths.joined(separator: "\n").utf8.count > 64 * 1024)

        let hashes = try await ReviewGit.contentHashes(paths, root: repo.url)

        #expect(hashes.count == paths.count)
        #expect(hashes == expected, "each path's own bytes, odd names included")
    }

    @Test(.tags(.smoke)) func indexEntries_byNameOrWhole_agree() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let paths = (0..<70).map { "f\($0).txt" }
        for path in paths {
            try Data("\(path)\n".utf8).write(to: repo.url.appendingPathComponent(path))
        }
        _ = try await GitProcess.run(["add", "."], cwd: repo.url)

        let few = try await ReviewGit.indexEntries(Set(paths.prefix(3)), root: repo.url)
        let all = try await ReviewGit.indexEntries(Set(paths), root: repo.url)

        #expect(few.count == 3, "by name")
        #expect(all.count == 70, "the whole index, filtered")
        #expect(paths.prefix(3).allSatisfy { few[$0] == all[$0] })
    }

    @Test func theIndex_isReadAsBytes_passingOverPathsThatAreNotUTF8() {
        var data = Data("100644 aaaa 0\tgood.txt".utf8)
        data.append(0)
        data.append(contentsOf: Array("100644 bbbb 0\t".utf8) + [0xFF, 0xFE])
        data.append(0)
        data.append(contentsOf: Array("100644 cccc 1\tgood.txt".utf8))
        data.append(0)

        let entries = ReviewGit.parseIndex(data, wanted: ["good.txt", "other.txt"])

        #expect(entries == ["good.txt": "100644 aaaa 0;100644 cccc 1;"])
    }

    @Test func aSubmodule_isWatchedByItsFingerprint() {
        let regular = ReviewPathStat(kind: .regular, info: "33188:1", size: 1)
        let folder = ReviewPathStat(kind: .directory, info: "16877:1", size: 1)

        #expect(ReviewChangeCheck.isWatchable(index: "100644 aaaa 0;", stat: regular))
        #expect(!ReviewChangeCheck.isWatchable(index: "160000 aaaa 0;", stat: regular), "a gitlink: its diff is a commit")
        #expect(!ReviewChangeCheck.isWatchable(index: nil, stat: folder))
    }

    @Test(.tags(.smoke)) func readStates_seeAStage_aLinkPointedElsewhere_andABaseThatMoved() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let git = LiveReviewRepository()
        func run(_ arguments: [String]) async throws {
            _ = try await GitProcess.run(arguments, cwd: repo.url)
        }
        func changed(_ path: String, from states: [String: ReviewReadState], scope: ReviewScope = .uncommitted) async throws -> Bool {
            let state = try #require(states[path])
            // Unwrapped by hand: `#require` on an optional Bool is ambiguous
            // to the macro (a check, or an unwrap).
            guard let answer = await ReviewChangeCheck.anyChanged([(path, state)], git: git, root: repo.url, scope: scope) else {
                Issue.record("The change check could not decide for \(path)")
                throw CancellationError()
            }
            return answer
        }
        for name in ["a.txt", "b.txt"] {
            try Data("same\n".utf8).write(to: repo.url.appendingPathComponent(name))
        }
        try await run(["add", "a.txt", "b.txt"])
        try await run(["commit", "-qm", "files"])
        try await run(["branch", "base"])
        try Data("untracked\n".utf8).write(to: repo.url.appendingPathComponent("u.txt"))
        let link = repo.url.appendingPathComponent("l")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")

        var states = await ReviewChangeCheck.take(["u.txt", "l"], git: git, root: repo.url, scope: .uncommitted)
        #expect(try await !changed("u.txt", from: states))
        try await run(["add", "u.txt"])
        #expect(try await changed("u.txt", from: states), "untracked, then added")

        states = await ReviewChangeCheck.take(["l"], git: git, root: repo.url, scope: .uncommitted)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "b.txt")
        #expect(try await changed("l", from: states), "a link pointed at an identical file is still another link")

        try Data("more\n".utf8).write(to: repo.url.appendingPathComponent("a.txt"))
        try await run(["commit", "-qam", "more"])
        let branch = ReviewScope.branch(base: "base")
        states = await ReviewChangeCheck.take(["a.txt"], git: git, root: repo.url, scope: branch)
        #expect(try await !changed("a.txt", from: states, scope: branch))
        try await run(["branch", "-f", "base", "HEAD"])
        #expect(try await changed("a.txt", from: states, scope: branch), "the merge base moved")
    }

    @Test(.tags(.smoke)) func contentHashes_regularFilesInsideTheWorkTree_withinTheLimit() async throws {
        try await withTempDir { outside in
            let repo = try await TempGitRepo.make()
            defer { repo.cleanup() }
            try Data("outside\n".utf8).write(to: outside.appendingPathComponent("f.txt"))
            func write(_ path: String, _ text: String) throws {
                try Data(text.utf8).write(to: repo.url.appendingPathComponent(path))
            }
            try write("small.txt", "small\n")
            try write("large.txt", String(repeating: "x", count: 100))
            try write("locked.txt", "locked\n")
            try FileManager.default.createDirectory(at: repo.url.appendingPathComponent("folder"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: repo.url.appendingPathComponent("away").path,
                withDestinationPath: outside.appendingPathComponent("f.txt").path
            )
            try FileManager.default.createSymbolicLink(
                atPath: repo.url.appendingPathComponent("out").path,
                withDestinationPath: outside.path
            )
            let locked = repo.url.appendingPathComponent("locked.txt")
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

            let hashes = try await ReviewGit.contentHashes(
                ["small.txt", "large.txt", "locked.txt", "folder", "away", "out/f.txt"],
                root: repo.url,
                maxBytes: 50
            )

            #expect(hashes["small.txt"] == Self.blobID(Data("small\n".utf8)), "kept although another path failed its batch")
            #expect(hashes["large.txt"] == nil, "over the limit: never read")
            #expect(hashes["locked.txt"] == nil, "Git could not read it")
            #expect(hashes["folder"] == nil, "not a file")
            #expect(hashes["away"] == "link:" + outside.appendingPathComponent("f.txt").path, "a link is its target's name, not followed")
            #expect(hashes["out/f.txt"] == nil, "not read outside the work tree through a link")
        }
    }

    @Test(.tags(.smoke)) func indexEntries_tooLargeToReadWhole_areReadByNameInBatches() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let paths = (0..<5).map { "f\($0).txt" }
        for path in paths {
            try Data("\(path)\n".utf8).write(to: repo.url.appendingPathComponent(path))
        }
        _ = try await GitProcess.run(["add", "."], cwd: repo.url)

        let whole = try await ReviewGit.indexEntries(Set(paths), root: repo.url, byName: 2)
        let batched = try await ReviewGit.indexEntries(Set(paths), root: repo.url, byName: 2, wholeIndexLimitBytes: 10)

        #expect(whole.count == 5)
        #expect(batched == whole, "the whole index over its limit, read by name instead")
    }
}
