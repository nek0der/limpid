// ApprovalQuestionForm.swift
// Weir — question and option controls for a question approval card.

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
    /// The user's Weir accent, not `Color.accentColor`, which follows the
    /// system accent rather than the one the user picked in Weir.
    @Environment(\.weirAccent) private var weirAccent

    private var activeIndex: Int {
        min(max(draft.activeQuestionIndex, 0), max(questions.count - 1, 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceS) {
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
                VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceSnug) {
                    if let header = question.header, !header.isEmpty {
                        Text(verbatim: header)
                            .font(.supervision(.meta))
                            .foregroundStyle(SupervisionTokens.muted.color)
                    }
                    Text(verbatim: question.prompt)
                        .font(.supervision(.body, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        Button {
                            draft.toggle(label: option.label, questionIndex: activeIndex, in: question)
                            // A pointer click does not move keyboard focus on
                            // its own, so the answer field would keep it.
                            focus.wrappedValue = .option(optionIndex)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceS) {
                                indicator(
                                    isSelected: draft.isSelected(option.label, questionIndex: activeIndex),
                                    in: question
                                )
                                VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceHairline) {
                                    Text(verbatim: option.label).font(.supervision(.body))
                                    if let description = option.description, !description.isEmpty {
                                        Text(verbatim: description)
                                            .font(.supervision(.meta))
                                            .foregroundStyle(SupervisionTokens.muted.color)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused(focus, equals: .option(optionIndex))
                        .accessibilityLabel(Text(verbatim: option.label))
                        // The label replaces the children, so the option's
                        // description under it is read as its value: a hint
                        // says what pressing does, and some turn hints off.
                        .accessibilityValue(Text(verbatim: option.description ?? ""))
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
        return HStack(alignment: .center, spacing: WeirLayout.Supervision.spaceS) {
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
            // The option's own word, as the others have theirs; the field
            // beside it is where the answer goes.
            Text("Other")
                .font(.supervision(.body))
                .fixedSize()
                .accessibilityHidden(true)
            // No title of its own: the option's word stands before it, and
            // its spoken label is set below.
            TextField(
                text: Binding(
                    get: { draft.freeText[index] ?? "" },
                    set: { draft.setFreeText($0, questionIndex: index, in: question) }
                ),
                prompt: Text("Type your answer"),
                axis: .vertical
            ) {
                EmptyView()
            }
            // Return and Shift-Return are handled by the card's key monitor,
            // which leaves Option-Return to the field editor's own line
            // break; see `ApprovalCardKeyMonitor`.
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .font(.supervision(.body))
            // Matches the app's other text fields, which are flat fills
            // rather than the system bezel. A plain field draws no focus
            // ring, so the window's own ring stands in for it, as it does
            // on the card's buttons.
            .padding(.horizontal, WeirLayout.Supervision.spaceM)
            .padding(.vertical, WeirLayout.Supervision.spaceSnug)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WeirColor.rowActiveFill))
            .supervisionFocusRing(isFocused: focus.wrappedValue == .answerField, cornerRadius: 8)
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
            .font(.supervision(.label))
            .foregroundStyle(isSelected ? weirAccent : .secondary)
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

/// Pages between questions, as a segmented control: the selected segment is an
/// accent pill that slides to its new place, drawn by the segmented picker's
/// own track so a light accent keeps its words readable on it. A check marks
/// answered questions, which reads on the accent pill where a colored dot
/// would not.
private struct ApprovalQuestionTabs: View {
    let questions: [ApprovalQuestion]
    let draft: ApprovalAnswerDraft
    let selectedIndex: Int
    var focus: FocusState<ApprovalCardFocus?>.Binding
    let onSelect: (Int) -> Void

    /// These are smaller than the picker's track, as the card's tabs always
    /// were: a hairline around the pill and a small control's corner.
    private static let metrics = SegmentedTrackMetrics(
        inset: 1,
        cornerRadius: WeirLayout.Supervision.smallControlCornerRadius
    )

    var body: some View {
        // The track's slide runs on its own clock rather than in a
        // transaction, so the question below swaps without animation and the
        // card does not tween its height.
        SupervisionSegmentedTrack(
            count: questions.count,
            selectedIndex: selectedIndex,
            metrics: Self.metrics
        ) { tabIndex in
            segment(tabIndex, questions[tabIndex])
        } selectedLabel: { tabIndex, color in
            tabLabel(tabIndex, questions[tabIndex], color: color)
        }
        // ← and → move between pages as they move a segmented control's
        // choice (`SupervisionSegmentedPicker.keyStep`), stopping at the ends.
        .onKeyPress(.leftArrow) { step(by: -1) }
        .onKeyPress(.rightArrow) { step(by: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Questions"))
    }

    private func step(by offset: Int) -> KeyPress.Result {
        let step = SupervisionSegmentedPicker<Int>.keyStep(
            from: selectedIndex,
            by: offset,
            count: questions.count,
            isEnabled: true
        )
        if let next = step.next {
            onSelect(next)
            focus.wrappedValue = .questionTab(next)
        }
        return step.isHandled ? .handled : .ignored
    }

    private func segment(_ tabIndex: Int, _ question: ApprovalQuestion) -> some View {
        let isSelected = tabIndex == selectedIndex
        let isAnswered = draft.isAnswered(questionIndex: tabIndex, in: question)
        return Button {
            onSelect(tabIndex)
        } label: {
            tabLabel(tabIndex, question, color: SupervisionTokens.text.color)
                // A plain button only hit-tests its drawn content, which would
                // leave most of the segment dead.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused(focus, equals: .questionTab(tabIndex))
        .accessibilityLabel(Text(verbatim: question.header ?? question.prompt))
        .accessibilityValue(Text(isAnswered ? "Answered" : "Unanswered"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Draws a tab's words and its answered check in `color`: the text color
    /// on the track, or the pill's label color under the pill.
    private func tabLabel(_ tabIndex: Int, _ question: ApprovalQuestion, color: Color) -> some View {
        // The check leads, like the option indicators below and the
        // provider's own question tabs, and is smaller than the label so it
        // marks progress without competing with the header.
        HStack(spacing: WeirLayout.Supervision.spaceXS) {
            if draft.isAnswered(questionIndex: tabIndex, in: question) {
                Image(systemName: "checkmark")
                    .font(.supervision(.glyph, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(display: question.header.map(DisplayText.verbatim) ?? .localized("Question"))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, WeirLayout.Supervision.spaceXS)
    }
}
