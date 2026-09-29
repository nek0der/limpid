// TerminalLinkPolicyTests.swift
// Limpid — pins what a ⌘-clicked terminal link may do, so an OSC 8 target
// chosen by terminal output never reaches Launch Services unchecked and no
// click launches an application or script.

import Foundation
import Testing
@testable import Limpid

@Suite("Terminal link policy")
struct TerminalLinkPolicyTests {

    // MARK: Web and mail

    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink])
    func webLinkWithHostOpens(source: TerminalLinkSource) throws {
        let url = try #require(URL(string: "https://example.com/a?b=c"))
        #expect(TerminalLinkPolicy.action(for: "https://example.com/a?b=c", source: source) == .open(url))
    }

    @Test func webLinkWithoutHostIsRejected() {
        #expect(TerminalLinkPolicy.action(for: "https:relative", source: .hyperlink) == .reject(.invalidWebURL))
    }

    @Test func mailtoNeedsAnAddress() throws {
        let url = try #require(URL(string: "mailto:a@example.com"))
        #expect(TerminalLinkPolicy.action(for: "mailto:a@example.com", source: .hyperlink) == .open(url))
        #expect(TerminalLinkPolicy.action(for: "mailto:", source: .hyperlink) == .reject(.malformed))
    }

    // MARK: Custom schemes

    @Test func hyperlinkCustomSchemeAsksFirst() throws {
        let url = try #require(URL(string: "x-apple.systempreferences:com.apple.preference"))
        #expect(
            TerminalLinkPolicy.action(for: url.absoluteString, source: .hyperlink) == .confirm(url)
        )
    }

    /// A match's scheme comes from libghostty's fixed list and is visible on
    /// screen, so it opens like it does in Ghostty.
    @Test func matchedCustomSchemeOpens() throws {
        let url = try #require(URL(string: "ssh://host.example"))
        #expect(TerminalLinkPolicy.action(for: "ssh://host.example", source: .matchedText) == .open(url))
    }

    // MARK: Characters

    @Test(arguments: ["https://example.com/\u{202E}gpj.exe", "https://exa\u{200B}mple.com", "https://example.com/\na"])
    func invisibleOrLineBreakingCharactersAreRejected(text: String) {
        #expect(TerminalLinkPolicy.action(for: text, source: .matchedText) == .reject(.unsafeCharacters))
    }

    @Test func displayStringEscapesWhatWouldHideTheTarget() throws {
        let url = try #require(URL(string: "x-test:a%E2%80%AEb"))
        #expect(!TerminalLinkPolicy.displayString(for: url).contains("\u{202E}"))
    }

    // MARK: Files

    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink])
    func regularFileOpens(source: TerminalLinkSource) throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notes.txt")
            try Data("hi".utf8).write(to: file)
            let canonical = file.resolvingSymlinksInPath()
            #expect(TerminalLinkPolicy.action(for: file.absoluteString, source: source) == .open(canonical))
        }
    }

    @Test func matchedAbsolutePathOpens() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notes.txt")
            try Data("hi".utf8).write(to: file)
            #expect(
                TerminalLinkPolicy.action(for: file.path, source: .matchedText)
                    == .open(file.resolvingSymlinksInPath())
            )
        }
    }

    @Test func directoryOpens() throws {
        try withTempDir { dir in
            #expect(TerminalLinkPolicy.fileAction(for: dir) == .open(dir.resolvingSymlinksInPath()))
        }
    }

    /// The core of the fix: neither source may launch something that runs
    /// code. Finder shows it instead.
    @Test(arguments: [TerminalLinkSource.matchedText, .hyperlink])
    func applicationBundleIsRevealedNotLaunched(source: TerminalLinkSource) throws {
        try withTempDir { dir in
            let app = dir.appendingPathComponent("Tool.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            // Compare paths: a URL parsed from text gains a trailing slash
            // once it resolves to a directory, which `URL ==` distinguishes.
            let action = TerminalLinkPolicy.action(for: app.absoluteString, source: source)
            guard case let .reveal(url) = action else {
                Issue.record("expected reveal, got \(action)")
                return
            }
            #expect(url.path == app.resolvingSymlinksInPath().path)
        }
    }

    @Test(arguments: ["run.command", "run.sh", "script.scpt", "plain"])
    func scriptsAndExecutablesAreRevealed(name: String) throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\necho hi\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            #expect(TerminalLinkPolicy.fileAction(for: file) == .reveal(file.resolvingSymlinksInPath()))
        }
    }

    /// A harmless-looking name must not hide an executable target.
    @Test func symlinkIsJudgedByItsTarget() throws {
        try withTempDir { dir in
            let app = dir.appendingPathComponent("Real.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent("readme.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
            #expect(TerminalLinkPolicy.fileAction(for: link) == .reveal(app.resolvingSymlinksInPath()))
        }
    }

    @Test func missingFileIsRejected() {
        #expect(
            TerminalLinkPolicy.action(for: "file:///nonexistent/limpid-\(UUID().uuidString)", source: .hyperlink)
                == .reject(.missingFile)
        )
    }

    @Test func remoteFileHostIsRejected() {
        #expect(TerminalLinkPolicy.action(for: "file://server.example/etc/hosts", source: .hyperlink) == .reject(.remoteFile))
    }

    @Test func fileURLWithFragmentIsRejected() {
        #expect(TerminalLinkPolicy.action(for: "file:///etc/hosts#x", source: .hyperlink) == .reject(.malformed))
    }

    /// OSC 8 requires a URI; a bare path could be reinterpreted later.
    @Test func hyperlinkWithoutSchemeIsRejected() {
        #expect(TerminalLinkPolicy.action(for: "/etc/hosts", source: .hyperlink) == .reject(.malformed))
    }

    /// libghostty resolves a relative match against the pane's working
    /// directory when the file exists, so a relative path here names nothing.
    @Test func unresolvedRelativeMatchIsRejected() {
        #expect(TerminalLinkPolicy.action(for: "src/missing.swift:12", source: .matchedText) == .reject(.missingFile))
    }
}
