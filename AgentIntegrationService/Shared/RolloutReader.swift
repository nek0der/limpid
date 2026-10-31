// RolloutReader.swift
// Weir — reads the lines a Codex rollout gains, and the reset a usage limit names.

import Foundation

/// Reads the lines a rollout gains after `offset`, the size it had when its
/// session started: a failure before is not this watcher's to report.
struct RolloutReader {
    let path: String
    private var offset: UInt64
    /// The file read, so a rollout replaced by another (which may be larger)
    /// is read from its start.
    private var inode: UInt64?
    /// The start of a line whose end was not written yet, kept as bytes: a
    /// read can end inside a character.
    private var partial = Data()

    /// The most bytes read at once; a pass reads on to the end in chunks of
    /// this size.
    static let chunkBytes = 4 * 1024 * 1024
    /// The longest unended line kept. A failure line is short; a longer one
    /// (a tool's whole output on one line) is dropped rather than held.
    static let maximumPartialBytes = 1024 * 1024

    init(path: String, offset: UInt64) {
        self.path = path
        self.offset = offset
        inode = Self.inode(of: path)
    }

    /// The size of the file at `path` now; 0 when there is none.
    static func size(of path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
    }

    private static func inode(of path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? UInt64) ?? nil
    }

    /// The event a turn ends with, which the Codex crate names too
    /// (`rust/fixtures/contract/shared-values.json`).
    static let turnEndEvent = "task_complete"

    /// Whether a line can be a failure at all, checked as text, so a pass
    /// hands the Codex crate only the few lines that can: a turn's end.
    static func mayBeFailureLine(_ line: Substring) -> Bool {
        line.contains(turnEndEvent)
    }

    /// The lines added since the last read that `keep` keeps, read on to
    /// the end. Lines it does not keep are dropped chunk by chunk, so a
    /// large burst (a tool's output, an image) is not held all at once.
    mutating func readNewLines(keeping keep: (Substring) -> Bool = { _ in true }) -> [Substring] {
        let current = Self.inode(of: path)
        if current != inode {
            inode = current
            offset = 0
            partial = Data()
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        // A file that shrank was truncated; it is read from its start.
        if end < offset {
            offset = 0
            partial = Data()
        }
        guard end > offset, (try? handle.seek(toOffset: offset)) != nil else { return [] }
        var lines: [Substring] = []
        while offset < end, let data = try? handle.read(upToCount: Self.chunkBytes), !data.isEmpty {
            offset += UInt64(data.count)
            lines += split(partial + data).filter(keep)
        }
        return lines
    }

    /// The whole lines of `bytes`, keeping what follows the last newline.
    private mutating func split(_ bytes: Data) -> [Substring] {
        var rest = bytes[...]
        var lines: [Substring] = []
        while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
            // A line that is not text says nothing the watcher reads.
            if let text = String(bytes: rest[rest.startIndex..<newline], encoding: .utf8) {
                lines.append(Substring(text))
            }
            rest = rest[rest.index(after: newline)...]
        }
        partial = rest.count > Self.maximumPartialBytes ? Data() : Data(rest)
        return lines
    }
}

/// Codex's message when its usage limit ends a turn names the reset in the
/// time zone Codex runs in: "… try again at 10:29 AM." when the reset falls
/// on the day the message was written, "… try again at Sep 15th, 2026 10:29
/// AM." on any other (`codex-rs` formats it with `%-I:%M %p` and `%b
/// %-d<ordinal>, %Y %-I:%M %p`). The watcher reads it in Codex's own time
/// zone, which it runs in, so the record holds the instant rather than a
/// time of day to be placed later.
enum CodexUsageLimitMessage {
    /// The reset `message` names, written at `writtenAt` (the line's own
    /// time); `nil` when it names none ("Try again later.") or in a form
    /// this build does not know.
    static func resetAt(in message: String, writtenAt: Date, timeZone: TimeZone) -> Date? {
        guard let range = message.range(of: "try again at ", options: .caseInsensitive) else { return nil }
        var text = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") {
            text.removeLast()
        }
        // "Sep 15th, 2026" → "Sep 15, 2026": the formatter has no ordinals.
        text = text.replacingOccurrences(of: #"(\d)(st|nd|rd|th),"#, with: "$1,", options: .regularExpression)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.dateFormat = "h:mm a"
        guard let time = formatter.date(from: text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        // A time alone is on the day the message was written, never the
        // next: Codex dates any other day. When the watcher reads it (after
        // a sleep, past midnight) does not move it, and a reset found past
        // is a limit that has ended.
        return calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: writtenAt)
    }
}
