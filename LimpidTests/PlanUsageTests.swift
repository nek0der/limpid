// PlanUsageTests.swift
// Limpid — the plan usage values: the record the Rust side writes, and how close each window is to its limit.

import Foundation
import Testing
@testable import Limpid

@Suite("Plan usage")
struct PlanUsageTests {
    @Test("decodes the record the Rust side writes")
    func decode_readsTheRustRecord() throws {
        let record = Data(#"""
        {"windows":[{"kind":"five_hour","usedPercent":42.5,"resetsAt":"2026-10-29T04:20:00Z"},
                    {"kind":"seven_day","usedPercent":83.0}],
         "observedAt":"2026-10-29T02:13:20Z"}
        """#.utf8)
        let usage = try PlanUsage.decode(record)
        #expect(usage.windows.map(\.kind) == ["five_hour", "seven_day"])
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_793_247_600))
        #expect(usage.windows[1].resetsAt == nil)
        #expect(usage.observedAt == Date(timeIntervalSince1970: 1_793_240_000))
    }

    @Test("a window past its reset no longer counts toward the level")
    func level_ignoresWindowsThatHaveReset() {
        let now = Date(timeIntervalSince1970: 1000)
        let usage = PlanUsage(
            windows: [
                PlanUsageWindow(kind: PlanUsageWindow.fiveHour, usedPercent: 100, resetsAt: now.addingTimeInterval(-1)),
                PlanUsageWindow(kind: PlanUsageWindow.sevenDay, usedPercent: 85, resetsAt: now.addingTimeInterval(60))
            ],
            observedAt: now
        )
        #expect(usage.level(at: now) == .nearLimit)
        #expect(usage.level(at: now.addingTimeInterval(-10)) == .atLimit)
    }

    @Test("levels follow the share used", arguments: [
        (0.0, PlanUsageLevel.normal), (79.9, .normal), (80, .nearLimit), (99.9, .nearLimit), (100, .atLimit), (120, .atLimit),
    ])
    func level_followsTheShare(percent: Double, level: PlanUsageLevel) {
        #expect(PlanUsageLevel(usedPercent: percent) == level)
    }

    @Test("the displayed share stays between 0 and 100")
    func displayPercent_isClamped() {
        #expect(PlanUsageWindow(kind: "x", usedPercent: 42.5, resetsAt: nil).displayPercent == 43)
        #expect(PlanUsageWindow(kind: "x", usedPercent: 130, resetsAt: nil).displayPercent == 100)
        #expect(PlanUsageWindow(kind: "x", usedPercent: -3, resetsAt: nil).displayPercent == 0)
    }
}
