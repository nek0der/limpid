// TmuxReplyAssembler.swift
// Limpid — pairs `%begin` … `%end` / `%error` markers into whole replies; a value type with no I/O.

import Foundation

/// Folds the reply markers of a control-mode stream into complete replies.
///
/// tmux wraps the output of every command it runs for a control client in
/// a `%begin` block and closes it with `%end` or `%error`. The marker's
/// flags field says who asked. 1 means a command this client wrote. 0
/// means a command tmux ran on its own: the attach itself, which always
/// comes first, and any `after-<command>` hook the user configured, which
/// arrives between our replies. Only flags-1 blocks answer our commands,
/// so they are the only ones reported as replies. The first flags-0 block
/// is the attach, and later ones answer nobody and are dropped.
struct TmuxReplyAssembler: Equatable {
    enum Event: Equatable {
        /// The attach block closed. With `isError` tmux refused the attach
        /// and `lines` says why; otherwise commands sent from now on get
        /// their own replies in order.
        case attachFinished(lines: [String], isError: Bool)
        case reply(lines: [String], isError: Bool, marker: TmuxReplyMarker)
    }

    private var pending: [String]?
    private var hasSeenAttachBlock = false

    /// True between a `%begin` and its closing marker.
    var isInsideBlock: Bool {
        pending != nil
    }

    /// Feed one classified line. Returns an event when a block closes; body
    /// lines are absorbed and yield nothing. Lines that are not part of a
    /// block (`%output`, notifications) are ignored here and stay the
    /// caller's to route.
    mutating func consume(_ line: TmuxControlLine) -> Event? {
        switch line {
        case .begin:
            pending = []
            return nil
        case let .end(marker), let .error(marker):
            let lines = pending ?? []
            pending = nil
            var isError = false
            if case .error = line {
                isError = true
            }
            if marker.isClientCommand {
                return .reply(lines: lines, isError: isError, marker: marker)
            }
            guard !hasSeenAttachBlock else { return nil }
            hasSeenAttachBlock = true
            return .attachFinished(lines: lines, isError: isError)
        case let .text(text):
            pending?.append(text)
            return nil
        default:
            return nil
        }
    }
}
