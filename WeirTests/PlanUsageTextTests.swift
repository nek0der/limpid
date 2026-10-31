// PlanUsageTextTests.swift
// Weir — what the usage panel and its rail button say for each state.

import Foundation
import Testing
@testable import Weir

@Suite("Plan usage text")
struct PlanUsageTextTests {
    private let english = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_793_240_000)

    private func usage(_ windows: [PlanUsageWindow], observedAt: Date? = nil) -> PlanUsage {
        PlanUsage(windows: windows, observedAt: observedAt ?? now)
    }

    @Test("names a window as the decision bar does, and says when it resets")
    func row_namesTheWindowAndItsReset() {
        let resetsAt = now.addingTimeInterval(60 * 60)
        let window = PlanUsageWindow(kind: PlanUsageWindow.fiveHour, usedPercent: 81.4, resetsAt: resetsAt)
        let row = PlanUsageText.row(window, now: now, locale: english)
        #expect(row.name == StopReasonText.limitName(PlanUsageWindow.fiveHour))
        #expect(row.percent == 81)
        #expect(row.level == .nearLimit)
        #expect(!row.hasReset)
        let time = StopReasonText.resetTime(resetsAt, locale: english, now: now)
        #expect(row.resetText == "Resets \(time)")
    }

    @Test("a window Codex gives by its length alone is named by that length")
    func windowName_byLength() {
        let name = PlanUsageText.windowName("minutes_1440", locale: english).resolved(in: english)
        #expect(name.hasSuffix(" limit"))
        #expect(name != "Usage limit")
        #expect(PlanUsageText.windowName(PlanUsageWindow.sevenDay, locale: english) == StopReasonText.limitName(PlanUsageWindow.sevenDay))
        #expect(PlanUsageText.windowName("primary", locale: english) == StopReasonText.limitName("primary"))
    }

    @Test("a window past its reset reads as reset, with nothing to wait for")
    func row_afterItsReset_saysReset() {
        let window = PlanUsageWindow(kind: PlanUsageWindow.fiveHour, usedPercent: 100, resetsAt: now.addingTimeInterval(-1))
        let row = PlanUsageText.row(window, now: now, locale: english)
        #expect(row.hasReset)
        #expect(row.percent == 0)
        #expect(row.level == .normal)
        #expect(row.resetText == nil)
        #expect(PlanUsageText.spokenValue(row, locale: english) == "Reset")
    }

    @Test("Codex's section tells a missing plan from a failed read")
    func codexSection_tellsNoPlanFromFailure() {
        let last = usage([PlanUsageWindow(kind: PlanUsageWindow.sevenDay, usedPercent: 12, resetsAt: nil)])
        let noPlan = PlanUsageText.codexSection(.read(.noPlan), last: last, now: now, locale: english)
        #expect(noPlan.rows.isEmpty)
        #expect(noPlan.note?.key.contains("Sign in") == true)

        let failed = PlanUsageText.codexSection(.read(.failed), last: last, now: now, locale: english)
        #expect(failed.rows.count == 1)
        #expect(failed.isDimmed)
        #expect(failed.title == "Codex")
        #expect(failed.note?.key.contains("could not be read") == true)

        let read = PlanUsageText.codexSection(.read(.usage(last)), last: last, now: now, locale: english)
        #expect(!read.isDimmed)
        #expect(read.note == nil)
    }

    /// A read under way changes nothing in the section, so the panel keeps
    /// its height while Codex answers.
    @Test("Codex's section keeps its last values while a read runs")
    func codexSection_whileReading_keepsTheLastValues() {
        let last = usage([PlanUsageWindow(kind: PlanUsageWindow.sevenDay, usedPercent: 12, resetsAt: nil)])
        let read = PlanUsageText.codexSection(.read(.usage(last)), last: last, now: now, locale: english)
        let reading = PlanUsageText.codexSection(.reading, last: last, now: now, locale: english)
        #expect(reading == read)

        let first = PlanUsageText.codexSection(.reading, last: nil, now: now, locale: english)
        #expect(first.rows.isEmpty)
        #expect(first.note?.key == "Reading…")
    }

    @Test("Claude Code's section says what it needs until a value comes")
    func claudeSection_beforeAnyValue_saysWhatItNeeds() {
        let empty = PlanUsageText.claudeSection(nil, now: now, locale: english)
        #expect(empty.title == "Claude")
        #expect(empty.rows.isEmpty)
        #expect(empty.note?.key.contains("/statusline") == true)
    }

    @Test("Claude Code's section says under its values how fresh they are")
    func claudeSection_withValues_saysTheyAreAsOfTheLastReply() {
        let windows = [PlanUsageWindow(kind: PlanUsageWindow.fiveHour, usedPercent: 1, resetsAt: nil)]
        let section = PlanUsageText.claudeSection(usage(windows), now: now, locale: english)
        #expect(section.rows.count == 1)
        #expect(section.note?.key == "Claude’s values are as of its last reply.")
    }

    @Test("Codex's reset credits read as a line under its windows, and none as nothing")
    func codexSection_resetCredits() {
        let withCredits = PlanUsage(
            windows: [PlanUsageWindow(kind: PlanUsageWindow.sevenDay, usedPercent: 0, resetsAt: nil)],
            observedAt: now,
            resetCredits: PlanResetCredits(available: 2, expiresAt: nil)
        )
        let section = PlanUsageText.codexSection(.read(.usage(withCredits)), last: withCredits, now: now, locale: english)
        #expect(section.resetCredits == "Reset credits left: 2")

        let dated = PlanUsageText.resetCredits(PlanResetCredits(available: 1, expiresAt: now), locale: english)
        #expect(dated.hasPrefix("Reset credits left: 1 (until "))

        let none = usage([PlanUsageWindow(kind: PlanUsageWindow.sevenDay, usedPercent: 0, resetsAt: nil)])
        #expect(PlanUsageText.codexSection(.read(.usage(none)), last: none, now: now, locale: english).resetCredits == nil)
    }

    @Test("values an hour old read as stale")
    func section_marksOldValuesStale() {
        let windows = [PlanUsageWindow(kind: PlanUsageWindow.fiveHour, usedPercent: 1, resetsAt: nil)]
        let fresh = PlanUsageText.claudeSection(usage(windows), now: now, locale: english)
        let old = PlanUsageText.claudeSection(
            usage(windows, observedAt: now.addingTimeInterval(-PlanUsageText.staleAfter - 1)),
            now: now,
            locale: english
        )
        #expect(!fresh.isStale)
        #expect(old.isStale)
    }

    @Test("the rail marks a near limit and a reached one differently")
    func railBadge_differsByLevel() {
        #expect(PlanUsageText.railBadge(.normal) == nil)
        #expect(PlanUsageText.railBadge(.nearLimit) == .usage(isAtLimit: false))
        #expect(PlanUsageText.railBadge(.atLimit) == .usage(isAtLimit: true))
        #expect(PlanUsageText.railHelp(.normal, locale: english) == "Plan Usage")
        #expect(PlanUsageText.railHelp(.atLimit, locale: english) == "Plan Usage · At a limit")
    }
}
