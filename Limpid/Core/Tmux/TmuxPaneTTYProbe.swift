// TmuxPaneTTYProbe.swift
// Limpid — reads a tmux pane's tty line discipline to tell whether it is taking a password.

import Darwin
import Foundation

/// For a local pane libghostty owns the pty and reports password prompts
/// itself. A mirror pane's pty belongs to tmux, so the same question is
/// answered by opening `#{pane_tty}` and reading its termios: canonical
/// mode with echo off is what `read -s`, `sudo`, and `ssh` set while they
/// wait for a secret.
enum TmuxPaneTTYProbe {
    /// `nil` when the tty cannot be inspected (the pane is gone, or it
    /// belongs to another user). The descriptor is opened without
    /// becoming the controlling terminal and closed before returning; a
    /// pty is reused for a later pane the moment this one exits.
    static func isSecureInput(tty: String) -> Bool? {
        let fd = open(tty, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var attributes = termios()
        guard tcgetattr(fd, &attributes) == 0 else { return nil }
        let canonical = attributes.c_lflag & UInt(ICANON) != 0
        let echoing = attributes.c_lflag & UInt(ECHO) != 0
        return canonical && !echoing
    }
}
