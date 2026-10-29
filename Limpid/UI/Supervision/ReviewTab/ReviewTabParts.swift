// ReviewTabParts.swift
// Limpid — the review tab's own controls: the turns that ended since, and the band at its foot.

import SwiftUI

/// "T8 finished" with "Add to Scope", in the review tab's top edge while
/// turns have ended after the fixed range since it was fixed.
/// Nothing is added until the person asks. A box in the unread blue's soft
/// fill and edge: the turns it names are unread ones.
struct ReviewTabFollowingBar: View {
    let tab: ReviewTabState
    let handler: ReviewTabHandler
    @Environment(\.locale) private var locale

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        let turns = ReviewTabModel.followingTurns(tab, handler.context(tab))
        if let text = ReviewTabText.followingTurns(turns, locale: locale) {
            // Carried on only from the range on screen, once it has been
            // read; a range still loading has nothing to carry.
            let isReady = handler.isShowingItsScope(tab)
            let shape = RoundedRectangle(cornerRadius: Layout.reviewFollowingCornerRadius, style: .continuous)
            HStack(spacing: LimpidLayout.Supervision.spaceS) {
                Text(verbatim: text)
                    .font(.supervision(.row, weight: .semibold))
                    .foregroundStyle(SupervisionTokens.text.color)
                    .lineLimit(1)
                Spacer(minLength: LimpidLayout.Supervision.spaceS)
                Button("Add to Scope") {
                    handler.addFollowingTurns()
                }
                .buttonStyle(.supervisionSecondary(size: .compact))
                .disabled(!isReady)
                .accessibilityLabel(Text("Add to Scope"))
            }
            .padding(Layout.reviewFollowingInsets)
            .background(shape.fill(SupervisionTokens.unreadFill.color))
            .overlay(shape.strokeBorder(SupervisionTokens.unread.color, lineWidth: 1))
            // Its fill is opaque, so its button fills opaquely too.
            .environment(\.supervisionSurfaceOpacity, 1)
            .padding(Layout.reviewFollowingMargins)
            .accessibilityElement(children: .contain)
        }
    }
}

/// The band's insert controls, as the review that owns them draws them:
/// the destination it polls, how many comments an insert carries, and the
/// insert itself.
struct ReviewTabInsert {
    let destination: ReviewDestination?
    let isResolving: Bool
    /// What runs in front of each pane the destination menu offers, by
    /// pane, as the review's poll last read it; a pane not read yet has
    /// none.
    var choiceForegrounds: [UUID: String] = [:]
    let count: Int
    let canInsert: Bool
    /// While an insert runs, "Mark as Viewed" waits: it closes the tab,
    /// and the insert would then end with no review to report to.
    let isInserting: Bool
    let onInsert: () -> Void
}

/// The band at the foot of the review tab, in the 32pt row the decision bar
/// has in an agent's pane: how far the files have been read, where
/// comments go and "Insert n Comments", "Mark as Viewed", and Close. "Mark
/// as Viewed" moves the one viewed line, to the end of the fixed range; the
/// files' checkboxes only mark reading, so even with all of them checked
/// the band only makes the button the primary one.
struct ReviewTabBand: View {
    let tab: ReviewTabState
    let reviewSession: ReviewSession?
    let handler: ReviewTabHandler
    /// `nil` where there is no review to insert from: a tab with no
    /// comparison.
    var insert: ReviewTabInsert?
    @Environment(\.locale) private var locale

    var body: some View {
        // Read off the review only once it shows the tab's range: while one
        // loads, its files and the button would describe different ranges.
        let isReady = handler.isShowingItsScope(tab)
        let action = isReady ? ReviewTabModel.markViewed(tab, handler.context(tab)) : nil
        let status = ReviewTabModel.bandStatus(
            tab.selection,
            fileIDs: isReady ? reviewSession?.files.map(\.id) ?? [] : [],
            viewed: Set(reviewSession.map { Array($0.viewed.keys) } ?? [])
        )
        let isInserting = insert?.isInserting == true
        let shown = tab.isShown && !isInserting
            ? action.map { ReviewBandGate.Shown(opening: tab.opening, selection: tab.selection, action: $0) }
            : nil
        let tone = ReviewTabModel.bandTone(tab, handler.context(tab))
        // Nothing about the files until the review has read them: an empty
        // list while it loads is not "No changes". A tab with no comparison
        // says so at once.
        let shownStatus = isReady || tab.scope == nil ? status : nil
        SupervisionFootBar(fill: ReviewTabBandRow.fill(tone), rule: ReviewTabBandRow.rule(tone)) {
            ReviewTabBandRow(
                tone: tone,
                status: shownStatus,
                markViewed: action.map {
                    ReviewTabBandRow.MarkViewed(action: $0, isPrimary: status == .allFilesViewed, isEnabled: !isInserting)
                },
                insert: insertRow,
                onMarkViewed: handler.markViewed,
                onClose: handler.close
            )
        }
        // Opaque, so its buttons fill opaquely too.
        .environment(\.supervisionSurfaceOpacity, 1)
        // ⌘⏎ waits for the button it would press to have been on screen;
        // behind a terminal tab there is no button on screen.
        .onChange(of: shown, initial: true) { _, shown in
            handler.noteBandShown(shown, tab.opening)
        }
        .onDisappear {
            handler.noteBandShown(nil, tab.opening)
        }
        // Read as the "Review" region, as the decision bar it stands in for
        // is one, with the files' status: in the narrower fits the
        // row shows it in no words of its own.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Review"))
        .accessibilityValue(Text(verbatim: shownStatus.map { ReviewTabText.band($0, locale: locale) } ?? ""))
    }

    /// Only with comments to send.
    private var insertRow: ReviewTabBandRow.Insert? {
        guard let insert, insert.count > 0 else { return nil }
        let agents = handler.conversations(tab)
        let choices = handler.destinations(tab, agents)
        return ReviewTabBandRow.Insert(
            count: insert.count,
            canInsert: insert.canInsert,
            destination: ReviewTabDestinationMenu(
                choices: choices,
                selectedPaneID: tab.destinationPaneID,
                status: ReviewTabModel.destinationStatus(tab, .init(
                    isPaneOpen: handler.isDestinationOpen(tab),
                    destination: insert.destination,
                    isResolving: insert.isResolving,
                    choices: choices,
                    agents: agents
                )),
                foregrounds: insert.choiceForegrounds,
                onChoose: handler.chooseDestination
            ),
            onInsert: insert.onInsert,
            isInserting: insert.isInserting
        )
    }
}

/// The band's row: its tag, how far the files were read, and its buttons,
/// from values alone. Apart from `ReviewTabBand`, which reads the review and
/// the window's handler, so the row can be drawn, and measured against the
/// foot bar, without either.
///
/// The row takes the first of its layouts (`Fit`) that fits the session's
/// column. Its buttons keep their words at any width, so a row with one
/// layout asked the column for more than it had, and the review above it,
/// which is as wide as its widest child, was laid out past the column's
/// edge with its right side cut off.
struct ReviewTabBandRow: View {
    /// How much of the row is drawn, widest first. The order is the order
    /// things give way in: each fit drops only what is said somewhere else
    /// as well, and keeps every control on the one 32pt line. The widths
    /// each needs with the bar's insets at the band's widest (no pane to
    /// write to, for each reason the band gives, 12 comments, "Mark as
    /// Viewed") are, in English, 905, 790, 708, 560, 525, and 398pt, and in
    /// Japanese 851, 731, 645, 531, 495, and 342pt
    /// (`SupervisionFootBarTests`). The two widest full rows are a tab
    /// writing nowhere with Insert's count, which from `fullFitWidth`
    /// (840pt) shows `withoutStatus`; any other row shows `full` there
    /// (831pt in English).
    enum Fit: Int, CaseIterable, Comparable {
        /// Everything: the files' status, "Review Destination" before
        /// the menu, what runs at the destination, the ⌘⏎ hint, and Close
        /// in words.
        case full
        /// Without the status, which the tag carries as its tooltip and
        /// the band as its VoiceOver value.
        case withoutStatus
        /// Also without "Review Destination", which the menu keeps as its
        /// VoiceOver label. It outlives the status: it says what the menu
        /// beside it is for.
        case withoutHeading
        /// Also without the ⌘⏎ hint, which "Mark as Viewed"'s tooltip
        /// names, and with the destination and what runs there as one
        /// string held to `reviewDestinationMaxWidth`, cut in its middle so
        /// what runs there, at its end, stays, and whole in the tooltip.
        /// Before Close turns into the ×, so a 1280×800 window's column
        /// keeps Close in words.
        case compact
        /// Also Close as the ×, as the review's tab has it.
        case closeAsGlyph
        /// Also without the tag, whose name the tab and the band's
        /// VoiceOver region say, and whose status the file list's "n / m
        /// Viewed" does; and "Insert" without its count, which its
        /// VoiceOver label keeps. Fits `LimpidLayout.reviewMinWidth`, and
        /// narrower still the destination's string is cut first, so Close
        /// stays in the column.
        case narrowest

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var showsTag: Bool {
            self < .narrowest
        }

        var showsStatus: Bool {
            self == .full
        }

        var showsDestinationHeading: Bool {
            self < .withoutHeading
        }

        var showsKeyHint: Bool {
            self < .compact
        }

        /// The destination and what runs there as one capped string.
        var capsDestination: Bool {
            self >= .compact
        }

        var closesWithGlyph: Bool {
            self >= .closeAsGlyph
        }

        var showsInsertCount: Bool {
            self < .narrowest
        }

        /// Where the tab writes nowhere, whose pane closed, before
        /// "Choose Destination…" (`ReviewTabDestinationMenu`).
        var showsClosedReason: Bool {
            self < .narrowest
        }
    }

    /// "Mark as Viewed" as the band offers it.
    struct MarkViewed {
        let action: ReviewTabModel.MarkViewed
        /// Filled once every file is checked; bordered until then.
        let isPrimary: Bool
        /// Off while an insert runs: the press closes the tab, and the
        /// insert would then end with no review to report to.
        let isEnabled: Bool
    }

    /// "Review Destination" and "Insert n Comments".
    struct Insert {
        let count: Int
        let canInsert: Bool
        let destination: ReviewTabDestinationMenu
        let onInsert: () -> Void
        /// Whether an insert is waiting on its paste, which holds Close
        /// as it holds "Mark as Viewed" (`ReviewTabInsert.isInserting`).
        var isInserting = false
    }

    let tone: DecisionBarModel.Tone
    /// `nil` while the review reads the files, when the band says nothing
    /// about them.
    let status: ReviewTabModel.BandStatus?
    let markViewed: MarkViewed?
    let insert: Insert?
    let onMarkViewed: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    var body: some View {
        // Each fit measured at its ideal width, so the one chosen draws
        // every word it has whole; which words go first is the fits' order.
        ViewThatFits(in: .horizontal) {
            ForEach(Fit.allCases, id: \.self) { fit in
                Line(row: self, fit: fit)
            }
        }
    }

    /// The band's ground: the blue of unread turns while they are what it
    /// is on, the sidebar's color otherwise.
    static func fill(_ tone: DecisionBarModel.Tone) -> Color {
        tone == .unread ? SupervisionTokens.unreadFill.color : SupervisionTokens.sidebar.color
    }

    static func rule(_ tone: DecisionBarModel.Tone) -> Color {
        (tone == .unread ? SupervisionTokens.unread : SupervisionTokens.line).color
    }

    /// The row in one of its fits.
    struct Line: View {
        let row: ReviewTabBandRow
        let fit: Fit
        @Environment(\.locale) private var locale
        @Environment(PrimaryKeyHint.self) private var keyHint

        /// Whether the row offers "Choose Destination…" with the reason
        /// before it, where the tab writes nowhere. That pair is wider than
        /// a destination's name, and room is made for it from what it makes
        /// idle or what is said elsewhere: from `withoutHeading` on (a
        /// heading this row does not show), Insert, which cannot be pressed
        /// until a pane is chosen, keeps its count only in its VoiceOver
        /// label; and from `compact` on the tag goes, as it does in
        /// `narrowest`, so a 1280×800 window's column still says whose pane
        /// closed.
        private var isChoosing: Bool {
            row.insert?.destination.status.offersChoice == true
        }

        private var showsTag: Bool {
            fit.showsTag && !(isChoosing && fit >= .compact)
        }

        private var showsInsertCount: Bool {
            fit.showsInsertCount && !(isChoosing && fit >= .withoutHeading)
        }

        var body: some View {
            let status = row.status.map { ReviewTabText.band($0, locale: locale) }
            HStack(spacing: LimpidLayout.Supervision.decisionBarSpacing) {
                if showsTag {
                    tag(status: fit.showsStatus ? nil : status)
                }
                if fit.showsStatus, let status {
                    Text(verbatim: status)
                        .font(.supervision(.body, weight: row.status == .noChanges ? .regular : .semibold))
                        .foregroundStyle(SupervisionTokens.text.color)
                        .lineLimit(1)
                }
                // Below the destination, which in turn gives way before the
                // buttons: in a column narrower than the narrowest fit, the
                // destination's string is cut rather than Close pushed out.
                Spacer(minLength: LimpidLayout.Supervision.spaceS)
                    .layoutPriority(-2)
                if let insert = row.insert {
                    insert.destination.laidOut(fit)
                        .layoutPriority(-1)
                    insertButton(insert)
                }
                if let markViewed = row.markViewed {
                    markViewedButton(markViewed)
                        .disabled(!markViewed.isEnabled)
                }
                // Off while an insert waits on its paste, as Insert and
                // "Mark as Viewed" are: the tab closes to the pane once the
                // paste lands, or stays if it is refused, and not before.
                Group {
                    if fit.closesWithGlyph {
                        DismissGlyphButton(label: "Close Review") {
                            row.onClose()
                        }
                    } else {
                        Button("Close") {
                            row.onClose()
                        }
                        .buttonStyle(.supervisionSecondary(tone: .ghost))
                        .accessibilityLabel(Text("Close Review"))
                    }
                }
                .disabled(row.insert?.isInserting == true)
            }
        }

        /// The tag, with the files' status as its tooltip where the row
        /// has no room to say it. VoiceOver reads the status off the band
        /// (`ReviewTabBand`), which is there in every fit.
        @ViewBuilder
        private func tag(status: String?) -> some View {
            let tag = DecisionBarTag(text: ReviewTabText.bandTag(locale: locale), tone: row.tone)
                .accessibilityAddTraits(.isHeader)
            if let status {
                tag.help(Text(verbatim: status))
            } else {
                tag
            }
        }

        private func insertButton(_ insert: Insert) -> some View {
            Button(action: insert.onInsert) {
                if showsInsertCount {
                    Text("Insert \(insert.count) Comments")
                } else {
                    Text("Insert", comment: "Review bar: Insert n Comments, short of room; VoiceOver still reads the count")
                }
            }
            .buttonStyle(.supervisionSecondary)
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
            .disabled(!insert.canInsert)
            .help(ReviewTabText.insertHelp(insert.destination.status, locale: locale).map { Text(verbatim: $0) } ?? Text(verbatim: ""))
            .accessibilityLabel(Text("Insert \(insert.count) Comments"))
        }

        @ViewBuilder
        private func markViewedButton(_ markViewed: MarkViewed) -> some View {
            let button = Button {
                row.onMarkViewed()
            } label: {
                // The key until it has been used a few times, as on the
                // decision bar.
                PrimaryKeyHintLabel(title: Text("Mark as Viewed"), showsHint: keyHint.isShown && fit.showsKeyHint)
            }
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
            .help(Text(verbatim: ReviewTabText.markViewedHelp(markViewed.action, locale: locale)))
            if markViewed.isPrimary {
                button.buttonStyle(SupervisionPrimaryButtonStyle())
            } else {
                button.buttonStyle(.supervisionSecondary)
            }
        }
    }
}

/// "Review Destination" in the band: the pane comments go to, with what
/// runs there now, and a menu of the session's other panes, shells included.
/// The menu writes the tab's destination, which every later insert
/// and the close after it follow. Both stay on screen in every fit of the
/// band: where the text goes and what is in front there are read before
/// Insert is pressed. Where the tab writes nowhere and there are panes to
/// pick (`DestinationStatus.offersChoice`), it says whose pane closed and
/// draws the same menu as a bordered "Choose Destination…", since a name
/// with a small chevron did not read as something to press.
struct ReviewTabDestinationMenu: View {
    let choices: [ReviewTabModel.DestinationChoice]
    /// The tab's destination (`ReviewTabState.destinationPaneID`).
    let selectedPaneID: UUID?
    let status: ReviewTabModel.DestinationStatus
    /// What runs in front of each pane offered (`ReviewTabInsert
    /// .choiceForegrounds`).
    var foregrounds: [UUID: String] = [:]
    let onChoose: @MainActor (UUID) -> Void
    /// The band's fit it is drawn in (`ReviewTabBandRow.Fit`).
    private(set) var fit = ReviewTabBandRow.Fit.full
    @Environment(\.locale) private var locale

    private typealias Layout = LimpidLayout.Supervision

    /// The menu as the band draws it in `fit`.
    func laidOut(_ fit: ReviewTabBandRow.Fit) -> Self {
        var menu = self
        menu.fit = fit
        return menu
    }

    var body: some View {
        if status.offersChoice {
            choosing
        } else {
            named
        }
    }

    /// "Claude #1's pane is closed" and "Choose Destination…". No "Review
    /// Destination" before them: the button names what it chooses. Short
    /// of room the reason is cut first, whole in its tooltip; the narrowest
    /// fit keeps only the button, whose VoiceOver value and tooltip say it.
    @ViewBuilder
    private var choosing: some View {
        let reason = ReviewTabText.destinationName(status, locale: locale)
        let title = ReviewTabText.chooseDestination(locale: locale)
        HStack(spacing: LimpidLayout.Supervision.spaceS) {
            if fit.showsClosedReason, status.hasClosedReason {
                let text = Text(verbatim: reason)
                    .font(.supervision(.row))
                    .foregroundStyle(SupervisionTokens.text.color)
                    .lineLimit(1)
                    .supervisionTruncation(.sentence)
                    // The menu says it, as its value.
                    .accessibilityHidden(true)
                if fit.capsDestination {
                    WidthCap(max: Layout.reviewDestinationMaxWidth) {
                        text
                    }
                    .help(Text(verbatim: reason))
                } else {
                    text.fixedSize()
                }
            }
            let menu = Menu {
                items
            } label: {
                Text(verbatim: title)
                    .lineLimit(1)
            }
            .menuStyle(.button)
            // Alone in the narrowest fit, and what is cut in a column
            // narrower still, as the destination's name is, so Close stays
            // in the column.
            .buttonStyle(SupervisionSecondaryButtonStyle(truncatesTitle: !fit.showsClosedReason))
            .menuIndicator(.hidden)
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
            .help(Text(verbatim: reason))
            // Named by the words on it, so VoiceOver and Voice Control say
            // what is seen; the reason is its value, and "Review
            // Destination", the name the menu has where it holds a pane,
            // reaches it too.
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(Text(verbatim: reason))
            .accessibilityInputLabels([Text(verbatim: title), Text("Review Destination")])
            if fit.showsClosedReason {
                menu.fixedSize()
            } else {
                menu
            }
        }
    }

    /// The pane comments go to, with what runs there.
    @ViewBuilder
    private var named: some View {
        // The menu's own name for it, so two panes of one name read apart
        // here as they do in the menu, and a conversation's pane by the
        // name its chip has.
        let chosen = choices.first { $0.destination.paneID == selectedPaneID && status.isReady }
        let name = chosen.map { ReviewTabText.destinationLabel($0, locale: locale) }
            ?? ReviewTabText.destinationName(status, locale: locale)
        // VoiceOver names a titled conversation with its agent, as the
        // menu's items do.
        let spokenName = chosen.map { ReviewTabText.destinationLabel($0, form: .spoken, locale: locale) } ?? name
        let foreground = ReviewTabText.destinationForeground(status)
        HStack(spacing: LimpidLayout.Supervision.spaceXS) {
            if fit.showsDestinationHeading {
                Text("Review Destination")
                    .font(.supervision(.row))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineLimit(1)
                    // The menu says it too, as its label.
                    .accessibilityHidden(true)
            }
            if fit.capsDestination {
                // One string, so a cut in its middle keeps what runs there,
                // at its end, in view. Not fixed: in a column narrower than
                // the narrowest fit it is what gets cut.
                let whole = AgentStatusText.joined([name, foreground].compactMap(\.self), locale: locale)
                WidthCap(max: Layout.reviewDestinationMaxWidth) {
                    menu(
                        label: Self.joined(name: name, foreground: foreground),
                        value: AgentStatusText.spokenList([spokenName, foreground].compactMap(\.self), locale: locale)
                    )
                }
                .help(Text(verbatim: whole))
            } else {
                menu(label: Text(verbatim: name).font(.supervision(.row, weight: .medium)), value: spokenName)
                    .fixedSize()
                if let foreground {
                    Text(verbatim: "·")
                        .font(.supervision(.row))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .accessibilityHidden(true)
                    Text(verbatim: foreground)
                        .font(.supervision(.caption).monospaced())
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The panes offered, each with what runs in front there: for the one
    /// chosen, what the band shows beside it; for the rest, the poll's last
    /// reading.
    private var items: some View {
        ForEach(choices, id: \.destination.paneID) { choice in
            let paneID = choice.destination.paneID
            let isChosen = paneID == selectedPaneID
            let foreground: String? = if isChosen, case let .ready(destination) = status {
                destination.foreground
            } else {
                foregrounds[paneID]
            }
            let title = ReviewTabText.destinationChoice(choice, foreground: foreground, form: .menu, locale: locale)
            let whole = ReviewTabText.destinationChoice(choice, foreground: foreground, locale: locale)
            let spoken = ReviewTabText.destinationChoice(choice, foreground: foreground, form: .spoken, locale: locale)
            // The menu's own checkmark, as the scope menu's (`ReviewTabScopeMenu`).
            Toggle(isOn: Binding(get: { isChosen }, set: { _ in onChoose(paneID) })) {
                Text(verbatim: title)
            }
            .help(Text(verbatim: whole))
            .accessibilityLabel(Text(verbatim: spoken))
        }
    }

    private func menu(label: Text, value: String) -> some View {
        Menu {
            items
        } label: {
            HStack(spacing: LimpidLayout.Supervision.spaceXS) {
                label
                    // Its own mode, not one of the rule's kinds: the one
                    // string holds the pane's name and what runs there
                    // ("Claude #1 · npm test"), and its middle goes so both
                    // stay.
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.supervision(.disclosure, weight: .semibold))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("Review Destination"))
        .accessibilityValue(Text(verbatim: value))
    }

    /// "Claude Code · claude", each part in the look it has apart.
    private static func joined(name: String, foreground: String?) -> Text {
        var text = AttributedString(name)
        text.font = .supervision(.row, weight: .medium)
        if let foreground {
            var separator = AttributedString(" · ")
            separator.font = .supervision(.row)
            separator.foregroundColor = SupervisionTokens.muted.color
            var process = AttributedString(foreground)
            process.font = .supervision(.caption).monospaced()
            process.foregroundColor = SupervisionTokens.muted.color
            text += separator
            text += process
        }
        return Text(text)
    }
}

/// ⌘⏎ with the file list focused (Full Keyboard Access) does what it does
/// in the diff: the band's "Mark as Viewed", through its gate.
struct ReviewTabPrimaryKey: ViewModifier {
    @Environment(\.reviewTabHandler) private var handler

    func body(content: Content) -> some View {
        content.onKeyPress(.return, phases: .down) { press in
            // Caps Lock and the keypad aside, as any ⌘⏎ check reads it.
            guard press.modifiers.chord == .command, let handler else { return .ignored }
            handler.primaryKey()
            return .handled
        }
    }
}
