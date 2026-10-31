// CodexTurnFailureTests.swift
// Weir — a failed Codex turn: the rollout lines the watcher reads, and the reset in a usage limit's message.

import Foundation
import Testing
@testable import Weir

struct CodexTurnFailureTests {
    private static let limited = #"{"timestamp":"2026-10-13T01:00:00.500Z","type":"event_msg","payload":{"type":"task_complete","#
        + #""error":{"message":"Try again at 10:29 AM.","codex_error_info":"usage_limit_exceeded"}}}"#
    private static let done = #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"ok"}}"#

    private static func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func append(_ text: String, to url: URL) throws {
        try append(Data(text.utf8), to: url)
    }

    private static func reader(over url: URL) -> RolloutReader {
        RolloutReader(path: url.path, offset: RolloutReader.size(of: url.path))
    }

    @Test func reader_readsOnlyWhatTheRolloutGainsAfterTheSessionStarted() throws {
        try withTempDir { directory in
            let url = directory.appendingPathComponent("rollout.jsonl")
            try Data((Self.limited + "\n").utf8).write(to: url)
            var reader = Self.reader(over: url)
            #expect(reader.readNewLines().isEmpty, "a failure before the session is not reported")

            try Self.append(Self.done + "\n" + Self.limited, to: url)
            #expect(reader.readNewLines() == [Substring(Self.done)], "a line not ended yet waits")
            try Self.append("\n", to: url)
            #expect(reader.readNewLines() == [Substring(Self.limited)])
        }
    }

    @Test func reader_aCharacterSplitBetweenReadsIsKept() throws {
        try withTempDir { directory in
            let url = directory.appendingPathComponent("rollout.jsonl")
            try Data().write(to: url)
            var reader = Self.reader(over: url)
            let line = Data(#"{"text":"上限"}"#.utf8)
            // Cut inside the three bytes of 上.
            try Self.append(line.prefix(11), to: url)
            #expect(reader.readNewLines().isEmpty)
            try Self.append(line.dropFirst(11) + Data("\n".utf8), to: url)
            #expect(reader.readNewLines() == [#"{"text":"上限"}"#])
        }
    }

    /// The Codex crate's own tests cover what it reads from a line. This one
    /// covers what crosses the bridge, which the watcher then reports.
    @Test func report_crossesTheBridgeWithTheMessageTheHostReads() throws {
        let report = try RustProviderBridge.turnFailureReport(
            provider: "codex",
            line: Data(Self.limited.utf8),
            transcriptPath: "/tmp/rollout.jsonl",
            sessionID: "session-a",
            readAt: Date(timeIntervalSince1970: 1_791_853_260)
        )
        let failure = try #require(report)
        #expect(failure.payload["hook_event_name"] as? String == "WeirTurnFailed")
        #expect(failure.payload["transcript_path"] as? String == "/tmp/rollout.jsonl")
        #expect(failure.payload["session_id"] as? String == "session-a")
        #expect(failure.writtenAt == Date(timeIntervalSince1970: 1_791_853_200), "the line's own time")
        #expect(failure.usageLimitMessage == "Try again at 10:29 AM.")

        // A failure on a line longer than any hook payload is still reported.
        let long = String(repeating: "x", count: 2 * 1024 * 1024)
        let longLine = Self.limited.replacingOccurrences(of: #""type":"event_msg""#, with: #""type":"event_msg","padding":"\#(long)""#)
        #expect(try RustProviderBridge.turnFailureReport(
            provider: "codex",
            line: Data(longLine.utf8),
            transcriptPath: "/tmp/rollout.jsonl",
            sessionID: "session-a",
            readAt: Date()
        ) != nil)
        #expect(failure.messageResetKey == "weir_message_resets_at")

        #expect(try RustProviderBridge.turnFailureReport(
            provider: "codex",
            line: Data(Self.done.utf8),
            transcriptPath: "/tmp/rollout.jsonl",
            sessionID: "session-a",
            readAt: Date()
        ) == nil)
    }

    @Test func reader_aLineThatIsNotTextIsPassedOver() throws {
        try withTempDir { directory in
            let url = directory.appendingPathComponent("rollout.jsonl")
            try Data().write(to: url)
            var reader = Self.reader(over: url)
            try Self.append(Data([0xFF, 0xFE, 0x0A]) + Data((Self.done + "\n").utf8), to: url)
            #expect(reader.readNewLines() == [Substring(Self.done)])
        }
    }

    @Test func reader_readsPastOneChunkToTheEnd() throws {
        try withTempDir { directory in
            let url = directory.appendingPathComponent("rollout.jsonl")
            try Data().write(to: url)
            var reader = Self.reader(over: url)
            let filler = String(repeating: "x", count: 1023) + "\n"
            let count = RolloutReader.chunkBytes / filler.utf8.count + 8
            try Self.append(String(repeating: filler, count: count) + Self.limited + "\n", to: url)
            let kept = reader.readNewLines(keeping: RolloutReader.mayBeFailureLine)
            #expect(kept.count == 1, "the filler is not kept")
            #expect(kept.last == Substring(Self.limited))
        }
    }

    @Test func reader_startsOverWhenTheFileIsReplaced() throws {
        try withTempDir { directory in
            let url = directory.appendingPathComponent("rollout.jsonl")
            try Data(String(repeating: "x", count: 50).utf8).write(to: url)
            var reader = Self.reader(over: url)
            // Replaced by a larger file, as a rewrite would.
            let other = directory.appendingPathComponent("other.jsonl")
            let first = String(repeating: "y", count: 80)
            try Data((first + "\n" + Self.limited + "\n").utf8).write(to: other)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: other)
            // The first line whole: from the old offset, its start is cut off.
            #expect(reader.readNewLines() == [Substring(first), Substring(Self.limited)])
        }
    }

    @Test func reader_aMissingFileReadsNothing() {
        var reader = RolloutReader(path: "/nonexistent/weir/rollout.jsonl", offset: 0)
        #expect(reader.readNewLines().isEmpty)
    }

    private static let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .gmt

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = tokyo
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func reset(_ message: String, writtenAt: String) throws -> Date? {
        try CodexUsageLimitMessage.resetAt(in: message, writtenAt: #require(date(writtenAt)), timeZone: tokyo)
    }

    /// A message, when its line was written, and the reset it names.
    struct ResetCase: Sendable, CustomTestStringConvertible {
        let message: String
        let writtenAt: String
        let resetsAt: String?

        var testDescription: String {
            message
        }
    }

    /// A time alone is on the day the line was written, however late the
    /// watcher reads it (after a sleep, past midnight); Codex dates any
    /// other day, and a message with no time names none.
    @Test(arguments: [
        ResetCase(
            message: "You've hit your usage limit. Try again at 10:29 AM.",
            writtenAt: "2026-10-13T09:00:00+09:00",
            resetsAt: "2026-10-13T10:29:00+09:00"
        ),
        ResetCase(message: "Try again at 12:05 PM.", writtenAt: "2026-10-13T09:00:00+09:00", resetsAt: "2026-10-13T12:05:00+09:00"),
        ResetCase(message: "Try again at 1:00 PM.", writtenAt: "2026-10-13T09:00:00+09:00", resetsAt: "2026-10-13T13:00:00+09:00"),
        ResetCase(message: "Try again at 12:30 AM.", writtenAt: "2026-10-13T00:10:00+09:00", resetsAt: "2026-10-13T00:30:00+09:00"),
        ResetCase(message: "Try again at 10:29 AM.", writtenAt: "2026-10-13T10:00:00+09:00", resetsAt: "2026-10-13T10:29:00+09:00"),
        ResetCase(message: "Try again at 11:59 PM.", writtenAt: "2026-10-13T23:59:55+09:00", resetsAt: "2026-10-13T23:59:00+09:00"),
        ResetCase(
            message: "You've hit your usage limit. Upgrade to Pro, or try again at Sep 15th, 2026 10:29 AM.",
            writtenAt: "2026-09-13T09:00:00+09:00",
            resetsAt: "2026-09-15T10:29:00+09:00"
        ),
        ResetCase(
            message: "Try again at Oct 1st, 2026 9:05 PM.",
            writtenAt: "2026-09-29T09:00:00+09:00",
            resetsAt: "2026-10-01T21:05:00+09:00"
        ),
        ResetCase(message: "You've hit your usage limit. Try again later.", writtenAt: "2026-10-13T09:00:00+09:00", resetsAt: nil),
        ResetCase(message: "Try again at noon.", writtenAt: "2026-10-13T09:00:00+09:00", resetsAt: nil)
    ])
    func message_namesItsReset(_ example: ResetCase) throws {
        #expect(try Self.reset(example.message, writtenAt: example.writtenAt) == example.resetsAt.flatMap(Self.date))
    }
}
