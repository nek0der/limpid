// DecisionBarRow.swift
// Weir — what the decision bar shows, drawn from its model alone, and the bar it stands in.

import SwiftUI
import WeirDomain

/// The decision bar of a pane in its foot bar: the row on the tone's fill
/// under the tone's rule, on the line the sidebar's and the changes panel's
/// foot bars are on.
struct DecisionBarFootBar: View {
    let model: DecisionBarModel
    let paneID: UUID
    let receiptHelp: String?
    let canStartNew: Bool
    /// Why the stop's pane cannot start a new conversation, `nil` when it
    /// can or nothing is known (`StopLedgerStore.newConversationBlockers`).
    var newConversationBlocker: DecisionBarContent.ResumeBlocker?
    let onShowNext: () -> Void

    var body: some View {
        SupervisionFootBar(fill: DecisionBarRow.fill(model.tone), rule: DecisionBarRow.rule(model.tone)) {
            DecisionBarRow(
                model: model,
                paneID: paneID,
                receiptHelp: receiptHelp,
                canStartNew: canStartNew,
                onShowNext: onShowNext,
                newConversationBlocker: newConversationBlocker
            )
        }
        // Its fill is opaque, so its buttons fill theirs opaquely too
        // rather than take on the bar's tint.
        .environment(\.supervisionSurfaceOpacity, 1)
        .accessibilityElement(children: .contain)
    }
}

/// The decision bar's row: its tag, its count, its words, and its buttons,
/// from the bar's model and what the pane reads for it. Apart from
/// `DecisionBarView`, which reads the window's stores, so the row can be
/// drawn, and measured against the foot bar, from a model alone.
struct DecisionBarRow: View {
    let model: DecisionBarModel
    let paneID: UUID
    /// The receipt's tooltip: the turn's prompt, how long it ran, and its
    /// check's command, which the pane reads from the turn history.
    let receiptHelp: String?
    /// Whether the stop's ⋯ can start a new conversation now: the shell is
    /// at its prompt with nothing typed (`StopLedgerStore.startsNew`).
    let canStartNew: Bool
    /// The count's press: the pane's next item.
    let onShowNext: () -> Void
    /// Why it cannot (`StopResumeRules.newConversationBlocker`), which the
    /// disabled item says as its tooltip.
    var newConversationBlocker: DecisionBarContent.ResumeBlocker?
    /// The fits the row may take, widest first: the model's
    /// (`DecisionBarModel.fits`), but for a test that measures one fit on
    /// its own.
    var fits: [DecisionBarModel.Fit]?
    @Environment(PrimaryKeyHint.self) private var keyHint
    @Environment(\.primaryActionHandler) private var actions
    @Environment(\.restoreHandler) private var restore
    @Environment(SettingsStore.self) private var settings
    @Environment(\.locale) private var locale

    var body: some View {
        // Each fit is measured with its words (the sentence, and where to
        // answer and the time left beside it, all under the one cap) at no
        // more than their least, or at nothing where the fit is chosen
        // while the rest fits at all (`Shape.keepsWordsFloor`); the fit
        // chosen then gives the words all the rest.
        ViewThatFits(in: .horizontal) {
            ForEach(fits ?? model.fits(locale: locale), id: \.self) { fit in
                row(model, shape: model.shape(fit, locale: locale))
            }
        }
    }

    private func row(_ model: DecisionBarModel, shape: DecisionBarModel.Shape) -> some View {
        let layout = WeirLayout.Supervision.self
        return HStack(spacing: layout.decisionBarSpacing) {
            if let tag = model.tag, shape.showsTag {
                DecisionBarTag(text: tag, tone: model.tone)
                    .accessibilityLabel(Text(verbatim: model.spokenTag ?? tag))
            }
            // Beside the tag, as part of what the bar is on: which of the
            // pane's items it shows, and whether a higher one waits.
            if let countText = model.countText, shape.showsCount {
                countButton(model, text: countText)
            }
            IdealWidthCap(maxIdealWidth: shape.keepsWordsFloor ? layout.decisionBarTextMinWidth : 0) {
                words(model, showsTag: shape.showsTag)
            }
            if shape.showsButtons {
                Spacer(minLength: WeirLayout.Supervision.spaceS)
                HStack(spacing: layout.decisionBarButtonSpacing) {
                    buttons(model, shape: shape)
                }
            }
        }
    }

    /// The sentence, then where to answer and the time left, quieter: one
    /// line, the two sharing it as `DecisionBarWordsLayout` lays them out.
    private func words(_ model: DecisionBarModel, showsTag: Bool) -> some View {
        HStack(spacing: WeirLayout.Supervision.spaceXS) {
            // Right after an item was handled, a quiet mark in place of a
            // tag: the sentence says what happened, and VoiceOver reads
            // that, so the mark is only for the eye. Muted, not green, as
            // no state is drawn in green.
            if model.tone == .done {
                Image(systemName: "checkmark")
                    .font(.supervision(.caption, weight: .semibold))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .accessibilityHidden(true)
            }
            if let instruction = model.instruction {
                // Where to answer takes its width before the sentence does:
                // it is what the bar is for, and the sentence's tooltip keeps
                // what it cuts.
                // The sentence keeps a few words rather than its ellipsis
                // alone, and where even those are not left, where to answer
                // takes its short form.
                DecisionBarWordsLayout(
                    spacing: WeirLayout.Supervision.spaceXS,
                    sentenceFloor: WeirLayout.Supervision.decisionBarTextMinWidth
                ) {
                    sentence(model, showsTag: showsTag)
                    ViewThatFits(in: .horizontal) {
                        instructionText(instruction)
                        instructionText(model.shortInstruction ?? instruction, isWhole: false)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: instruction))
                }
            } else {
                sentence(model, showsTag: showsTag)
            }
            if let deadline = model.heldUntil {
                // Seconds count down, so this one part redraws each second.
                Text(verbatim: "·")
                    .font(.supervision(.body))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let now = SuspendingClock().now
                    Text(verbatim: DecisionBarModel.timeLeft(deadline, now: now, locale: locale))
                        .font(.supervision(.body).monospacedDigit())
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .fixedSize()
                        .accessibilityLabel(Text(verbatim: ApprovalCardModel.spokenTimeLeftText(
                            for: deadline.remaining(at: now),
                            locale: locale
                        )))
                }
            }
        }
    }

    /// The sentence in semibold, all else in the line's muted tone at rest
    /// (a muted summary), which reads evenly. Where the row has no room
    /// for the tag, VoiceOver reads it ahead of the sentence.
    private func sentence(_ model: DecisionBarModel, showsTag: Bool) -> some View {
        let spoken = showsTag ? model.spokenText : AgentStatusText.spokenList([model.spokenTag ?? "", model.spokenText], locale: locale)
        return ReceiptRunsText(
            runs: model.runs,
            size: .body,
            base: model.tone == .muted ? SupervisionTokens.muted.color : SupervisionTokens.text.color,
            showsEmphasis: model.tone != .muted
        )
        .lineLimit(1)
        .supervisionTruncation(model.cutsTextInMiddle ? .subject : .sentence)
        .help((receiptHelp ?? model.textHelp).map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        .accessibilityLabel(Text(verbatim: spoken))
    }

    /// Where to answer, at its whole width while it is a candidate for
    /// the space; the last form may still be cut, rather than overflow.
    private func instructionText(_ text: String, isWhole: Bool = true) -> some View {
        Text(verbatim: text)
            .font(.supervision(.body))
            .foregroundStyle(SupervisionTokens.muted.color)
            .lineLimit(1)
            .fixedSize(horizontal: isWhole, vertical: false)
    }

    /// "1 / 2 · Approval also pending" (or a question, a response, a stop),
    /// in a box beside the tag; a press
    /// shows the pane's next item.
    private func countButton(_ model: DecisionBarModel, text: String) -> some View {
        Button {
            onShowNext()
        } label: {
            let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.chipCornerRadius, style: .continuous)
            Text(verbatim: text)
                .font(.supervision(.caption).monospacedDigit())
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
                .padding(.horizontal, WeirLayout.Supervision.decisionBarCountHorizontalPadding)
                .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
                .contentShape(shape)
                .fixedSize()
        }
        .buttonStyle(.plain)
        // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
        .focusable(false)
        .help(Text(verbatim: model.countSpokenText ?? text))
        .accessibilityLabel(Text(verbatim: model.countSpokenText ?? text))
        .accessibilityHint(Text("Shows the next item in this pane"))
    }

    /// The row's buttons in `shape`: what the model leaves in the row, then
    /// the ⋯ with the rest (`DecisionBarModel.Shape.moreSections`).
    @ViewBuilder
    private func buttons(_ model: DecisionBarModel, shape: DecisionBarModel.Shape) -> some View {
        if let undo = model.undo, let actions {
            Button {
                actions.undo(undo, paneID)
            } label: {
                Text("Undo", comment: "Takes back the last move: a toast's, the decision bar's after Mark as Viewed, or a restore's")
            }
            .buttonStyle(.supervisionSecondary)
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
            .help(Text("Moves the viewed line back where it was", comment: "Decision bar: tooltip of Undo after Mark as Viewed"))
        }
        if let done = model.restoreDone, let restore, let journal = restore.journal(done), journal.isUndoable,
           restore.record(paneID)?.opID == done.opID
        {
            RestoreUndoButton(journal: journal, handler: restore, isShort: shape.usesShortLabels)
        }
        if let action = model.primaryAction, let actions {
            primaryButton(action, actions: actions, shape: shape)
        }
        if shape.showsReview, let actions {
            Button {
                actions.openReview(paneID, model.reviewConversation)
            } label: {
                Text("Review Unviewed")
            }
            .buttonStyle(.supervisionSecondary)
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
            .help(Text(verbatim: ShortcutHelpText.make(
                name: "Review Unviewed",
                shortcut: settings.settings.keyboard.shortcut(for: .review)?.displayString,
                locale: locale
            )))
            // This conversation's, apart from the changes panel's button,
            // which opens every conversation's in the worktree.
            .accessibilityHint(Text(
                "Opens this conversation’s unviewed turns in review",
                comment: "Decision bar, VoiceOver: what Review Unviewed does, the pane's conversation's unviewed turns alone"
            ))
        }
        if !moreEntries(shape.moreSections).isEmpty {
            moreMenu(shape.moreSections)
        }
    }

    /// The ⋯'s rows: each section's items the window can carry out, with a
    /// separator between sections.
    private func moreEntries(_ sections: [[DecisionBarModel.MoreItem]]) -> [PopUpMenuEntry] {
        let groups = sections
            .map { $0.compactMap(moreItem) }
            .filter { !$0.isEmpty }
        return groups.enumerated().flatMap { index, items in
            (index > 0 ? [PopUpMenuEntry.separator] : []) + items.map(PopUpMenuEntry.item)
        }
    }

    /// One entry of the ⋯, named and doing as the button it stands for;
    /// `nil` where the window has no handler for it.
    private func moreItem(_ item: DecisionBarModel.MoreItem) -> PopUpMenuItem? {
        let paneID = paneID
        switch item {
        case .showNext:
            guard let countText = model.countText else { return nil }
            let onShowNext = onShowNext
            return PopUpMenuItem(
                title: LocalizedStringResource(
                    "Show Next Item (\(countText))",
                    comment: "Decision bar's ⋯, short of room: shows the pane's next item; argument: the count, as 1 / 2"
                )
            ) {
                onShowNext()
            }
        case .review:
            guard let actions else { return nil }
            let conversation = model.reviewConversation
            // The key the menu bar's Review Changes answers, shown here as
            // every menu of Weir's shows a command's key (`MenuCommand`).
            return PopUpMenuItem(title: "Review Unviewed", shortcut: MenuCommand.reviewChanges.shortcut(in: settings.settings.keyboard)) {
                actions.openReview(paneID, conversation)
            }
        case let .showPartialChanges(itemID):
            guard let actions else { return nil }
            return PopUpMenuItem(
                title: LocalizedStringResource(
                    "Show Partial Changes",
                    comment: "Decision bar's ⋯ on a stop: opens the changes of the turn that stopped"
                )
            ) {
                actions.showPartialChanges(itemID, paneID)
            }
        case let .startNewConversation(itemID):
            guard let actions else { return nil }
            return PopUpMenuItem(
                title: LocalizedStringResource(
                    "Start New Conversation",
                    comment: "Decision bar's ⋯ on a stop: starts the agent anew in its pane"
                ),
                isEnabled: canStartNew,
                help: canStartNew ? nil : newConversationBlocker.map(StopResumeRules.newConversationHelp)
            ) {
                actions.startNewConversation(itemID, paneID)
            }
        case let .restore(entry):
            guard let restore else { return nil }
            // Destructive, as every action that rewrites the person's files
            // is; it only opens the strip that asks.
            return PopUpMenuItem(
                title: RestoreText.entryResource(turnNumber: entry.turnNumber),
                isEnabled: restore.canAsk(entry.turnID),
                isDestructive: true
            ) {
                restore.ask(entry.turnID)
            }
        }
    }

    /// "Mark as Viewed" or "Resume Same Conversation", with "⌘⏎" beside
    /// its title until the person has used the key a few times; short of
    /// room, without the key and in its short form, whole in its tooltip
    /// and VoiceOver label.
    private func primaryButton(_ action: PrimaryAction, actions: PrimaryActionHandler, shape: DecisionBarModel.Shape) -> some View {
        Button {
            actions.perform(action, paneID)
        } label: {
            PrimaryKeyHintLabel(
                title: Text(shape.usesShortLabels ? Self.shortName(action) : Self.name(action)),
                showsHint: keyHint.isShown && shape.showsKeyHint
            )
        }
        .buttonStyle(SupervisionPrimaryButtonStyle())
        // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
        .focusable(false)
        .help(Text(verbatim: ShortcutHelpText.make(name: Self.name(action), shortcut: "⌘⏎", locale: locale)))
        .accessibilityLabel(Text(Self.name(action)))
        .accessibilityHint(primaryHint(action))
    }

    /// The bar's ⋯: a stop's other moves, the unread turns' restore, and
    /// what a narrow row moves into it. Built when it opens, so its items
    /// show the keys as they are set then, and answer them only while it
    /// is open (`PopUpMenuButton`).
    private func moreMenu(_ sections: [[DecisionBarModel.MoreItem]]) -> some View {
        PopUpMenuButton(title: LocalizedStringResource(
            "More Actions",
            comment: "Tooltip and VoiceOver label of a ⋯ menu (the decision bar, the notification history, the menu bar item)"
        )) {
            moreEntries(sections)
        } label: {
            Image(systemName: "ellipsis")
                .font(.supervision(.row, weight: .medium))
                .frame(width: WeirLayout.Supervision.decisionBarMoreWidth, height: WeirLayout.Supervision.decisionBarMoreWidth)
                .contentShape(Rectangle())
        }
        // Out of the ⇥ order, as the bar's buttons are, so ⇥ stays the
        // terminal's for its TUI; a click and VoiceOver open it.
        .keyboardFocusable(false)
        .fixedSize()
    }

    /// The primary button's name.
    private static func name(_ action: PrimaryAction) -> LocalizedStringResource {
        switch action {
        case .markReviewed:
            LocalizedStringResource("Mark as Viewed")
        case .resume:
            LocalizedStringResource(
                "Resume Same Conversation",
                comment: "Decision bar on a stop: resumes the agent's conversation in its pane"
            )
        case .notifyAtReset:
            LocalizedStringResource(
                "Notify When It Resets",
                comment: "Decision bar on a usage limit stop: asks for a notification when the limit resets"
            )
        case .closeAllTabs:
            LocalizedStringResource("Close All Tabs")
        }
    }

    /// The primary button's name in a pane too narrow for `name`.
    private static func shortName(_ action: PrimaryAction) -> LocalizedStringResource {
        switch action {
        case .markReviewed:
            LocalizedStringResource("Mark as Viewed")
        case .resume:
            LocalizedStringResource(
                "Resume",
                comment: "Decision bar on a stop, short of room: Resume Same Conversation; the tooltip and VoiceOver say the whole"
            )
        case .notifyAtReset:
            LocalizedStringResource(
                "Notify Me",
                comment: "Decision bar on a usage limit stop, short of room: Notify When It Resets; the tooltip and VoiceOver say the whole"
            )
        case .closeAllTabs:
            LocalizedStringResource("Close All Tabs")
        }
    }

    private func primaryHint(_ action: PrimaryAction) -> Text {
        switch action {
        case .markReviewed:
            Text(
                "Marks this conversation’s turns as viewed, through the last one shown",
                comment: "Decision bar, VoiceOver: what Mark as Viewed does, to the conversation shown, through its turn shown"
            )
        case .resume:
            Text(
                "Restarts the agent in the same conversation, not a new one",
                comment: "Decision bar, VoiceOver: what Resume Same Conversation does"
            )
        case .notifyAtReset:
            Text(
                "A notification arrives when the limit resets; the conversation can then be resumed",
                comment: "Decision bar, VoiceOver: what Notify When It Resets does"
            )
        case .closeAllTabs:
            Text(
                "Closes every tab of this deleted worktree",
                comment: "Decision bar, VoiceOver: what Close All Tabs does on a worktree that was deleted"
            )
        }
    }

    /// The bar's ground: the soft fill of what waits on the person, and
    /// the sidebar's color at rest and after something was done.
    static func fill(_ tone: DecisionBarModel.Tone) -> Color {
        switch tone {
        case .waiting: SupervisionTokens.waitingFill.color
        case .stopped: SupervisionTokens.stoppedFill.color
        case .unread: SupervisionTokens.unreadFill.color
        case .done, .muted: SupervisionTokens.sidebar.color
        }
    }

    /// The rule along the bar's top, in the color of what waits.
    static func rule(_ tone: DecisionBarModel.Tone) -> Color {
        switch tone {
        case .waiting: SupervisionTokens.waiting.color
        case .stopped: SupervisionTokens.stopped.color
        case .unread: SupervisionTokens.unread.color
        case .done, .muted: SupervisionTokens.line.color
        }
    }
}

/// The decision bar's sentence and where to answer, side by side in the
/// width they are given and never wider. Where to answer is laid out
/// first, at the width it asks for, but leaves the sentence its floor; in
/// a pane too narrow for both, the floor shrinks to half the width, and
/// where to answer is offered the rest, which its short form, or a cut
/// one, fits.
struct DecisionBarWordsLayout: Layout {
    var spacing: CGFloat
    var sentenceFloor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews: subviews)
        let height = zip(subviews, widths)
            .map { subview, width in subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height }
            .max() ?? 0
        return CGSize(width: total(widths), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        HorizontalLayoutPlacement.place(
            subviews,
            widths: widths(for: bounds.width, subviews: subviews),
            in: bounds,
            spacing: spacing
        )
    }

    private func total(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
    }

    /// The sentence's width and where to answer's, in that order.
    private func widths(for width: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard subviews.count == 2, let width else { return ideal }
        let room = max(0, width - spacing)
        let floor = min(sentenceFloor, ideal[0], room / 2)
        let offered = room - floor
        let instruction = min(subviews[1].sizeThatFits(ProposedViewSize(width: offered, height: nil)).width, offered)
        return [min(ideal[0], room - instruction), instruction]
    }
}
