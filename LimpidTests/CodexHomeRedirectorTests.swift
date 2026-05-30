// CodexHomeRedirectorTests.swift
// Limpid — covers the standalone helpers on `CodexHomeRedirector`
// that don't require a real `~/.codex/` to exist. End-to-end shadow
// dir construction is exercised via the Bash spike
// `scripts/spike-codex-shadow.sh`.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("CodexHomeRedirector.environment")
struct CodexHomeRedirectorEnvironmentTests {
    @Test("omits CODEX_HOME when the shadow dir does not exist")
    func omitsCodexHomeWhenShadowMissing() throws {
        try withTempDir { dir in
            // `refresh()` skips shadow creation when the user has no
            // `~/.codex/`, so a still-missing shadow dir must not be
            // exported — otherwise a hand-run `codex` aborts on a
            // non-existent CODEX_HOME.
            let missing = dir.appendingPathComponent("codex-home", isDirectory: true)
            let redirector = CodexHomeRedirector(
                shadowCodexHome: missing,
                hookScriptURL: dir.appendingPathComponent("limpid-codex-hook")
            )
            let env = redirector.environment(forPaneID: nil)
            #expect(env["CODEX_HOME"] == nil)
        }
    }

    @Test("exports CODEX_HOME when the shadow dir exists")
    func exportsCodexHomeWhenShadowPresent() throws {
        try withTempDir { dir in
            let shadow = dir.appendingPathComponent("codex-home", isDirectory: true)
            try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: true)
            let redirector = CodexHomeRedirector(
                shadowCodexHome: shadow,
                hookScriptURL: dir.appendingPathComponent("limpid-codex-hook")
            )
            let env = redirector.environment(forPaneID: nil)
            #expect(env["CODEX_HOME"] == shadow.path)
        }
    }
}

@Suite("CodexHomeRedirector.stripHookStateBlocks")
struct CodexHomeRedirectorStripTests {
    @Test("strips only owned shadow-path blocks, preserves others")
    func stripsOnlyOwnedBlocks() {
        let owned = "/shadow/codex-home/hooks.json"
        let input = """
        model = "gpt-5.5"

        [hooks.state]

        [hooks.state."/shadow/codex-home/hooks.json:session_start:0:0"]
        trusted_hash = "sha256:owned-aaa"

        [hooks.state."/Users/foo/.codex/hooks.json:session_start:0:0"]
        trusted_hash = "sha256:user-bbb"

        [hooks.state."/shadow/codex-home/hooks.json:stop:0:0"]
        trusted_hash = "sha256:owned-ccc"

        [tui]
        notifications = false
        """
        let out = CodexHomeRedirector.stripHookStateBlocks(input, ownedHooksJsonPath: owned)
        // Owned blocks gone
        #expect(!out.contains("sha256:owned-aaa"))
        #expect(!out.contains("sha256:owned-ccc"))
        // Non-owned (user / third-party) blocks preserved
        #expect(out.contains("sha256:user-bbb"))
        #expect(out.contains("[hooks.state.\"/Users/foo/.codex/hooks.json:session_start:0:0\"]"))
        // Bare parent + unrelated sections preserved
        #expect(out.contains("[hooks.state]"))
        #expect(out.contains("[tui]"))
        #expect(out.contains("model = \"gpt-5.5\""))
    }

    @Test("leaves config untouched when no owned hooks.state present")
    func passthrough() {
        let input = """
        model = "gpt-5.5"

        [hooks.state."/Users/foo/.codex/hooks.json:session_start:0:0"]
        trusted_hash = "sha256:aaa"
        """
        let out = CodexHomeRedirector.stripHookStateBlocks(input, ownedHooksJsonPath: "/shadow/hooks.json")
        #expect(out.contains("model = \"gpt-5.5\""))
        #expect(out.contains("sha256:aaa"))
    }
}

@Suite("CodexHomeRedirector.injectTitleSuppression")
struct CodexHomeRedirectorTitleSuppressionTests {
    @Test("inserts terminal_title under existing [tui] section")
    func insertUnderExistingTui() throws {
        let input = """
        model = "gpt-5.5"

        [tui]
        status_line = ["model-name"]

        [tui.subsection]
        x = 1
        """
        let out = CodexHomeRedirector.injectTitleSuppression(input)
        // The override line comes right after [tui]
        let lines = out.components(separatedBy: "\n")
        let tuiIdx = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "[tui]" })
        #expect(lines[tuiIdx + 1] == "terminal_title = []")
        // status_line is preserved
        #expect(out.contains("status_line = [\"model-name\"]"))
        // Subsection preserved
        #expect(out.contains("[tui.subsection]"))
    }

    @Test("appends [tui] section when missing")
    func appendsWhenMissing() {
        let input = """
        model = "gpt-5.5"
        """
        let out = CodexHomeRedirector.injectTitleSuppression(input)
        #expect(out.contains("[tui]"))
        #expect(out.contains("terminal_title = []"))
    }

    @Test("strips existing terminal_title inside [tui] to avoid duplicates")
    func stripsExisting() {
        let input = """
        [tui]
        terminal_title = ["spinner", "project"]
        status_line = ["x"]
        """
        let out = CodexHomeRedirector.injectTitleSuppression(input)
        #expect(!out.contains("[\"spinner\", \"project\"]"))
        // Only one terminal_title line, value is []
        let count = out.components(separatedBy: "terminal_title").count - 1
        #expect(count == 1)
        #expect(out.contains("terminal_title = []"))
    }

    @Test("doesn't touch terminal_title outside [tui] (other-section keys)")
    func leavesUnrelatedKeysAlone() {
        let input = """
        [other]
        terminal_title = "keep me"

        [tui]
        status_line = ["x"]
        """
        let out = CodexHomeRedirector.injectTitleSuppression(input)
        #expect(out.contains("terminal_title = \"keep me\""))
        #expect(out.contains("terminal_title = []"))
    }
}
