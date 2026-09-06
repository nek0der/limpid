// TmuxPanePresence.swift
// Limpid — which panes are showing tmux right now, so the tab column can
// mark them. This cannot be read off the agent lifecycle records: those
// only exist where an agent is running, and a shell the user put into
// tmux by hand has no agent and therefore no record. libghostty reports
// the process in the foreground of a surface's pty, and a pane showing
// tmux has the tmux client there — the client owns the pty and whatever
// the session runs sits behind it.

import Foundation
import OSLog

@MainActor
@Observable
final class TmuxPanePresence {
    /// Panes whose pty has a tmux client in the foreground. Empty until
    /// the first poll, so the mark appears rather than flickering off.
    private(set) var paneIDs: Set<UUID> = []

    /// Two seconds is the compromise: close enough behind a `tmux` typed
    /// at the prompt to read as immediate, and each poll costs one
    /// `proc_name` per mounted pane — a syscall, not a process spawn, so
    /// the tick stays cheaper than the tmux the probe at quit shells out
    /// to.
    nonisolated static let pollInterval: TimeInterval = 2

    /// What `proc_name` reports for a tmux client. It truncates to
    /// `MAXCOMLEN`, which this is well inside, and it is already a
    /// basename so an install path never reaches the comparison.
    nonisolated static let clientProcessName = "tmux"

    private var timer: Timer?
    private weak var registry: (any SurfaceViewProviding)?
    private weak var session: WindowSession?
    private static let log = Logger(subsystem: "dev.limpid", category: "tmux.presence")

    init() {}

    /// Begin polling. Both collaborators are held weakly: this store
    /// outlives neither, and a timer that kept them alive would pin a
    /// closed window's surfaces.
    func start(registry: any SurfaceViewProviding, session: WindowSession) {
        self.registry = registry
        self.session = session
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Best-effort, like the agent pid sweep: drift costs nothing and
        // letting the system coalesce the wakeups is worth more than a
        // punctual tick.
        timer.tolerance = Self.pollInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Recompute from the surfaces that are mounted right now. A pane
    /// with no surface yet contributes nothing rather than dropping out
    /// of a set it was never in.
    func refresh() {
        guard let registry, let session else { return }
        var found: Set<UUID> = []
        for paneID in session.tabs.flatMap({ $0.splitTree.allLeafIDs() }) {
            guard let surface = registry.view(for: paneID)?.surface,
                  let pid = GhosttyFFI.surfaceForegroundPID(surface),
                  Self.processName(of: pid) == Self.clientProcessName
            else { continue }
            found.insert(paneID)
        }
        if found != paneIDs {
            paneIDs = found
            Self.log.notice("tmux panes: \(found.count, privacy: .public)")
        }
    }

    /// Executable name for a pid, or `nil` when the process is gone or
    /// belongs to someone else. `proc_name` is a syscall — the point of
    /// using it rather than asking tmux is that this runs on a timer.
    nonisolated static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = proc_name(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
