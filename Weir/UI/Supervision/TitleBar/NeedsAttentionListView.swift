// NeedsAttentionListView.swift
// Weir — the Needs Attention list: every item, in arrival order, across projects.

import SwiftUI

/// The list the title bar's pill opens. Pressed open, no row is
/// selected; ⌃⌘J opens it on the first. ↑↓ move; the pointer selects the
/// row it is over; Return opens the item's pane; Tab moves onto the row's
/// Answer…, when it has one, and back; and Escape closes the list
/// (`TitleBarMenuHost`). Opening a row's
/// pane closes the list first, through `choose`; Answer… opens the card
/// over the list, which stays until the card is done with. Next
/// Action in the heading closes it and does what ⌘J does.
struct NeedsAttentionListView: View {
    /// The most the rows may take before they scroll: what fits below the
    /// pill inside the window.
    let maxListHeight: CGFloat
    /// Where the keyboard starts: on no row when the pill was pressed, on
    /// the first when ⌃⌘J opened the list (`TitleBarMenuRequest`).
    let opening: NeedsAttentionListSelection.Opening
    /// Closes the list, then runs the action.
    let choose: (@escaping () -> Void) -> Void
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(WorkspaceSession.self) private var session
    @Environment(WindowRegistry.self) private var registry
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(ProjectWindowState.self) private var window
    @Environment(SettingsStore.self) private var settings
    @Environment(\.locale) private var locale
    @State private var selection = NeedsAttentionListSelection(rows: [])
    /// Counts ↑ and ↓, so only the keys scroll the selected row into view:
    /// a row the pointer selected is under it already, and scrolling
    /// would put another row there, which the pointer would then select.
    @State private var keyboardMoves = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let model = NeedsAttentionListModel(
            queue: attentionQueue.queue,
            session: session,
            approvals: approvals,
            projectsInOtherWindows: registry.projectsShown(besides: window.id, in: session),
            windowProjectID: .some(window.selection.shownProjectID),
            locale: locale
        )
        VStack(alignment: .leading, spacing: 0) {
            heading(model)
            if model.rows.isEmpty {
                NeedsAttentionCapacityWarning(isNearCapacity: approvals.isNearCapacity)
                SupervisionEmptyState(.nothingNeedsAttention, size: .compact)
            } else {
                rows(model.rows)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        // The list holds the keyboard, so VoiceOver reads the list: its
        // heading when it opens, and the row the keys are on as they move.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: AgentStatusText.spoken(model.heading.resolved(in: locale), locale: locale)))
        .accessibilityValue(Text(verbatim: selection.spokenRow(in: model.rows)))
        .onKeyPress(.downArrow) {
            selection.move(forward: true, in: model.rows)
            keyboardMoves += 1
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection.move(forward: false, in: model.rows)
            keyboardMoves += 1
            return .handled
        }
        .onKeyPress(keys: [.tab, .backTab]) { press in
            let row = model.rows.first { $0.id == selection.rowID }
            selection.nextAction(count: row.map(NeedsAttentionListSelection.listActionCount) ?? 0, backward: press.isBackTab)
            return .handled
        }
        .onKeyPress(.return) {
            guard let row = model.rows.first(where: { $0.id == selection.rowID }) else { return .ignored }
            if selection.isOnAction, let action = row.action {
                perform(action, on: row)
            } else {
                open(row, .returnKey)
            }
            return .handled
        }
        .onAppear {
            selection = NeedsAttentionListSelection(rows: model.rows, opening: opening)
            KeyboardHandoff.afterResponderSettles { isFocused = true }
        }
        .onChange(of: model.rows) { previous, current in
            selection.reconcile(previous: previous, current: current)
        }
    }

    /// The count over the rows, and Next Action at its end while there is
    /// something to go to.
    private func heading(_ model: NeedsAttentionListModel) -> some View {
        NeedsAttentionHeading(model.heading) {
            if !model.rows.isEmpty {
                Button("Next Action") {
                    choose { [attentionQueue, window] in
                        attentionQueue.jump(forward: true, in: window)
                    }
                }
                .buttonStyle(.supervisionSecondary)
                .help(Text(verbatim: ShortcutHelpText.make(
                    name: "Next Action",
                    shortcut: settings.settings.keyboard.shortcut(for: .nextAttention)?.displayString,
                    locale: locale
                )))
            }
        }
    }

    private func rows(_ rows: [NeedsAttentionListModel.Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The wait time steps once a minute ("just now", then 1m,
                // 2m…), so a finer tick would only redraw the same text.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    // Inside the scroll, above the first row: the list's
                    // height is what fits below its control, so a line
                    // outside it would push the last row off the window.
                    VStack(spacing: 0) {
                        NeedsAttentionCapacityWarning(isNearCapacity: approvals.isNearCapacity)
                        LazyVStack(spacing: WeirLayout.Supervision.needsAttentionRowSpacing) {
                            ForEach(rows) { row in
                                NeedsAttentionRowView(
                                    row: row,
                                    now: context.date,
                                    isSelected: row.id == selection.rowID,
                                    isActionSelected: row.id == selection.rowID && selection.isOnAction,
                                    onOpen: { open(row, $0) },
                                    onAction: { row.action.map { perform($0, on: row) } },
                                    // The pointer selects, as in the menu
                                    // bar's list: one row is lit, the one
                                    // Return opens, never a keyboard row
                                    // and a hovered one at once.
                                    onHover: { isHovering in
                                        if isHovering {
                                            selection.select(row.id)
                                        } else {
                                            selection.deselect(row.id)
                                        }
                                    }
                                )
                                .id(row.id)
                            }
                        }
                        .padding(WeirLayout.Supervision.popoverInset)
                    }
                }
            }
            // Every item stays reachable: the list scrolls rather than
            // stopping at a count, within what fits in the window.
            .frame(maxHeight: maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: keyboardMoves) { _, _ in
                guard let id = selection.rowID else { return }
                proxy.scrollTo(id)
            }
        }
    }

    /// Choosing the row itself goes to its pane; a request whose pane is
    /// in sight is handed to the terminal there. The window's ⌘J
    /// continues from it. How it was chosen (`opening`) decides whether an
    /// item of another project opens in a new window: ⌘-click does, and
    /// VoiceOver's Open in New Window; Return never does.
    private func open(_ row: NeedsAttentionListModel.Row, _ opening: NeedsAttentionListOpening) {
        guard let item = attentionQueue.queue.items.first(where: { $0.id == row.id }) else { return }
        selection.select(row.id)
        choose { [attentionQueue, window] in
            attentionQueue.focus(item, from: window, opensInNewWindow: opening.opensInNewWindow)
        }
    }

    private func perform(_ action: NeedsAttentionListModel.RowAction, on row: NeedsAttentionListModel.Row) {
        switch action {
        case let .answer(key):
            // Answering moves neither the window nor the pane: the card
            // opens where it is and takes the keyboard, over the list.
            guard let presentation = approvals.ledger.entries[key]?.presentation else { return }
            let pill = window.needsAttentionAnchor
            window.approvalCard.present(presentation, from: approvals, openedFrom: pill == .zero ? nil : pill)
        }
    }
}
