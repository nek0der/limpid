// ReviewIntralineDiff.swift
// Limpid — bounded character ranges inside paired changed lines.

import Foundation

/// Highlight ranges keyed by the original `ReviewLine.id`. The ranges are
/// decoration only: comments, copying and Git validation continue to use the
/// unmodified line text.
struct ReviewIntralineHighlights: Equatable, Sendable {
    var rangesByLineID: [Int: [NSRange]] = [:]

    subscript(lineID: Int) -> [NSRange] {
        rangesByLineID[lineID] ?? []
    }
}

/// A Sendable snapshot of the existing position-paired changed lines.
/// Building it on the main actor keeps `ReviewLine` itself free of UI-derived
/// correspondence and lets the bounded character work run off actor.
struct ReviewIntralinePair: Sendable {
    let oldLineID: Int
    let oldText: String
    let newLineID: Int
    let newText: String
}

enum ReviewIntralineDiff {
    /// Hard deterministic budgets. A timeout alone would make highlighting
    /// depend on machine speed and load; exceeding one of these omits only the
    /// inner decoration and leaves the line-level diff intact.
    nonisolated static let maxUTF16UnitsPerLine = 4096
    nonisolated static let maxPairWork = 262_144
    nonisolated static let maxFileUTF16Units = 200_000
    nonisolated static let maxFileWork = 2_000_000
    nonisolated static let maxRangesPerLine = 64

    /// Uses the same pairing the split layout already draws. Unified and split
    /// views therefore cannot disagree about which two lines were compared.
    @MainActor
    static func pairs(for lines: [ReviewLine]) -> [ReviewIntralinePair] {
        ReviewSideBySideBuilder.elements(for: lines).compactMap { element in
            guard case let .pair(pair) = element,
                  let old = pair.old, old.kind == .removed,
                  let new = pair.new, new.kind == .added
            else { return nil }
            return ReviewIntralinePair(
                oldLineID: old.id,
                oldText: old.text,
                newLineID: new.id,
                newText: new.text
            )
        }
    }

    nonisolated static func computeOffActor(_ pairs: [ReviewIntralinePair]) async -> ReviewIntralineHighlights {
        await Task.detached(priority: .userInitiated) {
            compute(pairs)
        }.value
    }

    nonisolated static func compute(_ pairs: [ReviewIntralinePair]) -> ReviewIntralineHighlights {
        var remainingUTF16Units = maxFileUTF16Units
        var remainingWork = maxFileWork
        var result: [Int: [NSRange]] = [:]
        for pair in pairs {
            guard remainingUTF16Units > 0, remainingWork > 0,
                  let ranges = ranges(
                      old: pair.oldText,
                      new: pair.newText,
                      remainingUTF16Units: &remainingUTF16Units,
                      remainingWork: &remainingWork
                  )
            else { continue }
            if !ranges.old.isEmpty {
                result[pair.oldLineID] = ranges.old
            }
            if !ranges.new.isEmpty {
                result[pair.newLineID] = ranges.new
            }
        }
        return ReviewIntralineHighlights(rangesByLineID: result)
    }

    private struct Token: Hashable, Sendable {
        let utf16Range: NSRange
        /// Exact scalar identity, not `Character ==`: Swift character equality
        /// is canonically equivalent and would hide an NFC↔NFD change Git saw.
        let scalars: [UInt32]
        let isWhitespace: Bool

        static func == (lhs: Token, rhs: Token) -> Bool {
            lhs.scalars == rhs.scalars
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(scalars)
        }
    }

    private struct PairRanges {
        let old: [NSRange]
        let new: [NSRange]
    }

    private nonisolated static func ranges(
        old oldText: String,
        new newText: String,
        remainingUTF16Units: inout Int,
        remainingWork: inout Int
    ) -> PairRanges? {
        guard !oldText.utf8.elementsEqual(newText.utf8) else { return nil }
        let oldUTF16Count = oldText.utf16.count
        let newUTF16Count = newText.utf16.count
        let inputUnits = oldUTF16Count + newUTF16Count
        guard oldUTF16Count <= maxUTF16UnitsPerLine,
              newUTF16Count <= maxUTF16UnitsPerLine,
              inputUnits <= remainingUTF16Units
        else { return nil }
        remainingUTF16Units -= inputUnits

        let old = tokens(in: oldText)
        let new = tokens(in: newText)

        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].scalars == new[prefix].scalars {
            prefix += 1
        }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > prefix, newEnd > prefix,
              old[oldEnd - 1].scalars == new[newEnd - 1].scalars
        {
            oldEnd -= 1
            newEnd -= 1
        }

        let oldMiddle = Array(old[prefix..<oldEnd])
        let newMiddle = Array(new[prefix..<newEnd])
        let work = max(oldMiddle.count, 1) * max(newMiddle.count, 1)
        guard work <= maxPairWork, work <= remainingWork else { return nil }
        remainingWork -= work

        var oldChanged = Array(repeating: false, count: oldMiddle.count)
        var newChanged = Array(repeating: false, count: newMiddle.count)
        let difference = newMiddle.difference(from: oldMiddle)
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                oldChanged[offset] = true
            case let .insert(offset, _, _):
                newChanged[offset] = true
            }
        }

        let common = min(
            old.count - oldChanged.count(where: { $0 }),
            new.count - newChanged.count(where: { $0 })
        )
        // A position pair can be two unrelated lines when a change block has
        // unequal sides. Broad inner fills add no information beyond the line
        // backgrounds, so require a meaningful shared spine before drawing.
        let oldMeaningful = old.count(where: { !$0.isWhitespace })
        let newMeaningful = new.count(where: { !$0.isWhitespace })
        let removedMeaningful = zip(oldMiddle, oldChanged).count { !$0.0.isWhitespace && $0.1 }
        let insertedMeaningful = zip(newMiddle, newChanged).count { !$0.0.isWhitespace && $0.1 }
        let meaningfulCommon = min(oldMeaningful - removedMeaningful, newMeaningful - insertedMeaningful)
        guard common > 0,
              meaningfulCommon > 0,
              meaningfulCommon * 2 >= max(oldMeaningful, newMeaningful)
        else { return nil }
        let oldRanges = mergedRanges(tokens: oldMiddle, changed: oldChanged)
        let newRanges = mergedRanges(tokens: newMiddle, changed: newChanged)
        guard oldRanges.count <= maxRangesPerLine, newRanges.count <= maxRangesPerLine else { return nil }
        return PairRanges(old: oldRanges, new: newRanges)
    }

    private nonisolated static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        result.reserveCapacity(text.count)
        var utf16Offset = 0
        for character in text {
            let value = String(character)
            let length = value.utf16.count
            result.append(Token(
                utf16Range: NSRange(location: utf16Offset, length: length),
                scalars: value.unicodeScalars.map(\.value),
                isWhitespace: value.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            ))
            utf16Offset += length
        }
        return result
    }

    private nonisolated static func mergedRanges(tokens: [Token], changed: [Bool]) -> [NSRange] {
        var result: [NSRange] = []
        for index in tokens.indices where changed[index] {
            let range = tokens[index].utf16Range
            if let last = result.indices.last, NSMaxRange(result[last]) == range.location {
                result[last].length += range.length
            } else {
                result.append(range)
            }
        }
        return result
    }
}
