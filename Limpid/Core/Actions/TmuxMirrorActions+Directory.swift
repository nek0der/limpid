// TmuxMirrorActions+Directory.swift
// Limpid — what the sidebar's tmux directory does: open a listed window, start a session or a window, and end one.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.directory")

/// What the directory offers on one session row, apart from the view, so
/// every item can be checked without drawing anything. The same shape as
/// `ToolbarTmuxChipContent`: a disabled menu item shows no tooltip, so the
/// reason it is disabled has to be part of what is drawn.
struct TmuxDirectorySessionRow: Equatable {
    /// The items the session's menu offers, in the order it offers them.
    /// Right-click is the source of truth for every one of them (item 2-3):
    /// the keyboard and VoiceOver reach a context menu, and a button that
    /// appears on hover does not.
    enum Item: Equatable, CaseIterable {
        case newWindow
        case openAll
        case reconnect
        case closeTabs
        case quitSession
    }

    /// How the tabs showing this session stand, in the vocabulary the tab
    /// row and the toolbar chip use, or nil when there is nothing to report
    /// (item 2-5). A session nothing here shows has no state of its own:
    /// it is a session in tmux, which is what the row already says.
    let state: TmuxStatePresentation?
    let windowCount: Int
    /// How many of those windows a tab is already showing.
    let shownWindowCount: Int
    /// How many tabs show a window of this session.
    let tabCount: Int
    /// Whether some tab of this session could be connected again now, as
    /// the store sees it.
    let canReconnect: Bool
    /// Why this Mac's tmux rules the tmux-side items out, or nil.
    let tmuxObstacle: String?

    /// Whether the session's Limpid connection is not live, which is when
    /// the row wears a state symbol and offers Reconnect.
    var needsAttention: Bool {
        state != nil
    }

    func obstacle(for item: Item) -> String? {
        switch item {
        case .newWindow, .quitSession:
            return tmuxObstacle
        case .openAll:
            if let tmuxObstacle {
                return tmuxObstacle
            }
            guard shownWindowCount >= windowCount else { return nil }
            return String(localized: "already open", comment: "why a tmux directory item is disabled")
        case .reconnect:
            if let tmuxObstacle {
                return tmuxObstacle
            }
            guard !canReconnect else { return nil }
            return tabCount == 0
                ? String(localized: "no tabs show this session", comment: "why a tmux directory item is disabled")
                : String(localized: "nothing to reconnect", comment: "why a tmux directory item is disabled")
        case .closeTabs:
            guard tabCount == 0 else { return nil }
            return String(localized: "no tabs show this session", comment: "why a tmux directory item is disabled")
        }
    }

    func isEnabled(_ item: Item) -> Bool {
        obstacle(for: item) == nil
    }

    /// What one session's row stands for, read from the store.
    ///
    /// The state is the connection's, not the picture's: a tab whose mirror
    /// warns that its window is larger than the tab says something about
    /// that tab, and the directory speaks of the session. So only the
    /// states a reconnect is about reach the row.
    @MainActor
    static func make(
        _ session: TmuxDirectorySession,
        tabs: [Tab],
        store: TmuxConnectionStore,
        tmuxSupport: AgentTmuxSupport = .pending
    ) -> Self {
        let mine = tabs.filter { tab in
            TmuxMirrorActions.mirrorRef(of: tab).map { TmuxConnectionStore.Key($0.binding) == session.key } ?? false
        }
        let shown = Set(session.windows.map(\.windowID)).intersection(
            mine.compactMap { TmuxMirrorActions.mirrorRef(of: $0)?.windowID }
        )
        let states = mine.compactMap { tab in
            TmuxTabRowMark.make(
                connection: store.tabConnections[tab.id],
                hasMirror: store.mirror(for: tab.id) != nil,
                issues: nil,
                tmuxSupport: tmuxSupport
            )?.primary
        }
        return Self(
            state: states.first,
            windowCount: session.windows.count,
            shownWindowCount: shown.count,
            tabCount: mine.count,
            canReconnect: store.tmuxExecutable != nil && mine.contains { store.canReconnect(tabID: $0.id) },
            tmuxObstacle: store.tmuxExecutable == nil
                ? String(localized: "no tmux found")
                : tmuxSupport.reconnectObstacle
        )
    }
}

extension TmuxMirrorActions {

    // MARK: - Opening what is listed

    /// Open the listed window as a mirror tab in the active container, or
    /// bring forward the tab already showing it (design D7). Opening goes
    /// the route the palette takes, so the clients attached elsewhere are
    /// dealt with the same way.
    @discardableResult
    static func openFromDirectory(
        _ window: TmuxDirectoryWindow,
        session: WindowSession,
        store: TmuxConnectionStore
    ) -> Task<Void, Never>? {
        if let tabID = mirrorTabID(showing: window, in: session) {
            session.setActiveTab(tabID)
            return nil
        }
        return openFromPalette(window.target, session: session, store: store)
    }

    /// The tab showing this window, connected or not. A disconnected mirror
    /// tab still shows the window — what it holds is that window's screen —
    /// so opening a second tab on it would leave the user with two tabs of
    /// one name, only one of which could ever be fed.
    static func mirrorTabID(showing window: TmuxDirectoryWindow, in session: WindowSession) -> UUID? {
        let key = TmuxConnectionStore.Key(window.target.binding)
        return session.tabs.first { tab in
            guard let ref = mirrorRef(of: tab) else { return false }
            return ref.windowID == window.windowID && TmuxConnectionStore.Key(ref.binding) == key
        }?.id
    }

    /// Open every window of `directorySession` that no tab shows yet.
    ///
    /// The clients attached elsewhere are asked about once rather than once
    /// per window: they are attached to the session, which is the same
    /// session for all of these windows, so the second question would be
    /// the first one asked again.
    @discardableResult
    static func openAllWindows(
        of directorySession: TmuxDirectorySession,
        session: WindowSession,
        store: TmuxConnectionStore
    ) -> Task<Void, Never>? {
        let pending = directorySession.windows.filter { mirrorTabID(showing: $0, in: session) == nil }
        guard let first = pending.first, let tmuxPath = store.tmuxExecutable else { return nil }
        let gate = otherClientsGate(tmuxPath: tmuxPath, session: session, store: store)
        return Task {
            guard await gate(first.target) else { return }
            for window in pending {
                open(window.target, session: session, store: store)
            }
        }
    }

    // MARK: - The session's connection

    /// Connect the tabs showing this session again (item 2-5). Each tab
    /// takes the others of its socket, session and server run along, so the
    /// tabs left after the first call have nothing to reconnect and add
    /// nothing.
    static func reconnectSession(
        _ directorySession: TmuxDirectorySession,
        session: WindowSession,
        store: TmuxConnectionStore
    ) {
        for tab in tabs(of: directorySession, in: session) where store.canReconnect(tabID: tab.id) {
            reconnectAsked(tabID: tab.id, session: session, store: store)
        }
    }

    /// Close every tab showing a window of this session. The vocabulary is
    /// the plan's D4: this closes tabs, it does not end anything in tmux,
    /// and every window goes on running. Nothing is asked, for that reason
    /// and because asking per tab would put one dialog after another in
    /// front of a single gesture.
    static func closeTabs(
        ofSession directorySession: TmuxDirectorySession,
        session: WindowSession,
        store: TmuxConnectionStore
    ) {
        for tab in tabs(of: directorySession, in: session) {
            TabActions.closeTab(session, registry: store.registry, tabID: tab.id, source: .mouse, confirm: false)
        }
    }

    /// The tabs of this window's session, in the session's own tab order.
    private static func tabs(of directorySession: TmuxDirectorySession, in session: WindowSession) -> [Tab] {
        session.tabs.filter { tab in
            mirrorRef(of: tab).map { TmuxConnectionStore.Key($0.binding) == directorySession.key } ?? false
        }
    }

    // MARK: - Making things in tmux

    /// Open a new window in this listed session and a mirror tab for it
    /// (⌃⌘T, design D1), through a short-lived client rather than through a
    /// mirror: the directory offers this for a session no tab shows, where
    /// there is no mirror to ask.
    ///
    /// `-d` leaves every client attached where it is: the window belongs to
    /// the tab about to open for it, not to whatever else shows the
    /// session.
    @discardableResult
    static func newWindowInSession(
        _ directorySession: TmuxDirectorySession,
        session: WindowSession,
        store: TmuxConnectionStore
    ) -> Task<Void, Never>? {
        guard let tmuxPath = store.tmuxExecutable, let binding = directorySession.binding else { return nil }
        return Task {
            let result = await runTmux(
                ["new-window", "-d", "-t", binding.sessionID, "-P", "-F", TmuxMirrorTargetLister.listFormat],
                tmuxPath: tmuxPath,
                socketPath: binding.socketPath
            )
            guard case let .success(output) = result,
                  let target = TmuxMirrorTargetLister.parse(output, socketPath: binding.socketPath).first
            else {
                log.error("new-window in \(binding.sessionID, privacy: .public) failed: \(String(describing: result), privacy: .public)")
                store.onNotice?(String(localized: "Couldn't open a new tmux window"))
                return
            }
            // Nothing else can be showing a window made a moment ago, so
            // there is no question about other clients to ask.
            open(target, session: session, store: store)
        }
    }

    // MARK: - Ending things in tmux

    /// What the user is asked before `kill-session` (design D4). The
    /// sibling of `QuitWindowPrompt`, and it says the same two things: what
    /// ends, and what closing the tabs instead would leave running.
    struct QuitSessionPrompt: Equatable {
        let title: String
        let message: String
        let confirmLabel: String

        init(name: String, windowCount: Int) {
            title = String(localized: "Quit the tmux session “\(name)”?")
            message = String(
                localized: """
                Everything running in its \(windowCount) windows ends, for every client showing them, \
                and every Limpid tab of this session closes. Closing those tabs instead leaves the \
                session running in tmux.
                """
            )
            confirmLabel = String(localized: "Quit Session")
        }
    }

    /// Ask, and on a yes end the listed session. What becomes of the tabs
    /// is left to the `%session-changed` and `%window-close` tmux answers
    /// with, the same route as a session killed from anywhere else, so the
    /// tabs close with the notice they would have had either way.
    @discardableResult
    static func quitSessionAsked(
        _ directorySession: TmuxDirectorySession,
        store: TmuxConnectionStore,
        confirm: @MainActor (QuitSessionPrompt) -> Bool = askAboutQuittingSession
    ) -> Task<Void, Never>? {
        guard let tmuxPath = store.tmuxExecutable, let binding = directorySession.binding else { return nil }
        let prompt = QuitSessionPrompt(name: directorySession.name, windowCount: directorySession.windows.count)
        guard confirm(prompt) else { return nil }
        log.notice("kill-session \(binding.sessionID, privacy: .public)")
        return Task {
            _ = await runTmux(
                guarded("kill-session", target: binding.sessionID, binding: binding),
                tmuxPath: tmuxPath,
                socketPath: binding.socketPath
            )
        }
    }

    static func askAboutQuittingSession(_ prompt: QuitSessionPrompt) -> Bool {
        LimpidConfirm.runDestructive(
            title: prompt.title,
            message: prompt.message,
            confirmLabel: prompt.confirmLabel
        )
    }

    /// Ask, and on a yes end the listed window, with the confirmation a
    /// mirror tab's chip uses. A window some tab shows goes through that
    /// tab, so tmux's answer takes the tab with it; a window no tab shows
    /// is ended through a short-lived client.
    @discardableResult
    static func quitWindowAsked(
        _ window: TmuxDirectoryWindow,
        session: WindowSession,
        store: TmuxConnectionStore,
        confirm: @MainActor (QuitWindowPrompt) -> Bool = askAboutQuittingWindow
    ) -> Task<Void, Never>? {
        let binding = window.target.binding
        if let mirror = store.liveMirror(showing: window.windowID, of: binding) {
            quitWindowAsked(tabID: mirror.tabID, session: session, store: store, confirm: confirm)
            return nil
        }
        guard let tmuxPath = store.tmuxExecutable else { return nil }
        // Never an agent's window: the directory leaves Limpid's own agent
        // servers out (design D6).
        guard confirm(QuitWindowPrompt(name: window.target.displayName, isAgent: false)) else { return nil }
        log.notice("kill-window \(window.windowID, privacy: .public)")
        return Task {
            _ = await runTmux(
                guarded("kill-window", target: window.windowID, binding: binding),
                tmuxPath: tmuxPath,
                socketPath: binding.socketPath
            )
        }
    }

    // MARK: - Short-lived clients

    /// Wrap a destructive command so tmux runs it only on the server run
    /// the directory listed, the way `TmuxClientProbe.selectPane` guards a
    /// click. Session and window ids are unique within a server run and
    /// start again when a server is replaced, so a list a few seconds old
    /// could otherwise name something on a new server. tmux evaluates the
    /// condition itself; no shell is involved.
    ///
    /// A binding without a recorded generation — a server too old to report
    /// `#{pid}` — runs the command unguarded, which is what every other
    /// path does with such a server.
    static func guarded(_ verb: String, target: String, binding: TmuxBinding) -> [String] {
        guard let pid = binding.serverPID, let startedAt = binding.serverStartedAt else {
            return [verb, "-t", target]
        }
        let condition = "#{&&:#{==:#{pid},\(pid)},#{==:#{start_time},\(startedAt)}}"
        return ["if-shell", "-F", "-t", target, condition, "\(verb) -t \(TmuxProtocol.quote(target))"]
    }

    /// One short-lived tmux client, off the main actor for the reason every
    /// other listing gives: it blocks on a child process.
    private nonisolated static func runTmux(
        _ arguments: [String],
        tmuxPath: String,
        socketPath: String
    ) async -> TmuxCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: TmuxCommand().run(
                        executable: tmuxPath,
                        arguments: TmuxCommand.clientArguments(socketPath: socketPath, arguments)
                    )
                )
            }
        }
    }
}
