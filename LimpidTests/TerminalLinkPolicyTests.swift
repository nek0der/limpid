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
            #expect(TerminalLinkPolicy.action(for: file.absoluteString, source: source) == .openFile(canonical, nil))
        }
    }

    @Test func matchedAbsolutePathOpens() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notes.txt")
            try Data("hi".utf8).write(to: file)
            #expect(
                TerminalLinkPolicy.action(for: file.path, source: .matchedText)
                    == .openFile(file.resolvingSymlinksInPath(), nil)
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

    @Test func relativeMatchWithNowhereToLookIsRejected() {
        #expect(TerminalLinkPolicy.action(for: "src/missing.swift:12", source: .matchedText) == .reject(.missingFile))
    }

    // MARK: Paths with a position

    /// What agents and compilers print: a path relative to the pane's
    /// directory with a line and column.
    @Test(arguments: [
        ("Sources/Main.swift:12:5", FilePosition(line: 12, column: 5)),
        ("Sources/Main.swift:12", FilePosition(line: 12, column: nil)),
        ("Sources/Main.swift#L12", FilePosition(line: 12, column: nil)),
        ("Sources/Main.swift#L12C5", FilePosition(line: 12, column: 5)),
        ("Sources/Main.swift#L12-L20", FilePosition(line: 12, column: nil)),
    ])
    func relativePathWithPositionOpensAtThatPosition(text: String, position: FilePosition) throws {
        try withTempDir { dir in
            let file = try makeFile("Sources/Main.swift", in: dir)
            #expect(
                TerminalLinkPolicy.action(for: text, source: .matchedText, baseDirectories: [dir])
                    == .openFile(file.resolvingSymlinksInPath(), position)
            )
        }
    }

    @Test func absolutePathWithPositionOpensAtThatPosition() throws {
        try withTempDir { dir in
            let file = try makeFile("a.txt", in: dir)
            #expect(
                TerminalLinkPolicy.action(for: file.path + ":3", source: .matchedText)
                    == .openFile(file.resolvingSymlinksInPath(), FilePosition(line: 3, column: nil))
            )
        }
    }

    /// A file whose name really ends in `:12` is opened as named.
    @Test func literalNameWinsOverASuffix() throws {
        try withTempDir { dir in
            let file = try makeFile("notes:12", in: dir)
            #expect(
                TerminalLinkPolicy.action(for: "notes:12", source: .matchedText, baseDirectories: [dir])
                    == .openFile(file.resolvingSymlinksInPath(), nil)
            )
        }
    }

    /// The first base that has the file wins, so the pane's own directory
    /// takes precedence over the container root.
    @Test func baseDirectoriesAreTriedInOrder() throws {
        try withTempDir { dir in
            let paneDir = dir.appendingPathComponent("pane")
            let rootDir = dir.appendingPathComponent("root")
            let inPane = try makeFile("x/a.swift", in: paneDir)
            _ = try makeFile("x/a.swift", in: rootDir)
            let onlyInRoot = try makeFile("y/b.swift", in: rootDir)
            #expect(
                TerminalLinkPolicy.action(for: "x/a.swift:1", source: .matchedText, baseDirectories: [paneDir, rootDir])
                    == .openFile(inPane.resolvingSymlinksInPath(), FilePosition(line: 1, column: nil))
            )
            #expect(
                TerminalLinkPolicy.action(for: "y/b.swift:1", source: .matchedText, baseDirectories: [paneDir, rootDir])
                    == .openFile(onlyInRoot.resolvingSymlinksInPath(), FilePosition(line: 1, column: nil))
            )
        }
    }

    /// A position never turns a script into something that opens.
    @Test func scriptWithPositionIsStillRevealed() throws {
        try withTempDir { dir in
            let file = try makeFile("run.sh", in: dir)
            #expect(
                TerminalLinkPolicy.action(for: "run.sh:1", source: .matchedText, baseDirectories: [dir])
                    == .reveal(file.resolvingSymlinksInPath())
            )
        }
    }

    @Test(arguments: ["a.swift:0", "a.swift:", "a.swift#L", "a.swift#Lx"])
    func malformedSuffixIsNotAPosition(text: String) {
        #expect(TerminalPathReference.candidates(for: text) == [TerminalPathReference(path: text, position: nil)])
    }

    private func makeFile(_ relativePath: String, in dir: URL) throws -> URL {
        let file = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        return file
    }
}
