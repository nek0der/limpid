// TextBalanceTests.swift
// Weir — a wrapping text takes the narrowest width that keeps its line count, so its lines are of even length.

import CoreGraphics
import Testing
@testable import Weir

struct TextBalanceTests {
    /// A greedy line breaker over pieces of the given widths, as a text
    /// breaks words in English or characters in Japanese: the lines it
    /// sets at `width`, each `lineHeight` tall.
    private static func height(of pieces: [CGFloat], at width: CGFloat, lineHeight: CGFloat = 16) -> CGFloat {
        var lines = 1
        var line: CGFloat = 0
        for piece in pieces {
            if line > 0, line + piece > width {
                lines += 1
                line = piece
            } else {
                line += piece
            }
        }
        return CGFloat(lines) * lineHeight
    }

    private static func widths(of pieces: [CGFloat], at width: CGFloat) -> [CGFloat] {
        var lines: [CGFloat] = [0]
        for piece in pieces {
            if let last = lines.last, last > 0, last + piece > width {
                lines.append(piece)
            } else {
                lines[lines.count - 1] += piece
            }
        }
        return lines
    }

    private static func balanced(_ pieces: [CGFloat], room: CGFloat) -> CGFloat {
        TextBalance.width(idealWidth: pieces.reduce(0, +), room: room) { height(of: pieces, at: $0) }
    }

    @Test func minimumLineCount_isTheIdealWidthOverTheRoom_roundedUp() {
        #expect(TextBalance.minimumLineCount(idealWidth: 100, room: 200) == 1)
        #expect(TextBalance.minimumLineCount(idealWidth: 200, room: 200) == 1)
        #expect(TextBalance.minimumLineCount(idealWidth: 201, room: 200) == 2)
        #expect(TextBalance.minimumLineCount(idealWidth: 400, room: 200) == 2)
        #expect(TextBalance.minimumLineCount(idealWidth: 401, room: 200) == 3)
        #expect(TextBalance.minimumLineCount(idealWidth: 50, room: 0) == 1)
    }

    /// A text that fits on one line keeps the room, so nothing changes.
    @Test func aTextThatFits_keepsTheRoom() {
        let pieces: [CGFloat] = Array(repeating: 10, count: 10)
        #expect(Self.balanced(pieces, room: 280) == 280)
        #expect(Self.balanced(pieces, room: 100) == 100)
    }

    /// The Japanese widow: 28 characters of 10pt in 270pt set 27 on the
    /// first line and one alone on the second; balanced, 14 and 14.
    @Test func aJapaneseSentence_breaksIntoTwoEvenLines() {
        let pieces: [CGFloat] = Array(repeating: 10, count: 28)
        let width = Self.balanced(pieces, room: 270)

        #expect(Self.widths(of: pieces, at: 270) == [270, 10])
        #expect(Self.height(of: pieces, at: width) == Self.height(of: pieces, at: 270))
        #expect(Self.widths(of: pieces, at: width) == [140, 140])
        #expect(width >= 140 && width < 141)
    }

    /// Words of uneven length: the lines are as even as the breaks allow,
    /// and there are no more of them than the room gives.
    @Test func englishWords_balanceOnTheirBreaks() {
        let pieces: [CGFloat] = [40, 25, 60, 30, 45, 20, 55, 35, 15]
        let room: CGFloat = 250
        let width = Self.balanced(pieces, room: room)
        let lines = Self.widths(of: pieces, at: width)

        #expect(lines.count == Self.widths(of: pieces, at: room).count)
        #expect(width <= room)
        // One point narrower and another line would be needed.
        #expect(Self.height(of: pieces, at: width - TextBalance.precision) > Self.height(of: pieces, at: room))
        #expect((lines.max() ?? 0) - (lines.min() ?? 0) < 60, "\(lines)")
    }

    /// Three lines stay three, each about a third.
    @Test func aLongText_keepsItsLineCount_andEvensItsLines() {
        let pieces: [CGFloat] = Array(repeating: 10, count: 61)
        let width = Self.balanced(pieces, room: 300)

        #expect(Self.widths(of: pieces, at: 300) == [300, 300, 10])
        #expect(Self.widths(of: pieces, at: width).count == 3)
        // 210, 210, 190 rather than 300, 300, 10.
        let lines = Self.widths(of: pieces, at: width)
        #expect((lines.max() ?? 0) - (lines.min() ?? 0) <= 20, "\(lines)")
    }
}
