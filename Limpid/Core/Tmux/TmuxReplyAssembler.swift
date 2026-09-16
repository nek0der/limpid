// TmuxReplyAssembler.swift
// Limpid — pairs `%begin` … `%end` / `%error` markers into whole replies; a value type with no I/O.

import Foundation

/// Folds the reply markers of a control-mode stream into complete replies.
///
/// tmux answers every command with a `%begin` block and closes it with
/// `%end` or `%error`; the lines in between are the command's output. It
/// also emits one such block on its own when the client attaches, before
/// any command was sent. That block must not be paired with the first
/// command, or every later reply would land one command late. The first
/// closed block is therefore reported as `attachFinished`, not as a reply.
struct TmuxReplyAssembler: Equatable {
    enum Event: Equatable {
        /// The attach block closed; commands sent from now on get their
        /// own replies in order.
        case attachFinished
        case reply(lines: [String], isError: Bool, marker: TmuxReplyMarker)
    }

    private var pending: [String]?
    private(set) var hasSeenAttachBlock = false

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
            if !hasSeenAttachBlock {
                hasSeenAttachBlock = true
                return .attachFinished
            }
            if case .error = line {
                return .reply(lines: lines, isError: true, marker: marker)
            }
            return .reply(lines: lines, isError: false, marker: marker)
        case let .text(text):
            pending?.append(text)
            return nil
        default:
            return nil
        }
    }
}
