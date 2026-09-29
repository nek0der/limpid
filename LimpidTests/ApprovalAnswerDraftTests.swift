// ApprovalAnswerDraftTests.swift
// Limpid — answer composition rules for the question card.

import Testing
@testable import Limpid

struct ApprovalAnswerDraftTests {
    private let color = ApprovalQuestion(
        header: "Color", prompt: "Which color?",
        options: [.init(label: "Red", description: nil), .init(label: "Blue", description: nil)],
        isMultiSelect: true
    )
    private let size = ApprovalQuestion(
        header: nil,
        prompt: "Which size?",
        options: [.init(label: "S", description: nil)],
        isMultiSelect: false
    )

    @Test func answers_requireEveryQuestion() {
        var draft = ApprovalAnswerDraft()
        draft.toggle(label: "Red", questionIndex: 0, in: color)
        #expect(draft.answers(for: [color, size]) == nil)
        draft.toggle(label: "S", questionIndex: 1, in: size)
        #expect(draft.answers(for: [color, size]) == ["Which color?": "Red", "Which size?": "S"])
    }

    @Test func multiSelect_joinsLabelsInOptionOrder() {
        var draft = ApprovalAnswerDraft()
        draft.toggle(label: "Blue", questionIndex: 0, in: color)
        draft.toggle(label: "Red", questionIndex: 0, in: color)
        #expect(draft.answers(for: [color]) == ["Which color?": "Red, Blue"])
        draft.toggle(label: "Red", questionIndex: 0, in: color)
        #expect(draft.answers(for: [color]) == ["Which color?": "Blue"])
    }

    @Test func singleSelect_replacesThePreviousLabel() {
        var draft = ApprovalAnswerDraft()
        draft.toggle(label: "S", questionIndex: 0, in: size)
        let other = ApprovalQuestion(
            header: nil,
            prompt: "Which size?",
            options: [.init(label: "S", description: nil), .init(label: "M", description: nil)],
            isMultiSelect: false
        )
        draft.toggle(label: "M", questionIndex: 0, in: other)
        #expect(draft.answers(for: [other]) == ["Which size?": "M"])
    }

    @Test func isAnswered_tracksOnlyThatQuestion() {
        var draft = ApprovalAnswerDraft()
        draft.toggle(label: "S", questionIndex: 1, in: size)
        #expect(!draft.isAnswered(questionIndex: 0, in: color))
        #expect(draft.isAnswered(questionIndex: 1, in: size))
    }

    @Test func freeText_countsAsAnAnswerAndIsAppendedForMultiSelect() {
        var draft = ApprovalAnswerDraft()
        draft.setFreeText("  XL  ", questionIndex: 1, in: size)
        draft.toggle(label: "Red", questionIndex: 0, in: color)
        draft.setFreeText("Green", questionIndex: 0, in: color)
        #expect(draft.answers(for: [color, size]) == ["Which color?": "Red, Green", "Which size?": "XL"])
        draft.setFreeText("   ", questionIndex: 1, in: size)
        #expect(draft.answers(for: [color, size]) == nil)
    }

    @Test func singleSelect_optionDeselectsOtherButKeepsItsText() {
        var draft = ApprovalAnswerDraft()
        draft.setFreeText("XL", questionIndex: 0, in: size)
        #expect(draft.isOtherSelected(questionIndex: 0))

        draft.toggle(label: "S", questionIndex: 0, in: size)
        #expect(!draft.isOtherSelected(questionIndex: 0))
        #expect(draft.freeText[0] == "XL")
        #expect(draft.answers(for: [size]) == ["Which size?": "S"])

        // Editing the kept text chooses the row again and replaces the option.
        draft.setFreeText("XXL", questionIndex: 0, in: size)
        #expect(!draft.isSelected("S", questionIndex: 0))
        #expect(draft.answers(for: [size]) == ["Which size?": "XXL"])
    }

    @Test func toggleOther_selectsKeptTextAndDeselectsIt() {
        var draft = ApprovalAnswerDraft()
        draft.setFreeText("XL", questionIndex: 0, in: size)
        draft.toggleOther(questionIndex: 0, in: size)
        #expect(draft.answers(for: [size]) == nil)
        #expect(draft.freeText[0] == "XL")

        draft.toggle(label: "S", questionIndex: 0, in: size)
        draft.toggleOther(questionIndex: 0, in: size)
        #expect(!draft.isSelected("S", questionIndex: 0))
        #expect(draft.answers(for: [size]) == ["Which size?": "XL"])
    }

    @Test func selectOtherIfFilled_reselectsKeptTextOnly() {
        var draft = ApprovalAnswerDraft()
        draft.selectOtherIfFilled(questionIndex: 0, in: size)
        #expect(!draft.isOtherSelected(questionIndex: 0))

        draft.setFreeText("XL", questionIndex: 0, in: size)
        draft.toggle(label: "S", questionIndex: 0, in: size)
        draft.selectOtherIfFilled(questionIndex: 0, in: size)
        #expect(draft.isOtherSelected(questionIndex: 0))
        #expect(draft.answers(for: [size]) == ["Which size?": "XL"])
    }

    @Test func multiSelect_otherIsIndependentOfOptions() {
        var draft = ApprovalAnswerDraft()
        draft.toggle(label: "Red", questionIndex: 0, in: color)
        draft.setFreeText("Green", questionIndex: 0, in: color)
        draft.toggle(label: "Blue", questionIndex: 0, in: color)
        #expect(draft.isOtherSelected(questionIndex: 0))
        #expect(draft.answers(for: [color]) == ["Which color?": "Red, Blue, Green"])
        draft.toggleOther(questionIndex: 0, in: color)
        #expect(draft.answers(for: [color]) == ["Which color?": "Red, Blue"])
    }

    @Test func fitsDecisionLimit_countsEncodedBytesNotCharacters() {
        #expect(ApprovalResolution.answer(["Which color?": "Red"]).fitsDecisionLimit)
        #expect(ApprovalResolution.answer(["q": String(repeating: "a", count: 8000)]).fitsDecisionLimit)
        // 3,000 characters, but 9,000 UTF-8 bytes on the wire.
        #expect(!ApprovalResolution.answer(["q": String(repeating: "あ", count: 3000)]).fitsDecisionLimit)
        #expect(ApprovalResolution.delegate.fitsDecisionLimit)
    }
}
