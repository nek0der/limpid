// PhraseBreaksTests.swift
// Limpid — Japanese empty-state words group into phrases, so a line never starts with a particle.

import Foundation
import Testing
@testable import Limpid

struct PhraseBreaksTests {
    private static let japanese = Locale(identifier: "ja")
    private static let english = Locale(identifier: "en")

    private static func phrases(of state: EmptyState) -> [String] {
        PhraseBreaks.phrases(in: state.description(locale: japanese) ?? "")
    }

    @Test func notificationHistory_breaksOnlyBetweenItsPhrases() {
        #expect(Self.phrases(of: .noNotifications) == ["エージェントの", "応答と", "コマンドの", "完了が", "表示されます。"])
    }

    /// A compound in one script stays whole (スナップショット), and a
    /// comma goes with the phrase before it.
    @Test func anIncompleteRecord_keepsItsCompoundsAndItsComma() {
        #expect(Self.phrases(of: .incompleteRecord) == [
            "ターンの", "記録に", "スナップショットが", "欠けているため、", "変更を", "表示できません。"
        ])
    }

    /// A line break the translation writes is a piece of its own, and the
    /// phrases on either side of it keep their words (ワークツリー, 要対応).
    @Test func allProjects_keepsItsLineBreak_betweenPhrases() {
        #expect(Self.phrases(of: .noOpenWorktrees) == [
            "タブを", "開いている", "ワークツリーと、", "\n", "要対応のある", "ワークツリーが", "表示されます。"
        ])
    }

    @Test func eachJapaneseDescription_isItsPhrases_withNothingLost() {
        for state in EmptyState.inventory {
            guard let text = state.description(locale: Self.japanese) else { continue }
            #expect(PhraseBreaks.phrases(in: text).joined() == text)
            let joined = PhraseBreaks.joined(text, locale: Self.japanese)
            #expect(joined.replacingOccurrences(of: PhraseBreaks.wordJoiner, with: "") == text)
        }
    }

    /// The joiners stand only inside a phrase: between two phrases the
    /// line may still break.
    @Test func theJoiners_standInsideEachPhrase_only() {
        let joined = PhraseBreaks.joined("変更を追跡できません。", locale: Self.japanese)
        #expect(joined == ["変更を", "追跡できません。"].map { $0.map(String.init).joined(separator: PhraseBreaks.wordJoiner) }.joined())
    }

    @Test func english_isLeftAsItIs() {
        let text = EmptyState.noNotifications.description(locale: Self.english) ?? ""
        #expect(PhraseBreaks.joined(text, locale: Self.english) == text)
    }
}
