// NotificationHistoryView.swift
// Limpid — floating panel showing every notification Limpid has ever
// fired, grouped by day and filtered by origin (agents / commands).
// Reachable from either bell button (sidebar / toolbar capsule) and
// from `⌘⇧N`.

import AppKit
import SwiftUI

@MainActor
func toggleNotificationHistory(
    _ presentation: NotificationHistoryPresentation,
    session: WindowSession
) {
    CommandPaletteActions.closeCommandPalette(session)
    presentation.isPresented.toggle()
}

/// Window-level host that gives notification history the same detached,
/// arrowless placement as the command palette while keeping it anchored
/// to whichever toolbar bell is currently visible.
struct NotificationHistoryOverlay: View {
    let state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state.historyPresentation.isPresented,
               state.historyPresentation.anchorFrame.width > 0
            {
                GeometryReader { overlayGeo in
                    let overlayOrigin = overlayGeo.frame(in: .global).origin
                    let anchorFrame = state.historyPresentation.anchorFrame
                    let panelWidth: CGFloat = 400
                    let preferredHeight = state.historyStore.entries.isEmpty
                        ? NotificationHistoryView.emptyHeight
                        : NotificationHistoryView.populatedHeight
                    let edgeInset: CGFloat = 12
                    let anchorX = anchorFrame.midX - overlayOrigin.x
                    let centerX = min(
                        max(anchorX, panelWidth / 2 + edgeInset),
                        overlayGeo.size.width - panelWidth / 2 - edgeInset
                    )
                    let panelTop = anchorFrame.maxY - overlayOrigin.y + 6
                    let availableHeight = overlayGeo.size.height - panelTop - edgeInset
                    let panelHeight = min(preferredHeight, max(0, availableHeight))

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.historyPresentation.isPresented = false
                        }
                    NotificationHistoryView(
                        height: panelHeight,
                        isPaneAlive: { paneID in
                            state.session.tab(containing: paneID) != nil
                        },
                        onJumpToPane: { paneID in
                            jumpToPane(paneID, session: state.session, registry: state.registry)
                        },
                        // Runtime first, pane second — the same route a macOS
                        // notification tap follows after a runtime moves panes.
                        onJumpToRuntime: { runtimeID in
                            state.attention.focusRuntime(
                                runtimeID,
                                in: state.session,
                                registry: state.registry
                            )
                        }
                    )
                    .position(x: centerX, y: panelTop + panelHeight / 2)
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(reduceMotion ? nil : LimpidMotion.paletteToggle, value: state.historyPresentation.isPresented)
        .onChange(of: state.session.commandPaletteState != nil) { _, isPresented in
            if isPresented {
                state.historyPresentation.isPresented = false
            }
        }
    }
}

struct NotificationHistoryView: View {
    static let populatedHeight: CGFloat = 480
    static let emptyHeight: CGFloat = 280

    @Environment(NotificationHistoryStore.self) private var store
    @Environment(NotificationHistoryPresentation.self) private var presentation
    @Environment(AttentionState.self) private var attention
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Resolved by the overlay from the space below the toolbar bell.
    /// The populated panel is scrollable, so shrinking it is preferable
    /// to clipping its destructive controls below a short window.
    let height: CGFloat
    /// Returns true if the pane id still resolves to a live SurfaceView
    /// in some open tab — controls whether a history row is clickable
    /// vs. grayed out as a closed source.
    let isPaneAlive: (UUID) -> Bool
    let onJumpToPane: (UUID) -> Void
    /// Focuses the runtime behind an agent row, returning false when it
    /// is no longer around to focus.
    let onJumpToRuntime: (String) -> Bool

    /// Gates the destructive clear behind a confirmation. The trash
    /// button used to drop the whole history — up to 500 rows — on a
    /// single misclick, with no undo and no surviving on-disk copy to
    /// recover from, so we ask first.
    @State private var isConfirmingClear = false

    /// Origin filter for the list. Session-scoped on purpose — a filter
    /// that survives a relaunch is one the user forgets is on, and the
    /// panel would then read as having lost notifications.
    @State private var filter: Filter = .all

    var body: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if isConfirmingClear {
                clearConfirmation
            } else if store.entries.isEmpty {
                emptyState
            } else {
                filterChips
                if daySections.isEmpty {
                    filteredEmptyState
                } else {
                    list
                        // Shorten the scroller track at the top + bottom so
                        // it doesn't run into the panel's rounded corners.
                        .padding(.vertical, 8)
                }
            }
        }
        .frame(
            width: 400,
            height: height
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .limpidGlass(.palette)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.20), lineWidth: 0.5)
        )
        .animation(reduceMotion ? nil : LimpidMotion.paletteToggle, value: isConfirmingClear)
        .background {
            NotificationHistoryEscapeMonitor {
                if isConfirmingClear {
                    isConfirmingClear = false
                } else {
                    presentation.isPresented = false
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Notifications")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            if store.unreadCount > 0 {
                // Perfect circle for 1-2 digit counts; the
                // notification bell color (orange) keeps the popover
                // visually in lockstep with the toolbar badge.
                Text("\(min(store.unreadCount, 99))")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(LimpidColor.notificationBell))
            }
            Spacer()
            if !store.entries.isEmpty, !isConfirmingClear {
                Button("Mark All as Read") { store.markAllRead() }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(store.unreadCount == 0)
                Button {
                    isConfirmingClear = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear All")
                .accessibilityLabel(Text("Clear All"))
            }
        }
        // Keep the title and divider fixed when the trailing controls disappear
        // while the in-panel clear confirmation is visible.
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Clear confirmation

    /// Keeps the destructive decision inside the surface that owns the
    /// data. A window-level sheet made clearing notification history
    /// look like an application-wide operation and broke the user's
    /// context for a panel-local action.
    private var clearConfirmation: some View {
        VStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 24))
                .foregroundStyle(Color(.systemRed))
            Text("Clear all notifications?")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("This cannot be undone.")
                .font(LimpidFont.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Cancel") { isConfirmingClear = false }
                    .buttonStyle(.bordered)
                    .tint(Color.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Clear All", role: .destructive) {
                    store.clearAll()
                    isConfirmingClear = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(.systemRed))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No notifications yet")
                .font(LimpidFont.bodySecondary)
                .foregroundStyle(.secondary)
            Text("Agent responses and completed commands appear as notifications.")
                .font(LimpidFont.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An explicit result for an empty filter prevents the blank panel
    /// from reading as a failed load. The unfiltered empty state above
    /// remains richer because it explains what the notification feature
    /// collects; this one only needs to confirm the active filter found
    /// no matches.
    private var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .agents ? "sparkles" : "terminal")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Group {
                switch filter {
                case .agents:
                    Text("No agent notifications")
                case .commands:
                    Text("No command notifications")
                case .all:
                    Text("No notifications yet")
                }
            }
            .font(LimpidFont.bodySecondary)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filter

    /// Which origins the list shows. `.desktop` / `.bell` ride with the
    /// commands bucket: both are shell-driven, and splitting them out
    /// would buy a third pill for a kind most users never fire.
    private enum Filter {
        case all
        case agents
        case commands

        func accepts(_ kind: NotificationEntry.Kind) -> Bool {
            switch self {
            case .all: true
            case .agents: Filter.isAgentKind(kind)
            case .commands: !Filter.isAgentKind(kind)
            }
        }

        /// Exhaustive on purpose: a kind added later has to be sorted
        /// into one of the two buckets rather than silently vanishing
        /// from both filtered views.
        private static func isAgentKind(_ kind: NotificationEntry.Kind) -> Bool {
            switch kind {
            case .agentFinished, .agentNeedsInput, .agentError: true
            case .commandFinished, .desktop, .bell: false
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            filterPill("All", .all)
            filterPill("Agents", .agents)
            filterPill("Commands", .commands)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Notification filter"))
    }

    private func filterPill(_ title: LocalizedStringKey, _ value: Filter) -> some View {
        let isSelected = filter == value
        return Button {
            filter = value
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                // The selected pill inverts against the window ground
                // rather than against white, so it stays legible in
                // both appearances.
                .foregroundStyle(isSelected ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(Capsule().fill(isSelected ? Color.primary.opacity(0.85) : Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(daySections) { section in
                    sectionHeader(section.title)
                    ForEach(section.entries) { entry in
                        row(for: entry)
                        Divider().opacity(0.15).padding(.leading, 14)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        // Case is left alone rather than uppercased: ja headers ("今日")
        // gain nothing from case folding, so `.textCase(.uppercase)`
        // would only shout on the en side.
        Text(title)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(LimpidColor.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(for entry: NotificationEntry) -> some View {
        let isPaneDestinationAlive = entry.paneID.map(isPaneAlive) ?? false
        let isRuntimeAlive = entry.runtimeID.map { runtimeID in
            attention.allRuntimes.contains { $0.id == runtimeID && !$0.paneIDs.isEmpty }
        } ?? false
        let isDestinationAlive = isRuntimeAlive || isPaneDestinationAlive
        return NotificationHistoryRow(
            entry: entry,
            isDestinationAlive: isDestinationAlive,
            onTap: {
                store.markRead(entry.id)
                // Runtime first, pane second, so a tmux-hosted agent
                // that moved panes is followed to where it lives now
                // rather than to the pane it announced itself from.
                if let runtimeID = entry.runtimeID, onJumpToRuntime(runtimeID) {
                    presentation.isPresented = false
                    return
                }
                if isPaneDestinationAlive, let paneID = entry.paneID {
                    onJumpToPane(paneID)
                    presentation.isPresented = false
                }
            },
            onDelete: { store.delete(entry.id) }
        )
    }

    // MARK: - Day grouping

    /// One day bucket. Relative day names beat absolute dates here
    /// because the entries a user opens this panel for are almost
    /// always from the running session; everything older collapses
    /// into a single "Earlier" bucket instead of growing one header
    /// per calendar day.
    private struct DaySection: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let entries: [NotificationEntry]
    }

    private var daySections: [DaySection] {
        let calendar = Calendar.current
        var today: [NotificationEntry] = []
        var yesterday: [NotificationEntry] = []
        var earlier: [NotificationEntry] = []
        // `store.entries` is already newest-first, so appending in
        // iteration order preserves that ordering inside each bucket.
        for entry in store.entries where filter.accepts(entry.kind) {
            if calendar.isDateInToday(entry.timestamp) {
                today.append(entry)
            } else if calendar.isDateInYesterday(entry.timestamp) {
                yesterday.append(entry)
            } else {
                earlier.append(entry)
            }
        }
        return [
            DaySection(id: "today", title: "Today", entries: today),
            DaySection(id: "yesterday", title: "Yesterday", entries: yesterday),
            DaySection(id: "earlier", title: "Earlier", entries: earlier)
        ]
        .filter { !$0.entries.isEmpty }
    }
}

/// Consumes Escape while the arrowless history overlay is open. Unlike
/// `Popover`, an ordinary overlay does not enter AppKit's modal responder
/// chain; without this monitor the focused terminal receives the escape byte.
private struct NotificationHistoryEscapeMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.hostWindow = window
        }
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.hostWindow = view.window
    }

    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        coordinator.remove()
        coordinator.hostWindow = nil
    }

    @MainActor
    final class HostView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        var onEscape: () -> Void
        weak var hostWindow: NSWindow?
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let hostWindow,
                      event.window === hostWindow,
                      event.keyCode == 53,
                      event.modifierFlags.isDisjoint(with: [.command, .control, .option])
                else { return event }
                onEscape()
                return nil
            }
        }

        func remove() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// One history row.
///
/// The history is a log, but an agent row points at a runtime that is
/// still alive, so we say whether the wait it announced is still open:
/// The glyph carries state visually; repeating it as a word would crowd
/// the body on the narrow panel. Its color always means the same state
/// here and in Waiting; read and navigation state use separate signals.
private struct NotificationHistoryRow: View {
    let entry: NotificationEntry
    /// False when neither the originating pane nor the tracked runtime
    /// resolves to an open destination. A tmux runtime may move after
    /// notification delivery, so the source pane alone is not enough
    /// to decide whether the row is still actionable.
    let isDestinationAlive: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                kindGlyph
                    .frame(width: 18)
                    // Attach unread state to the kind glyph as a badge;
                    // a separate leading dot reads like a list bullet.
                    .overlay(alignment: .topTrailing) {
                        unreadDot.offset(x: 1, y: -1)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    messageText
                        .font(LimpidFont.bodySecondary)
                        .lineLimit(2)
                    if let caption = captionText {
                        Text(caption)
                            .font(LimpidFont.caption)
                            .foregroundStyle(LimpidColor.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(rowBackground)
            .opacity(isDestinationAlive ? 1.0 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isDestinationAlive ? "" : "Source pane was closed")
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(entry.title)
                .font(.system(size: 12.5, weight: entry.isRead ? .medium : .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                // The title is the only piece we are willing to shorten
                // on a narrow row, so it yields before the chip does.
                .layoutPriority(0)
            Spacer(minLength: 6)
            // The hover affordance replaces the timestamp in the same
            // footprint instead of reserving a permanent trailing slot.
            ZStack(alignment: .trailing) {
                Text(timeLabel)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    // Relative labels run much wider in ja ("5 分前") than
                    // in en, so the timestamp keeps its intrinsic width.
                    .fixedSize()
                    .opacity(isHovering ? 0 : 1)
                deleteButton
            }
        }
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel(Text("Dismiss"))
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }

    @ViewBuilder
    private var unreadDot: some View {
        if !entry.isRead {
            Circle()
                .fill(LimpidColor.notificationBell)
                .frame(width: 5, height: 5)
                // A bare `Shape` is not an accessibility element, so
                // the label would be dropped without promoting it
                // first.
                .accessibilityElement()
                .accessibilityLabel(Text("Unread"))
        }
    }

    /// Leading kind glyph. Agent rows borrow `AgentState`'s symbol and
    /// tint verbatim so an entry reads as the same object the Waiting
    /// list shows; command and script rows reuse the same
    /// `.circle.fill` family in a neutral tint. General shell alerts use
    /// a terminal glyph: another bell inside notification history only
    /// repeats the surrounding UI and does not identify their source.
    /// VoiceOver still receives the semantic state after its visible
    /// label is removed; shell alerts have no state and stay decorative.
    @ViewBuilder
    private var kindGlyph: some View {
        let image = Image(systemName: glyph.name)
            .font(.system(size: 14))
            .foregroundStyle(glyph.color)
            .frame(width: 18, height: 18)
        if let label = kindAccessibilityLabel {
            image.accessibilityLabel(Text(label))
        } else {
            image.accessibilityHidden(true)
        }
    }

    private var glyph: (name: String, color: Color) {
        baseGlyph
    }

    private var baseGlyph: (name: String, color: Color) {
        if let state = entry.kind.agentState, let name = state.iconName, let color = state.iconColor {
            return (name, color)
        }
        switch entry.kind {
        case .commandFinished:
            return hasFailed
                ? ("exclamationmark.circle.fill", Color(.systemRed))
                : ("checkmark.circle.fill", Color.secondary)
        case .desktop, .bell:
            return ("terminal", Color.secondary)
        case .agentFinished, .agentNeedsInput, .agentError:
            return ("bell.circle.fill", Color.secondary)
        }
    }

    /// A missing exit code means the hook reported completion without
    /// a status, which we read as success rather than inventing a
    /// failure the user never saw.
    private var hasFailed: Bool {
        (entry.exitCode ?? 0) != 0
    }

    private var kindAccessibilityLabel: String? {
        if let state = entry.kind.agentState {
            return state.localizedLabel
        }
        switch entry.kind {
        case .commandFinished:
            return hasFailed
                ? String(localized: "Failed")
                : String(localized: "Finished")
        case .desktop, .bell, .agentFinished, .agentNeedsInput, .agentError:
            return nil
        }
    }

    private var messageText: Text {
        Text(entry.body).foregroundStyle(.secondary)
    }

    /// Provenance line. Each piece drops out when it would repeat what
    /// the row already says — an agent entry's title is its container
    /// label, so the folder chip that used to sit here was showing the
    /// title twice.
    private var captionText: String? {
        var pieces: [String] = []
        if let tab = entry.tabTitleSnapshot, !tab.isEmpty, tab != entry.title, tab != entry.body {
            pieces.append(tab)
        }
        if let container = entry.containerLabel, !container.isEmpty, container != entry.title {
            pieces.append(container)
        }
        if !isDestinationAlive {
            pieces.append(String(localized: "Source pane was closed"))
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    /// Row background — hover fill only. The red kind glyph already
    /// conveys "failed", no need to also tint the whole row.
    private var rowBackground: Color {
        if isHovering, isDestinationAlive {
            return LimpidColor.rowHoverFill
        }
        return .clear
    }

    private var timeLabel: String {
        let now = Date()
        let delta = now.timeIntervalSince(entry.timestamp)
        if delta < 60 {
            return String(localized: "now")
        }
        if delta < 86400 {
            // Recent entries get a locale-aware abbreviated relative
            // form ("5 min. ago" / "5分前"). `Date.RelativeFormatStyle`
            // honors `Locale.current` for the unit suffix.
            return entry.timestamp.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        }
        // Older entries hand off to the locale's own short date — no
        // hand-pinned `"MM/dd"` so ja users see e.g. `2026/06/04` and
        // long-form locales see their own shape.
        return entry.timestamp.formatted(date: .abbreviated, time: .omitted)
    }
}
