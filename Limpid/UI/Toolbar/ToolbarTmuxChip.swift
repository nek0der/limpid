// ToolbarTmuxChip.swift
// Limpid — the toolbar chip that says which tmux window the active tab shows, how it stands, and what can be done to it.

import SwiftUI

/// What the chip says about the active tab, apart from the view, so every
/// width and every menu item can be checked without drawing anything.
///
/// The chip is layer 2 of the tmux surface: the tab row says which tabs are
/// mirrors, and the chip says what the one on screen is and how it stands.
/// It took the connection card's place over the panes, because that card
/// could only appear by covering the very panes it spoke of, and its height
/// was the size tmux gave the window.
///
/// Symbol, color and wording come from `TmuxStatePresentation` and
/// `TmuxConnectionCardContent`, the vocabulary the tab's row reads too, so
/// one state is never told two ways.
struct ToolbarTmuxChipContent: Equatable {
    /// How much of the chip fits. The widest form the toolbar can hold is
    /// the one drawn; the narrowest is always drawable, and carries the
    /// rest in its tooltip.
    enum Width: Equatable, CaseIterable {
        /// Identity and state.
        case full
        /// Identity alone.
        case identity
        /// The symbol alone.
        case symbolOnly
    }

    /// The items the chip's menu offers, in the order it offers them.
    enum Item: Equatable, CaseIterable {
        case newWindow
        case reconnect
        case otherClients
        case closeTab
        case quitWindow
    }

    /// The most pressing state, as the tab's row resolves it.
    let state: TmuxStatePresentation
    /// What the tab shows in the user's own words: `session:window` for a
    /// window they opened, the agent's name for a tab opened for an agent
    /// (D6 — an agent's session is named `limpid-…`, which they never typed).
    let identity: String
    /// Whether the widest form leads with `tmux`. An agent's tab does not
    /// put tmux in front of the user (D6).
    let showsTmuxPrefix: Bool
    /// What the connection card said underneath its heading, shown at the
    /// head of the menu. Nil while the tab is connected.
    let message: LocalizedStringResource?
    /// Whether the tab's mirror carries commands. Every item that asks
    /// something of tmux needs it.
    let isConnected: Bool
    /// Whether a reconnect can start now, as the store and this Mac's tmux
    /// both see it.
    let canReconnect: Bool
    /// Why this Mac's tmux rules a reconnect out, in the few words that
    /// trail the item's title, or nil when tmux is not what stands in the
    /// way.
    let tmuxObstacle: String?

    /// `tmux · work:editor`, or the agent's name on its own.
    var identityText: String {
        guard showsTmuxPrefix else { return identity }
        return "tmux · \(identity)"
    }

    /// The state in the words the row and the menu use, or nil when there
    /// is nothing to report: a tab that mirrors and nothing more says so by
    /// being there at all.
    var stateText: String? {
        guard !isAtRest else { return nil }
        return String(localized: state.title)
    }

    /// Nothing to report: connected, with nothing the mirror warns about.
    var isAtRest: Bool {
        if case .mirroring = state {
            return true
        }
        return false
    }

    /// What the chip reads as at `width`. Empty at `symbolOnly`, where the
    /// symbol carries the state and `fullText` is the tooltip.
    func text(_ width: Width) -> String {
        switch width {
        case .full: fullText
        case .identity: identityText
        case .symbolOnly: ""
        }
    }

    /// Everything the chip can say, for the tooltip and for VoiceOver: what
    /// the tab shows and how it stands.
    var fullText: String {
        guard let stateText else { return identityText }
        return "\(identityText), \(stateText)"
    }

    /// Why `item` is disabled, in the few words that trail its title, or nil
    /// when it is enabled. A disabled menu item shows no tooltip, so the
    /// reason has to be part of what is drawn — the same rule the Pane
    /// menu's reconnect item follows.
    func obstacle(for item: Item) -> String? {
        switch item {
        case .closeTab:
            return nil
        case .newWindow, .otherClients, .quitWindow:
            guard !isConnected else { return nil }
            return state == .connecting
                ? String(localized: "connecting", comment: "why a tmux menu item is disabled")
                : String(localized: "not connected", comment: "why a tmux menu item is disabled")
        case .reconnect:
            guard !canReconnect else { return nil }
            if let tmuxObstacle {
                return tmuxObstacle
            }
            if isConnected {
                return String(localized: "already connected", comment: "why Reconnect is disabled")
            }
            if state == .connecting {
                return String(localized: "connecting", comment: "why a tmux menu item is disabled")
            }
            return String(localized: "nothing left to connect to", comment: "why Reconnect is disabled")
        }
    }

    func isEnabled(_ item: Item) -> Bool {
        obstacle(for: item) == nil
    }

    /// What a mirror tab is called, on both sides: the names tmux gave it
    /// and the name Limpid knows its agent by. Which of them the user reads
    /// is `origin`'s to decide (D6).
    struct Names: Equatable {
        /// The tmux window the tab shows.
        let windowName: String
        /// The tmux session it belongs to.
        let sessionName: String
        /// What the agent behind an agent's tab is called. Unread for a
        /// window the user opened.
        var agentName: String = ""
        /// Who the tab was opened for.
        var origin: Tab.MirrorOrigin = .user

        var isAgent: Bool {
            origin == .agent
        }

        /// What the chip shows: `session:window`, or the agent's name.
        var identity: String {
            isAgent ? agentName : TmuxMirrorTarget.displayName(sessionName: sessionName, windowName: windowName)
        }
    }

    /// The chip for a mirror tab. Whether a tab is one at all is the
    /// caller's to decide (`TmuxMirrorActions.mirrorRef`); every mirror tab
    /// has a chip, in every state.
    ///
    /// - Parameters:
    ///   - connection: what the store records for the tab.
    ///   - hasMirror: whether the store holds a mirror for it.
    ///   - issues: what a live tab's mirror warns about.
    ///   - canReconnect: whether the store would let a reconnect start.
    ///   - tmuxSupport: what the launch probe found about this Mac's tmux.
    ///   - names: what the tab is called.
    static func make(
        connection: TmuxTabConnection?,
        hasMirror: Bool,
        issues: TmuxTabIssues?,
        canReconnect: Bool,
        tmuxSupport: AgentTmuxSupport = .pending,
        names: Names
    ) -> Self {
        // The row's mark is left empty when nothing wants the user, because
        // its slot is for what does. The chip is always drawn for a mirror
        // tab, so what the row leaves out is what the chip says at rest.
        let mark = TmuxTabRowMark.make(
            connection: connection,
            hasMirror: hasMirror,
            issues: issues,
            tmuxSupport: tmuxSupport
        )
        let card = TmuxConnectionCardContent.make(
            connection: connection,
            hasMirror: hasMirror,
            canReconnect: canReconnect,
            tmuxSupport: tmuxSupport,
            // The message speaks of the session, not of the window, and an
            // agent's session is one Limpid named.
            sessionName: names.isAgent ? names.agentName : names.sessionName
        )
        return Self(
            state: mark?.primary ?? .mirroring(windowName: names.windowName),
            identity: names.identity,
            showsTmuxPrefix: !names.isAgent,
            message: card?.message,
            // The card says nothing exactly while the tab is live, which is
            // the one reading of "connected" every item here needs.
            isConnected: card == nil,
            canReconnect: canReconnect,
            tmuxObstacle: tmuxSupport.reconnectObstacle
        )
    }
}

/// The chip itself, in the terminal column's toolbar beside the command
/// palette. Nothing is drawn for a tab that is not a mirror.
struct ToolbarTmuxChip: View {
    /// The compact toolbar gets the narrowest form: at that width the
    /// palette and the review button are what the toolbar owes the user,
    /// and the chip's tooltip still carries its words.
    let isCompact: Bool

    @Environment(WindowSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(SettingsStore.self) private var settings
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    @Environment(\.agentProjection) private var agentProjection
    @State private var isHovering = false

    /// Whether `.connecting` has lasted long enough to be worth saying. At
    /// launch every restored mirror tab connects at once, and a chip that
    /// says so for a few hundred milliseconds is noise rather than news.
    @State private var showsConnecting = false

    static let connectingDelay: Duration = .seconds(1)

    /// Read in the body, so a change to the tab's record or to its mirror
    /// redraws the chip.
    private var content: ToolbarTmuxChipContent? {
        guard let tmuxStore,
              let tab = session.activeTab,
              let ref = TmuxMirrorActions.mirrorRef(of: tab)
        else { return nil }
        return ToolbarTmuxChipContent.make(
            connection: tmuxStore.tabConnections[tab.id],
            hasMirror: tmuxStore.mirror(for: tab.id) != nil,
            issues: tmuxStore.tabIssues[tab.id],
            canReconnect: tmuxStore.tmuxExecutable != nil && tmuxStore.canReconnect(tabID: tab.id),
            tmuxSupport: settings.agentTmuxSupport,
            names: ToolbarTmuxChipContent.Names(
                windowName: TmuxMirrorActions.windowName(of: tab, binding: ref.binding, store: tmuxStore),
                sessionName: ref.binding.sessionName,
                agentName: TmuxConnectionStore.agentName(of: tab),
                origin: tab.mirrorOrigin
            )
        )
    }

    /// What the chip shows of `content`: everything but a connect that has
    /// not yet lasted `connectingDelay`, which reads as the state the tab
    /// was in a moment ago.
    static func visibleState(
        _ state: TmuxStatePresentation,
        showsConnecting: Bool
    ) -> TmuxStatePresentation? {
        guard state == .connecting else { return state }
        return showsConnecting ? state : nil
    }

    var body: some View {
        if let content {
            chip(content)
                // Restarted whenever the state changes, so a tab that stops
                // connecting — or starts again — is timed from that moment.
                .task(id: content.state) {
                    showsConnecting = false
                    guard content.state == .connecting else { return }
                    try? await Task.sleep(for: Self.connectingDelay)
                    guard !Task.isCancelled else { return }
                    showsConnecting = true
                }
                // The card over the panes used to announce this; it stays on
                // screen across the change, so VoiceOver would not otherwise
                // hear that a reconnect began or how it ended. Announced
                // from what is shown, so a connect too short to appear is
                // not spoken either, and only for the tab the user stayed
                // on: switching tabs is a move they made, not news.
                .onChange(of: Announced(tabID: session.activeTabID, state: content.state)) { old, new in
                    guard old.tabID == new.tabID else { return }
                    announce(new.state, was: old.state)
                }
        }
    }

    /// What an announcement is made of, so a state that changed because the
    /// user switched tabs can be told from one that changed by itself.
    private struct Announced: Equatable {
        let tabID: UUID?
        let state: TmuxStatePresentation
    }

    /// Heading and message together, as the card announced them: the
    /// heading alone says a reconnect ended without saying how. A reconnect
    /// that worked leaves nothing on the chip to read, which is the one
    /// outcome that has to be spoken in words of its own.
    private func announce(_ state: TmuxStatePresentation, was old: TmuxStatePresentation) {
        if case .mirroring = state {
            if case .mirroring = old {
                return
            }
            guard Self.visibleState(old, showsConnecting: showsConnecting) != nil else { return }
            AccessibilityNotification.Announcement(String(localized: "Connected to tmux")).post()
            return
        }
        guard Self.visibleState(state, showsConnecting: showsConnecting) != nil, let content else { return }
        guard let message = content.message else {
            AccessibilityNotification.Announcement(content.fullText).post()
            return
        }
        AccessibilityNotification.Announcement("\(String(localized: state.title)) \(String(localized: message))").post()
    }

    private func chip(_ content: ToolbarTmuxChipContent) -> some View {
        Menu {
            ToolbarTmuxChipMenu(content: content, perform: { perform($0) })
        } label: {
            label(content)
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .help(Text(verbatim: content.fullText))
        .accessibilityLabel(Text(verbatim: content.fullText))
    }

    @ViewBuilder
    private func label(_ content: ToolbarTmuxChipContent) -> some View {
        if isCompact {
            capsule(content, width: .symbolOnly)
        } else {
            ViewThatFits(in: .horizontal) {
                capsule(content, width: .full)
                capsule(content, width: .identity)
                capsule(content, width: .symbolOnly)
            }
        }
    }

    private func capsule(_ content: ToolbarTmuxChipContent, width: ToolbarTmuxChipContent.Width) -> some View {
        HStack(spacing: 5) {
            Image(systemName: content.state.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(content.state.severity.color)
            if width != .symbolOnly {
                Text(verbatim: content.text(width))
                    .font(LimpidFont.bodySecondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, width == .symbolOnly ? 8 : 10)
        .frame(height: LimpidLayout.toolbarContentHeight)
        .background(isHovering ? LimpidColor.rowHoverFill : Color.primary.opacity(0.03), in: Capsule())
        .overlay(Capsule().stroke(LimpidColor.toolbarHairline, lineWidth: 0.5))
        .contentShape(Capsule())
    }

    private func perform(_ item: ToolbarTmuxChipContent.Item) {
        guard let tmuxStore, let tabID = session.activeTabID else { return }
        switch item {
        case .newWindow:
            TmuxMirrorActions.newWindow(tabID: tabID, session: session, store: tmuxStore)
        case .reconnect:
            TmuxMirrorActions.reconnectAsked(tabID: tabID, session: session, store: tmuxStore)
        case .otherClients:
            TmuxMirrorActions.otherClientsAsked(tabID: tabID, session: session, store: tmuxStore)
        case .closeTab:
            TabActions.closeTab(
                session,
                registry: registry,
                tabID: tabID,
                source: .mouse,
                attention: attention,
                agentProjection: agentProjection
            )
        case .quitWindow:
            TmuxMirrorActions.quitWindowAsked(tabID: tabID, session: session, store: tmuxStore)
        }
    }
}

/// The chip's menu. Its own view so the chip's body stays readable; it
/// holds no state of its own.
private struct ToolbarTmuxChipMenu: View {
    let content: ToolbarTmuxChipContent
    let perform: (ToolbarTmuxChipContent.Item) -> Void

    var body: some View {
        // What the state means, where the card used to say it. Not a
        // control: there is nothing to press, and a disabled button would
        // read as an action the user is being kept from.
        if let message = content.message {
            Section(String(localized: content.state.title)) {
                Text(message)
            }
        }
        item(.newWindow, title: "New tmux Window", symbol: "plus.rectangle.on.rectangle")
            .keyboardShortcut("t", modifiers: [.control, .command])
        item(.reconnect, title: "Reconnect", symbol: "arrow.clockwise")
        item(.otherClients, title: "Other Clients…", symbol: "person.2")
        item(.closeTab, title: "Close Tab", symbol: "xmark")
            .keyboardShortcut("w", modifiers: [.command, .option])
        Divider()
        item(.quitWindow, title: "Quit This Window…", symbol: "trash", isDestructive: true)
    }

    private func item(
        _ item: ToolbarTmuxChipContent.Item,
        title: LocalizedStringResource,
        symbol: String,
        isDestructive: Bool = false
    ) -> some View {
        Button(role: isDestructive ? .destructive : nil) {
            perform(item)
        } label: {
            Label {
                if let obstacle = content.obstacle(for: item) {
                    Text(verbatim: "\(String(localized: title)) (\(obstacle))")
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
        .disabled(!content.isEnabled(item))
    }
}
