// AgentDateParsingTests.swift
// Weir — pins the ISO-8601 instants the projection boundary reads and writes.

import Foundation
import Testing
@testable import Weir

/// Every producer of these instants (the Rust `format_utc_seconds`, and
/// `formatISO8601` itself) writes UTC with whole seconds and no fraction, so
/// that is the shape these tests pin, along with what the boundary has always
/// refused.
struct AgentDateParsingTests {
    /// 2026-10-22T12:34:56Z.
    private static let instant = Date(timeIntervalSince1970: 1_792_672_496)

    @Test func parse_wholeSecondsUTC_readsTheInstant() {
        #expect(AgentDateParsing.parseISO8601("2026-10-22T12:34:56Z") == Self.instant)
        #expect(AgentDateParsing.parseISO8601("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(AgentDateParsing.parseISO8601("2000-02-29T00:00:01Z") == Date(timeIntervalSince1970: 951_782_401))
    }

    /// No producer writes an offset, and the Rust reader refuses one. We pin
    /// what `ISO8601DateFormatter` does with one only so that a change of
    /// parser shows up here; it is a record of behavior, not the contract.
    @Test func parse_anOffset_isAcceptedThoughNoProducerWritesOne() {
        #expect(AgentDateParsing.parseISO8601("2026-10-22T21:34:56+09:00") == Self.instant)
    }

    @Test func parse_aFractionOrAnIncompleteTime_isRejected() {
        // No producer writes a fraction, and the Rust reader refuses one (as
        // it refuses an offset). The Swift side has always refused a
        // fraction, so we keep that refusal rather than read a value the
        // rules would not.
        #expect(AgentDateParsing.parseISO8601("2026-10-22T12:34:56.789Z") == nil)
        #expect(AgentDateParsing.parseISO8601("2026-10-22T12:34:56") == nil)
        #expect(AgentDateParsing.parseISO8601("2026-10-22") == nil)
        #expect(AgentDateParsing.parseISO8601("") == nil)
        #expect(AgentDateParsing.parseOptional(nil) == nil)
        #expect(AgentDateParsing.parseOptional("") == nil)
    }

    @Test func format_writesWholeSecondsUTC() {
        #expect(AgentDateParsing.formatISO8601(Self.instant) == "2026-10-22T12:34:56Z")
        #expect(AgentDateParsing.formatISO8601(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }

    /// A fixed instant with a fraction past the half second: formatting
    /// drops the fraction rather than rounding it, so the round trip lands
    /// on the second it started in. Reading the clock here failed whenever
    /// the run fell in the second half of a second.
    @Test func formatThenParse_roundTripsToTheSecond() throws {
        let instant = Self.instant.addingTimeInterval(0.75)
        let parsed = try #require(AgentDateParsing.parseISO8601(AgentDateParsing.formatISO8601(instant)))
        #expect(parsed == Self.instant)
        #expect(AgentDateParsing.formatISO8601(parsed) == AgentDateParsing.formatISO8601(instant))
        #expect(AgentDateParsing.parseISO8601(AgentDateParsing.formatISO8601(Self.instant)) == Self.instant)
    }

    @Test func parseAndFormat_fromManyTasksAtOnce_giveTheSameAnswers() async {
        // A smoke test: the projection parses on detached tasks while the
        // main actor formats, and concurrent calls must still give the same
        // answers. The race itself is what Thread Sanitizer would catch.
        let answers = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let date = Self.instant.addingTimeInterval(TimeInterval(index))
                    let text = AgentDateParsing.formatISO8601(date)
                    return AgentDateParsing.parseISO8601(text) == date
                }
            }
            var all: [Bool] = []
            for await answer in group {
                all.append(answer)
            }
            return all
        }
        #expect(answers.count == 200)
        #expect(!answers.contains(false))
    }
}
