// OpenTabsMenu.swift
// Limpid — Open Tabs: the session's tabs in a searchable list that hangs from the pane strip's leading button.

import SwiftUI

/// Every tab of the session the strip heads, as Chrome's tab search lists
/// a window's tabs: a search field, the terminal tabs in the strip's order,
/// then the review's tab under a rule. A row says who runs in the tab and
/// in what state, which a tab cut short in a crowded strip no longer does.
/// The keyboard starts in the search field, with the shown tab selected:
/// ↑↓ move, Return switches to the selected tab, and Escape closes the list
/// (`TitleBarMenuHost`). A row's × closes its tab, as the strip's does, and
/// the list stays open on what is left.
struct OpenTabsMenu: View {
    let container: ContainerID
    /// Closes the list and hands the keyboard back to the terminal.
    let dismiss: () -> Void
    /// The tallest the list may be under its button.
    let maxHeight: CGFloat
    @Environment(WorkspaceSession.self) private var session
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(AttentionState.self) private var attention
    @Environment(TmuxPanePresence.self) private var tmuxPresence
    @Environment(ProjectWindowState.self) private var window
    @Environment(SettingsStore.self) private var settings
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.agentProjection) private var agentProjection
    @Environment(\.paneVisibilityReporter) private var paneVisibility
    @Environment(\.reviewTabHandler) private var reviewTabHandler
    @Environment(\.popoverSurface.ground) private var ground
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var selectedID: OpenTabsModel.RowID?
    @FocusState private var isSearchFocused: Bool
    /// The panel's measured height and its list's: the rest is their
    /// difference, and the list gets what `maxHeight` leaves after it
    /// (`FloatingPanelPlacement.scrollingBodyHeight`).
    @State private var panelHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        let model = model(query: query)
        let rows = model.rows
        VStack(alignment: .leading, spacing: Layout.popoverRowSpacing) {
            searchField(rows: rows)
            DropdownHeading(Text("Open Tabs"))
            if rows.isEmpty {
                SupervisionEmptyState(query.isEmpty ? .noTabs : .noResults, size: .compact)
                    .padding(.top, Layout.spaceS)
            } else {
                list(model)
            }
        }
        .padding(Layout.dropdownPadding)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        .onAppear {
            selectedID = rows.first(where: \.isCurrent)?.id ?? rows.first?.id
            KeyboardHandoff.afterResponderSettles { isSearchFocused = true }
        }
        // A new search starts on its best match, as Chrome's does: kept on
        // the shown tab, Return would only close the list.
        .onChange(of: query) {
            selectedID = rows.first?.id
        }
        .onChange(of: rows.map(\.id)) { previous, ids in
            // The selected tab closed, here or elsewhere: the selection
            // moves to the row that took its place, as the strip's moves to
            // its neighbor. A list that had no rows starts at the top.
            if !ids.contains(where: { $0 == selectedID }) {
                let index = selectedID.flatMap { previous.firstIndex(of: $0) } ?? 0
                selectedID = ids.isEmpty ? nil : ids[min(index, ids.count - 1)]
            }
            // Closing the shown tab mounts the next one's terminal, which
            // takes the keyboard as it mounts; the list is still open, so
            // its field takes it back. Not while the list is closing: the
            // window moved on, and the keyboard is the new session's.
            KeyboardHandoff.afterResponderSettles {
                if isOpen {
                    isSearchFocused = true
                }
            }
        }
    }

    private func searchField(rows: [OpenTabsModel.Row]) -> some View {
        TextField("", text: $query, prompt: Text("Search Tabs").foregroundStyle(SupervisionTokens.muted.color))
            .textFieldStyle(.plain)
            .font(.supervision(.icon))
            .searchFieldFace(.dropdown(well: ground.well.color), showsRing: isSearchFocused)
            .accessibilityLabel(Text("Search Tabs"))
            .focused($isSearchFocused)
            .onSubmit {
                if let row = rows.first(where: { $0.id == selectedID }) {
                    activate(row)
                }
            }
            .onKeyPress(.downArrow) {
                move(forward: true, in: rows)
                return .handled
            }
            .onKeyPress(.upArrow) {
                move(forward: false, in: rows)
                return .handled
            }
            // Further in than the rows, so its focus ring keeps clear of
            // the panel's edge.
            .padding(Layout.popoverFieldMargins)
    }

    private func list(_ model: OpenTabsModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Layout.popoverRowSpacing) {
                    ForEach(model.terminalRows) { row(for: $0) }
                    if let reviewRow = model.reviewRow {
                        // The review is not a terminal tab: it stands apart,
                        // as it stands last in the strip.
                        if !model.terminalRows.isEmpty {
                            DropdownSeparator()
                        }
                        row(for: reviewRow)
                    }
                }
            }
            .frame(maxHeight: FloatingPanelPlacement.scrollingBodyHeight(
                preferred: 360,
                cap: maxHeight,
                chrome: panelHeight - listHeight
            ))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(for row: OpenTabsModel.Row) -> some View {
        OpenTabsRow(
            row: row,
            isSelected: row.id == selectedID,
            checkColor: SupervisionTokens.accentIcon(settings.settings.appearance.accentColor),
            onActivate: { activate(row) },
            onClose: { close(row) }
        )
        .id(row.id)
    }

    /// Whether the window still shows this list: it may be fading out.
    private var isOpen: Bool {
        window.titleBarMenu?.menu == .openTabs(container) && !window.isTitleBarMenuLeftBehind
    }

    private func model(query: String) -> OpenTabsModel {
        let strip = PaneStripModel(
            container: container,
            session: session,
            window: window.id,
            queue: attentionQueue.queue,
            runtimes: attention.allRuntimes,
            mountedTmuxPaneIDs: tmuxPresence.paneIDs,
            reviewTab: window.reviewStripTab(in: container, session: session)
        )
        return OpenTabsModel(
            strip: strip,
            reviewTitle: window.review.map { ReviewTabText.tabName($0.selection, locale: locale) },
            query: query,
            locale: locale
        )
    }

    private func move(forward: Bool, in rows: [OpenTabsModel.Row]) {
        let index = rows.firstIndex { $0.id == selectedID }
        guard let next = ListKeyboardStep.index(from: index, count: rows.count, forward: forward) else { return }
        selectedID = rows[next].id
    }

    /// Shows the row's tab as a click on it in the strip does: a terminal
    /// tab picked while the review is in front puts the review behind it.
    private func activate(_ row: OpenTabsModel.Row) {
        dismiss()
        switch row.id {
        case let .terminal(tabID):
            ReviewTabActions.hide(
                window: window,
                showing: tabID,
                session: session,
                registry: registry,
                paneVisibility: paneVisibility
            )
        case .review:
            ReviewTabActions.show(window: window)
        }
    }

    /// Closes the row's tab as the strip's × does, its confirmation
    /// included; the list stays open on the tabs that are left.
    private func close(_ row: OpenTabsModel.Row) {
        switch row.id {
        case let .terminal(tabID):
            TabActions.closeTab(
                session,
                registry: registry,
                tabID: tabID,
                source: .mouse,
                attention: attention,
                agentProjection: agentProjection,
                in: window.id
            )
        case .review:
            reviewTabHandler?.close()
        }
    }
}

/// One tab in Open Tabs: a check on the tab the window shows, in the
/// column the project dropdown keeps for it, its badge (the review's symbol
/// for the review), its title with the strip's marks, the line saying who
/// runs in it, and a × that closes it. The line
/// takes the state's color when the tab waits on the person or stopped, so
/// the tabs that need them stand out down the list.
private struct OpenTabsRow: View {
    let row: OpenTabsModel.Row
    let isSelected: Bool
    let checkColor: Color
    let onActivate: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        HStack(spacing: Layout.dropdownRowSpacing) {
            Button(action: onActivate) {
                HStack(spacing: Layout.dropdownRowSpacing) {
                    // First, as the project dropdown's rows carry it.
                    DropdownCheckMark(isChecked: row.isCurrent, color: checkColor)
                    badge
                    VStack(alignment: .leading, spacing: Layout.spaceHairline) {
                        HStack(spacing: Layout.spaceSnug) {
                            Text(verbatim: row.title)
                                .font(.supervision(.label, weight: .medium))
                                .foregroundStyle(SupervisionTokens.text.color)
                                .lineLimit(1)
                                .supervisionTruncation(row.item?.titleTruncation ?? .name)
                            if let item = row.item {
                                PaneStripTabMarks(item: item)
                            }
                        }
                        Text(verbatim: row.detail)
                            .font(.supervision(.meta))
                            .foregroundStyle(detailColor)
                            .lineLimit(1)
                            .supervisionTruncation(.name)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: row.spokenLabel))
            .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
            // VoiceOver moves through the rows without selecting them, so
            // the × of a row it is on can be hidden; the row closes its tab
            // itself, as the strip's tab does.
            .accessibilityActions {
                Button(row.item == nil ? "Close Review" : "Close Tab", action: onClose)
            }
            closeButton
        }
        .padding(Layout.dropdownRowInsets)
        .dropdownRowBackground(isSelected: isSelected, isHovering: isHovering)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder private var badge: some View {
        if let item = row.item {
            PaneStripTabBadge(agent: item.agent, state: item.stateGlyph)
        } else {
            // The review's own symbol, as its tab in the strip draws it, in
            // a badge's box so the titles line up.
            Image(systemName: ReviewPresentation.symbol)
                .font(.supervision(.row, weight: .medium))
                .foregroundStyle(SupervisionTokens.muted.color)
                .frame(width: Layout.agentBadgeWidth, height: Layout.agentBadgeLargeHeight)
                .accessibilityHidden(true)
        }
    }

    /// Shown on the selected row and the one under the pointer, as the
    /// strip shows its tabs' ×; hidden, it is neither pressed, reached by
    /// the keyboard, nor read.
    private var closeButton: some View {
        let isShown = isSelected || isHovering
        return DismissGlyphButton(label: row.item == nil ? "Close Review" : "Close Tab", action: onClose)
            .opacity(isShown ? 1 : 0)
            .disabled(!isShown)
            .accessibilityHidden(!isShown)
    }

    private var detailColor: Color {
        switch row.item?.stateGlyph {
        case .needsAnswer?, .needsApproval?, .needsResponse?: SupervisionTokens.waitingText.color
        case .stopped?: SupervisionTokens.stoppedText.color
        default: SupervisionTokens.muted.color
        }
    }
}
