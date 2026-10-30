// NotificationHistoryView.swift
// Limpid — the floating panel of every notification, by day and source, opened from the rail or ⇧⌘N.

import AppKit
import SwiftUI

@MainActor
func toggleNotificationHistory(
    _ presentation: NotificationHistoryPresentation,
    session: WorkspaceSession
) {
    CommandPaletteActions.closeCommandPalette(session)
    presentation.isPresented.toggle()
}

/// Window-level host that gives notification history the same detached,
/// arrowless placement as the command palette while keeping it anchored
/// to this window's control beside the rail.
struct NotificationHistoryOverlay: View {
    let state: AppState
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if window.notificationHistory.isPresented,
               let anchor = window.historyAnchor,
               anchor.frame.width > 0
            {
                GeometryReader { overlayGeo in
                    let overlayOrigin = overlayGeo.frame(in: .global).origin
                    let panel = NotificationHistoryPlacement.frame(
                        anchor: anchor.frame.offsetBy(dx: -overlayOrigin.x, dy: -overlayOrigin.y),
                        columnTop: anchor.columnTop - overlayOrigin.y,
                        container: overlayGeo.size,
                        metrics: .init(
                            width: NotificationHistoryView.width,
                            preferredHeight: state.historyStore.entries.isEmpty
                                ? NotificationHistoryView.emptyHeight
                                : NotificationHistoryView.populatedHeight,
                            inset: 12,
                            gap: 6
                        )
                    )

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            window.notificationHistory.isPresented = false
                        }
                    NotificationHistoryView(
                        height: panel.height,
                        canOpen: { target in
                            state.canOpenNotificationTarget(target)
                        },
                        // The same route a macOS notification tap follows:
                        // the request's card while it can be answered there,
                        // else the agent's pane where it runs now.
                        onOpen: { target in
                            state.openNotificationTarget(target)
                        }
                    )
                    .position(x: panel.midX, y: panel.midY)
                }
                .ignoresSafeArea()
                .modalTransition(.floatingPanel, reduceMotion: reduceMotion)
                .zIndex(100)
            }
        }
        .animation(
            ModalMotion.floatingPanel.animation(reduceMotion: reduceMotion),
            value: window.notificationHistory.isPresented
        )
        .onChange(of: state.session.commandPaletteState?.windowID == window.id) { _, isPresented in
            if isPresented {
                window.notificationHistory.isPresented = false
            }
        }
        // The plan usage panel opens from the same rail, and one layer is
        // open at a time.
        .onChange(of: window.planUsage.isPresented) { _, isPresented in
            if isPresented {
                window.notificationHistory.isPresented = false
            }
        }
        // The list held the keyboard while it was open; whatever it closed
        // for (Escape, a row, a click elsewhere), the terminal gets it back
        // unless what the row opened took it.
        .onChange(of: window.notificationHistory.isPresented) { wasPresented, isPresented in
            if wasPresented, !isPresented {
                window.historyExpandedSources = []
                // At once, as the title bar's dropdowns do: anything but a
                // terminal holding the keys is the list, still fading out.
                KeyboardHandoff.returnToFocusedPane(
                    in: window.id,
                    session: state.session,
                    registry: registry,
                    keeper: .terminal,
                    timing: .now
                )
            }
        }
    }
}

struct NotificationHistoryView: View {
    /// As wide as the window's other lists.
    static let width = LimpidLayout.Supervision.notificationHistoryWidth

    /// Both leave room for the foot: the notice, there only when a banner
    /// may not reach the person. The empty height keeps that room though
    /// the list is one line: the notice is known only after the panel
    /// opens (`loadsNotificationDeliveryStatus`), and a panel sized
    /// without it would grow under the pointer when it comes.
    static let populatedHeight: CGFloat = 520
    static let emptyHeight: CGFloat = 320

    @Environment(NotificationHistoryStore.self) private var store
    @Environment(NotificationHistoryPresentation.self) private var presentation
    @Environment(AttentionState.self) private var attention
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(WorkspaceSession.self) private var session
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    /// Resolved by the overlay from the space beside its control.
    /// The populated panel is scrollable, so shrinking it is preferable
    /// to clipping its destructive controls below a short window.
    let height: CGFloat
    /// Whether a row still leads anywhere (`NotificationRoute`); a source
    /// whose newest row does not is drawn as closed.
    let canOpen: (NotificationTarget) -> Bool
    /// Opens what a row points at (`NotificationRoute`), returning false
    /// when nothing it named is left to open.
    let onOpen: (NotificationTarget) -> Bool

    /// Gates the destructive clear behind a confirmation. The trash
    /// button drops the whole history — up to 500 rows — with no undo and
    /// no surviving on-disk copy to recover from, so a single misclick
    /// must not be enough.
    @State private var isConfirmingClear = false

    /// Origin filter for the list. Session-scoped on purpose — a filter
    /// that survives a relaunch is one the user forgets is on, and the
    /// panel would then read as having lost notifications.
    @State private var filter: Filter = .all

    @State private var selection = ListKeyboardSelection<NotificationHistoryList.ItemID>(ids: [])
    @FocusState private var isListFocused: Bool

    /// Whether a banner will reach the person, for the notice under the
    /// rows; read by the panel, which is always there.
    @State private var deliveryStatus: NotificationDeliveryStatus?

    var body: some View {
        content
            .frame(width: Self.width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .floatingPanelSurface(cornerRadius: 16)
            // The confirmation takes the panel's place with the panel's own
            // fade, Reduce Motion or not.
            .animation(LimpidMotion.floatingPanel, value: isConfirmingClear)
            // Unlike `Popover`, an ordinary overlay does not enter AppKit's
            // modal responder chain; without this monitor the focused
            // terminal under the panel would receive Escape's byte.
            .background {
                WindowKeyDownMonitor { event, _ in
                    guard Self.isDismissKey(event) else { return false }
                    if isConfirmingClear {
                        isConfirmingClear = false
                    } else {
                        presentation.isPresented = false
                    }
                    return true
                }
            }
    }

    /// Returns whether `event` is Escape with neither ⌘, ⌃, nor ⌥ held, which
    /// closes the confirmation, or else the panel. Shift is let through, as a held Shift is no
    /// reason for Escape to fall to the terminal.
    static func isDismissKey(_ event: NSEvent) -> Bool {
        event.namedKey == .escape && event.modifierFlags.isDisjoint(with: [.command, .control, .option])
    }

    // MARK: - Content

    /// The panel: the name and what acts on the whole list over the
    /// filters, then each day's sources, a heading over each one's rows in
    /// two lines, edged as one group with a rule between each row, in the
    /// supervision colors.
    /// Nothing sits under the rows unless a banner may not reach the person.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            SupervisionHistoryHeading(
                canMarkAllRead: store.unreadCount > 0 && !isConfirmingClear,
                canClear: !store.entries.isEmpty && !isConfirmingClear,
                onMarkAllRead: {
                    NotificationReadSync.markAllRead(
                        historyStore: store,
                        attention: attention,
                        session: session
                    )
                },
                onClear: { isConfirmingClear = true }
            )
            .padding(LimpidLayout.Supervision.notificationHeadingInsets)
            if isConfirmingClear {
                SupervisionHistoryClearConfirmation(
                    onCancel: { isConfirmingClear = false },
                    onClear: {
                        store.clearAll()
                        isConfirmingClear = false
                    }
                )
            } else if store.entries.isEmpty {
                SupervisionEmptyState(.noNotifications, size: .regular)
            } else {
                filters
                // Ticks every minute, so "now" becomes "1 min. ago" while
                // the history stays open, as the sidebar's times do.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let model = listModel(now: context.date)
                    if model.items.isEmpty {
                        SupervisionEmptyState(filteredEmptyState, size: .regular)
                    } else {
                        list(model, now: context.date)
                    }
                }
            }
            Spacer(minLength: 0)
            SupervisionHistoryDeliveryNotice(status: deliveryStatus)
        }
        .padding(LimpidLayout.Supervision.notificationHistoryPadding)
        .loadsNotificationDeliveryStatus($deliveryStatus)
    }

    /// The filters, Unread last with a dot while anything is unread; how
    /// many is its tooltip and what VoiceOver reads.
    private var filters: some View {
        // The window's one segmented control (`SupervisionSegmentedPicker`),
        // so the filters take ← → and mark the choice as the others do.
        SupervisionSegmentedPicker(
            Text("Notification filter"),
            selection: $filter,
            options: [
                .init(.all, Text("All")),
                .init(.agents, Text("Agents")),
                .init(.commands, Text("Commands")),
                // How many is on Unread itself, where the dot is.
                .init(
                    .unread,
                    Text("Unread"),
                    help: store.unreadCount > 0 ? Text("\(store.unreadCount) unread") : Text("Unread"),
                    accessibilityValue: store.unreadCount > 0 ? Text("\(store.unreadCount) unread") : nil,
                    // A dot, not a count: a count beside "Needs attention
                    // 0" reads as that many to act on.
                    hasDot: store.unreadCount > 0
                )
            ],
            isCompact: true
        )
        .padding(LimpidLayout.Supervision.notificationFilterRowInsets)
    }

    // MARK: - List

    /// The list as the model builds it, with what it asks of the app: the
    /// runtimes looked up from one table and the requests from the ledger,
    /// whether a source's pane opens, and where it is, each asked once per
    /// source.
    private func listModel(now: Date) -> NotificationHistoryList {
        NotificationHistoryList(
            entries: store.entries.filter(filter.accepts),
            now: now,
            calendar: .current,
            expanded: window.historyExpandedSources,
            liveStatus: attention.liveStatusLookup(requests: approvals.ledger),
            canOpen: { canOpen(NotificationTarget($0)) },
            place: { NotificationHistoryRowText.place(of: $0, in: session, locale: locale) },
            projectsInOtherWindows: windowRegistry.projectsShown(besides: window.id, in: session)
        )
    }

    private func list(_ model: NotificationHistoryList, now: Date) -> some View {
        let selectable = model.selectableIDs
        return ScrollViewReader { proxy in
            ScrollView {
                // No spacing: a source's lines meet, so its group's edge runs
                // unbroken; the headings keep their own room.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.items) { item in
                        itemView(item, now: now)
                            .id(item.id)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            .onKeyPress(.downArrow) {
                selection.move(forward: true, in: selectable)
                return .handled
            }
            .onKeyPress(.upArrow) {
                selection.move(forward: false, in: selectable)
                return .handled
            }
            .onKeyPress(.return) {
                guard let item = model.items.first(where: { $0.id == selection.id }) else { return .ignored }
                activate(item)
                return .handled
            }
            // ⌘⌫ deletes the selected row, as Finder moves a file away.
            .onKeyPress(.delete, phases: .down) { press in
                guard press.modifiers == .command,
                      case let .row(selected)? = model.items.first(where: { $0.id == selection.id })
                else { return .ignored }
                store.delete(selected.entry.id)
                return .handled
            }
            .onAppear {
                selection = ListKeyboardSelection(ids: selectable)
                KeyboardHandoff.afterResponderSettles { isListFocused = true }
            }
            .onChange(of: selectable) { previous, current in
                selection.reconcile(previous: previous, current: current)
            }
            .onChange(of: selection.id) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: NotificationHistoryList.Item, now: Date) -> some View {
        switch item {
        case let .day(day, isFirst):
            SupervisionHistoryDayHeading(title: day.title, isFirst: isFirst)
        case let .heading(source, isFirstOfDay):
            SupervisionHistorySourceHeading(heading: source.heading, isFirstOfDay: isFirstOfDay)
        case let .row(historyRow):
            rowView(historyRow, now: now)
                .notificationSourceGroup(isFirst: historyRow.isFirstOfSource, isLast: historyRow.isLastOfSource)
        case let .fold(source, count, isExpanded):
            SupervisionHistoryFold(
                count: count,
                isExpanded: isExpanded,
                sourceName: source.heading.foldName(locale: locale),
                isSelected: selection.id == item.id
            ) {
                selection.select(item.id)
                toggle(source.id)
            }
            .notificationSourceGroup(isFirst: false, isLast: true)
        }
    }

    private func rowView(_ historyRow: NotificationHistoryList.Row, now: Date) -> some View {
        let entry = historyRow.entry
        let happening = NotificationHistoryRowText.happening(of: entry, locale: locale)
        return SupervisionHistoryRow(
            lines: NotificationHistoryRowText.lines(of: happening, sourceTabTitle: historyRow.headingTab, locale: locale),
            mark: NotificationHistoryRowText.mark(
                of: entry,
                happening: happening,
                liveStatus: historyRow.liveStatus,
                isSourceClosed: historyRow.isClosed
            ),
            timeLabel: NotificationHistoryRowText.timeLabel(for: entry, now: now, locale: locale),
            isUnread: !entry.isRead,
            isClosed: historyRow.isClosed,
            opensPane: historyRow.opensPane,
            isSelected: selection.id == .row(entry.id),
            onOpen: {
                selection.select(.row(entry.id))
                open(historyRow)
            },
            onMarkRead: { store.markRead(entry.id) },
            onDelete: { store.delete(entry.id) }
        )
    }

    /// Opening a row reads it. A row that opens no pane (a closed
    /// source's) leaves the panel where it is; any other closes it once
    /// what it named is open.
    private func open(_ historyRow: NotificationHistoryList.Row) {
        store.markRead(historyRow.entry.id)
        guard historyRow.opensPane else { return }
        if onOpen(NotificationTarget(historyRow.entry)) {
            presentation.isPresented = false
        }
    }

    private func activate(_ item: NotificationHistoryList.Item) {
        switch item {
        case let .row(historyRow):
            open(historyRow)
        case let .fold(source, _, _):
            toggle(source.id)
        case .day, .heading:
            break
        }
    }

    private func toggle(_ source: NotificationHistoryList.SourceID) {
        withAnimation(reduceMotion ? nil : LimpidMotion.disclosure) {
            window.historyExpandedSources = NotificationHistoryList.toggled(source, in: window.historyExpandedSources)
        }
    }

    private var filteredEmptyState: EmptyState {
        switch filter {
        case .agents: .noAgentNotifications
        case .commands: .noCommandNotifications
        case .unread: .noUnreadNotifications
        case .all: .noNotifications
        }
    }

    // MARK: - Filter

    /// Which origins the list shows, or only what is unread.
    /// `.desktop` / `.bell` ride with the commands bucket: both are
    /// shell-driven, and splitting them out would buy another segment for a
    /// kind most users never fire.
    private enum Filter {
        case all
        case agents
        case commands
        case unread

        func accepts(_ entry: NotificationEntry) -> Bool {
            switch self {
            case .all: true
            case .agents: !entry.kind.isFromACommand
            case .commands: entry.kind.isFromACommand
            case .unread: !entry.isRead
            }
        }
    }
}
