// ApprovalQuestionForm.swift
// Limpid — question and option controls for a question approval card.

import SwiftUI

/// One question at a time. With several questions a tab row switches
/// between them; the design keeps the card at one width and
/// mirrors the provider's own terminal dialog, which also pages by header.
struct ApprovalQuestionForm: View {
    let questions: [ApprovalQuestion]
    @Binding var draft: ApprovalAnswerDraft
    /// The card's focus state, so keyboard focus on a tab, an option, or the
    /// text field still counts as focus inside the card.
    var focus: FocusState<ApprovalCardFocus?>.Binding
    /// The user's Limpid accent, not `Color.accentColor`, which follows the
    /// system accent rather than the one the user picked in Limpid.
    @Environment(\.limpidAccent) private var limpidAccent

    private var activeIndex: Int {
        min(max(draft.activeQuestionIndex, 0), max(questions.count - 1, 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if questions.count > 1 {
                ApprovalQuestionTabs(
                    questions: questions,
                    draft: draft,
                    selectedIndex: activeIndex,
                    focus: focus
                ) { tabIndex in
                    ApprovalAnswerComposition.commit()
                    draft.activeQuestionIndex = tabIndex
                    focus.wrappedValue = .questionTab(tabIndex)
                }
            }
            if questions.indices.contains(activeIndex) {
                let question = questions[activeIndex]
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        Text(verbatim: header)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: question.prompt)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        Button {
                            draft.toggle(label: option.label, questionIndex: activeIndex, in: question)
                            // A pointer click does not move keyboard focus on
                            // its own, so the answer field would keep it.
                            focus.wrappedValue = .option(optionIndex)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                indicator(
                                    isSelected: draft.isSelected(option.label, questionIndex: activeIndex),
                                    in: question
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: option.label).font(.subheadline)
                                    if let description = option.description, !description.isEmpty {
                                        Text(verbatim: description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused(focus, equals: .option(optionIndex))
                        .accessibilityLabel(Text(verbatim: option.label))
                        .accessibilityAddTraits(draft.isSelected(option.label, questionIndex: activeIndex) ? .isSelected : [])
                    }
                    otherRow(question: question, index: activeIndex)
                }
                // A new field per question. One field reused across pages
                // keeps an input method's uncommitted text, which the input
                // method then commits into whichever question is showing.
                .id(activeIndex)
            }
        }
    }

    /// The free-text row, laid out like an option so it reads as one. A
    /// deselected row keeps its text but dims it, which shows the text will
    /// not be sent without throwing it away.
    private func otherRow(question: ApprovalQuestion, index: Int) -> some View {
        let isSelected = draft.isOtherSelected(questionIndex: index)
        return HStack(alignment: .center, spacing: 8) {
            Button {
                draft.toggleOther(questionIndex: index, in: question)
                // Choosing the row leads straight into typing. Deselecting it
                // must not land in the field, whose focus would select the
                // row again.
                focus.wrappedValue = draft.isOtherSelected(questionIndex: index) ? .answerField : .otherOption
            } label: {
                indicator(isSelected: isSelected, in: question)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused(focus, equals: .otherOption)
            .accessibilityLabel(Text("Other answer"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            TextField(
                "Other",
                text: Binding(
                    get: { draft.freeText[index] ?? "" },
                    set: { draft.setFreeText($0, questionIndex: index, in: question) }
                ),
                prompt: Text("Type your answer"),
                axis: .vertical
            )
            // Return and Shift-Return are handled by the card's key monitor,
            // which leaves Option-Return to the field editor's own line
            // break; see `ApprovalCardKeyMonitor`.
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .font(.subheadline)
            // Matches the app's other text fields, which are flat fills
            // rather than the system bezel. A plain field draws no focus
            // ring, so the accent stroke stands in for it.
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LimpidColor.rowActiveFill))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(limpidAccent, lineWidth: 1.5)
                    .opacity(focus.wrappedValue == .answerField ? 1 : 0)
            }
            .opacity(isSelected || (draft.freeText[index] ?? "").isEmpty ? 1 : 0.55)
            .focused(focus, equals: .answerField)
            .onChange(of: focus.wrappedValue) { _, newFocus in
                if newFocus == .answerField {
                    draft.selectOtherIfFilled(questionIndex: index, in: question)
                }
            }
            .accessibilityLabel(Text("Other answer text"))
        }
    }

    /// Fixed-size so a radio and a checkbox occupy the same box; otherwise
    /// the glyphs' different bounds change the card height between a
    /// single-select and a multi-select question.
    private func indicator(isSelected: Bool, in question: ApprovalQuestion) -> some View {
        Image(systemName: symbol(isSelected: isSelected, in: question))
            .font(.system(size: 13))
            .foregroundStyle(isSelected ? limpidAccent : .secondary)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }

    private func symbol(isSelected: Bool, in question: ApprovalQuestion) -> String {
        if question.isMultiSelect {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }
}

/// Pages between questions. Drawn like the Waiting filter switch, the app's
/// other segmented control: the selected segment is an accent pill that
/// slides to its new place. A check marks answered questions, which reads on
/// the accent pill where a colored dot would not.
private struct ApprovalQuestionTabs: View {
    let questions: [ApprovalQuestion]
    let draft: ApprovalAnswerDraft
    let selectedIndex: Int
    var focus: FocusState<ApprovalCardFocus?>.Binding
    let onSelect: (Int) -> Void

    @Environment(\.limpidAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [Int: CGRect] = [:]

    private nonisolated static let space = "approval-question-tabs"

    private var motion: Animation {
        reduceMotion ? LimpidMotion.reducedSlide : LimpidMotion.paneMergeHighlight
    }

    private var selected: CGRect {
        frames[selectedIndex] ?? .zero
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(questions.enumerated()), id: \.offset) { tabIndex, question in
                segment(tabIndex, question)
            }
        }
        .coordinateSpace(.named(Self.space))
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(accent)
                .frame(width: selected.width, height: selected.height)
                .offset(x: selected.minX)
                .opacity(selected.isEmpty ? 0 : 1)
                // Scoped to the pill: the question below swaps without
                // animation so the card does not tween its height.
                .animation(motion, value: selectedIndex)
        }
        .padding(1)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        // The card can move in the same update that starts the slide. The
        // pill's animation is otherwise resolved against the card's old
        // position and travels diagonally to catch up.
        .geometryGroup()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Questions"))
    }

    private func segment(_ tabIndex: Int, _ question: ApprovalQuestion) -> some View {
        let isSelected = tabIndex == selectedIndex
        let isAnswered = draft.isAnswered(questionIndex: tabIndex, in: question)
        return Button {
            onSelect(tabIndex)
        } label: {
            // Leading, like the option indicators below and the provider's
            // own question tabs, and smaller than the label so it marks
            // progress without competing with the header.
            HStack(spacing: 3) {
                if isAnswered {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(display: question.header.map(DisplayText.verbatim) ?? .localized("Question"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? LimpidColor.onAccent : Color.primary.opacity(0.65))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            // A plain button only hit-tests its drawn content, which would
            // leave most of the segment dead.
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.space))
            } action: { frame in
                frames[tabIndex] = frame
            }
        }
        .buttonStyle(.plain)
        .focused(focus, equals: .questionTab(tabIndex))
        .accessibilityLabel(Text(verbatim: question.header ?? question.prompt))
        .accessibilityValue(Text(isAnswered ? "Answered" : "Unanswered"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
