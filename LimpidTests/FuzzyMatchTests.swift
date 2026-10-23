// FuzzyMatchTests.swift
// Limpid — the palette's fuzzy match: what matches, at which characters, and which match ranks higher.

import Foundation
import Testing
@testable import Limpid

@Suite("FuzzyMatch")
struct FuzzyMatchTests {
    /// The first query's match of `candidate` outranks the second's: an
    /// exact substring over scattered characters, word starts over the
    /// middle of a word, consecutive characters over spread ones.
    @Test("a better match scores higher", arguments: [
        ("New", "Nwa", "New Tab"),
        ("nt", "ew", "New Tab"),
        ("Sp", "St", "Split Right")
    ])
    func aBetterMatch_scoresHigher(better: String, worse: String, candidate: String) throws {
        let high = try #require(FuzzyMatch.score(query: better, candidate: candidate))
        let low = try #require(FuzzyMatch.score(query: worse, candidate: candidate))
        #expect(high.score > low.score)
    }

    @Test("empty query matches everything with score 0")
    func emptyQuery_matchesAll() throws {
        let result = try #require(FuzzyMatch.score(query: "", candidate: "anything"))
        #expect(result.score == 0)
        #expect(result.matchedIndices.isEmpty)
    }

    @Test("no match returns nil")
    func noMatch_returnsNil() {
        #expect(FuzzyMatch.score(query: "xyz", candidate: "New Tab") == nil)
    }

    @Test("case insensitive matching works")
    func caseInsensitive() {
        #expect(FuzzyMatch.score(query: "new tab", candidate: "New Tab") != nil)
    }

    @Test("matched indices are the characters matched")
    func matchedIndices_areTheCharactersMatched() throws {
        let result = try #require(FuzzyMatch.score(query: "NT", candidate: "New Tab"))
        // N and T.
        #expect(result.matchedIndices == [0, 4])
    }
}
