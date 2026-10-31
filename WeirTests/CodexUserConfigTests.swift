// CodexUserConfigTests.swift
// Weir — pins how the trust tables earlier builds wrote are taken out of
// the user's own `~/.codex/config.toml`. This is the one file Weir edits
// that it does not own, so the edit removes only the lines it wrote itself,
// keeps whatever Codex or the person wrote around and inside them, and
// leaves the file byte-identical when there is nothing of ours.

import Foundation
import Testing
@testable import Weir

@Suite("CodexUserConfig.removing")
struct CodexUserConfigTests {
    private let theirs = """
    model = "gpt-5.6-sol"

    [tui]
    theme = "dark"
    """

    private let keys = CodexUserConfig.legacyTrustKeys

    private func table(_ label: String, group: Int = 0, hash: String = "sha256:aaaa") -> String {
        """
        [hooks.state."/<session-flags>/config.toml:\(label):\(group):0"]
        enabled = true
        trusted_hash = "\(hash)"
        """
    }

    /// The block as an earlier build appended it after the person's lines.
    private var legacyBlock: String {
        [
            CodexUserConfig.beginMarker,
            table("session_start"),
            table("pre_tool_use"),
            table("pre_tool_use", group: 1),
            table("stop"),
            CodexUserConfig.endMarker
        ].joined(separator: "\n")
    }

    private func removing(_ text: String) -> String {
        CodexUserConfig.removing(keys: keys, from: text)
    }

    /// The keys are written out, not taken from the hooks passed today: a
    /// key `CodexHookInjection` keys the same way is the same table.
    @Test("names every table an earlier build wrote")
    func legacyTrustKeys_coverEveryHandlerGroup() {
        #expect(keys.count == 11)
        #expect(keys.contains(CodexHookInjection.trustKey(eventLabel: "pre_tool_use", group: 1)))
        #expect(keys.contains(CodexHookInjection.trustKey(eventLabel: "stop", group: 0)))
    }

    @Test("removes the block appended after the person's lines")
    func removing_appendedBlock_leavesTheirLines() {
        #expect(removing(theirs + "\n\n" + legacyBlock + "\n") == theirs + "\n")
    }

    @Test("leaves a config with nothing of ours byte-identical")
    func removing_nothingOfOurs_isUnchanged() {
        #expect(removing(theirs + "\n") == theirs + "\n")
        #expect(removing("") == "")
    }

    @Test("empties a config that held only the block")
    func removing_onlyTheBlock_leavesAnEmptyFile() {
        #expect(removing(legacyBlock + "\n").isEmpty)
    }

    @Test("closes up the gap the block leaves between the person's lines")
    func removing_blockBetweenTheirLines_leavesOneBlankLine() {
        let file = "model = \"gpt-5.6-sol\"\n\n" + legacyBlock + "\n\n[tui]\ntheme = \"dark\"\n"
        #expect(removing(file) == theirs + "\n")
    }

    @Test("keeps a [projects] table Codex appended inside the span")
    func removing_codexAppendedProjectsTable_isKept() {
        let projects = """
        [projects."/tmp/weir-fixture/repos/beta"]
        trust_level = "trusted"
        """
        let file = theirs + "\n\n" + legacyBlock.replacingOccurrences(
            of: "\n" + CodexUserConfig.endMarker,
            with: "\n\n" + projects + "\n" + CodexUserConfig.endMarker
        ) + "\n"
        #expect(removing(file) == theirs + "\n\n" + projects + "\n")
    }

    @Test("keeps a key Codex added to one of our tables, under its header")
    func removing_foreignKeyInOurTable_keepsHeaderAndKey() {
        let file = table("stop") + "\nnote = \"theirs\"\n"
        #expect(removing(file) == "[hooks.state.\"/<session-flags>/config.toml:stop:0:0\"]\nnote = \"theirs\"\n")
        #expect(CodexUserConfig.problem(in: removing(file)) == nil)
    }

    @Test("removes one of its tables that sits outside the markers")
    func removing_ownTableOutsideSpan_isRemoved() {
        let file = theirs + "\n\n" + table("stop") + "\n"
        #expect(removing(file) == theirs + "\n")
    }

    /// Another program's session-flag hook, trusted from Codex's own
    /// review, has a key of the same form; only the keys we passed are ours.
    @Test("keeps a trust table with a key it never passed")
    func removing_otherSessionFlagKey_isKept() {
        let other = table("stop", group: 3)
        let file = theirs + "\n\n" + other + "\n"
        #expect(removing(file) == file)
    }

    @Test("keeps the person's lines after an opening marker with no end")
    func removing_unterminatedBlock_keepsFollowingLines() {
        let file = CodexUserConfig.beginMarker + "\n" + table("stop") + "\n\n[tui]\ntheme = \"dark\"\n"
        #expect(removing(file) == "[tui]\ntheme = \"dark\"\n")
    }

    @Test("leaves a multi-line string that quotes its table alone", arguments: ["\"\"\"", "'''"])
    func removing_tableQuotedInAMultilineString_isText(delimiter: String) {
        let file = """
        notes = \(delimiter)
        \(table("stop"))
        \(CodexUserConfig.beginMarker)
        \(delimiter)

        """
        #expect(removing(file) == file)
    }

    @Test("keeps CRLF line endings")
    func removing_crlfFile_keepsCRLF() {
        let crlf = { (text: String) in text.replacingOccurrences(of: "\n", with: "\r\n") }
        let out = removing(crlf(theirs + "\n\n" + legacyBlock + "\n"))
        #expect(out == crlf(theirs + "\n"))
    }

    @Test("treats an equivalently written header as its table", arguments: [
        "[hooks.state.'/<session-flags>/config.toml:stop:0:0']",
        "[ hooks . state . \"/<session-flags>/config.toml:stop:0:0\" ]",
        "[\"hooks\".'state'.\"/<session-flags>/config.toml:stop:0:0\"]",
        "  [hooks.\"state\"   .\"/<session-flags>/config.toml:stop:0:0\"]\t# moved",
    ])
    func removing_equivalentHeader_isRemoved(header: String) {
        let file = theirs + "\n\n" + header + "\nenabled = true\ntrusted_hash = \"sha256:old\"\n"
        #expect(removing(file) == theirs + "\n")
    }

    @Test("treats an equivalently written key as its key")
    func removing_quotedKey_isRemoved() {
        let file = """
        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        "enabled" = false
        'trusted_hash'   = "sha256:old"

        """
        #expect(removing(file).isEmpty)
    }

    /// Earlier builds appended the block at the end of the file, so a key
    /// typed after it is, to TOML, a key of our last table. Taking that
    /// table's header away would move the key into the table before.
    @Test("keeps the header of a table a key typed after the block belongs to")
    func removing_keyAfterTheEndMarker_keepsItsTable() {
        let file = "[mcp_servers.x]\ncommand = \"a\"\n\n" + legacyBlock + "\nmodel = \"o3\"\n"
        #expect(removing(file) == """
        [mcp_servers.x]
        command = "a"

        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        model = "o3"

        """)
    }

    @Test("closes up a run of blank lines after the block")
    func removing_blankRunAfterTheBlock_leavesOneBlankLine() {
        let file = "model = \"gpt-5.6-sol\"\n\n" + legacyBlock + "\n\n\n[tui]\ntheme = \"dark\"\n"
        #expect(removing(file) == "model = \"gpt-5.6-sol\"\n\n[tui]\ntheme = \"dark\"\n")
    }

    /// The line of an array that opens with `[` belongs to the value: it
    /// does not end our table or count as a header.
    @Test("does not take a line of a multi-line array for a header")
    func removing_arrayLineStartingWithBracket_isNotAHeader() {
        let file = """
        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        pairs = [
          ["a", "b"],
        ]
        enabled = true
        trusted_hash = "sha256:aaaa"

        """
        #expect(removing(file) == """
        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        pairs = [
          ["a", "b"],
        ]

        """)
    }

    /// Copies an earlier version appended are all ours, wherever they are.
    @Test("removes every copy of a table")
    func removing_duplicateCopies_areAllRemoved() {
        let file = theirs + "\n\n" + CodexUserConfig.beginMarker + "\n" + table("stop") + "\n"
            + table("stop", hash: "sha256:bbbb") + "\n" + CodexUserConfig.endMarker + "\n"
        #expect(removing(file) == theirs + "\n")
    }
}
