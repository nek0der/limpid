// DurationTextTests.swift
// Limpid — how long a command ran, in words.

import Foundation
import Testing
@testable import Limpid

struct DurationTextTests {
    private let en = Locale(identifier: "en")

    @Test func aCommandsTime_isSaidInWholeSecondsPastAMinute() {
        #expect(DurationText.command(134.6, locale: en) == DurationText.command(134, locale: en))
        #expect(DurationText.command(134, locale: en).contains("2"))
        #expect(DurationText.command(48.25, locale: en).contains("48.2") || DurationText.command(48.25, locale: en).contains("48.3"))
    }
}
