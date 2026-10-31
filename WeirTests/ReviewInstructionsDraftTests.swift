// ReviewInstructionsDraftTests.swift
// Weir — the review instructions editor shows the text in effect and saves "" for the default.

import Foundation
import Testing
@testable import Weir

struct ReviewInstructionsDraftTests {
    private let english = Locale(identifier: "en")
    private let japanese = Locale(identifier: "ja")

    @Test func theDefault_isShownAsText_inTheAppsLanguage() {
        let shown = ReviewInstructionsDraft.text(saved: "", locale: japanese)

        #expect(shown == ReviewPromptBuilder.defaultInstructions.resolved(in: japanese))
        #expect(ReviewInstructionsDraft.text(saved: "Mine", locale: japanese) == "Mine")
    }

    @Test func textEqualToADefault_savesEmpty_inEitherLanguage() {
        let defaults = ReviewInstructionsDraft.defaults
        let englishDefault = ReviewPromptBuilder.defaultInstructions.resolved(in: english)
        let japaneseDefault = ReviewPromptBuilder.defaultInstructions.resolved(in: japanese)

        #expect(ReviewInstructionsDraft.saved(text: englishDefault, defaults: defaults) == "")
        #expect(ReviewInstructionsDraft.saved(text: japaneseDefault, defaults: defaults) == "")
        // A newline left at the end is still the default.
        #expect(ReviewInstructionsDraft.saved(text: englishDefault + "\n", defaults: defaults) == "")
    }

    @Test func opening_showsWhatIsStoredAsIs_evenWhereSavingItWouldChangeIt() {
        // An older build could store the default's text itself. Opening the
        // pane shows it unchanged; only typing saves, which would write "".
        let stored = ReviewPromptBuilder.defaultInstructions.resolved(in: english)

        #expect(ReviewInstructionsDraft.text(saved: stored, locale: japanese) == stored)
        #expect(ReviewInstructionsDraft.saved(text: stored, defaults: ReviewInstructionsDraft.defaults) == "")
    }

    @Test func anEditedDefault_isSavedAsWritten() {
        let edited = ReviewPromptBuilder.defaultInstructions.resolved(in: english) + "\nKeep the diff small."

        #expect(ReviewInstructionsDraft.saved(text: edited, defaults: ReviewInstructionsDraft.defaults) == edited)
    }
}
