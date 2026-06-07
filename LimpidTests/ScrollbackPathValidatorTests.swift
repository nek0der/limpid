// ScrollbackPathValidatorTests.swift
// Limpid — `WindowSession.validatedScrollbackPath(_:)` is the gate
// between a freshly-restored `state.json` and libghostty's scrollback
// replay path. A tampered file could otherwise point at arbitrary
// targets (`~/.ssh/id_rsa`, `/etc/passwd`) and libghostty would
// happily read them into a pane, where an OSC 52 sequence could
// exfiltrate the contents.
//
// The validator only lets a path through when both:
//   - the extension is `.vt` (the format ghostty itself emits), and
//   - the path resolves under `scrollbackDir()`, the
//     Application-Support sandbox Limpid owns.
//
// Anything else returns nil. The tests below pin that contract
// against the obvious exfiltration shapes.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct ScrollbackPathValidatorTests {
    /// Build a `.vt` file path that lives inside the real
    /// scrollback sandbox — the only shape the validator should
    /// accept.
    private func sandboxedPath(name: String = "pane.vt") -> String {
        WindowSession.scrollbackDir()
            .appendingPathComponent(name)
            .path
    }

    @Test("a `.vt` file inside the scrollback sandbox passes through unchanged")
    func sandboxedVtFile_accepted() {
        let path = sandboxedPath()
        #expect(WindowSession.validatedScrollbackPath(path) == path)
    }

    @Test("a non-`.vt` extension is rejected even inside the sandbox")
    func sandboxedNonVtFile_rejected() {
        let badExt = WindowSession.scrollbackDir()
            .appendingPathComponent("pane.txt")
            .path
        #expect(WindowSession.validatedScrollbackPath(badExt) == nil)
    }

    @Test("an absolute path outside the sandbox is rejected")
    func absoluteOutsidePath_rejected() {
        #expect(WindowSession.validatedScrollbackPath("/etc/passwd") == nil)
        #expect(
            WindowSession.validatedScrollbackPath(
                ("~/.ssh/id_rsa" as NSString).expandingTildeInPath
            ) == nil
        )
    }

    @Test("a `..` traversal back to a sibling directory is rejected")
    func parentTraversal_rejected() {
        // Build `<scrollbackDir>/../leaked.vt` so the literal path
        // starts with the sandbox prefix but `standardizedFileURL`
        // pulls it back out. The validator must follow that
        // standardization rather than relying on the unresolved
        // string.
        let escaping = WindowSession.scrollbackDir()
            .appendingPathComponent("..")
            .appendingPathComponent("leaked.vt")
            .path
        #expect(WindowSession.validatedScrollbackPath(escaping) == nil)
    }

    @Test("a prefix-only collision is rejected (no trailing slash boundary)")
    func prefixCollision_rejected() {
        // `<scrollback>foo/pane.vt` shares the sandbox-directory
        // prefix character-for-character but lives in a sibling
        // directory. The validator must include the trailing `/` in
        // its comparison so this case doesn't pass.
        var sandboxParent = WindowSession.scrollbackDir().path
        // Strip trailing slash if present so we can append the
        // adjacent-directory probe directly.
        while sandboxParent.hasSuffix("/") {
            sandboxParent.removeLast()
        }
        let adjacent = sandboxParent + "-evil/pane.vt"
        #expect(WindowSession.validatedScrollbackPath(adjacent) == nil)
    }

    @Test("a malformed path string is rejected without crashing")
    func emptyString_rejected() {
        #expect(WindowSession.validatedScrollbackPath("") == nil)
    }

    /// A `.vt` symlink that lives lexically inside the sandbox but
    /// resolves to a target outside it is the strongest realistic
    /// attack against the validator — `URL.standardizedFileURL`
    /// strips `..` but does NOT walk symlinks. The validator pairs
    /// `resolvingSymlinksInPath()` with the prefix check; without
    /// that step a planted `<sandbox>/leak.vt -> ~/.ssh/id_rsa`
    /// would survive every other shape this suite already pins.
    @Test("a `.vt` symlink whose target is outside the sandbox is rejected")
    func symlinkOutsideSandbox_rejected() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: WindowSession.scrollbackDir(),
            withIntermediateDirectories: true
        )
        let targetURL = fm.temporaryDirectory
            .appendingPathComponent("limpid-symlink-victim-\(UUID().uuidString)")
        let linkURL = WindowSession.scrollbackDir()
            .appendingPathComponent("leak-\(UUID().uuidString).vt")
        try Data("secret".utf8).write(to: targetURL)
        defer {
            try? fm.removeItem(at: linkURL)
            try? fm.removeItem(at: targetURL)
        }
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        #expect(WindowSession.validatedScrollbackPath(linkURL.path) == nil)
    }
}
