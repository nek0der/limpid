// PhraseBreaks.swift
// Limpid — Japanese text that wraps only between phrases, so no line starts with a particle.

import Foundation
import NaturalLanguage

/// Japanese may break between any two characters, so a line can start
/// with a particle (「の完了が…」), which reads badly. We group the words
/// into phrases (bunsetsu): a word, then the particles, auxiliaries, and
/// closing punctuation that follow it. Inside a phrase the characters are
/// joined with U+2060 WORD JOINER, which the line breaker never breaks at,
/// so a line breaks only between phrases. The joiners are for the drawn
/// text alone; what VoiceOver reads keeps the plain string.
///
/// Other languages already break between words and are left as they are.
enum PhraseBreaks {
    static let wordJoiner = "\u{2060}"

    /// `text` with each phrase's characters joined, in Japanese; else
    /// `text` itself.
    static func joined(_ text: String, locale: Locale) -> String {
        guard isJapanese(locale) else { return text }
        return phrases(in: text).map(join).joined()
    }

    /// The phrases `text` breaks into, in order, which together are `text`.
    /// A space or a line break is a piece of its own, between phrases.
    static func phrases(in text: String) -> [String] {
        var phrases: [String] = []
        // Whether the last phrase takes what follows: not after a space.
        var isOpen = false
        // Opening brackets, held for the word they open.
        var opening = ""
        for piece in pieces(of: text) {
            switch piece.kind {
            case .space:
                if !opening.isEmpty {
                    phrases.append(opening)
                    opening = ""
                }
                phrases.append(piece.text)
                isOpen = false
            case .opening:
                opening += piece.text
            case .trailing where isOpen && opening.isEmpty:
                phrases[phrases.count - 1] += piece.text
            case .compound where isOpen && opening.isEmpty && phrases.last.map { isCompound($0, with: piece.text) } == true:
                phrases[phrases.count - 1] += piece.text
            case .trailing, .compound, .word:
                phrases.append(opening + piece.text)
                opening = ""
                isOpen = true
            }
        }
        if !opening.isEmpty {
            phrases.append(opening)
        }
        return phrases
    }

    // MARK: - Pieces

    private enum PieceKind {
        /// A space or a line break.
        case space
        /// An opening bracket, which goes with the word after it.
        case opening
        /// A particle, an auxiliary, or closing punctuation: hiragana
        /// alone, or 。、 and the like, which go with the word before.
        case trailing
        /// All katakana or all kanji, which a compound of the same
        /// script continues (ワーク|ツリー, 要|対応).
        case compound
        /// Any other word, which starts a phrase.
        case word
    }

    private struct Piece {
        let text: String
        let kind: PieceKind
    }

    private static let closing: Set<Character> = [
        "。",
        "、",
        "，",
        "．",
        "！",
        "？",
        "」",
        "』",
        "）",
        "】",
        "〉",
        "》",
        "・",
        ".",
        ",",
        "!",
        "?",
        ")",
        ":",
        ";"
    ]
    private static let openingBrackets: Set<Character> = ["「", "『", "（", "【", "〈", "《", "("]

    /// The tokenizer's words, and each character between them, by kind.
    private static func pieces(of text: String) -> [Piece] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.japanese)
        var pieces: [Piece] = []
        var cursor = text.startIndex
        func gap(upTo end: String.Index) {
            for character in text[cursor..<end] {
                pieces.append(Piece(text: String(character), kind: kind(ofGap: character)))
            }
        }
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            gap(upTo: range.lowerBound)
            let word = String(text[range])
            pieces.append(Piece(text: word, kind: kind(ofWord: word)))
            cursor = range.upperBound
            return true
        }
        gap(upTo: text.endIndex)
        return pieces
    }

    private static func kind(ofGap character: Character) -> PieceKind {
        if character.isWhitespace {
            return .space
        }
        if openingBrackets.contains(character) {
            return .opening
        }
        if closing.contains(character) {
            return .trailing
        }
        return .word
    }

    private static func kind(ofWord word: String) -> PieceKind {
        if word.unicodeScalars.allSatisfy(isHiragana) {
            return .trailing
        }
        if word.unicodeScalars.allSatisfy(isKatakana) || word.unicodeScalars.allSatisfy(isKanji) {
            return .compound
        }
        return .word
    }

    /// Whether `next` continues the compound `phrase` ends with: both
    /// katakana, or both kanji.
    private static func isCompound(_ phrase: String, with next: String) -> Bool {
        guard let last = phrase.unicodeScalars.last else { return false }
        if isKatakana(last) {
            return next.unicodeScalars.allSatisfy(isKatakana)
        }
        if isKanji(last) {
            return next.unicodeScalars.allSatisfy(isKanji)
        }
        return false
    }

    private static func isHiragana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x309F).contains(scalar.value) || scalar.value == 0x30FC
    }

    private static func isKatakana(_ scalar: Unicode.Scalar) -> Bool {
        (0x30A0...0x30FF).contains(scalar.value) || (0x31F0...0x31FF).contains(scalar.value)
    }

    private static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) || scalar.value == 0x3005
    }

    private static func join(_ phrase: String) -> String {
        phrase.map(String.init).joined(separator: wordJoiner)
    }

    private static func isJapanese(_ locale: Locale) -> Bool {
        locale.language.languageCode == .japanese
    }
}
