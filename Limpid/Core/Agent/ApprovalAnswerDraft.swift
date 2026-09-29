// ApprovalAnswerDraft.swift
// Limpid — unsent answers for a question approval card.

import Foundation

/// The user's in-progress answers. Kept as a value so the composition rules
/// can be tested without a view: a multi-select answer joins labels with
/// ", " in option order because that is what the provider expects.
///
/// Free text is the "Other" row, one more option rather than an override, as
/// in the provider's own terminal dialog. Its selection is tracked apart from
/// its text so that choosing a listed option in a single-select question
/// deselects the row without discarding what was typed; only what the card
/// shows as selected is ever sent.
struct ApprovalAnswerDraft: Equatable, Sendable {
    /// The question the card was showing, so a reopened card returns to it.
    var activeQuestionIndex = 0
    private(set) var selectedLabels: [Int: [String]] = [:]
    private(set) var freeText: [Int: String] = [:]
    private(set) var otherSelectedIndices: Set<Int> = []

    mutating func toggle(label: String, questionIndex: Int, in question: ApprovalQuestion) {
        var labels = selectedLabels[questionIndex] ?? []
        if let index = labels.firstIndex(of: label) {
            labels.remove(at: index)
        } else if question.isMultiSelect {
            labels.append(label)
        } else {
            labels = [label]
            otherSelectedIndices.remove(questionIndex)
        }
        selectedLabels[questionIndex] = labels
    }

    mutating func toggleOther(questionIndex: Int, in question: ApprovalQuestion) {
        if otherSelectedIndices.contains(questionIndex) {
            otherSelectedIndices.remove(questionIndex)
        } else {
            selectOther(questionIndex: questionIndex, in: question)
        }
    }

    /// Typing is taken as choosing the row, so the user never has to select
    /// it separately. Clearing the text leaves the selection alone; blank
    /// text is simply not an answer.
    mutating func setFreeText(_ text: String, questionIndex: Int, in question: ApprovalQuestion) {
        freeText[questionIndex] = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectOther(questionIndex: questionIndex, in: question)
        }
    }

    /// Returning to the field is taken as choosing the kept text again, so
    /// the dimmed row comes back without retyping. An empty field is not
    /// selected on focus alone, since it would have nothing to send.
    mutating func selectOtherIfFilled(questionIndex: Int, in question: ApprovalQuestion) {
        guard !(freeText[questionIndex] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectOther(questionIndex: questionIndex, in: question)
    }

    private mutating func selectOther(questionIndex: Int, in question: ApprovalQuestion) {
        otherSelectedIndices.insert(questionIndex)
        if !question.isMultiSelect {
            selectedLabels[questionIndex] = []
        }
    }

    func isSelected(_ label: String, questionIndex: Int) -> Bool {
        selectedLabels[questionIndex]?.contains(label) ?? false
    }

    func isOtherSelected(questionIndex: Int) -> Bool {
        otherSelectedIndices.contains(questionIndex)
    }

    /// Whether this question has an answer to send, which is what its tab's
    /// check mark shows.
    func isAnswered(questionIndex: Int, in question: ApprovalQuestion) -> Bool {
        answer(to: question, at: questionIndex) != nil
    }

    /// Every question's answer keyed by its prompt, or `nil` while any
    /// question is still unanswered.
    func answers(for questions: [ApprovalQuestion]) -> [String: String]? {
        var answers: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            guard let answer = answer(to: question, at: index) else { return nil }
            answers[question.prompt] = answer
        }
        return answers
    }

    private func answer(to question: ApprovalQuestion, at index: Int) -> String? {
        let chosen = selectedLabels[index] ?? []
        var parts = question.options.map(\.label).filter { chosen.contains($0) }
        let text = (freeText[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if otherSelectedIndices.contains(index), !text.isEmpty {
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
