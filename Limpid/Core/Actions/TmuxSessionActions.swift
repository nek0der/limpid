// TmuxSessionActions.swift
// Limpid — the tmux verbs that start from something other than a mirror tab: a new session, and the session a pane is attached to by hand.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.session")

/// Actions on tmux sessions rather than on the window a mirror tab shows.
///
/// `TmuxMirrorActions` acts on a tab that already mirrors a window; these
/// two start from elsewhere — the palette (a session that does not exist
/// yet) and a pane the user typed `tmux attach` into (design D2 and D5) —
/// and hand what they find to the same opening path.
///
/// Every decision a menu or a palette row needs is a pure function here, so
/// the reason an item is disabled is written once and read by both.
@MainActor
enum TmuxSessionActions {

    // MARK: - New window (D1)

    /// Why "New tmux Window" cannot run, in the few words that trail the
    /// item's title, or nil when it can. A disabled menu item shows no
    /// tooltip, so the reason has to be part of what is drawn — the rule
    /// the Pane menu's reconnect item and the toolbar chip both follow.
    ///
    /// The wording is the chip's, because the two disable the same item for
    /// the same reasons; what the chip never has to say is the first case,
    /// since it is only drawn for a mirror tab at all.
    nonisolated static func newWindowObstacle(
        isMirrorTab: Bool,
        connection: TmuxTabConnection?,
        hasLiveMirror: Bool
    ) -> String? {
        guard isMirrorTab else {
            return String(localized: "not a tmux tab", comment: "why a tmux menu item is disabled")
        }
        guard !hasLiveMirror else { return nil }
        return connection == .connecting
            ? String(localized: "connecting", comment: "why a tmux menu item is disabled")
            : String(localized: "not connected", comment: "why a tmux menu item is disabled")
    }

    /// The same question asked of the live session: whether the active tab
    /// is a mirror that carries commands right now.
    static func newWindowObstacle(session: WindowSession, store: TmuxConnectionStore?) -> String? {
        guard let store, let tab = session.activeTab, TmuxMirrorActions.mirrorRef(of: tab) != nil else {
            return newWindowObstacle(isMirrorTab: false, connection: nil, hasLiveMirror: false)
        }
        return newWindowObstacle(
            isMirrorTab: true,
            connection: store.tabConnections[tab.id],
            hasLiveMirror: store.liveMirror(for: tab.id) != nil
        )
    }

    /// Open a window in the session the active tab shows. Nothing happens
    /// when the tab is not one that can carry the command; the menu item
    /// and the palette row that run this are disabled in that case, so
    /// reaching here means the state changed since the item was drawn.
    static func newWindow(session: WindowSession, store: TmuxConnectionStore?) {
        guard let store, let tabID = session.activeTabID else { return }
        TmuxMirrorActions.newWindow(tabID: tabID, session: session, store: store)
    }

    // MARK: - New session (D2)

    /// Why a new session cannot be started on this Mac, or nil. The same
    /// answer a reconnect gets: a session Limpid cannot mirror is one it
    /// has no way to show, so it does not offer to make one.
    nonisolated static func newSessionObstacle(support: AgentTmuxSupport, hasTmux: Bool) -> String? {
        if let obstacle = support.reconnectObstacle {
            return obstacle
        }
        return hasTmux ? nil : String(localized: "no tmux found")
    }

    /// The socket every session the user makes here lives on: tmux's own
    /// default server. A session started anywhere else would be one they
    /// could not reach with a bare `tmux attach`.
    nonisolated static func defaultSocketPath(
        directory: URL = TmuxClientProbe.defaultServerDirectory()
    ) -> String {
        TmuxClientProbe.normalizeSocketPath(directory.appendingPathComponent("default").path)
    }

    /// `new-session -d`, printing the new session in the listing format, so
    /// the one line it answers with parses as the target to open.
    ///
    /// Detached: the tab Limpid opens afterwards is the client, and a
    /// session started attached would hold the terminal this process does
    /// not have.
    nonisolated static func newSessionArguments(
        socketPath: String,
        workingDirectory: URL?,
        isNamed: Bool = true
    ) -> [String] {
        var command = ["new-session", "-d"]
        if let workingDirectory {
            command += ["-c", workingDirectory.path]
            if isNamed, let name = sessionName(for: workingDirectory) {
                command += ["-s", name]
            }
        }
        command += ["-P", "-F", TmuxMirrorTargetLister.listFormat]
        return TmuxCommand.clientArguments(socketPath: socketPath, command)
    }

    /// What the session a pane is attached to is showing: the format
    /// expanded against that session, which resolves to its current window
    /// and that window's active pane.
    nonisolated static func currentWindowArguments(socketPath: String, sessionID: String) -> [String] {
        TmuxCommand.clientArguments(
            socketPath: socketPath,
            ["display-message", "-p", "-t", sessionID, TmuxMirrorTargetLister.listFormat]
        )
    }

    /// What to call a session started in `workingDirectory`: the directory's
    /// own name, which is how the user thinks of the work in it, or nil when
    /// nothing usable is left of it.
    ///
    /// tmux reads `.` and `:` in a target as the separators of
    /// `session:window.pane`, so a name carrying either cannot be addressed;
    /// they become hyphens rather than costing the name.
    nonisolated static func sessionName(for workingDirectory: URL) -> String? {
        let name = workingDirectory.lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Start a detached session on the default socket with the active
    /// container's working directory, and show it as a mirror tab (D2).
    ///
    /// The session is made before any tab is opened, as a new window is
    /// (`TmuxMirrorActions.newWindow`), so a refusal leaves no empty tab
    /// behind. Nothing is asked about other clients: the session was made a
    /// moment ago and nothing else can be attached to it yet.
    ///
    /// Returns the task that finishes opening, so a test can wait for it.
    @discardableResult
    static func newSession(
        session: WindowSession,
        store: TmuxConnectionStore,
        socketPath: String = defaultSocketPath(),
        run: @escaping @Sendable ([String], String) async -> TmuxCommandResult = runTmux
    ) -> Task<Void, Never>? {
        guard let tmuxPath = store.tmuxExecutable else { return nil }
        let directory = session.containerWorkingDirectory(session.activeContainerID)
        let arguments = newSessionArguments(socketPath: socketPath, workingDirectory: directory)
        return Task {
            var result = await run(arguments, tmuxPath)
            // tmux refuses a name it already has. The directory is what the
            // name was for, and a second session in it is as reasonable as
            // the first, so the retry keeps the directory and lets tmux
            // number the session itself.
            if case .success = result {} else {
                result = await run(
                    newSessionArguments(socketPath: socketPath, workingDirectory: directory, isNamed: false),
                    tmuxPath
                )
            }
            guard case let .success(output) = result,
                  let target = TmuxMirrorTargetLister.parse(output, socketPath: socketPath).first
            else {
                log.error("new-session refused: \(String(describing: result), privacy: .public)")
                store.onNotice?(String(localized: "Couldn't start a new tmux session"))
                return
            }
            TmuxMirrorActions.open(target, session: session, store: store)
        }
    }

    // MARK: - The session a pane runs by hand (D5)

    /// The session a pane is attached to by hand, or nil when the pane is
    /// not running a tmux client or the poll has not resolved which session
    /// it shows yet.
    ///
    /// A pane of a mirror tab is not one: that tab already is the window in
    /// a Limpid tab, and the pane's tty belongs to Limpid's own client.
    static func manualSession(
        paneID: UUID,
        session: WindowSession,
        presence: TmuxPanePresence
    ) -> TmuxBinding? {
        manualSession(
            isMirrorTab: session.tab(containing: paneID)?.kind == .tmuxMirror,
            isTmuxClient: presence.paneIDs.contains(paneID),
            binding: presence.bindingsByPaneID[paneID]
        )
    }

    /// The rule itself, apart from the poll: a pane is one to offer this
    /// for when it runs a tmux client of the user's own and the poll has
    /// resolved which session that client shows. A pane with a client but
    /// no binding yet is left alone rather than offered a tab that could
    /// not be filled.
    nonisolated static func manualSession(
        isMirrorTab: Bool,
        isTmuxClient: Bool,
        binding: TmuxBinding?
    ) -> TmuxBinding? {
        guard !isMirrorTab, isTmuxClient else { return nil }
        return binding
    }

    /// Show the session `paneID` is attached to in a tab of its own (D5).
    ///
    /// The window the session is on is asked for first, because a binding
    /// only names the session: the user is looking at one window of it, and
    /// that is the one the tab shows. From there this is the palette's own
    /// opening path, which detaches the client in this pane and says so —
    /// the pane returns to its shell with its scrollback.
    ///
    /// Returns the task that finishes opening, so a test can wait for it.
    @discardableResult
    static func showSessionInTab(
        paneID: UUID,
        session: WindowSession,
        store: TmuxConnectionStore,
        presence: TmuxPanePresence,
        run: @escaping @Sendable ([String], String) async -> TmuxCommandResult = runTmux
    ) -> Task<Void, Never>? {
        guard let binding = manualSession(paneID: paneID, session: session, presence: presence),
              let tmuxPath = store.tmuxExecutable
        else { return nil }
        let arguments = currentWindowArguments(socketPath: binding.socketPath, sessionID: binding.sessionID)
        return Task {
            let result = await run(arguments, tmuxPath)
            guard case let .success(output) = result,
                  let target = TmuxMirrorTargetLister.parse(output, socketPath: binding.socketPath).first
            else {
                log.error("no window for a pane's session: \(String(describing: result), privacy: .public)")
                store.onNotice?(String(localized: "Couldn't find the tmux session in this pane"))
                return
            }
            TmuxMirrorActions.openFromPalette(target, session: session, store: store)
        }
    }

    // MARK: - Running tmux

    /// A dispatch queue rather than a detached task, for the reason the
    /// palette's listing uses one: these block on a child process, and
    /// blocking a cooperative-pool thread starves the concurrency runtime.
    ///
    /// The whole poll budget rather than a query's half second: starting a
    /// server costs more than asking one that is already running.
    nonisolated static func runTmux(arguments: [String], tmuxPath: String) async -> TmuxCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: TmuxCommand().run(
                        executable: tmuxPath,
                        arguments: arguments,
                        timeout: TmuxTiming.pollBudget
                    )
                )
            }
        }
    }
}
