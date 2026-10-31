// GitRefCodingTests.swift
// Weir — a worktree's `gitRef` in `state.json`, read and written across builds.

import Foundation
import Testing
@testable import Weir

struct GitRefCodingTests {
    private static let fetched = Date(timeIntervalSince1970: 1_790_000_000)

    /// What an older build wrote, with the status it read, still reads.
    @Test func anOlderBuildsGitRef_reads() throws {
        let json = Data("""
        {"branchName":"feat/x","worktreePath":"file:///tmp/repo-feat/","headSHA":"abc","ahead":2,"behind":1,"isDirty":true}
        """.utf8)
        let ref = try JSONDecoder().decode(GitRef.self, from: json)
        #expect(ref == GitRef(branchName: "feat/x", worktreePath: URL(string: "file:///tmp/repo-feat/"), headSHA: "abc"))
    }

    /// An older build requires `ahead`, `behind`, and `isDirty`, and fails
    /// on the whole session without them, so they are still written.
    @Test func aGitRef_keepsTheKeysAnOlderBuildRequires() throws {
        let data = try JSONEncoder().encode(GitRef(branchName: "main", headSHA: "abc"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["ahead"] as? Int == 0)
        #expect(object["behind"] as? Int == 0)
        #expect(object["isDirty"] as? Bool == false)
        #expect(object["worktreePath"] == nil, "an absent value stays absent, as before")
    }

    @Test func aGitRef_roundTrips() throws {
        let ref = GitRef(
            branchName: "main",
            worktreePath: URL(fileURLWithPath: "/tmp/repo"),
            headSHA: "abc",
            lastFetched: Self.fetched
        )
        let encoder = PersistenceCoders.makeEncoder()
        let decoded = try PersistenceCoders.makeDecoder().decode(GitRef.self, from: encoder.encode(ref))
        #expect(decoded == ref)
    }
}
