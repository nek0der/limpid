// CodexUserConfigTests.swift
// Limpid — pins how the trust block is spliced into the user's own
// `~/.codex/config.toml`. This is the one file Limpid edits that it does
// not own, so the splice rewrites only the tables it generated itself,
// keeps whatever Codex or the person wrote around and inside them, and
// leaves the file byte-identical when there is nothing to change.

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

    private func table(_ key: String, hash: String = "sha256:aaaa") -> String {
        """
        [hooks.state."/<session-flags>/config.toml:\(key):0:0"]
        enabled = true
        trusted_hash = "\(hash)"
        """
    }

    private var block: String {
        [table("session_start"), table("stop")].joined(separator: "\n")
    }

    /// What `CodexHookInjection.trustBlock` produces for a real bundle.
    private var realBlock: String {
        CodexHookInjection.trustBlock(
            lifecycleCommand: "/bin/sh '/Applications/Limpid.app/Contents/Resources/codex-shim/limpid-hook'",
            worktreeCommand: "/bin/sh '/Applications/Limpid.app/Contents/Resources/codex-shim/limpid-pretool-worktree-hook'"
        )
    }

    @Test("appends a marked block to a config that has none")
    func applying_noBlock_appends() {
        let out = CodexUserConfig.applying(block: block, to: theirs)
        #expect(out == theirs + "\n\n" + CodexUserConfig.beginMarker + "\n" + block + "\n" + CodexUserConfig.endMarker + "\n")
    }

    @Test("rewrites only its own tables, leaving their lines untouched")
    func applying_existingBlock_rewritesOwnTablesOnly() {
        let first = CodexUserConfig.applying(block: block, to: theirs)
        let changed = [table("session_start", hash: "sha256:bbbb"), table("stop", hash: "sha256:bbbb")]
            .joined(separator: "\n")
        let second = CodexUserConfig.applying(block: changed, to: first)
        #expect(second.contains("sha256:bbbb"))
        #expect(!second.contains("sha256:aaaa"))
        #expect(second.hasPrefix(theirs))
        // One block, not two: a second run must not stack markers.
        #expect(second.components(separatedBy: CodexUserConfig.beginMarker).count == 2)
    }

    /// The caller skips the write on an unchanged result, so anyone keeping
    /// `~/.codex/` in version control sees a diff only when hooks change.
    @Test("is idempotent")
    func applying_sameBlockTwice_isUnchanged() {
        let once = CodexUserConfig.applying(block: realBlock, to: theirs)
        let twice = CodexUserConfig.applying(block: realBlock, to: once)
        #expect(twice == once)
    }

    @Test("handles an empty config")
    func applying_emptyConfig_stillProducesABlock() {
        let out = CodexUserConfig.applying(block: block, to: "")
        #expect(out == CodexUserConfig.beginMarker + "\n" + block + "\n" + CodexUserConfig.endMarker + "\n")
    }

    /// A hand-edited file can lose the closing marker. Reading to the end
    /// of the file in that case would swallow whatever the user wrote
    /// after our block, so the span has to stay bounded.
    @Test("does not swallow the rest of the file when the end marker is gone")
    func applying_unterminatedBlock_keepsFollowingLines() {
        let damaged = """
        \(CodexUserConfig.beginMarker)
        \(table("session_start", hash: "sha256:old"))

        [projects."/Users/me/keep"]
        trust_level = "trusted"
        """
        let out = CodexUserConfig.applying(block: block, to: damaged)
        #expect(out.contains("[projects.\"/Users/me/keep\"]\ntrust_level = \"trusted\""))
        #expect(out.contains(table("session_start")))
        #expect(out.contains(table("stop")))
        #expect(!out.contains("sha256:old"))
    }

    /// Codex records a folder trust by appending a `[projects."…"]` table
    /// after the last table in the file, which is ours, so it lands before
    /// `# END limpid`. Replacing the span wholesale deleted every such
    /// decision on the next launch; this is the exact layout that lost
    /// them.
    @Test("keeps a [projects] table Codex appended inside the span")
    func applying_codexAppendedProjectsTable_isKept() {
        let installed = CodexUserConfig.applying(block: realBlock, to: theirs)
        let projects = """
        [projects."/tmp/limpid-fixture/repos/beta"]
        trust_level = "trusted"
        """
        let afterCodex = installed.replacingOccurrences(
            of: "\n" + CodexUserConfig.endMarker,
            with: "\n\n" + projects + "\n" + CodexUserConfig.endMarker
        )
        #expect(afterCodex.hasSuffix("trust_level = \"trusted\"\n" + CodexUserConfig.endMarker + "\n"))

        let refreshed = CodexUserConfig.applying(block: realBlock, to: afterCodex)
        #expect(refreshed == afterCodex)
        #expect(refreshed.contains(projects))
    }

    @Test("keeps a foreign table in the middle of the span")
    func applying_foreignTableBetweenOurs_isKept() {
        let foreign = """
        [projects."/Users/me/repo"]
        trust_level = "trusted"
        """
        let file = """
        \(theirs)

        \(CodexUserConfig.beginMarker)
        \(table("session_start", hash: "sha256:old"))
        \(foreign)
        \(table("stop", hash: "sha256:old"))
        \(CodexUserConfig.endMarker)

        """
        let out = CodexUserConfig.applying(block: block, to: file)
        #expect(out == """
        \(theirs)

        \(CodexUserConfig.beginMarker)
        \(table("session_start"))
        \(foreign)
        \(table("stop"))
        \(CodexUserConfig.endMarker)

        """)
    }

    /// `trusted_hash` is a function of the command: while the command is
    /// the same, the hash we compute is the one already in the file, and
    /// Codex has no reason to ask again. A key Codex added to one of our
    /// tables is not ours to remove.
    @Test("keeps trusted_hash and foreign keys inside our tables when the block is unchanged")
    func applying_unchangedBlock_keepsHashAndForeignKeys() {
        let installed = CodexUserConfig.applying(block: realBlock, to: theirs)
        let annotated = installed.replacingOccurrences(
            of: "trusted_hash = ",
            with: "last_reviewed = 1\ntrusted_hash = "
        )
        let out = CodexUserConfig.applying(block: realBlock, to: annotated)
        #expect(out == annotated)
        #expect(out.components(separatedBy: "last_reviewed = 1").count == realBlock.components(separatedBy: "trusted_hash = ").count)
    }

    /// Codex runs a hook only while the recorded hash equals the one it
    /// computes from the command (`HookTrustStatus::Modified` otherwise),
    /// so a hash for the previous command has to go with it.
    @Test("replaces trusted_hash when the command changed")
    func applying_changedCommand_replacesHash() {
        let installed = CodexUserConfig.applying(block: realBlock, to: theirs)
        let moved = CodexHookInjection.trustBlock(
            lifecycleCommand: "/bin/sh '/Applications/Limpid Dev.app/Contents/Resources/codex-shim/limpid-hook'",
            worktreeCommand: nil
        )
        let out = CodexUserConfig.applying(block: moved, to: installed)
        for line in moved.components(separatedBy: "\n") {
            #expect(out.contains(line))
        }
        // Tables the new block no longer states — the worktree handler's —
        // are left alone rather than deleted along with their neighbors.
        #expect(out.contains(":pre_tool_use:1:0\"]"))
        #expect(out.components(separatedBy: CodexUserConfig.beginMarker).count == 2)
    }

    @Test("adds a table that is missing before the end marker")
    func applying_missingTable_isInsertedBeforeEndMarker() {
        let partial = CodexUserConfig.applying(block: table("session_start"), to: theirs)
        let out = CodexUserConfig.applying(block: block, to: partial)
        #expect(out == theirs + "\n\n" + CodexUserConfig.beginMarker + "\n" + block + "\n" + CodexUserConfig.endMarker + "\n")
    }

    private func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// Whether every line feed in `text` follows a carriage return.
    private func isAllCRLF(_ text: String) -> Bool {
        let units = Array(text.utf16)
        return units.indices.allSatisfy { units[$0] != 0x0A || ($0 > 0 && units[$0 - 1] == 0x0D) }
    }

    /// A config saved with CRLF used to match none of our headers or
    /// markers, so every launch appended a second set of our tables, and
    /// Codex refuses a file that defines a table twice.
    @Test("finds its block in a CRLF file and leaves the file as it was")
    func applying_crlfFileWithBlock_isUnchanged() {
        let installed = crlf(CodexUserConfig.applying(block: realBlock, to: theirs))
        #expect(isAllCRLF(installed))
        #expect(CodexUserConfig.applying(block: realBlock, to: installed) == installed)
    }

    @Test("rewrites a CRLF file's tables with CRLF")
    func applying_crlfFileWithChangedBlock_keepsCRLF() {
        let installed = crlf(CodexUserConfig.applying(block: block, to: theirs))
        let changed = [table("session_start", hash: "sha256:bbbb"), table("stop", hash: "sha256:bbbb")]
            .joined(separator: "\n")
        let out = CodexUserConfig.applying(block: changed, to: installed)
        #expect(out == crlf(CodexUserConfig.applying(block: changed, to: theirs)))
        #expect(out.components(separatedBy: CodexUserConfig.beginMarker).count == 2)
    }

    @Test("appends to a CRLF file with CRLF, its last line included")
    func applying_crlfFileWithoutBlock_appendsWithCRLF() {
        let out = CodexUserConfig.applying(block: block, to: crlf(theirs))
        #expect(isAllCRLF(out))
        #expect(out == crlf(CodexUserConfig.applying(block: block, to: theirs)))
    }

    /// Each line keeps the ending it had; what we add follows the ending
    /// most of the file uses.
    @Test("keeps each line's ending in a file that mixes them")
    func applying_mixedEndings_keepsEachLinesEnding() {
        let file = "model = \"gpt-5.6-sol\"\r\n\n[tui]\ntheme = \"dark\"\n"
        let out = CodexUserConfig.applying(block: block, to: file)
        #expect(out.hasPrefix(file))
        #expect(out == file + "\n" + CodexUserConfig.beginMarker + "\n" + block + "\n" + CodexUserConfig.endMarker + "\n")

        // Our tables written with CRLF into an otherwise LF file are still
        // found, and stay as they are.
        let ourCRLF = theirs + "\n\n" + crlf(CodexUserConfig.beginMarker + "\n" + block + "\n" + CodexUserConfig.endMarker + "\n")
        #expect(CodexUserConfig.applying(block: block, to: ourCRLF) == ourCRLF)
    }

    /// A table of ours that a person moved out of the span is still ours:
    /// writing it a second time inside the span would hand Codex a TOML
    /// file with a duplicate table, which it refuses to load.
    @Test("rewrites one of its tables that sits outside the markers")
    func applying_ownTableOutsideSpan_isRewrittenInPlace() {
        let file = """
        \(table("stop", hash: "sha256:old"))

        \(theirs)
        """
        let out = CodexUserConfig.applying(block: block, to: file)
        #expect(out.hasPrefix(table("stop") + "\n\n" + theirs))
        #expect(out.components(separatedBy: "[hooks.state.\"/<session-flags>/config.toml:stop:0:0\"]").count == 2)
        #expect(out.contains(table("session_start")))
    }

    /// A value that quotes our table, in either multi-line form, holds
    /// text: its lines are not rewritten, and our tables are written as if
    /// it were not there. A `"""` in a comment or in a one-line string
    /// opens no string, so our table after it is still found.
    @Test("leaves a multi-line string that quotes its table alone", arguments: ["\"\"\"", "'''"])
    func applying_tableQuotedInAMultilineString_isText(delimiter: String) {
        let quoted = """
        notes = \(delimiter)
        \(table("stop", hash: "sha256:example"))
        enabled = false
        \(CodexUserConfig.beginMarker)
        \(delimiter)
        """
        let file = theirs + "\n" + quoted + "\n"
        let out = CodexUserConfig.applying(block: block, to: file)
        #expect(out.hasPrefix(file), "\(out)")
        #expect(out == file + "\n" + CodexUserConfig.beginMarker + "\n" + block + "\n" + CodexUserConfig.endMarker + "\n")
        #expect(CodexUserConfig.applying(block: block, to: out) == out)

        // The delimiter inside a one-line string of the other quote.
        let oneLine = delimiter == "'''" ? "\"\(delimiter)\"" : "'\(delimiter)'"
        let opensNothing = """
        # an example: notes = \(delimiter)
        title = \(oneLine)
        \(table("stop", hash: "sha256:old"))
        """
        let rewritten = CodexUserConfig.applying(block: block, to: opensNothing)
        #expect(rewritten.hasPrefix("# an example: notes = \(delimiter)\ntitle = \(oneLine)\n" + table("stop")))
        #expect(!rewritten.contains("sha256:old"))
    }

    /// A key of ours is found past a value of Codex's own that spans lines,
    /// and one we add goes after that value, not into it.
    @Test("adds its key after a multi-line value, not inside it")
    func applying_keyAfterAMultilineValue_goesAfterTheValue() {
        let file = """
        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        note = \"\"\"
        enabled = false
        \"\"\"
        """
        let out = CodexUserConfig.applying(block: table("stop"), to: file)
        #expect(out == """
        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        note = \"\"\"
        enabled = false
        \"\"\"
        enabled = true
        trusted_hash = "sha256:aaaa"

        """)
    }

    // MARK: - Tables found by name

    /// A comment after a header is legal TOML. Compared as text, our header
    /// with one was not ours, so the table was appended a second time, and
    /// Codex refuses a file that defines a table twice.
    @Test("rewrites its table in place when the header carries a comment")
    func applying_headerWithTrailingComment_isRewrittenInPlace() {
        let header = "[hooks.state.\"/<session-flags>/config.toml:stop:0:0\"]"
        let installed = CodexUserConfig.applying(block: block, to: theirs)
        let annotated = installed.replacingOccurrences(of: header, with: header + "  # reviewed by hand")
        let changed = [table("session_start", hash: "sha256:bbbb"), table("stop", hash: "sha256:bbbb")]
            .joined(separator: "\n")

        let out = CodexUserConfig.applying(block: changed, to: annotated)

        #expect(out.contains(header + "  # reviewed by hand\nenabled = true\ntrusted_hash = \"sha256:bbbb\""))
        #expect(out.components(separatedBy: header).count == 2)
        #expect(!out.contains("sha256:aaaa"))
        #expect(CodexUserConfig.problem(in: out) == nil)
        #expect(CodexUserConfig.applying(block: changed, to: out) == out)
    }

    @Test("rewrites its commented table in place in a CRLF file")
    func applying_crlfHeaderWithTrailingComment_isRewrittenInPlace() {
        let header = "[hooks.state.\"/<session-flags>/config.toml:stop:0:0\"]"
        let installed = crlf(CodexUserConfig.applying(block: block, to: theirs))
            .replacingOccurrences(of: header, with: header + " # note")
        let changed = [table("session_start", hash: "sha256:bbbb"), table("stop", hash: "sha256:bbbb")]
            .joined(separator: "\n")

        let out = CodexUserConfig.applying(block: changed, to: installed)

        #expect(isAllCRLF(out))
        #expect(out.contains(header + " # note\r\nenabled = true\r\ntrusted_hash = \"sha256:bbbb\"\r\n"))
        #expect(out.components(separatedBy: header).count == 2)
        #expect(CodexUserConfig.problem(in: out) == nil)
    }

    /// Before tables were matched by name, the next launch after a person
    /// commented our header appended a second copy between the markers,
    /// and Codex would not start. That copy is ours to take back.
    @Test("removes the copy an earlier version appended beside a commented table")
    func applying_appendedCopyOfCommentedTable_isRemoved() {
        let header = "[hooks.state.\"/<session-flags>/config.toml:stop:0:0\"]"
        let broken = """
        \(theirs)

        \(header) # note
        enabled = true
        trusted_hash = "sha256:old"

        \(CodexUserConfig.beginMarker)
        \(table("session_start"))
        \(table("stop", hash: "sha256:old"))
        \(CodexUserConfig.endMarker)

        """
        #expect(CodexUserConfig.problem(in: broken) == .duplicateTable(line: 13))

        let out = CodexUserConfig.applying(block: block, to: broken)

        #expect(out == """
        \(theirs)

        \(header) # note
        enabled = true
        trusted_hash = "sha256:aaaa"

        \(CodexUserConfig.beginMarker)
        \(table("session_start"))
        \(CodexUserConfig.endMarker)

        """)
        #expect(CodexUserConfig.problem(in: out) == nil)
    }

    /// A file an earlier version broke, whose appended copy also holds
    /// lines that are not ours, and the file the repair should make of it.
    /// `shared` is set in both copies; `copyShared` is its value in the
    /// copy that is removed.
    private func brokenWithForeignLines(copyShared: String = "1") -> (broken: String, repaired: String) {
        let header = "[hooks.state.\"/<session-flags>/config.toml:stop:0:0\"]"
        let broken = """
        \(theirs)

        \(header) # note
        enabled = true
        trusted_hash = "sha256:old"
        shared = 1

        \(CodexUserConfig.beginMarker)
        \(table("session_start"))
        \(table("stop", hash: "sha256:old"))
        # reviewed by me
        last_reviewed = 1
        audit.owner = "me"
        shared = \(copyShared)
        notes = '''
        [hooks.state."quoted"]
        '''
        \(CodexUserConfig.endMarker)

        """
        let repaired = """
        \(theirs)

        \(header) # note
        enabled = true
        trusted_hash = "sha256:aaaa"
        shared = 1
        # reviewed by me
        last_reviewed = 1
        audit.owner = "me"
        notes = '''
        [hooks.state."quoted"]
        '''

        \(CodexUserConfig.beginMarker)
        \(table("session_start"))
        \(CodexUserConfig.endMarker)

        """
        return (broken, repaired)
    }

    /// The copy an earlier version appended is ours, but a key Codex or
    /// the person added to it, dotted or not, a multi-line value and a
    /// comment are not: they move into the table that is kept. A key both
    /// copies set the same way is not repeated.
    @Test("keeps the lines that are not ours when it removes an appended copy")
    func applying_appendedCopyWithForeignLines_movesThemIntoTheKeptTable() {
        let (broken, repaired) = brokenWithForeignLines()

        let out = CodexUserConfig.applying(block: block, to: broken)

        #expect(out == repaired)
        #expect(CodexUserConfig.problem(in: out) == nil)
    }

    @Test("keeps the lines that are not ours in a CRLF file, with CRLF")
    func applying_crlfAppendedCopyWithForeignLines_movesThemWithCRLF() {
        let (broken, repaired) = brokenWithForeignLines()

        let out = CodexUserConfig.applying(block: block, to: crlf(broken))

        #expect(out == crlf(repaired))
        #expect(isAllCRLF(out))
        #expect(CodexUserConfig.problem(in: out) == nil)
    }

    /// When every copy is between the markers the first is kept, and the
    /// lines that are not ours in the others move into it.
    @Test("moves the lines that are not ours into the first copy between the markers")
    func applying_copiesAllBetweenMarkers_moveForeignLinesIntoTheFirst() {
        let broken = """
        \(CodexUserConfig.beginMarker)
        \(table("session_start"))
        \(table("stop", hash: "sha256:old"))
        \(table("stop", hash: "sha256:old"))
        note = "mine"
        \(CodexUserConfig.endMarker)

        """

        let out = CodexUserConfig.applying(block: block, to: broken)

        #expect(out == """
        \(CodexUserConfig.beginMarker)
        \(table("session_start"))
        \(table("stop"))
        note = "mine"
        \(CodexUserConfig.endMarker)

        """)
        #expect(CodexUserConfig.problem(in: out) == nil)
    }

    /// Which of two values the person meant is not ours to decide: both
    /// stay, and the check refuses the result, so the file is not written.
    @Test("leaves a key the copies set differently for the check to refuse")
    func applying_appendedCopyWithConflictingKey_isRefusedByTheCheck() {
        let (broken, _) = brokenWithForeignLines(copyShared: "2")

        let out = CodexUserConfig.applying(block: block, to: broken)

        #expect(out.contains("shared = 1\n"))
        #expect(out.contains("shared = 2\n"))
        // The copy's `shared = 2`, moved under the kept table's `shared = 1`.
        #expect(CodexUserConfig.problem(in: out) == .duplicateKey(line: 12))
    }

    /// Swift calls `"caf\u{E9}"` and `"cafe\u{301}"` equal, but they are two
    /// values in TOML: the copy's is not the kept table's, so it is not
    /// dropped as a repeat but kept for the check to refuse.
    @Test("compares values by scalar when it merges a copy")
    func applying_appendedCopyWithCanonicallyEquivalentValue_isRefusedByTheCheck() {
        let header = "[hooks.state.\"/<session-flags>/config.toml:stop:0:0\"]"
        let broken = """
        \(header) # note
        note = "caf\u{E9}"

        \(CodexUserConfig.beginMarker)
        \(table("stop", hash: "sha256:old"))
        note = "cafe\u{301}"
        \(CodexUserConfig.endMarker)

        """

        let out = CodexUserConfig.applying(block: table("stop"), to: broken)

        #expect(out.unicodeScalars.split(separator: "\n").count { $0.starts(with: "note".unicodeScalars) } == 2)
        #expect(CodexUserConfig.problem(in: out) == .duplicateKey(line: 2))
    }

    /// Two copies a person wrote outside our markers are theirs to sort
    /// out; the result still has both, and the check refuses it.
    @Test("leaves duplicates outside the markers for the check to refuse")
    func applying_duplicatesOutsideMarkers_areLeftForTheCheck() {
        let file = table("stop", hash: "sha256:old") + "\n" + table("stop", hash: "sha256:old") + "\n"
        let out = CodexUserConfig.applying(block: table("stop"), to: file)
        #expect(out == table("stop") + "\n" + table("stop") + "\n")
        #expect(CodexUserConfig.problem(in: out) == .duplicateTable(line: 3))
    }

    /// Codex writes the file with `toml_edit`, and a person may too: the
    /// same table can come back quoted the other way or spaced out.
    @Test("treats an equivalently written header as its table", arguments: [
        "[hooks.state.'/<session-flags>/config.toml:stop:0:0']",
        "[ hooks . state . \"/<session-flags>/config.toml:stop:0:0\" ]",
        "[\"hooks\".'state'.\"/<session-flags>/config.toml:stop:0:0\"]",
        "  [hooks.\"state\"   .\"/<session-flags>/config.toml:stop:0:0\"]\t# moved",
    ])
    func applying_equivalentHeader_isRewrittenInPlace(header: String) {
        let file = theirs + "\n\n" + header + "\nenabled = true\ntrusted_hash = \"sha256:old\"\n"
        let out = CodexUserConfig.applying(block: table("stop"), to: file)
        #expect(out == theirs + "\n\n" + header + "\nenabled = true\ntrusted_hash = \"sha256:aaaa\"\n")
        #expect(CodexUserConfig.problem(in: out) == nil)
    }

    /// The same goes for a key: `"enabled"` is the key we state as
    /// `enabled`, and setting it a second time is as fatal as a second table.
    @Test("treats an equivalently written key as its key")
    func applying_quotedKey_isReplacedNotAdded() {
        let file = """
        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        "enabled" = false
        'trusted_hash'   = "sha256:old"
        """
        let out = CodexUserConfig.applying(block: table("stop"), to: file)
        #expect(out == table("stop"))
        #expect(CodexUserConfig.problem(in: out) == nil)
    }

    /// A `#` inside a quoted segment is part of the name. Read as a comment
    /// it would cut the header short, and ours would never match.
    @Test("reads a # inside a quoted key as part of the name")
    func applying_hashInsideQuotedKey_isNotAComment() {
        let ours = "[hooks.state.\"/repo#1/config.toml:stop:0:0\"]\nenabled = true"
        let file = "[hooks.state.'/repo#1/config.toml:stop:0:0'] # ours\nenabled = false\n"
        let out = CodexUserConfig.applying(block: ours, to: file)
        #expect(out == "[hooks.state.'/repo#1/config.toml:stop:0:0'] # ours\nenabled = true\n")

        // A different name before the `#` is a different table.
        let other = "[hooks.state.\"/repo\"] # 1/config.toml:stop:0:0\nenabled = false\n"
        let appended = CodexUserConfig.applying(block: ours, to: other)
        #expect(appended.hasPrefix(other))
        #expect(appended.contains(ours))
        #expect(CodexUserConfig.problem(in: appended) == nil)
    }

    /// The line of an array that opens with `[` belongs to the value: it
    /// does not end our table or count as a header.
    @Test("does not take a line of a multi-line array for a header")
    func applying_arrayLineStartingWithBracket_isNotAHeader() {
        let file = """
        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        pairs = [
          ["a", "b"],
        ]
        enabled = false
        """
        let out = CodexUserConfig.applying(block: table("stop"), to: file)
        #expect(out == """
        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        pairs = [
          ["a", "b"],
        ]
        enabled = true
        trusted_hash = "sha256:aaaa"

        """)
        #expect(CodexUserConfig.problem(in: out) == nil)
    }
}
