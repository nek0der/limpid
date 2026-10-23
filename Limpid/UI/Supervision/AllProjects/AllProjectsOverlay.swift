// AllProjectsOverlay.swift
// Limpid — the all projects sheet: every project's sessions as cards over the dimmed window.

import SwiftUI

/// Lays the all projects sheet over its window, dimming what is behind it,
/// while `ProjectWindowState.isAllProjectsPresented` is on. An overlay
/// rather than a system sheet, so a click outside it closes it, and the
/// approval card an "Answer…" opens comes up above it: answering
/// leaves the window, the pane, and the sheet where they are.
struct AllProjectsOverlay: View {
    let state: AppState
    @Environment(ProjectWindowState.self) private var window

    var body: some View {
        WindowOverlayHost(isPresented: window.isAllProjectsPresented, onDismiss: close) { proxy in
            let margins = LimpidLayout.Supervision.allProjectsMargins
            AllProjectsPanel(state: state, maxHeight: max(0, proxy.size.height - margins.top - margins.bottom))
                .padding(margins)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onWindowCommand(of: window) { command in
            guard command == .toggleAllProjects else { return false }
            if window.isAllProjectsPresented {
                AllProjectsActions.close(window, state: state)
            } else {
                // One layer at a time (`WindowLayer`): what is open over or
                // under the window goes as the sheet comes.
                window.openWindowOverlay(.allProjects, session: state.session)
            }
            return true
        }
        // And the sheet goes as another layer comes: the palette, a title
        // bar menu, the notification history, or the keyboard shortcuts
        // panel opened by its key.
        .onChange(of: window.isAnotherLayerOpen(than: .allProjects, session: state.session)) { _, isOpen in
            if isOpen, window.isAllProjectsPresented {
                window.isAllProjectsPresented = false
            }
        }
    }

    private func close() {
        AllProjectsActions.close(window, state: state)
    }
}

/// The sheet's face: the filter, the counts, and the cards by section.
private struct AllProjectsPanel: View {
    let state: AppState
    /// What the window leaves inside the sheet's margins.
    let maxHeight: CGFloat
    @Environment(ProjectWindowState.self) private var window
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(AttentionState.self) private var attention
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(PRStatusStore.self) private var prStatusStore
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var selection = AllProjectsSelection()
    /// Each card's last lines, read once while the sheet is open
    /// (`TerminalTailCache`).
    @State private var tails = TerminalTailCache()
    /// The grid's width as laid out, which sets how many cards a row holds
    /// (`AllProjectsSelection.columns`); 0 until it is first measured.
    @State private var gridWidth: CGFloat = 0
    /// Bumped by Return while the keyboard is on the selected card's
    /// button, which the card presses (it knows where its button is, for
    /// the approval card to point at).
    @State private var actionPress = 0
    @FocusState private var isFilterFocused: Bool

    private typealias Layout = LimpidLayout.Supervision

    private var model: AllProjectsModel {
        let cards = AllProjectsModel.cards(AllProjectsModel.Sources(
            session: state.session,
            window: window.id,
            registry: state.windowRegistry,
            queue: attentionQueue.queue,
            runtimes: attention.allRuntimes,
            approvals: approvals.ledger,
            pullRequest: { prStatusStore.info(for: $0) },
            gitFacts: { state.gitFacts.facts(for: $0) },
            locale: locale
        ))
        return AllProjectsModel(
            cards: cards,
            query: query,
            attentionCount: attentionQueue.queue.counts().total,
            hasProjects: !state.session.projects.isEmpty
        )
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: Layout.allProjectsSpacing) {
            header(model)
            ScrollViewReader { proxy in
                ScrollView {
                    content(model)
                        // Room for the selected card's ring, which stands
                        // outside it.
                        .padding(Layout.focusRingOutset)
                }
                // Taken back outside the scroll view, so the cards' edges
                // and the section headings line up with the title
                // while the ring still draws inside the scroll view.
                .padding(-Layout.focusRingOutset)
                .onChange(of: selection.selectedID) { _, id in
                    if let id {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .padding(Layout.allProjectsPadding)
        .frame(maxWidth: Layout.allProjectsMaxWidth)
        // As tall as its cards, up to what the window leaves; past that
        // the cards scroll under the heading.
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        // On the window's ground, so the cards read on the same ground as
        // the surfaces they stand for.
        .overlayPanelSurface()
        .background(WindowOverlayKeyMonitor(
            key: AllProjectsKeys.key(for:),
            onKey: { handle($0, self.model) },
            isPresented: { window.isAllProjectsPresented },
            isFieldFocused: { isFilterFocused },
            isCardFocused: { window.approvalCard.isFocused },
            reclaimKeyboard: { isFilterFocused = true }
        ))
        .onAppear {
            selection.reconcile(with: model.cards)
            KeyboardHandoff.afterResponderSettles { isFilterFocused = true }
        }
        // Back from the approval card an "Answer…" opened: the field takes
        // the keyboard again.
        .onChange(of: window.approvalCard.isOpen(in: approvals)) { _, isOpen in
            if !isOpen, window.isAllProjectsPresented {
                isFilterFocused = true
            }
        }
        .onChange(of: model.cards.map(\.id)) { _, _ in
            selection.reconcile(with: model.cards)
        }
        .onChange(of: model.cards.map { $0.action != nil }) { _, _ in
            selection.reconcile(with: model.cards)
        }
        // Typing goes to the filter, whatever Tab had drawn as focused.
        .onChange(of: query) { _, _ in
            selection.returnToFilter()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("All Projects"))
        .accessibilityAddTraits(.isModal)
    }

    /// One line: the title, the counts, the filter, and the close button.
    private func header(_ model: AllProjectsModel) -> some View {
        // Esc is the key monitor's (`WindowOverlayKeyMonitor`), which also
        // knows when the keyboard is in the approval card; the × takes no key.
        SupervisionSheetHeader(
            title: Text("All Projects"),
            onClose: { AllProjectsActions.close(window, state: state) },
            closeHelp: "Close (⎋)",
            isCloseFocused: selection.control == .close,
            leading: {
                if model.showsCounts {
                    Text(AllProjectsText.counts(attention: model.attentionCount, running: model.runningCount, locale: locale))
                        .font(.supervision(.label))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .monospacedDigit()
                        .lineLimit(1)
                        // The counts keep their words; in a narrow window the
                        // filter gives way first, down to its least width.
                        .layoutPriority(2)
                        .accessibilityLabel(Text(verbatim: AgentStatusText.spoken(
                            AllProjectsText.counts(attention: model.attentionCount, running: model.runningCount, locale: locale),
                            locale: locale
                        )))
                }
            },
            trailing: {
                filterField
                    // Ahead of the spacer, so it is full width whenever the
                    // line allows.
                    .layoutPriority(1)
            }
        )
    }

    private var filterField: some View {
        PanelSearchField(
            text: $query,
            prompt: Text("Filter by project, branch, or name"),
            isFocused: $isFilterFocused,
            showsRing: selection.control == .filter
        )
        // Narrower in a narrow window, so the counts beside the title stay
        // whole.
        .frame(minWidth: Layout.allProjectsFilterMinWidth, maxWidth: Layout.allProjectsFilterWidth)
        .help(Text(
            "← → move one card, ↑ ↓ one row. ⇥ goes to its button and Close, ⏎ opens, ⌘⏎ opens in a new window, ⎋ closes.",
            comment: "All projects sheet: the filter field's tooltip listing the sheet's keys"
        ))
    }

    /// The section's glyph (the same set everywhere), its name, and its
    /// number of cards, which reads lighter than the name.
    private func sectionHeading(_ group: AllProjectsModel.Group) -> some View {
        HStack(spacing: LimpidLayout.Supervision.spaceSnug) {
            SessionStateGlyph(glyph: group.section.glyph)
                .frame(width: Layout.stateGlyphSize, height: Layout.stateGlyphSize)
            Text(verbatim: AllProjectsText.sectionName(group.section, locale: locale))
                .font(.supervision(.row, weight: .semibold))
            Text(verbatim: "\(group.cards.count)")
                .font(.supervision(.row))
                .monospacedDigit()
        }
        .foregroundStyle(SupervisionTokens.muted.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AllProjectsText.section(group.section, count: group.cards.count, locale: locale)))
        .accessibilityAddTraits(.isHeader)
    }

    private func handle(_ key: AllProjectsKeys.Key, _ model: AllProjectsModel) {
        switch key {
        case .previous: selection.move(.previous, in: model.groups, columns: columns)
        case .next: selection.move(.next, in: model.groups, columns: columns)
        case .up: selection.move(.up, in: model.groups, columns: columns)
        case .down: selection.move(.down, in: model.groups, columns: columns)
        case .open where selection.control == .cardAction:
            actionPress += 1
        case .open where selection.control == .close:
            AllProjectsActions.close(window, state: state)
        case .open, .openInNewWindow:
            if let card = model.cards.first(where: { $0.id == selection.selectedID }) {
                AllProjectsActions.open(card, from: window, state: state, opensInNewWindow: key == .openInNewWindow)
            }
        case .close:
            AllProjectsActions.close(window, state: state)
        case .nextControl, .previousControl:
            selection.nextControl(backward: key == .previousControl, in: model.cards)
            isFilterFocused = true
        }
    }

    /// The cards a row holds at the grid's width, which the arrow keys
    /// step by as the grid draws them.
    private var columns: Int {
        AllProjectsSelection.columns(
            width: gridWidth,
            cardMinWidth: Layout.allProjectsCardMinWidth,
            spacing: Layout.allProjectsSpacing
        )
    }

    @ViewBuilder
    private func content(_ model: AllProjectsModel) -> some View {
        if let emptyState = model.emptyState {
            AllProjectsEmptyState(state: emptyState) { AllProjectsActions.close(window, state: state) }
        } else {
            VStack(alignment: .leading, spacing: Layout.allProjectsSectionGap) {
                ForEach(model.groups, id: \.section) { group in
                    VStack(alignment: .leading, spacing: Layout.allProjectsSpacing) {
                        sectionHeading(group)
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: Layout.allProjectsSpacing, alignment: .top),
                                count: columns
                            ),
                            alignment: .leading,
                            spacing: Layout.allProjectsSpacing
                        ) {
                            ForEach(group.cards) { card in
                                AllProjectsCardView(
                                    card: card,
                                    isSelected: card.id == selection.selectedID,
                                    isActionFocused: card.id == selection.selectedID && selection.control == .cardAction,
                                    actionPress: actionPress,
                                    state: state,
                                    tails: tails
                                )
                                .id(card.id)
                            }
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        }
    }
}

/// What the sheet shows in place of its cards. The sheet is as tall as
/// what it holds, so there is no room around the words to center them in,
/// as a panel's empty state is: the words get a room of their own, at
/// least `allProjectsEmptyMinHeight` tall and taller when larger text
/// needs it, and sit in its middle. Measuring the scroll view's height
/// instead would be the sheet measuring itself.
struct AllProjectsEmptyState: View {
    let state: EmptyState
    /// Closes the sheet before Open Folder… runs, so the new project shows
    /// in the window rather than under the sheet.
    var close: () -> Void = {}

    var body: some View {
        SupervisionEmptyState(state, size: .regular) {
            // With nothing added, the way to add something.
            if state == .noProjects {
                OpenFolderButton(beforeOpening: close)
            }
        }
        .frame(minHeight: LimpidLayout.Supervision.allProjectsEmptyMinHeight)
    }
}

/// One session: its state, name, and agent; its place and Git chips; what
/// it does now; and the last lines of its terminal. The glyph leads
/// and the agent's badge closes the top line, as on the session's sidebar
/// row, so the two read alike and VoiceOver says the state first.
/// Clicking it opens it; its one button answers or goes to the pane.
private struct AllProjectsCardView: View {
    let card: AllProjectsModel.Card
    let isSelected: Bool
    /// Tab put the keyboard on the card's button: Return presses it.
    let isActionFocused: Bool
    /// Return's presses of the focused button, counted by the sheet.
    let actionPress: Int
    let state: AppState
    let tails: TerminalTailCache
    @Environment(ProjectWindowState.self) private var window
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(PRStatusStore.self) private var prStatusStore
    @Environment(\.locale) private var locale
    /// Read once as the card appears (`SurfaceView.lastLines`).
    @State private var lastLines: [String] = []
    @State private var actionFrame: CGRect = .zero
    @State private var isHovering = false

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.allProjectsCardCornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            details
                .padding(Layout.allProjectsCardInsets)
            if let action = card.action {
                actionButton(action)
                    .padding(.horizontal, Layout.allProjectsCardInsets.leading)
                    .padding(.bottom, Layout.allProjectsCardInsets.bottom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(isAnswering ? SupervisionTokens.selection.color : SupervisionTokens.window.color))
        .overlay(shape.strokeBorder(isHovering ? SupervisionTokens.muted.color : SupervisionTokens.line.color, lineWidth: 1))
        // The arrow keys' card, in the accent as the sidebar's arrow-keys
        // row is: a ring outside the edge, so the edge keeps its hover and
        // the card its size.
        .supervisionFocusRing(isFocused: isSelected, cornerRadius: Layout.allProjectsCardCornerRadius)
        .contentShape(shape)
        .onHover { isHovering = $0 }
        .onClick { holdsCommand in AllProjectsActions.open(card, from: window, state: state, opensInNewWindow: holdsCommand) }
        .modifier(NewWindowHelp(isShown: card.opensInNewWindow))
        .onAppear {
            guard let pane = card.leadPaneID else { return }
            lastLines = tails.lines(of: pane) { state.registry.view(for: pane)?.lastLines() ?? [] }
        }
        .onChange(of: actionPress) { _, _ in
            if isActionFocused, let action = card.action {
                perform(action)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { AllProjectsActions.open(card, from: window, state: state) }
        // The card's own button, as an action of its own: combined into the
        // card, it would not be reached otherwise.
        .accessibilityActions {
            if let action = card.action {
                Button(action.title) { perform(action) }
            }
            // What ⌘-click does, which VoiceOver cannot do with a key held.
            if card.opensInNewWindow {
                Button {
                    AllProjectsActions.open(card, from: window, state: state, opensInNewWindow: true)
                } label: {
                    Text(NewWindowText.actionName)
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Layout.allProjectsCardSpacing) {
            HStack(spacing: LimpidLayout.Supervision.spaceS) {
                SessionStateGlyph(glyph: card.glyph)
                    .frame(width: Layout.stateGlyphSize, height: Layout.stateGlyphSize)
                Text(verbatim: card.name)
                    .font(.supervision(.label, weight: .bold))
                    .foregroundStyle(SupervisionTokens.text.color)
                    .lineLimit(1)
                    .supervisionTruncation(card.nameTruncation)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The pull request attached before the badge, as on the
                // session's row, whatever the session's state.
                // Combined into the card's label, it says the request's
                // state and its checks, which the chip does not.
                if card.pullRequest != nil, let mark = PRMarkPresentation.supervisionStyle(for: prStatusStore.info(for: card.id)) {
                    SessionPRMark(style: mark, size: LimpidLayout.Supervision.agentBadgeLargeHeight)
                }
                // The card's one mark of its agent, as on the session's row;
                // the card's label is made of what it shows, so the
                // badge says the agent's name aloud.
                SessionAgentBadge(
                    badge: card.badge,
                    text: card.badgeText,
                    size: .regular,
                    spokenName: card.badgeSpokenName
                )
            }
            place
            if !card.factText.isEmpty {
                Text(verbatim: card.factText)
                    .font(.supervision(.meta))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineLimit(1)
                    .supervisionTruncation(card.factTruncation)
            }
            if !lastLines.isEmpty {
                let tail = RoundedRectangle(cornerRadius: Layout.allProjectsTailCornerRadius, style: .continuous)
                Text(verbatim: lastLines.joined(separator: "\n"))
                    .font(.supervision(.detail, design: .monospaced))
                    // Muted rather than a dimmer terminal gray,
                    // which reads at 3.9:1 where text needs 4.5:1.
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineSpacing(3)
                    .lineLimit(TerminalTail.lineCount)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Layout.allProjectsTailInsets)
                    .background(tail.fill(SupervisionTokens.terminal.color))
                    .overlay(tail.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
            }
        }
    }

    /// This is the project's color and "project / branch" ("project /
    /// folder" for a card the person named) in the face branches have, then
    /// the Git chips, then which window shows the project. What does not fit
    /// wraps to the next line, at any width the sheet has, so nothing draws
    /// past the card and the place is cut only when it is longer than a
    /// whole line.
    private var place: some View {
        FlowLayout(spacing: LimpidLayout.Supervision.spaceSnug, lineSpacing: LimpidLayout.Supervision.spaceXS) {
            placeName
            placeFacts
        }
    }

    private var placeName: some View {
        HStack(spacing: LimpidLayout.Supervision.spaceSnug) {
            Circle()
                .fill(LimpidColor.paletteColor(card.paletteIndex))
                .frame(width: Layout.allProjectsPlaceDotSize, height: Layout.allProjectsPlaceDotSize)
                .accessibilityHidden(true)
            Text(verbatim: AllProjectsText.place(project: card.projectName, branch: card.branch, folder: card.folder))
                .font(.supervisionCode(beside: .meta))
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
                // Only a place too long for the card's whole line is cut,
                // and in the middle, so both the project and the branch's
                // end still show.
                .supervisionTruncation(.branch)
                .accessibilityLabel(Text(verbatim: AllProjectsText.spokenPlace(
                    project: card.projectName,
                    branch: card.branch,
                    folder: card.folder,
                    locale: locale
                )))
        }
    }

    @ViewBuilder private var placeFacts: some View {
        ForEach(Array(card.chips.enumerated()), id: \.offset) { _, chip in
            SupervisionChip(text: Text(verbatim: chip.text))
        }
        if let note = card.windowNote {
            Text(verbatim: AllProjectsText.windowNote(note, locale: locale))
                .font(.supervision(.detail))
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
        }
    }

    /// The card whose request the approval card is showing, from its
    /// Answer…: it keeps the selected fill while the card is up.
    private var isAnswering: Bool {
        guard case let .answer(key) = card.action else { return false }
        return window.approvalCard.isPresenting(key, in: approvals)
    }

    private func perform(_ action: AllProjectsModel.Action) {
        switch action {
        case let .answer(key):
            guard let request = approvals.ledger.entries[key]?.presentation else { return }
            window.approvalCard.present(request, from: approvals, openedFrom: actionFrame)
        case .openPane:
            AllProjectsActions.open(card, from: window, state: state)
        }
    }

    private func actionButton(_ action: AllProjectsModel.Action) -> some View {
        Button { perform(action) } label: { Text(action.title) }
            .buttonStyle(.supervisionSecondary)
            .supervisionFocusRing(isFocused: isActionFocused, cornerRadius: Layout.buttonCornerRadius)
            // The control Return presses, said as the ring shows it.
            .accessibilityAddTraits(isActionFocused ? .isSelected : [])
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actionFrame = $0 }
    }
}

/// The last lines of each card's pane, read once while the sheet is open.
/// A card read its terminal's whole screen each time it came into view,
/// and the grid brings a card back into view each time it is scrolled to,
/// so scrolling the sheet read the terminals over and over on the main
/// thread. A reference held by the sheet, so a card the grid made again
/// finds what was read.
@MainActor
final class TerminalTailCache {
    private var lines: [UUID: [String]] = [:]

    func lines(of pane: UUID, read: () -> [String]) -> [String] {
        if let known = lines[pane] {
            return known
        }
        let read = read()
        lines[pane] = read
        return read
    }
}
