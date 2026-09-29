// PathFormattingTests.swift
// Limpid — covers the home abbreviation every display path goes through.

import Foundation
import Testing
@testable import Limpid

@Suite("PathFormatting")
struct PathFormattingTests {
    /// The command palette once matched the prefix without the separator
    /// and showed a sibling directory such as `/Users/nameX` as `~X`.
    @Test("a sibling that only shares the home prefix is left alone")
    func abbreviateHome_siblingWithSharedPrefix_isUnchanged() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(PathFormatting.abbreviateHome(home + "X/dev") == home + "X/dev")
    }
}
