// ApprovalCardModel.swift
// Limpid — what the approval card offers and says for where its request stands.

import Foundation

/// What the approval card shows for one request: the actions it offers, the
/// line that says where the request stands, and whether the time left is
/// shown. Worked out from the ledger entry alone, so the table of states is
/// tested without drawing the card. Whether the card stays open at all is
/// the ledger's rule (`ApprovalLedger.Entry.holdsCardOpen`); this is nil
/// exactly when that rule closes it.
struct ApprovalCardModel: Equatable {
    enum Actions: Equatable {
        /// Answer in terminal and the decision buttons (Deny and Allow once,
        /// or the question form and Send Answer).
        case decide
        /// "Sending…" where the buttons were, so nothing is pressed twice.
        case sending
        /// Only the agent's own prompt takes the answer now (the request is
        /// with the TUI, or timed out); the card offers its pane, so it is
        /// never a dead end.
        case openPane
        /// Nothing left to do but close the card.
        case none
    }

    enum Status: Equatable {
        case none
        /// The person's decision did not reach the broker. They can try
        /// again or answer in the terminal.
        case sendFailed
        /// Handed to the provider's own prompt, which now takes the answer.
        case handedToTerminal
        /// The deadline passed; the answer goes in the terminal.
        case timedOut
        /// The person's decision lost to an answer given elsewhere.
        case alreadyAnswered
    }

    let actions: Actions
    let status: Status
    /// Only while Limpid can still answer. Once the request is with the TUI
    /// the provider's own prompt keeps its time, which Limpid cannot read.
    let showsTimeLeft: Bool

    /// `hasFailedDecision` is whether the failure on record is the person's
    /// own decision; a failed background hand-off leaves the request open
    /// without an error line, since nobody pressed anything.
    init?(entry: ApprovalLedger.Entry, hasFailedDecision: Bool) {
        guard entry.holdsCardOpen else { return nil }
        let showsTimeLeft = entry.state.isHeldByLimpid
        switch entry.state {
        case .held:
            self.init(actions: .decide, status: .none, showsTimeLeft: showsTimeLeft)
        case .sendFailed:
            self.init(
                actions: .decide,
                status: hasFailedDecision ? .sendFailed : .none,
                showsTimeLeft: showsTimeLeft
            )
        case .sending:
            self.init(actions: .sending, status: .none, showsTimeLeft: showsTimeLeft)
        case .handedToTerminal:
            self.init(actions: .openPane, status: .handedToTerminal, showsTimeLeft: showsTimeLeft)
        case .timedOut:
            // Past the deadline only the agent's prompt answers, which is
            // where every other place that lists the request leads.
            self.init(actions: .openPane, status: .timedOut, showsTimeLeft: showsTimeLeft)
        case .answered:
            // Kept open only to say the person's answer lost.
            self.init(actions: .none, status: .alreadyAnswered, showsTimeLeft: showsTimeLeft)
        case .withdrawn, .unknownResult:
            return nil
        }
    }

    /// The card for `approval` as `store` has it: none for a request the
    /// ledger does not hold, which has no card to open
    /// (`ApprovalPresentationStore.approvalForCard`). A failure line belongs
    /// only to the person's own last decision.
    @MainActor
    init?(approval: ApprovalPresentation, in store: ApprovalPresentationStore) {
        guard let entry = store.ledger.entry(for: approval) else { return nil }
        self.init(entry: entry, hasFailedDecision: store.lastFailureID == approval.id)
    }

    private init(actions: Actions, status: Status, showsTimeLeft: Bool) {
        self.actions = actions
        self.status = status
        self.showsTimeLeft = showsTimeLeft
    }

    /// The whole seconds left, rounded up, so "0:00" appears only once
    /// nothing is left; the drawn and the spoken time share it, so they
    /// never differ by a second.
    private static func wholeSeconds(_ remaining: Duration) -> Int {
        let (seconds, attoseconds) = remaining.components
        return Int(max(0, seconds + (attoseconds > 0 ? 1 : 0)))
    }

    /// The time left as the card writes it, "8:42".
    static func clockText(for remaining: Duration) -> String {
        let total = wholeSeconds(remaining)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "8:42 left", as the card and the decision bar say it.
    static func timeLeftText(for remaining: Duration, locale: Locale) -> String {
        LocalizedStringResource("\(clockText(for: remaining)) left").resolved(in: locale)
    }

    /// "8 minutes, 42 seconds left", as VoiceOver reads `timeLeftText`:
    /// VoiceOver reads "8:42" as a time of day. Under a minute only the
    /// seconds, so nothing left still says "0 seconds".
    static func spokenTimeLeftText(for remaining: Duration, locale: Locale) -> String {
        let total = wholeSeconds(remaining)
        let units: Set<Duration.UnitsFormatStyle.Unit> = total < 60 ? [.seconds] : [.minutes, .seconds]
        let words = Duration.seconds(total).formatted(
            .units(allowed: units, width: .wide, zeroValueUnits: .hide).locale(locale)
        )
        return LocalizedStringResource("\(words) left").resolved(in: locale)
    }

    /// The time left as it follows the reason on the card, "· 8:42 left",
    /// to be set after the reason with an ordinary space. The phrase is
    /// glued inside, so a line breaks only before it: a reason that wraps
    /// stays one sentence, and the clock, with its mark and its word, lands
    /// after the sentence's last line or whole on the line below, never
    /// between its lines and never cut from its mark.
    static func timeLeftAfterReason(for remaining: Duration, locale: Locale) -> String {
        let noBreakSpace = "\u{00A0}"
        return "·" + noBreakSpace + timeLeftText(for: remaining, locale: locale)
            .replacingOccurrences(of: " ", with: noBreakSpace)
    }
}

extension ApprovalCardModel {
    /// What the request is, above it on the card: a question, files to
    /// change, a command to run, or another tool's approval, as the
    /// decision bar says it.
    static func kindLabel(isQuestion: Bool, action: PromptApproval.Action) -> LocalizedStringResource {
        if isQuestion {
            return LocalizedStringResource("Question")
        }
        return switch action {
        case .fileChange:
            LocalizedStringResource("Wants to change files", comment: "Approval card: above a request to edit files")
        case .command:
            LocalizedStringResource("Wants to run a command", comment: "Approval card: above a command waiting to run")
        case .other:
            LocalizedStringResource(
                "Asking for approval",
                comment: "Approval card: above a request of a tool that neither edits files nor runs a command"
            )
        }
    }

    /// What the card's heading says after the agent's name: the
    /// request's session and its place, "{session} · {project}", said to be
    /// in another window as the Needs Attention list says it. `nil` for a
    /// request no pane is known for, which the list names by its agent
    /// alone: the heading already says that name.
    @MainActor
    static func place(of item: AttentionItem, in session: WorkspaceSession, projectsInOtherWindows: Set<UUID>, locale: Locale) -> String? {
        let names = NeedsAttentionListModel.names(of: item, in: session, locale: locale)
        guard let place = names.place else { return nil }
        let placed = NeedsAttentionListModel.place(
            place,
            isInAnotherWindow: NeedsAttentionListModel.isInAnotherWindow(item, projectsInOtherWindows: projectsInOtherWindows),
            locale: locale
        )
        return AgentStatusText.joined([names.title, placed], locale: locale)
    }
}

// MARK: - What the card shows and where its keyboard starts

extension ApprovalCardModel {
    /// The request's own words under its summary, `nil` when it has none
    /// or they only say the summary again.
    static func visibleDescription(_ description: String?, summary: String?) -> String? {
        guard let description = description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty,
              description != summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return description
    }

    /// How tall the tool input's well is: its lines at `lineHeight` with
    /// `verticalInsets` around them, at least one line, and no more than
    /// `maxHeight`, past which it scrolls.
    static func detailsHeight(of input: String, lineHeight: CGFloat, verticalInsets: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let lineCount = input.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(CGFloat(max(1, lineCount)) * lineHeight + verticalInsets, maxHeight)
    }

    /// Whether the question at `index` is the last of `count`, where Next
    /// becomes Send Answer.
    static func isLastQuestion(_ index: Int, of count: Int) -> Bool {
        index >= count - 1
    }

    /// Whether Send Answer can deliver `answer`: every question answered,
    /// within what a decision may carry.
    static func canSend(_ answer: ApprovalResolution?) -> Bool {
        answer?.fitsDecisionLimit ?? false
    }

    /// Whether the answer is too long to send, which the card says.
    static func answerExceedsLimit(_ answer: ApprovalResolution?) -> Bool {
        answer.map { !$0.fitsDecisionLimit } ?? false
    }

    /// Where keyboard focus lands when the card is asked for it: the action
    /// that commits nothing while the person can still decide, the pane once
    /// only the agent's prompt answers and there is one, and otherwise the
    /// close button.
    static func initialFocus(for actions: Actions, canOpenPane: Bool) -> ApprovalCardFocus {
        switch actions {
        case .decide: .secondaryAction
        case .openPane where canOpenPane: .primaryAction
        case .sending, .openPane, .none: .close
        }
    }
}

/// Every keyboard target inside the approval card. The card reports focus to
/// the store, which keeps a card the person moved into open as if they had
/// clicked its row, so each focusable control, including the question form's
/// fields, needs its own case.
enum ApprovalCardFocus: Hashable {
    case close
    case details
    /// Hands an approval to the TUI. On a question this is
    /// `secondaryAction`, its only action that commits nothing.
    case answerInTerminal
    /// Where focus starts while the person can decide: Deny on an
    /// approval, the safer of its two answers, or Answer in terminal on a
    /// question, which commits nothing.
    case secondaryAction
    /// Allow once, Next, Send Answer, or Open Pane.
    case primaryAction
    case questionTab(Int)
    case option(Int)
    case otherOption
    case answerField
}
