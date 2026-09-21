// TmuxDirectory.swift
// Limpid — the tmux sessions and windows the sidebar lists, and the model that keeps that list fresh.

import Foundation

/// One window of one session, as the sidebar's directory lists it.
struct TmuxDirectoryWindow: Identifiable, Equatable {
    /// Everything opening the window needs; the directory adds nothing to
    /// what the palette already opens a window from.
    let target: TmuxMirrorTarget
    /// What the row reads: `session:window`, with tmux's own window number
    /// added when the session holds more than one window of that name
    /// (design D9). Two windows called `zsh` are otherwise one row written
    /// twice, and the number is how the user finds them apart in tmux.
    let label: String

    /// A window id is unique per server, and a server is its socket.
    var id: String {
        "\(target.binding.socketPath)\u{1}\(target.windowID)"
    }

    var windowID: String {
        target.windowID
    }
}

/// One session in the directory, with the windows it holds.
struct TmuxDirectorySession: Identifiable, Equatable {
    /// Exactly how `TmuxConnectionStore` keys a connection, so what the row
    /// says about the connection is read with the same key the store filed
    /// it under (item 2-5).
    let key: TmuxConnectionStore.Key
    let name: String
    /// How the row names the server this session is on, or nil when there
    /// is nothing to say — see `TmuxDirectory.serverLabel`.
    let serverLabel: String?
    /// In tmux's own window order.
    let windows: [TmuxDirectoryWindow]

    var id: String {
        "\(key.socketPath)\u{1}\(key.sessionID)"
    }

    /// The session's binding, taken from any of its windows: every window
    /// of a session carries the same socket, session id and server
    /// generation. Nil only for a session with no windows, which tmux does
    /// not keep.
    var binding: TmuxBinding? {
        windows.first?.target.binding
    }
}

/// Turns what `TmuxMirrorTargetLister` reports into the sidebar's list.
/// Pure, so grouping, exclusion and the window limit are all checkable
/// without a tmux server.
enum TmuxDirectory {
    /// How many windows of one session the sidebar shows before it offers
    /// the rest behind one row. A directory is for finding a window again,
    /// not for reading a whole server: a session with forty windows would
    /// otherwise push Groups and Projects off the screen.
    static let windowLimit = 8

    /// The sessions to list, in the order the sidebar shows them: by name,
    /// then by socket so two sessions of one name on two servers keep a
    /// stable order.
    ///
    /// Limpid's own agent servers are left out (design D6). An agent runs
    /// in the background, and the Waiting region lists it in the user's
    /// words; this directory is the tmux the user set up themselves, and
    /// naming an agent's `limpid-…` session here would put tmux in front of
    /// someone who never chose it.
    static func sessions(
        from targets: [TmuxMirrorTarget],
        serverDirectory: URL = TmuxClientProbe.defaultServerDirectory()
    ) -> [TmuxDirectorySession] {
        let listed = targets.filter { !PaneShellEnvironment.isAgentSocketPath($0.binding.socketPath) }
        let grouped = Dictionary(grouping: listed) { TmuxConnectionStore.Key($0.binding) }
        return grouped.compactMap { key, targets -> TmuxDirectorySession? in
            guard let first = targets.first else { return nil }
            return TmuxDirectorySession(
                key: key,
                name: first.binding.sessionName,
                serverLabel: serverLabel(socketPath: key.socketPath, serverDirectory: serverDirectory),
                windows: windows(of: targets)
            )
        }
        .sorted { left, right in
            left.name == right.name
                ? left.key.socketPath < right.key.socketPath
                : left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// One session's windows, in tmux's window order, each labeled so no
    /// two rows of the session read the same (design D9). A window tmux
    /// listed without a number keeps its name alone: the number is what
    /// tells duplicates apart, and there is nothing to add when it is
    /// missing.
    private static func windows(of targets: [TmuxMirrorTarget]) -> [TmuxDirectoryWindow] {
        let ordered = targets.sorted { left, right in
            switch (left.windowIndex, right.windowIndex) {
            case let (.some(leftIndex), .some(rightIndex)) where leftIndex != rightIndex:
                leftIndex < rightIndex
            default:
                left.windowID.compare(right.windowID, options: .numeric) == .orderedAscending
            }
        }
        var counts: [String: Int] = [:]
        for target in ordered {
            counts[target.windowName, default: 0] += 1
        }
        return ordered.map { target in
            let isShared = counts[target.windowName, default: 0] > 1
            let label = isShared && target.windowIndex != nil
                // Punctuation rather than words: the row is as wide as the
                // sidebar, and tmux writes a window's number beside its
                // name in its own status line too.
                ? "\(target.displayName) (\(target.windowIndex ?? 0))"
                : target.displayName
            return TmuxDirectoryWindow(target: target, label: label)
        }
    }

    /// How a row names the server a session is on (decision M7, which the
    /// plan's appendix does not write down):
    ///
    /// - nothing for the default socket, which is the server the user gets
    ///   by typing `tmux` and the one they never named;
    /// - the socket's name for a server started with `-L name`, which is
    ///   the name they gave it;
    /// - the path for a server started with `-S path`, abbreviated with
    ///   `~`, because such a socket has no name of its own and its
    ///   directory is what tells two of them apart.
    ///
    /// The rule reads off the path alone: `-L name` is exactly a socket of
    /// that name inside tmux's server directory, so a socket elsewhere was
    /// addressed by path.
    static func serverLabel(
        socketPath: String,
        serverDirectory: URL = TmuxClientProbe.defaultServerDirectory()
    ) -> String? {
        let url = URL(fileURLWithPath: socketPath)
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().standardizedFileURL.path
            == serverDirectory.standardizedFileURL.path
        else {
            return (socketPath as NSString).abbreviatingWithTildeInPath
        }
        return name == defaultSocketName ? nil : name
    }

    /// What tmux calls the socket of a server started without `-L` or `-S`.
    static let defaultSocketName = "default"
}

/// The sidebar's tmux directory: which sessions exist, which of their
/// windows to show, and which rows are open.
///
/// It lists through `TmuxMirrorTargetLister`, the same `list-windows -a`
/// per socket the command palette uses, rather than holding a connection of
/// its own: a directory is a list of what is there, and a control client
/// per server would cost a process for every server the user has, connected
/// or not.
@MainActor
@Observable
final class TmuxDirectoryModel {
    /// How the model asks tmux. A closure so a test answers for a server
    /// without starting one.
    typealias Lister = @Sendable (_ tmuxPath: String) async -> [TmuxMirrorTarget]

    private(set) var sessions: [TmuxDirectorySession] = []
    /// Whether a listing has come back since the model was made. The
    /// section tells "nothing yet" from "no tmux sessions" by it, so an
    /// empty sidebar never claims the user has no sessions before anything
    /// has been asked.
    private(set) var hasListed = false
    /// Which sessions are open, by `TmuxDirectorySession.id`.
    var expandedSessionIDs: Set<String> = []
    /// Which sessions show every window rather than the first
    /// `TmuxDirectory.windowLimit`.
    var unfoldedSessionIDs: Set<String> = []

    /// How often the directory is listed while it is on screen and open.
    ///
    /// Five seconds. Each pass is one short-lived tmux client per server
    /// socket, which is the cost of a status line refresh, and tmux's own
    /// default `status-interval` is fifteen. A window opened in a terminal
    /// elsewhere should be findable here without the user reaching for a
    /// refresh, and a list this cheap is not worth a push channel: the
    /// events that matter to Limpid itself — a mirror tab opening or
    /// closing — refresh it at once rather than waiting for the next pass.
    static let refreshInterval: Duration = .seconds(5)

    @ObservationIgnored private let tmuxPath: String?
    @ObservationIgnored private let list: Lister
    /// A pass already running. Refreshing again on top of it would start a
    /// second client per socket for the same answer.
    @ObservationIgnored private var isListing = false

    init(tmuxPath: String?, list: @escaping Lister = TmuxDirectoryModel.listTargets) {
        self.tmuxPath = tmuxPath
        self.list = list
    }

    /// Whether this Mac has a tmux to list at all. Without one the section
    /// says so once rather than polling nothing.
    var hasTmux: Bool {
        tmuxPath != nil
    }

    /// List once. Silent about failure: a socket whose server hangs
    /// contributes nothing and the next pass is a few seconds away, which
    /// is the same answer a stale row would give.
    func refresh() async {
        guard let tmuxPath, !isListing else { return }
        isListing = true
        defer { isListing = false }
        let targets = await list(tmuxPath)
        sessions = TmuxDirectory.sessions(from: targets)
        hasListed = true
        // A session that is gone takes its open state with it, so a new
        // session that happens to reuse the id does not come up open.
        let ids = Set(sessions.map(\.id))
        expandedSessionIDs.formIntersection(ids)
        unfoldedSessionIDs.formIntersection(ids)
    }

    /// Keep listing until the caller's task is cancelled. Started only
    /// while the sidebar is on screen and the section is open (item 2-1):
    /// a directory nobody is looking at is a process per server for
    /// nothing.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: Self.refreshInterval)
            } catch {
                return
            }
        }
    }

    // MARK: - Rows

    func isExpanded(_ session: TmuxDirectorySession) -> Bool {
        expandedSessionIDs.contains(session.id)
    }

    func toggleExpanded(_ session: TmuxDirectorySession) {
        if expandedSessionIDs.contains(session.id) {
            expandedSessionIDs.remove(session.id)
        } else {
            expandedSessionIDs.insert(session.id)
        }
    }

    func showsEveryWindow(_ session: TmuxDirectorySession) -> Bool {
        unfoldedSessionIDs.contains(session.id)
    }

    func showEveryWindow(_ session: TmuxDirectorySession) {
        unfoldedSessionIDs.insert(session.id)
    }

    /// The windows drawn under `session`: all of them once the user has
    /// asked for the rest, and the first `TmuxDirectory.windowLimit`
    /// otherwise.
    func visibleWindows(of session: TmuxDirectorySession) -> [TmuxDirectoryWindow] {
        showsEveryWindow(session) ? session.windows : Array(session.windows.prefix(TmuxDirectory.windowLimit))
    }

    /// How many windows the limit is holding back, or zero.
    func hiddenWindowCount(of session: TmuxDirectorySession) -> Int {
        session.windows.count - visibleWindows(of: session).count
    }

    /// Dispatch rather than a detached task, for the reason
    /// `CommandPaletteActions.listTmuxWindows` gives: listing blocks on
    /// child processes, and a blocked cooperative-pool thread starves the
    /// runtime. The closure is formed in this nonisolated function so
    /// Dispatch never runs one that carries main-actor isolation.
    nonisolated static func listTargets(tmuxPath: String) async -> [TmuxMirrorTarget] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: TmuxMirrorTargetLister.targets(tmuxPath: tmuxPath))
            }
        }
    }
}
