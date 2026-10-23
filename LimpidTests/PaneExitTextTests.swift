// PaneExitTextTests.swift
// Limpid — the exited pane's hint names the bound close key, or only the restart.

import Foundation
import Testing
@testable import Limpid

struct PaneExitTextTests {
    private static let en = Locale(identifier: "en")
    private static let ja = Locale(identifier: "ja")

    @Test func hint_withACloseKey_namesIt() {
        let hint = PaneExitText.hint(closeKey: "⌥⌘K")
        #expect(hint.resolved(in: Self.en) == "Press ⌥⌘K to close, or ⏎ to restart.")
        #expect(hint.resolved(in: Self.ja) == "⌥⌘K で閉じるか、⏎ で再起動してください。")
    }

    @Test func hint_withNoCloseKey_saysOnlyRestart() {
        let hint = PaneExitText.hint(closeKey: nil)
        #expect(hint.resolved(in: Self.en) == "Press ⏎ to restart.")
        #expect(hint.resolved(in: Self.ja) == "⏎ で再起動してください。")
    }
}
