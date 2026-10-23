// ReviewTerminalProbe.swift
// Limpid — what is in front on the terminal the feedback will reach.

import Foundation

/// Where review's text lands, and what is running there.
///
/// This reports; it does not gate. What keeps an unbracketed paste from being
/// run line by line is the confirmation sheet, not this probe — all the reader
/// needs from here is to see which terminal the text goes to and what is in
/// front on it. As a precondition it would refuse nearly every insertion.
///
/// Deliberately nonisolated: both calls block on a process or a `sysctl`, so
/// callers run them off the main actor.
enum ReviewTerminalProbe {
    /// The terminal that text written to a pane's surface reaches.
    ///
    /// An agent hosted in tmux does not run on the surface's pty: that one
    /// carries the tmux client, and the agent sits on a pane pty inside the
    /// server. Asking the surface tty what is in front would always answer
    /// "the tmux client", so the client's session is resolved first.
    ///
    /// Every failure falls back to the surface tty. Nothing is refused on that
    /// basis; the worst case is a chip that names the client.
    static func deliveryTTY(surfaceTTY: String, surfaceForeground: String? = nil) -> String {
        // Asked of the kernel first when the caller has already read it: a pane
        // that is not running a tmux client cannot be hosted in one, and the
        // scan below starts a process per socket on the machine. Nothing is
        // refused on this basis — an unknown foreground falls through.
        if let surfaceForeground, surfaceForeground != TmuxClientProbe.clientProcessName {
            return surfaceTTY
        }
        guard let tmuxPath = TmuxClientProbe.locateTmux() else { return surfaceTTY }
        let clients = TmuxClientProbe.attachedClients(
            tmuxPath: tmuxPath,
            serverDirectory: TmuxClientProbe.defaultServerDirectory()
        )
        // No client on this tty means the user is at the pane's own shell.
        guard let binding = clients[surfaceTTY] else { return surfaceTTY }
        return TmuxClientProbe.activePaneTTY(
            tmuxPath: tmuxPath,
            socketPath: binding.socketPath,
            sessionID: binding.sessionID
        ) ?? surfaceTTY
    }

    /// What is in front on the tmux pane behind each of `surfaceTTYs`, each
    /// a surface whose foreground is a tmux client, by surface tty. Lists
    /// the machine's attached clients once for all of them, since that
    /// starts a process per socket. Every failure reads the surface's own
    /// tty, as `deliveryTTY` falls back to it: tmux not found, no client on
    /// the tty, or no active pane for its session.
    static func hostedForegrounds(surfaceTTYs: [String]) -> [String: String] {
        let tmuxPath = TmuxClientProbe.locateTmux()
        let clients = tmuxPath.map {
            TmuxClientProbe.attachedClients(tmuxPath: $0, serverDirectory: TmuxClientProbe.defaultServerDirectory())
        } ?? [:]
        return hostedForegrounds(
            surfaceTTYs: surfaceTTYs,
            clients: clients,
            activePaneTTY: { binding in
                tmuxPath.flatMap {
                    TmuxClientProbe.activePaneTTY(tmuxPath: $0, socketPath: binding.socketPath, sessionID: binding.sessionID)
                }
            },
            foreground: { foregroundProcess(on: $0)?.name }
        )
    }

    /// `hostedForegrounds(surfaceTTYs:)` with its readings handed in: the
    /// attached clients by tty (empty without tmux), the active pane's tty
    /// of a client's session, and the command in front on a tty.
    static func hostedForegrounds(
        surfaceTTYs: [String],
        clients: [String: TmuxBinding],
        activePaneTTY: (TmuxBinding) -> String?,
        foreground: (String) -> String?
    ) -> [String: String] {
        var foregrounds: [String: String] = [:]
        for surfaceTTY in surfaceTTYs {
            let tty = clients[surfaceTTY].flatMap(activePaneTTY) ?? surfaceTTY
            foregrounds[surfaceTTY] = foreground(tty)
        }
        return foregrounds
    }

    /// The command in the foreground process group of `tty`
    /// (`ProcessNames.foregroundProcess(on:)`), by the kernel's accounting
    /// name as the reader would type it (`displayName`).
    static func foregroundProcess(on tty: String) -> (pid: Int32, name: String)? {
        ProcessNames.foregroundProcess(on: tty).map { ($0.pid, displayName($0.accountingName)) }
    }

    /// The kernel's accounting name is not always what the reader typed.
    /// Claude Code's single-file build reports `claude.exe` — the suffix comes
    /// from how the executable is packed and there is no such file on disk —
    /// and a login shell reports `-zsh`.
    static func displayName(_ comm: String) -> String {
        var name = comm
        if name.hasPrefix("-") {
            name.removeFirst()
        }
        if name.hasSuffix(".exe") {
            name.removeLast(4)
        }
        return name.isEmpty ? comm : name
    }
}
