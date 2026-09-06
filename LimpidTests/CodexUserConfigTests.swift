// CodexUserConfigTests.swift
// Limpid — pins how the trust block is spliced into the user's own
// `~/.codex/config.toml`. This is the one file Limpid edits that it does
// not own, so the splice reads nothing outside its own markers and leaves
// the file byte-identical when there is nothing to change.

import Foundation
import Testing
@testable import Limpid

@Suite("CodexUserConfig.applying")
struct CodexUserConfigTests {
    private let theirs = """
    model = "gpt-5.6-sol"

    [tui]
    theme = "dark"
    """

    @Test("appends a marked block to a config that has none")
    func applying_noBlock_appends() {
        let out = CodexUserConfig.applying(block: "trusted = true", to: theirs)
        #expect(out.hasPrefix(theirs))
        #expect(out.contains(CodexUserConfig.beginMarker))
        #expect(out.contains("trusted = true"))
        #expect(out.contains(CodexUserConfig.endMarker))
    }

    @Test("replaces only the marked span, leaving their lines untouched")
    func applying_existingBlock_replacesSpanOnly() {
        let first = CodexUserConfig.applying(block: "old = 1", to: theirs)
        let second = CodexUserConfig.applying(block: "new = 2", to: first)
        #expect(second.contains("new = 2"))
        #expect(!second.contains("old = 1"))
        #expect(second.hasPrefix(theirs))
        // One block, not two: a second run must not stack markers.
        #expect(second.components(separatedBy: CodexUserConfig.beginMarker).count == 2)
    }

    /// The caller skips the write on an unchanged result, so anyone keeping
    /// `~/.codex/` in version control sees a diff only when hooks change.
    @Test("is idempotent")
    func applying_sameBlockTwice_isUnchanged() {
        let once = CodexUserConfig.applying(block: "trusted = true", to: theirs)
        let twice = CodexUserConfig.applying(block: "trusted = true", to: once)
        #expect(twice == once)
    }

    @Test("handles an empty config")
    func applying_emptyConfig_stillProducesABlock() {
        let out = CodexUserConfig.applying(block: "trusted = true", to: "")
        #expect(out.contains(CodexUserConfig.beginMarker))
        #expect(out.contains("trusted = true"))
    }

    /// A hand-edited file can lose the closing marker. Reading to the end
    /// of the file in that case would swallow whatever the user wrote
    /// after our block, so the span has to stay bounded.
    @Test("does not swallow the rest of the file when the end marker is gone")
    func applying_unterminatedBlock_keepsFollowingLines() {
        let damaged = """
        \(CodexUserConfig.beginMarker)
        old = 1
        keep = "this"
        """
        let out = CodexUserConfig.applying(block: "new = 2", to: damaged)
        #expect(out.contains("keep = \"this\""))
        #expect(out.contains("new = 2"))
    }
}
