// TestWriteGuardTests.swift
// Weir — pins that a test run cannot change the user's real ~/Library.

import Foundation
import Testing
@testable import Weir

/// Every change these tests attempt at the real folder is one that would
/// fail on its own if the guard ever stopped refusing: its parent folder does
/// not exist, or sits under a file, so nothing can land beside the user's
/// data. What would make missing parents, or touch a folder that exists, is
/// checked through the rule alone.
struct TestWriteGuardTests {
    /// The real Application Support folder, asked of the system rather than
    /// `WeirPaths`, which moves it while tests run.
    private static var realApplicationSupport: URL {
        get throws {
            try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        }
    }

    /// A folder that does not exist inside the real Application Support.
    private static func missingProbeFolder() throws -> URL {
        try realApplicationSupport.appendingPathComponent("weir-guard-probe-\(UUID().uuidString)", isDirectory: true)
    }

    /// A folder inside the real Library that cannot be made at all, for a
    /// change that would create its folder first: it sits under the global
    /// preferences, a file, so even a guard that let it through leaves
    /// nothing behind.
    private static func uncreatableProbeFolder() throws -> URL {
        let library = try #require(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
        let file = library.appendingPathComponent("Preferences/.GlobalPreferences.plist")
        var isDirectory: ObjCBool = true
        try #require(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && !isDirectory.boolValue)
        return file.appendingPathComponent("weir-guard-probe-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Refusals at the real folder

    @Test func isRunningInTests_isTrueInTheTestHost() {
        #expect(WeirPaths.isRunningInTests)
        // The environment is the part that covers the host app's launch,
        // before the XCTest classes load, so it must answer on its own.
        #expect(WeirPaths.isTestHostByEnvironment)
    }

    @Test func writeAtomic_realApplicationSupport_isRefused() throws {
        let target = try Self.missingProbeFolder().appendingPathComponent("state.json")
        #expect(throws: TestWriteGuard.Refusal.self) {
            try SecureFileWrite.writeAtomic(Data("{}".utf8), to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func check_buildDataFolder_isRefused() throws {
        // The exact folder a store that skipped `init(directory:)` would have
        // used before the test host's folder moved out of `~/Library`. Asked
        // of the rule, not written: the folder exists on a developer's Mac.
        let target = try Self.realApplicationSupport
            .appendingPathComponent(WeirPaths.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("state.json")
        #expect(throws: TestWriteGuard.Refusal.self) {
            try TestWriteGuard.check(target)
        }
    }

    @Test func permits_realApplicationSupportFolder_isFalse() throws {
        // `ensureUserOnlyDirectory` asks exactly this before it creates
        // anything; creating the folder itself would make its parents.
        #expect(try !TestWriteGuard.permits(Self.missingProbeFolder()))
    }

    @Test func removeAndMove_realApplicationSupport_areRefusedBeforeTheFileSystemIsAsked() throws {
        let missing = try Self.missingProbeFolder().appendingPathComponent("notifications.json")
        // A refusal, not "no such file": the guard answers before
        // `FileManager` looks.
        #expect(throws: TestWriteGuard.Refusal.self) {
            try SecureFileWrite.removeItem(at: missing)
        }
        try withTempDir { dir in
            let source = dir.appendingPathComponent("frecency.json")
            try Data("[]".utf8).write(to: source)
            #expect(throws: TestWriteGuard.Refusal.self) {
                try SecureFileWrite.moveItem(at: source, to: missing)
            }
            // The refused move left the source where it was.
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func fileLock_realApplicationSupport_isRefusedBeforeTheSidecarIsCreated() throws {
        let record = try Self.missingProbeFolder().appendingPathComponent("record.json")
        var didRunBody = false
        #expect(throws: TestWriteGuard.Refusal.self) {
            try AgentFileLock.withLock(for: record) {
                didRunBody = true
                return .applied
            }
        }
        #expect(!didRunBody)
    }

    @MainActor
    @Test func scrollbackCapture_realApplicationSupport_isRefusedBeforeTheTerminalIsAsked() throws {
        // libghostty writes the dump itself, past `SecureFileWrite`, so the
        // capture has to ask the guard before it hands over the path.
        let writer = CountingScrollbackWriter()
        let files = try ScrollbackFiles(directory: Self.uncreatableProbeFolder())
        #expect(files.capture(UUID(), with: writer) == nil)
        #expect(writer.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: files.directory.path))
    }

    @MainActor
    @Test func ghosttyConfigWrite_realApplicationSupport_isRefused() throws {
        let folder = try Self.uncreatableProbeFolder()
        let path = GhosttyConfigBridge.writeConfigFile(settings: .default, resourcesDir: nil, directory: folder)
        #expect(path == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func applicationSupportDirectory_underTests_liesOutsideEveryProtectedFolder() {
        let directory = WeirPaths.applicationSupportDirectory()
        #expect(!TestWriteGuard.refuses(directory, protectedRoots: TestWriteGuard.protectedRoots))
        #expect(TestWriteGuard.permits(directory.appendingPathComponent("state.json")))
    }

    @Test func protectedRoots_includeTheRealLibraryAndCodexHome() throws {
        let library = try #require(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
        #expect(TestWriteGuard.refuses(
            library.appendingPathComponent("Preferences/x.plist"),
            protectedRoots: TestWriteGuard.protectedRoots
        ))
        let codexConfig = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
        #expect(TestWriteGuard.refuses(codexConfig, protectedRoots: TestWriteGuard.protectedRoots))
        // The Data volume's name for the same folder.
        let firmlinked = URL(fileURLWithPath: "/System/Volumes/Data" + library.path)
            .appendingPathComponent("Preferences/x.plist")
        #expect(TestWriteGuard.refuses(firmlinked, protectedRoots: TestWriteGuard.protectedRoots))
    }

    @Test func protectedFolder_namesTheKindOfFolderTheFaultLogs() throws {
        let state = try Self.realApplicationSupport
            .appendingPathComponent(WeirPaths.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("state.json")
        #expect(TestWriteGuard.protectedFolder(containing: state) == .library)
        let codexConfig = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
        #expect(TestWriteGuard.protectedFolder(containing: codexConfig) == .codexHome)
        #expect(TestWriteGuard.protectedFolder(containing: WeirPaths.applicationSupportDirectory()) == nil)
    }

    // MARK: - The rule, on folders of our own

    @Test func refuses_pathsInsideTheRoot_andNothingBeside() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            #expect(TestWriteGuard.refuses(root, protectedRoots: [root]))
            #expect(TestWriteGuard.refuses(root.appendingPathComponent("a/b/c.json"), protectedRoots: [root]))
            // A sibling whose name only starts the same way is not inside.
            #expect(!TestWriteGuard.refuses(dir.appendingPathComponent("Library2/c.json"), protectedRoots: [root]))
            #expect(!TestWriteGuard.refuses(dir.appendingPathComponent("c.json"), protectedRoots: [root]))
        }
    }

    @Test func refuses_seesThroughCaseDotDotAndSymlinks() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent("innocent", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

            #expect(TestWriteGuard.refuses(dir.appendingPathComponent("LIBRARY/x.json"), protectedRoots: [root]))
            #expect(TestWriteGuard.refuses(dir.appendingPathComponent("other/../Library/x.json"), protectedRoots: [root]))
            // The target does not exist yet; the link it goes through does.
            #expect(TestWriteGuard.refuses(link.appendingPathComponent("not-yet/x.json"), protectedRoots: [root]))
        }
    }

    @Test func refuses_followsDotDotAfterALinkTheWayTheKernelDoes() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("Library", isDirectory: true)
            let inner = root.appendingPathComponent("Inner", isDirectory: true)
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent("innocent", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inner)
            // Read as text, `innocent/..` is `dir`; the kernel takes it as
            // the parent of the link's target, which is the root.
            let target = URL(fileURLWithPath: link.path + "/../x.json")
            #expect(TestWriteGuard.refuses(target, protectedRoots: [root]))
        }
    }

    @Test func refuses_followsALinkWhoseTargetDoesNotExistYet() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("Library", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let dangling = dir.appendingPathComponent("state.json")
            // An open that follows the link would create the file at its
            // target, so the link is refused too.
            try FileManager.default.createSymbolicLink(
                at: dangling,
                withDestinationURL: root.appendingPathComponent("state.json")
            )
            #expect(TestWriteGuard.refuses(dangling, protectedRoots: [root]))
        }
    }

    @Test func refuses_aLoopOfLinks_ends() throws {
        try withTempDir { dir in
            let first = dir.appendingPathComponent("a")
            let second = dir.appendingPathComponent("b")
            try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: second.path)
            try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: first.path)
            #expect(!TestWriteGuard.refuses(first, protectedRoots: [dir.appendingPathComponent("Library")]))
        }
    }

    @Test func refuses_aLinkInsideTheRootThatPointsOutside() throws {
        try withTempDir { dir in
            let root = dir.appendingPathComponent("Library", isDirectory: true)
            let outside = dir.appendingPathComponent("dotfiles", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: outside.appendingPathComponent("config.toml"))
            // A file kept in a dotfiles folder and linked into the root: a
            // rename or unlink replaces the link, which lives in the root.
            let linkedFile = root.appendingPathComponent("config.toml")
            try FileManager.default.createSymbolicLink(
                at: linkedFile,
                withDestinationURL: outside.appendingPathComponent("config.toml")
            )
            #expect(TestWriteGuard.refuses(linkedFile, protectedRoots: [root]))
            // A whole folder of the root linked elsewhere.
            let linkedFolder = root.appendingPathComponent("Weir", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: outside)
            #expect(TestWriteGuard.refuses(
                linkedFolder.appendingPathComponent("state.json"),
                protectedRoots: [root]
            ))
            // The folder outside, reached by its own name, stays allowed.
            #expect(!TestWriteGuard.refuses(outside.appendingPathComponent("state.json"), protectedRoots: [root]))
        }
    }

    @Test func refuses_noRoots_refusesNothing() {
        #expect(!TestWriteGuard.refuses(URL(fileURLWithPath: "/tmp/x"), protectedRoots: []))
    }
}

/// A terminal that counts the dumps it was asked for and writes none.
@MainActor
private final class CountingScrollbackWriter: ScrollbackWriting {
    private(set) var calls = 0

    func writeScrollback(ofPane _: UUID, to _: URL) -> Bool {
        calls += 1
        return false
    }
}
