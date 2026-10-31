// CodexTurnFailureTests.swift
// Limpid — a failed Codex turn: the rollout lines the watcher reads, and the reset in a usage limit's message.

import Foundation
import Testing
@testable import Limpid

struct CodexTurnFailureTests {
    private static let limited = #"{"timestamp":"2026-10-13T01:00:00.500Z","type":"event_msg","payload":{"type":"task_complete","#
        + #""error":{"message":"Try again at 10:29 AM.","codex_error_info":"usage_limit_exceeded"}}}"#
    private static let limitedLine = RolloutReader.FailureLine(
        kind: "usage_limit_exceeded",
        message: "Try again at 10:29 AM.",
        writtenAt: Date(timeIntervalSince1970: 1_791_853_200.5)
    )
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
            #expect(reader.readNewLines().compactMap(RolloutReader.failureLine(in:)) == [Self.limitedLine])
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

    /// The report names the session the watcher read and when the turn
    /// failed, so the hook runtime can tell a report about an earlier
    /// conversation or turn from one about the run as it is, and the kind,
    /// which stands when the rollout cannot be read again.
    @Test func report_namesTheSessionTheKindAndWhenTheTurnFailed() {
        let readAt = Date(timeIntervalSince1970: 1_791_853_260)
        let payload = CodexTurnFailureReport.payload(
            rollout: "/tmp/rollout.jsonl",
            sessionID: "session-a",
            line: Self.limitedLine,
            readAt: readAt,
            messageResetAt: Date(timeIntervalSince1970: 1_791_854_940)
        )
        #expect(payload["hook_event_name"] as? String == "LimpidTurnFailed")
        #expect(payload["transcript_path"] as? String == "/tmp/rollout.jsonl")
        #expect(payload["session_id"] as? String == "session-a")
        #expect(payload[CodexTurnFailureReport.failedAtKey] as? Int == 1_791_853_200, "the line's own second")
        #expect(payload[CodexTurnFailureReport.errorKindKey] as? String == "usage_limit_exceeded")
        #expect(payload[CodexTurnFailureReport.messageResetKey] as? Int == 1_791_854_940)

        let undated = CodexTurnFailureReport.payload(
            rollout: "/tmp/rollout.jsonl",
            sessionID: "session-a",
            line: RolloutReader.FailureLine(kind: nil, message: nil, writtenAt: nil),
            readAt: readAt,
            messageResetAt: nil
        )
        #expect(undated[CodexTurnFailureReport.failedAtKey] as? Int == 1_791_853_260, "no later than the read")
        #expect(undated[CodexTurnFailureReport.errorKindKey] == nil)
        #expect(undated[CodexTurnFailureReport.messageResetKey] == nil)
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
            #expect(kept.last.flatMap(RolloutReader.failureLine(in:)) != nil)
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
        var reader = RolloutReader(path: "/nonexistent/limpid/rollout.jsonl", offset: 0)
        #expect(reader.readNewLines().isEmpty)
    }

    /// Only a turn that failed counts, whatever the failure, never a turn
    /// that ended on its own or an answer that quotes the words.
    @Test func failureLine_isATaskCompleteWithAnErrorOnly() {
        #expect(RolloutReader.failureLine(in: Substring(Self.limited)) == Self.limitedLine)
        #expect(Self.limitedLine.isUsageLimit)
        #expect(RolloutReader.failureLine(in: Substring(Self.done)) == nil)
        let quoted = #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"usage_limit_exceeded"}}"#
        #expect(RolloutReader.failureLine(in: Substring(quoted)) == nil)
        let notAnEvent = #"{"type":"response_item","payload":{"type":"task_complete","#
            + #""error":{"codex_error_info":"usage_limit_exceeded"}}}"#
        #expect(RolloutReader.failureLine(in: Substring(notAnEvent)) == nil)
        let bare = #"{"type":"event_msg","payload":{"type":"task_complete","error":{"codex_error_info":"usage_limit_exceeded"}}}"#
        #expect(RolloutReader.failureLine(in: Substring(bare)) == RolloutReader.FailureLine(
            kind: "usage_limit_exceeded",
            message: nil,
            writtenAt: nil
        ))
        // Taken from what Codex CLI 0.165.0 wrote for a model it does not have.
        let model = #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":null,"#
            + #""error":{"message":"The 'no-such-model' model is not supported.","codex_error_info":"model_not_found"}}}"#
        let modelLine = RolloutReader.failureLine(in: Substring(model))
        #expect(modelLine?.kind == "model_not_found")
        #expect(modelLine?.isUsageLimit == false)
        let detailed = #"{"type":"event_msg","payload":{"type":"task_complete","#
            + #""error":{"message":"lost","codex_error_info":{"http_connection_failed":{"http_status_code":502}}}}}"#
        #expect(RolloutReader.failureLine(in: Substring(detailed))?.kind == "http_connection_failed")
        let unnamed = #"{"type":"event_msg","payload":{"type":"task_complete","error":{"message":"Something broke."}}}"#
        #expect(RolloutReader.failureLine(in: Substring(unnamed)) == RolloutReader.FailureLine(
            kind: nil,
            message: "Something broke.",
            writtenAt: nil
        ))
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
