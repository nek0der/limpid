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
        /// The stream broke a rule that pairing rests on. Nothing here can
        /// re-synchronize: which command a later block answers is no longer
        /// derivable, so the caller ends the connection.
        case broken(Violation)
    }

    /// A stream that is not the ordered sequence of closed blocks the
    /// protocol describes.
    enum Violation: Equatable {
        /// A `%begin` arrived while a block was still open. tmux runs one
        /// command at a time for a control client and never nests blocks,
        /// so the line before it was taken for something it was not.
        case nestedBegin(begin: TmuxReplyMarker, open: TmuxReplyMarker)
        /// A terminator arrived with no block open. Taking it for a reply
        /// would hand the oldest command an answer that is not its own.
        case terminatorWithoutBegin(TmuxReplyMarker)
        /// A block numbered at or below the block before it. tmux numbers
        /// them per server and strictly increasing, so this is either a
        /// repeat or a reordering, and the block a reply belongs to can no
        /// longer be told.
        case numberNotIncreasing(begin: TmuxReplyMarker, previous: Int)
    }

    /// The `%begin` of the block being read, and the lines read so far.
    private struct Block: Equatable {
        let begin: TmuxReplyMarker
        var lines: [String] = []
    }

    private var pending: Block?
    private var hasSeenAttachBlock = false
    /// The number of the last `%begin` we read. tmux numbers blocks per
    /// server, so the numbers of one client's blocks have gaps (299, 305,
    /// 306, 309 in the recorded session) and only their order is ours to
    /// check.
    private var lastBeginNumber: Int?

    /// The marker of the block between its `%begin` and its terminator, or
    /// `nil` outside a block. The line parser needs it to tell the
    /// terminator from a row of the reply that reads like one
    /// (`TmuxProtocol.parseLine`).
    var openBlock: TmuxReplyMarker? {
        pending?.begin
    }

    /// Feed one classified line. Returns an event when a block closes; body
    /// lines are absorbed and yield nothing. Lines that are not part of a
    /// block (`%output`, notifications) are ignored here and stay the
    /// caller's to route.
    mutating func consume(_ line: TmuxControlLine) -> Event? {
        switch line {
        case let .begin(marker):
            if let open = pending?.begin {
                return .broken(.nestedBegin(begin: marker, open: open))
            }
            if let previous = lastBeginNumber, marker.number <= previous {
                return .broken(.numberNotIncreasing(begin: marker, previous: previous))
            }
            lastBeginNumber = marker.number
            pending = Block(begin: marker)
            return nil
        case let .end(marker), let .error(marker):
            guard let block = pending else {
                return .broken(.terminatorWithoutBegin(marker))
            }
            let lines = block.lines
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
            pending?.lines.append(text)
            return nil
        default:
            return nil
        }
    }
}
