// MenuBarModel.swift
// Limpid — the menu bar extra: the Needs Attention rows, and what each lets the person do from there.

import Foundation

/// The menu bar extra's items: the Needs Attention list's rows, in its
/// order, each with what the menu lets the person do without opening
/// Limpid. The row itself, and its button on the right (Answer…), are
/// the list's; what is added here sits under the row. It is a value, so
/// which buttons each item offers is tested without a menu.
struct MenuBarModel: Equatable {
    /// What the menu knows of a request beyond the list's row.
    struct Request: Equatable {
        /// The shell command, shown whole over Allow Once and Deny; `nil`
        /// for a question and for a tool that runs no command.
        let command: String?
        let isQuestion: Bool
        let offer: MenuBarApprovalRule.Offer
        /// The last decision could not be sent: the menu offers it again
        /// and says why.
        var hasFailedToSend = false
    }

    /// Why the menu does not answer a request itself, or what became of it.
    enum Note: Equatable {
        case highImpact
        case tooLong
        case notShownWhole
        case sending
        case sendFailed
        case answered
        case handedToTerminal
        case timedOut
        /// A usage limit stop whose reset will be notified.
        case resetNoticeRequested
    }

    /// A button under a row: what settles the item where the menu is,
    /// leaving Limpid as it is. Going to Limpid is the row itself,
    /// or the list's button beside it.
    enum Action: Equatable {
        case allowOnce
        case deny
        case resume
        /// "Notify When It Resets", on a usage limit stop while its limit
        /// holds, in place of resuming.
        case notifyAtReset

        /// Whether it is the item's primary button, the one filled blue:
        /// allowing, resuming, or asking to hear of the reset.
        var isPrimary: Bool {
            self != .deny
        }

        /// Whether it refuses, drawn in the stop's red rather than filled.
        var isRefusal: Bool {
            self == .deny
        }
    }

    /// What a row says it does for VoiceOver: going to the pane in Limpid,
    /// where a request is then handed to the agent's own prompt, or
    /// opening the card of a request that has no pane.
    enum OpenHint: Equatable {
        case goesToPane
        case goesToPaneToAnswerInTerminal
        case opensCard
    }

    struct Item: Identifiable, Equatable {
        let row: NeedsAttentionListModel.Row
        /// The request behind an approval or a question; `nil` for a stop,
        /// an unread turn, or a request the ledger no longer holds.
        let request: Request?
        let note: Note?
        /// Under the row, left to right; the primary, when there is one,
        /// first.
        let actions: [Action]
        let openHint: OpenHint

        var id: AttentionItemID {
            row.id
        }

        /// The command shown whole over Allow Once and Deny, so what is
        /// allowed is read where it is allowed; `nil` without them, where
        /// the row's own line names the command.
        var command: String? {
            actions.contains(.allowOnce) ? request?.command : nil
        }

        /// The buttons Tab goes through, in order: those under the row, left
        /// to right, then the list's button beside it.
        var controls: [Control] {
            actions.map(Control.inPlace) + (row.action.map { [Control.rowAction($0)] } ?? [])
        }

        var keyboardActionCount: Int {
            controls.count
        }

        /// What the keyboard is on at `index` in Tab's order
        /// (`NeedsAttentionListSelection.actionIndex`): the row itself for
        /// `nil`, else one of `controls`; `nil` for a place the item no
        /// longer has.
        func control(at index: Int?) -> Control? {
            guard let index else { return .row }
            return controls.indices.contains(index) ? controls[index] : nil
        }
    }

    /// What a press on an item reaches: the row, which goes to its pane; a
    /// button under it, which acts in place; or the list's button beside
    /// it (Answer…).
    enum Control: Equatable {
        case row
        case inPlace(Action)
        case rowAction(NeedsAttentionListModel.RowAction)
    }

    let items: [Item]

    /// `request` gives what the menu knows of an approval's or a question's
    /// request, `canResume` whether a stop resumes in the same conversation,
    /// `resetNotice` what a usage limit stop offers while its limit holds,
    /// and `isInPane` whether an item has a pane to go to.
    init(
        rows: [NeedsAttentionListModel.Row],
        request: (AttentionItemID) -> Request?,
        canResume: (AttentionItemID) -> Bool,
        resetNotice: (AttentionItemID) -> UsageLimitResetNotice?,
        isInPane: (AttentionItemID) -> Bool = { _ in true }
    ) {
        items = rows.map { row in
            let request = request(row.id)
            let notice = row.state == .stopped ? resetNotice(row.id) : nil
            let resumes = row.state == .stopped && canResume(row.id)
            return Item(
                row: row,
                request: request,
                note: request.flatMap(Self.note) ?? (notice == .requested ? .resetNoticeRequested : nil),
                actions: Self.actions(row: row, request: request, resumes: resumes, notice: notice),
                openHint: Self.openHint(row: row, isInPane: isInPane(row.id))
            )
        }
    }

    private static func note(_ request: Request) -> Note? {
        switch request.offer {
        case .highImpact: .highImpact
        case .tooLong: .tooLong
        case .notShownWhole: .notShownWhole
        case .sending: .sending
        case .answered: .answered
        case .handedToTerminal: .handedToTerminal
        case .timedOut: .timedOut
        case .allowOrDeny, .notACommand, .answerInLimpid: request.hasFailedToSend ? .sendFailed : nil
        case .openPane: nil
        }
    }

    /// The buttons under a row. Nothing here answers a question, marks a
    /// turn viewed, or takes changes back; an answer on its way offers
    /// nothing. Allow Once and Deny need both the menu's rule and the
    /// list's: the list offers Answer… only while the broker still takes a
    /// decision (`AttentionItem.canAnswerInLimpid`), and the menu does not
    /// decide what the list would not let the card decide.
    private static func actions(
        row: NeedsAttentionListModel.Row,
        request: Request?,
        resumes: Bool,
        notice: UsageLimitResetNotice?
    ) -> [Action] {
        // While a usage limit holds, resuming meets it again.
        switch notice {
        case .offered: return [.notifyAtReset]
        case .requested: return []
        case nil: break
        }
        if let request {
            guard request.offer == .allowOrDeny, case .answer = row.action else { return [] }
            return [.allowOnce, .deny]
        }
        return resumes ? [.resume] : []
    }

    /// Going to an approval's or a question's pane shows it, which hands
    /// the request to the agent's own prompt; one with no pane opens
    /// its card instead.
    private static func openHint(row: NeedsAttentionListModel.Row, isInPane: Bool) -> OpenHint {
        switch row.state {
        case .approval, .question: isInPane ? .goesToPaneToAnswerInTerminal : .opensCard
        // A prompt wait is always in its pane; it has no card to open.
        case .response: isInPane ? .goesToPaneToAnswerInTerminal : .goesToPane
        case .stopped, .unread: .goesToPane
        }
    }
}

extension MenuBarModel.Request {
    /// What the menu knows of `request` in `state`.
    init(_ request: ApprovalPresentation, state: ApprovalRequestState) {
        let command = request.isQuestion ? nil : request.command
        var hasFailedToSend = false
        if case .sendFailed = state {
            hasFailedToSend = true
        }
        self.init(
            command: command,
            isQuestion: request.isQuestion,
            offer: MenuBarApprovalRule.offer(
                isQuestion: request.isQuestion,
                supportsNativeAnswer: request.supportsNativeAnswer,
                command: command,
                state: state
            ),
            hasFailedToSend: hasFailedToSend
        )
    }
}

/// Which appearance the menu bar extra's window takes: the system's,
/// as the menu bar is the system's chrome and the menus beside it follow
/// the OS Appearance setting, not Limpid's own Appearance preference,
/// which `NSApp.appearance` pins every window of the app to. The system's
/// choice is `SystemAppearance`'s reading of the global defaults.
enum MenuBarAppearance {
    static let interfaceStyleKey = SystemAppearance.interfaceStyleKey
    static let themeChangedNotification = SystemAppearance.themeChangedNotification

    /// Whether `interfaceStyle`, the defaults' value, is the dark appearance.
    static func isDark(interfaceStyle: String?) -> Bool {
        SystemAppearance.isDark(interfaceStyle: interfaceStyle)
    }

    /// Whether the system is in its dark appearance now, as `defaults`
    /// (the standard ones, which see the global domain) say.
    static func isSystemDark(defaults: UserDefaults = .standard) -> Bool {
        SystemAppearance.isSystemDark(defaults: defaults)
    }
}
