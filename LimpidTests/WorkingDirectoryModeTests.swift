// WorkingDirectoryModeTests.swift
// Limpid — covers the WorkingDirectoryMode enum's wire form and the
// cwd-resolution precedence in `openTab` for the scratch (loose) tabs.

import Foundation
import Testing
@testable import Limpid

@Suite("WorkingDirectoryMode")
@MainActor
struct WorkingDirectoryModeTests {

    // MARK: - Codable

    @Test("WorkingDirectoryMode encodes to a stable rawValue string")
    func mode_encodesToRawValue() throws {
        let encoder = JSONEncoder()
        let encoded = try WorkingDirectoryMode.allCases.map { mode in
            try String(bytes: encoder.encode(mode), encoding: .utf8)
        }
        #expect(encoded == [#""home""#, #""inheritPrevious""#, #""fixed""#])
    }

    // MARK: - The scratch row's folder

    /// The scratch row's Show in Finder opens where a new scratch tab
    /// would start, not always home.
    @Test func scratchStartDirectory_isWhereANewScratchTabStarts() {
        let session = WorkspaceSession()
        session.quickTabDefaultsProvider = { (.inheritPrevious, nil) }
        #expect(session.scratchStartDirectory(in: session.primaryWindowID) == nil)
        _ = session.openTab(container: .loose, workingDirectory: URL(fileURLWithPath: "/tmp/limpid-seed"))
        #expect(session.scratchStartDirectory(in: session.primaryWindowID)?.path == "/tmp/limpid-seed")
        session.quickTabDefaultsProvider = { (.fixed, URL(fileURLWithPath: "/tmp/limpid-fixed")) }
        #expect(session.scratchStartDirectory(in: session.primaryWindowID)?.path == "/tmp/limpid-fixed")
        session.quickTabDefaultsProvider = { (.home, nil) }
        #expect(session.scratchStartDirectory(in: session.primaryWindowID) == FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: - openTab cwd resolution (.loose / scratch)

    @Test("openTab .loose inheritPrevious with no active tab falls back to nil cwd")
    func openTab_looseInherit_noActive_isNil() {
        let session = WorkspaceSession()
        session.quickTabDefaultsProvider = { (.inheritPrevious, nil) }
        let tab = session.openTab(container: .loose)
        #expect(tab.workingDirectory == nil)
    }

    @Test("openTab .loose inheritPrevious copies the active tab's cwd")
    func openTab_looseInherit_copiesActiveCwd() {
        let session = WorkspaceSession()
        session.quickTabDefaultsProvider = { (.inheritPrevious, nil) }
        // Seed an active tab with a known cwd.
        let seed = session.openTab(
            container: .loose,
            workingDirectory: URL(fileURLWithPath: "/tmp/limpid-seed")
        )
        #expect(session.primarySelection.activeTabID == seed.id)
        let next = session.openTab(container: .loose)
        #expect(next.workingDirectory == "/tmp/limpid-seed")
    }

    @Test("openTab .loose inheritPrevious prefers the active tab's live pwd over its launch cwd")
    func openTab_looseInherit_prefersLivePwd() {
        let session = WorkspaceSession()
        session.quickTabDefaultsProvider = { (.inheritPrevious, nil) }
        let seed = session.openTab(
            container: .loose,
            workingDirectory: URL(fileURLWithPath: "/tmp/limpid-seed")
        )
        // Simulate the shell `cd`-ing: libghostty's PWD action updates
        // `pwd`, which must win over the stale launch `workingDirectory`.
        if let idx = session.tabs.firstIndex(where: { $0.id == seed.id }) {
            session.tabs[idx].pwd = "/tmp/limpid-after-cd"
        }
        let next = session.openTab(container: .loose)
        #expect(next.workingDirectory == "/tmp/limpid-after-cd")
    }

    @Test("openTab .loose reads the injected scratch defaults")
    func openTab_loose_usesProviderHome() {
        let session = WorkspaceSession()
        session.quickTabDefaultsProvider = { (.home, nil) }
        let tab = session.openTab(container: .loose)
        #expect(tab.workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test("openTab .loose fixed mode uses the provider's path")
    func openTab_loose_fixedPath() {
        let session = WorkspaceSession()
        let fixed = URL(fileURLWithPath: "/tmp/limpid-quicktab")
        session.quickTabDefaultsProvider = { (.fixed, fixed) }
        let tab = session.openTab(container: .loose)
        #expect(tab.workingDirectory == fixed.path)
    }

    @Test("explicit workingDirectory always wins over the resolved mode")
    func openTab_explicitWD_overridesMode() {
        let session = WorkspaceSession()
        session.quickTabDefaultsProvider = { (.home, nil) }
        let explicit = URL(fileURLWithPath: "/tmp/limpid-explicit")
        let tab = session.openTab(container: .loose, workingDirectory: explicit)
        #expect(tab.workingDirectory == explicit.path)
    }
}
