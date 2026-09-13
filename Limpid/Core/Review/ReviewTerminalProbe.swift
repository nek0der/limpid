// ReviewTerminalProbe.swift
// Limpid — what is in front on the terminal the feedback will reach.

import Foundation

/// Where review's text lands, and what is running there.
///
/// This reports; it does not gate. What keeps an unbracketed paste from being
/// run line by line is the confirmation sheet, not this probe — all the reader
/// needs from here is to see which terminal the text goes to and what is in
/// front on it. An earlier version made that a precondition and refused every
/// insertion, which is the opposite of useful.
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

    /// The current directory inside the tmux pane driven by `surfaceTTY`.
    ///
    /// `nil` is deliberately distinct from the outer shell's directory. If
    /// the client detached or the server stopped answering, insertion must be
    /// refused rather than validated against a terminal it will not reach.
    static func hostedWorkingDirectory(
        surfaceTTY: String,
        surfaceForeground: String? = nil,
        knownBinding: TmuxBinding? = nil
    ) -> String? {
        if let surfaceForeground, surfaceForeground != TmuxClientProbe.clientProcessName {
            return nil
        }
        guard let tmuxPath = TmuxClientProbe.locateTmux() else { return nil }
        var socketPaths = TmuxClientProbe.socketPaths(
            inServerDirectory: TmuxClientProbe.defaultServerDirectory()
        )
        if let knownBinding {
            let knownPath = TmuxClientProbe.normalizeSocketPath(knownBinding.socketPath)
            if !socketPaths.contains(where: { TmuxClientProbe.normalizeSocketPath($0.path) == knownPath }) {
                socketPaths.append(URL(fileURLWithPath: knownPath))
            }
        }
        let clients = TmuxClientProbe.attachedClients(
            tmuxPath: tmuxPath,
            socketPaths: socketPaths
        )
        guard let binding = clients[surfaceTTY] else { return nil }
        return TmuxClientProbe.activePanePath(
            tmuxPath: tmuxPath,
            socketPath: binding.socketPath,
            sessionID: binding.sessionID
        )
    }

    /// The command in the foreground process group of `tty`.
    ///
    /// `KERN_PROC_TTY` lists every process whose controlling terminal is that
    /// device; the foreground one is where its process group matches the
    /// terminal's. We ask the kernel about the processes rather than the
    /// terminal because `tcgetpgrp` is `ioctl(TIOCGPGRP)`, which XNU answers
    /// only for the caller's own controlling terminal — and a windowed app has
    /// none.
    static func foregroundProcess(on tty: String) -> (pid: Int32, name: String)? {
        var device = stat()
        guard tty.hasPrefix("/dev/"), stat(tty, &device) == 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(device.st_rdev)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 1
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return nil }
        let count = size / MemoryLayout<kinfo_proc>.stride
        let foreground = processes.prefix(count).filter {
            $0.kp_eproc.e_pgid == $0.kp_eproc.e_tpgid && $0.kp_eproc.e_tpgid > 1
        }
        // An agent running a tool puts several processes in the same group.
        // The leader is the one worth naming: "claude", not the helper it spawned.
        guard let process = foreground.first(where: { $0.kp_proc.p_pid == $0.kp_eproc.e_pgid })
            ?? foreground.first
        else { return nil }
        return (process.kp_proc.p_pid, name(of: process))
    }

    /// `p_comm` is a fixed-size C array, which Swift imports as a tuple.
    private static func name(of process: kinfo_proc) -> String {
        var command = process.kp_proc.p_comm
        let raw = withUnsafeBytes(of: &command) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return displayName(raw)
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
