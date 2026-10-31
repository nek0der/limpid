// ScrollbackPathValidatorTests.swift
// Weir — `ScrollbackFiles.validatedPath(_:)` is the gate
// between a freshly-restored `state.json` and libghostty's scrollback
// replay path. A tampered file could otherwise point at arbitrary
// targets (`~/.ssh/id_rsa`, `/etc/passwd`) and libghostty would
// happily read them into a pane, where an OSC 52 sequence could
// exfiltrate the contents.
//
// The validator only lets a path through when both:
//   - the extension is `.vt` (the format ghostty itself emits), and
//   - the path resolves under the scrollback folder the session was
//     handed (`WorkspaceSession.scrollbackFiles`).
//
// Anything else returns nil. The tests below pin that contract
// against the obvious exfiltration shapes, each in a folder of its own.

import Foundation
import Testing
@testable import Weir

struct ScrollbackPathValidatorTests {
    /// A `.vt` file path in the folder: the only shape the validator
    /// should accept.
    fileprivate static func sandboxedPath(_ files: ScrollbackFiles, name: String = "pane.vt") -> String {
        files.directory.appendingPathComponent(name).path
    }

    /// Runs `body` with a scrollback folder of its own, which exists,
    /// spelled as the validator hands a path on (`/var/…`, links followed).
    private func withFiles(_ body: (ScrollbackFiles) throws -> Void) throws {
        try withTempDir { dir in
            let directory = dir.appendingPathComponent("scrollback", isDirectory: true).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body(ScrollbackFiles(directory: directory))
        }
    }

    @Test("a `.vt` file inside the scrollback sandbox passes through unchanged")
    func sandboxedVtFile_accepted() throws {
        try withFiles { files in
            let path = Self.sandboxedPath(files)
            #expect(files.validatedPath(path) == path)
        }
    }

    /// A path shape the validator turns away, built in the given folder.
    enum Rejected: CaseIterable, Sendable {
        /// Not `.vt`, though inside the sandbox.
        case otherExtension
        /// An absolute path outside the sandbox.
        case outside
        /// `<scrollback>/../leaked.vt`: the literal path starts with the
        /// sandbox prefix but `standardizedFileURL` pulls it back out, so
        /// the validator must follow that standardization rather than
        /// relying on the unresolved string.
        case parentTraversal
        /// `<scrollback>-evil/pane.vt` shares the sandbox's prefix
        /// character for character but lives in a sibling folder, so the
        /// comparison must include the trailing `/`.
        case prefixCollision
        /// A malformed path string, rejected without crashing.
        case empty

        func paths(in files: ScrollbackFiles) -> [String] {
            switch self {
            case .otherExtension:
                return [ScrollbackPathValidatorTests.sandboxedPath(files, name: "pane.txt")]
            case .outside:
                return ["/etc/passwd", ("~/.ssh/id_rsa" as NSString).expandingTildeInPath]
            case .parentTraversal:
                return [files.directory.appendingPathComponent("..").appendingPathComponent("leaked.vt").path]
            case .prefixCollision:
                var sandbox = files.directory.path
                while sandbox.hasSuffix("/") {
                    sandbox.removeLast()
                }
                return [sandbox + "-evil/pane.vt"]
            case .empty:
                return [""]
            }
        }
    }

    @Test(arguments: Rejected.allCases)
    func aPathShapeOutsideTheContract_isRejected(_ shape: Rejected) throws {
        try withFiles { files in
            for path in shape.paths(in: files) {
                #expect(files.validatedPath(path) == nil, "\(path)")
            }
        }
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
        try withFiles { files in
            let fm = FileManager.default
            let targetURL = files.directory.deletingLastPathComponent().appendingPathComponent("victim")
            let linkURL = files.directory.appendingPathComponent("leak.vt")
            try Data("secret".utf8).write(to: targetURL)
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

            #expect(files.validatedPath(linkURL.path) == nil)
        }
    }
}
