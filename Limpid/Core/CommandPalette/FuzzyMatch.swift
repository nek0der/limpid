// FuzzyMatch.swift
// Limpid — Smith-Waterman-inspired fuzzy matching with bonuses for
// word-start, consecutive, CamelCase, and exact-case matches.

import Foundation

enum FuzzyMatch {

    struct Result: Equatable {
        let score: Int
        let matchedIndices: [Int]
    }

    // MARK: - Bonuses / penalties

    private static let baseMatch = 16
    private static let wordStartBonus = 32
    private static let camelCaseBonus = 24
    private static let consecutiveBonus = 16
    private static let exactCaseBonus = 8
    private static let gapPenalty = -3

    // MARK: - Separators

    private static let separators: Set<Character> = [" ", "/", "-", "_", ".", "\\"]

    // MARK: - Public API

    /// Returns nil when the query cannot be matched against the candidate.
    /// Empty query matches everything with score 0.
    static func score(query: String, candidate: String) -> Result? {
        if query.isEmpty {
            return Result(score: 0, matchedIndices: [])
        }
        if candidate.isEmpty { return nil }

        let q = Array(query.lowercased())
        let cLower = Array(candidate.lowercased())
        let cOriginal = Array(candidate)
        let qOriginal = Array(query)
        let qLen = q.count
        let cLen = cLower.count

        if qLen > cLen { return nil }

        // scores[i][j] = best score aligning query[0..<i] ending at candidate[j-1].
        // diagonal[i][j] = diagonal score (last move was a match) — tracks consecutive.
        var scores = [[Int]](repeating: [Int](repeating: 0, count: cLen + 1), count: qLen + 1)
        var diagonal = [[Int]](repeating: [Int](repeating: 0, count: cLen + 1), count: qLen + 1)

        for i in 1...qLen {
            // We need every query char to match, so row-minimum stays 0
            // (Smith-Waterman floor) but we track whether full alignment
            // is possible.
            for j in 1...cLen {
                if q[i - 1] == cLower[j - 1] {
                    var bonus = baseMatch

                    // Word-start: preceded by separator or is the first character.
                    if j == 1 || separators.contains(cOriginal[j - 2]) {
                        bonus += wordStartBonus
                    }

                    // CamelCase: lowercase -> uppercase boundary.
                    if j > 1, cOriginal[j - 2].isLowercase, cOriginal[j - 1].isUppercase {
                        bonus += camelCaseBonus
                    }

                    // Exact case match.
                    if qOriginal[i - 1] == cOriginal[j - 1] {
                        bonus += exactCaseBonus
                    }

                    // Consecutive: previous query char matched at j-1.
                    let prev = diagonal[i - 1][j - 1]
                    if prev > 0 {
                        bonus += consecutiveBonus
                    }

                    let matchScore = max(0, scores[i - 1][j - 1] + bonus)
                    diagonal[i][j] = matchScore
                    scores[i][j] = max(scores[i][j - 1] + gapPenalty, matchScore)
                    scores[i][j] = max(scores[i][j], 0)
                } else {
                    diagonal[i][j] = 0
                    scores[i][j] = max(0, scores[i][j - 1] + gapPenalty)
                }
            }
        }

        // Find the best score in the last query row.
        var bestScore = 0
        var bestJ = 0
        for j in 1...cLen {
            if scores[qLen][j] > bestScore {
                bestScore = scores[qLen][j]
                bestJ = j
            }
        }

        if bestScore == 0 { return nil }

        // Traceback to recover matched indices.
        var matched: [Int] = []
        var i = qLen
        var j = bestJ
        while i > 0, j > 0 {
            if q[i - 1] == cLower[j - 1], diagonal[i][j] > 0 {
                matched.append(j - 1)
                i -= 1
                j -= 1
            } else {
                j -= 1
            }
        }

        // All query chars must be consumed.
        if i > 0 { return nil }

        matched.reverse()
        return Result(score: bestScore, matchedIndices: matched)
    }
}
