// TmuxDirectoryView.swift
// Limpid — the tmux directory in the container slab: which sessions exist, which of their windows a tab shows, and what can be done to
// them.

import SwiftUI

/// Layer 3 of the tmux surface: what else is there, and how to get back to
/// it. A category of the container slab beside Groups and Projects, not a
/// part of the Waiting region below — that region is the inbox of what is
/// waiting for the user, and a list of everything running in tmux is not
/// waiting for anybody.
///
/// Nothing is drawn on a Mac without a tmux: there is no directory to show,
/// and an empty category headed `tmux` would be a standing question about
/// a feature the user has not installed. The Integrations pane is where
/// that is said.
struct TmuxDirectorySection: View {
    /// Whether the slab is on screen. The directory lists tmux every few
    /// seconds while it is open, and a list nobody can see is a process per
    /// server for nothing (item 2-1).
    let isVisible: Bool

    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    /// Made on the first pass, from the store's tmux, so the directory and
    /// every mirror tab agree on which tmux this Mac has.
    @State private var model: TmuxDirectoryModel?

    var body: some View {
        if tmuxStore?.tmuxExecutable != nil {
            FoldableSection(isExpanded: session.tmuxSectionExpanded, height: contentHeight) {
                SlabSectionHeader(
                    title: "tmux",
                    isExpanded: session.tmuxSectionExpanded,
                    toggle: {
                        withAnimation(LimpidMotion.reorder) {
                            session.tmuxSectionExpanded.toggle()
                        }
                    },
                    accessory: AnyView(newSessionButton)
                )
            } content: {
                VStack(alignment: .leading, spacing: LimpidLayout.reorderRowSpacing) {
                    ForEach(model?.sessions ?? []) { directorySession in
                        sessionBlock(directorySession)
                    }
                }
            }
            // Restarted whenever the section opens or closes, the slab
            // comes or goes, or a mirror tab opens or closes: the loop
            // lists once before it waits, so each of those is followed by
            // a fresh list rather than by up to `refreshInterval` of a
            // stale one.
            .task(id: RefreshKey(isActive: isActive, mirrors: mirrorSignature)) {
                await run()
            }
        }
    }

    /// What restarts the listing loop.
    private struct RefreshKey: Equatable {
        let isActive: Bool
        let mirrors: [String]
    }

    private var isActive: Bool {
        isVisible && session.tmuxSectionExpanded
    }

    /// The windows mirror tabs are showing, so opening or closing one
    /// relists at once. Their ids, not their number: a window closed and
    /// another opened in the same moment leaves the count alone.
    private var mirrorSignature: [String] {
        session.tabs.compactMap { tab in
            TmuxMirrorActions.mirrorRef(of: tab).map { "\($0.binding.socketPath)\u{1}\($0.windowID)" }
        }
        .sorted()
    }

    private func run() async {
        let model = model ?? TmuxDirectoryModel(tmuxPath: tmuxStore?.tmuxExecutable)
        if self.model == nil {
            self.model = model
        }
        guard isActive else { return }
        await model.poll()
    }

    // MARK: - Height

    /// Height of everything below the header, computed rather than
    /// measured for the reason `ProjectSectionView.worktreeStackHeight`
    /// gives: a section folded to a height cannot also report its natural
    /// one. Every row is `containerColumnRowHeight`, so the arithmetic is
    /// exact.
    private var contentHeight: CGFloat {
        guard let model else { return 0 }
        return ContainerSlabView.stackedHeight(model.sessions.map { blockHeight(of: $0) })
    }

    private func blockHeight(of directorySession: TmuxDirectorySession) -> CGFloat {
        guard let model, model.isExpanded(directorySession) else { return LimpidLayout.containerColumnRowHeight }
        let rows = model.visibleWindows(of: directorySession).count
            + (model.hiddenWindowCount(of: directorySession) > 0 ? 1 : 0)
        guard rows > 0 else { return LimpidLayout.containerColumnRowHeight }
        return LimpidLayout.containerColumnRowHeight
            + CGFloat(rows) * (LimpidLayout.containerColumnRowHeight + LimpidLayout.reorderRowSpacing)
    }

    // MARK: - Rows

    /// Why this Mac cannot start a session, or nil. The same answer the
    /// palette's row gets, so the two are never offered differently.
    private var newSessionObstacle: String? {
        TmuxSessionActions.newSessionObstacle(
            support: settings.agentTmuxSupport,
            hasTmux: tmuxStore?.tmuxExecutable != nil
        )
    }

    private var newSessionButton: some View {
        Button {
            guard let tmuxStore else { return }
            withAnimation(LimpidMotion.reorder) {
                session.tmuxSectionExpanded = true
            }
            TmuxSessionActions.newSession(session: session, store: tmuxStore)
        } label: {
            SectionAddBadge()
        }
        .buttonStyle(.plain)
        .disabled(newSessionObstacle != nil)
        .help(Text(verbatim: newSessionObstacle.map {
            "\(String(localized: "New tmux Session")) (\($0))"
        } ?? String(localized: "New tmux Session")))
        .accessibilityLabel(Text("New tmux Session"))
    }

    @ViewBuilder
    private func sessionBlock(_ directorySession: TmuxDirectorySession) -> some View {
        let isExpanded = model?.isExpanded(directorySession) ?? false
        VStack(alignment: .leading, spacing: LimpidLayout.reorderRowSpacing) {
            sessionRow(directorySession, isExpanded: isExpanded)
            if isExpanded, let model {
                ForEach(model.visibleWindows(of: directorySession)) { window in
                    windowRow(window)
                }
                let hidden = model.hiddenWindowCount(of: directorySession)
                if hidden > 0 {
                    showMoreRow(directorySession, hidden: hidden)
                }
            }
        }
    }

    private func sessionRow(_ directorySession: TmuxDirectorySession, isExpanded: Bool) -> some View {
        let row = rowContent(directorySession)
        return HStack(spacing: LimpidLayout.containerColumnRowContentSpacing) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.45))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: LimpidLayout.containerColumnMarkerSlot)
            Text(verbatim: directorySession.name)
                .font(LimpidFont.body)
                .lineLimit(1)
            if let serverLabel = directorySession.serverLabel {
                Text(verbatim: serverLabel)
                    .font(LimpidFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let state = row?.state {
                Image(systemName: state.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(state.severity.color)
                    .frame(
                        width: LimpidLayout.containerColumnTrailingSlot,
                        height: LimpidLayout.containerColumnTrailingSlot
                    )
            }
        }
        .padding(.leading, LimpidLayout.containerColumnIndentTop)
        .padding(.trailing, LimpidLayout.containerColumnRowTrailingPadding)
        .frame(height: LimpidLayout.containerColumnRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(LimpidMotion.expand) {
                model?.toggleExpanded(directorySession)
            }
        }
        .contextMenu {
            if let row {
                sessionMenu(directorySession, row: row)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: sessionLabel(directorySession, row: row)))
        .accessibilityAddTraits(.isButton)
    }

    private func windowRow(_ window: TmuxDirectoryWindow) -> some View {
        let shownTabID = TmuxMirrorActions.mirrorTabID(showing: window, in: session)
        return HStack(spacing: LimpidLayout.containerColumnRowContentSpacing) {
            Text(verbatim: window.label)
                .font(LimpidFont.bodySecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if shownTabID != nil {
                Text("Showing")
                    .font(LimpidFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, LimpidLayout.containerColumnNestedPillLeading)
        .padding(.trailing, LimpidLayout.containerColumnRowTrailingPadding)
        .frame(height: LimpidLayout.containerColumnRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { open(window) }
        .contextMenu { windowMenu(window, isShown: shownTabID != nil) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: shownTabID == nil
                ? window.label
                : "\(window.label), \(String(localized: "Showing"))"))
        .accessibilityAddTraits(.isButton)
    }

    private func showMoreRow(_ directorySession: TmuxDirectorySession, hidden: Int) -> some View {
        Button {
            withAnimation(LimpidMotion.expand) {
                model?.showEveryWindow(directorySession)
            }
        } label: {
            Text("Show \(hidden) more")
                .font(LimpidFont.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, LimpidLayout.containerColumnNestedPillLeading)
                .frame(height: LimpidLayout.containerColumnRowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Menus

    @ViewBuilder
    private func sessionMenu(_ directorySession: TmuxDirectorySession, row: TmuxDirectorySessionRow) -> some View {
        item(.newWindow, title: "New Window", symbol: "plus.rectangle.on.rectangle", row: row) {
            guard let tmuxStore else { return }
            TmuxMirrorActions.newWindowInSession(directorySession, session: session, store: tmuxStore)
        }
        .keyboardShortcut("t", modifiers: [.control, .command])
        item(.openAll, title: "Open All Windows", symbol: "rectangle.stack", row: row) {
            guard let tmuxStore else { return }
            TmuxMirrorActions.openAllWindows(of: directorySession, session: session, store: tmuxStore)
        }
        item(.reconnect, title: "Reconnect", symbol: "arrow.clockwise", row: row) {
            guard let tmuxStore else { return }
            TmuxMirrorActions.reconnectSession(directorySession, session: session, store: tmuxStore)
        }
        item(.closeTabs, title: "Close Its Tabs", symbol: "xmark", row: row) {
            guard let tmuxStore else { return }
            TmuxMirrorActions.closeTabs(ofSession: directorySession, session: session, store: tmuxStore)
        }
        Divider()
        item(.quitSession, title: "Quit This Session…", symbol: "trash", row: row, isDestructive: true) {
            guard let tmuxStore else { return }
            TmuxMirrorActions.quitSessionAsked(directorySession, store: tmuxStore)
        }
    }

    @ViewBuilder
    private func windowMenu(_ window: TmuxDirectoryWindow, isShown: Bool) -> some View {
        Button {
            open(window)
        } label: {
            Label(isShown ? "Show" : "Open", systemImage: isShown ? "arrow.right.circle" : "rectangle.on.rectangle")
        }
        Divider()
        Button(role: .destructive) {
            guard let tmuxStore else { return }
            TmuxMirrorActions.quitWindowAsked(window, session: session, store: tmuxStore)
        } label: {
            Label("Quit This Window…", systemImage: "trash")
        }
    }

    /// One session-menu item, with the reason it is disabled in its title.
    /// A disabled menu item shows no tooltip, the rule the toolbar chip's
    /// menu follows too.
    private func item(
        _ item: TmuxDirectorySessionRow.Item,
        title: LocalizedStringResource,
        symbol: String,
        row: TmuxDirectorySessionRow,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Label {
                if let obstacle = row.obstacle(for: item) {
                    Text(verbatim: "\(String(localized: title)) (\(obstacle))")
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
        .disabled(!row.isEnabled(item))
    }

    // MARK: - Reading the store

    private func rowContent(_ directorySession: TmuxDirectorySession) -> TmuxDirectorySessionRow? {
        guard let tmuxStore else { return nil }
        return TmuxDirectorySessionRow.make(
            directorySession,
            tabs: session.tabs,
            store: tmuxStore,
            tmuxSupport: settings.agentTmuxSupport
        )
    }

    /// What VoiceOver reads for a session row: its name, the server when
    /// there is one to name, and its state when it has one.
    private func sessionLabel(_ directorySession: TmuxDirectorySession, row: TmuxDirectorySessionRow?) -> String {
        var parts = [directorySession.name]
        if let serverLabel = directorySession.serverLabel {
            parts.append(serverLabel)
        }
        if let state = row?.state {
            parts.append(String(localized: state.title))
        }
        return parts.joined(separator: ", ")
    }

    private func open(_ window: TmuxDirectoryWindow) {
        guard let tmuxStore else { return }
        TmuxMirrorActions.openFromDirectory(window, session: session, store: tmuxStore)
    }
}
