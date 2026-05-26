// WorkingDirectoryModeTests.swift
// Limpid — covers the WorkingDirectoryMode enum, its Codable
// back-compat on TabGroup, and the cwd-resolution precedence in
// `openTab` for the Group and Quick Tabs (loose) scopes.

import Foundation
import Testing
@testable import Limpid

@Suite("WorkingDirectoryMode")
@MainActor
struct WorkingDirectoryModeTests {

    // MARK: - Codable round-trip + back-compat

    @Test("WorkingDirectoryMode encodes to a stable rawValue string")
    func mode_encodesToRawValue() throws {
        let encoder = JSONEncoder()
        for mode in WorkingDirectoryMode.allCases {
            let data = try encoder.encode(mode)
            let json = String(bytes: data, encoding: .utf8)
            #expect(json == "\"\(mode.rawValue)\"")
        }
    }

    @Test("TabGroup round-trips its cwd fields", .tags(.persistence))
    func tabGroup_roundTripsCwd() throws {
        let url = URL(fileURLWithPath: "/tmp/limpid-fixed")
        let group = TabGroup(name: "G", cwdMode: .fixed, cwdPath: url)
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(TabGroup.self, from: data)
        #expect(decoded.cwdMode == .fixed)
        #expect(decoded.cwdPath == url)
    }

    @Test("legacy TabGroup JSON (no cwd keys) decodes with defaults", .tags(.persistence))
    func tabGroup_legacyDecodeDefaults() throws {
        // A snapshot written before the cwd fields existed.
        let legacy = """
        { "id": "\(UUID().uuidString)", "name": "Legacy", "isExpanded": true }
        """
        let decoded = try JSONDecoder().decode(TabGroup.self, from: Data(legacy.utf8))
        #expect(decoded.cwdMode == .inheritPrevious)
        #expect(decoded.cwdPath == nil)
    }

    @Test("group cwd survives a full SessionSnapshot round-trip", .tags(.persistence))
    func sessionSnapshot_persistsGroupCwd() throws {
        let session = WindowSession()
        let group = session.addGroup(name: "Servers")
        let fixed = URL(fileURLWithPath: "/tmp/limpid-servers")
        session.setGroupCwdMode(group.id, to: .fixed, path: fixed)

        let data = try JSONEncoder().encode(session.makeSnapshot())
        let restored = WindowSession()
        try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))

        let g = restored.groups.first { $0.id == group.id }
        #expect(g?.cwdMode == .fixed)
        #expect(g?.cwdPath == fixed)
    }

    // MARK: - setGroupCwdMode

    @Test("setGroupCwdMode clears the fixed path when mode isn't .fixed")
    func setGroupCwdMode_clearsPathWhenNotFixed() {
        let session = WindowSession()
        let group = session.addGroup(name: "G")
        session.setGroupCwdMode(group.id, to: .fixed, path: URL(fileURLWithPath: "/tmp/x"))
        session.setGroupCwdMode(group.id, to: .home)
        let g = session.groups.first { $0.id == group.id }
        #expect(g?.cwdMode == .home)
        #expect(g?.cwdPath == nil)
    }

    // MARK: - openTab cwd resolution (.group)

    @Test("openTab .group home mode resolves to the home directory")
    func openTab_groupHome_usesHome() {
        let session = WindowSession()
        let group = session.addGroup(name: "G")
        session.setGroupCwdMode(group.id, to: .home)
        let tab = session.openTab(container: .group(group.id))
        #expect(tab.workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test("openTab .group fixed mode resolves to the fixed path")
    func openTab_groupFixed_usesPath() {
        let session = WindowSession()
        let group = session.addGroup(name: "G")
        let fixed = URL(fileURLWithPath: "/tmp/limpid-group-fixed")
        session.setGroupCwdMode(group.id, to: .fixed, path: fixed)
        let tab = session.openTab(container: .group(group.id))
        #expect(tab.workingDirectory == fixed.path)
    }

    @Test("openTab .group inheritPrevious with no active tab falls back to nil cwd")
    func openTab_groupInherit_noActive_isNil() {
        let session = WindowSession()
        let group = session.addGroup(name: "G")
        // Default mode is .inheritPrevious; no tab is active yet.
        let tab = session.openTab(container: .group(group.id))
        #expect(tab.workingDirectory == nil)
    }

    @Test("openTab .group inheritPrevious copies the active tab's cwd")
    func openTab_groupInherit_copiesActiveCwd() {
        let session = WindowSession()
        let group = session.addGroup(name: "G")
        // Seed an active tab with a known cwd.
        let seed = session.openTab(
            container: .group(group.id),
            workingDirectory: URL(fileURLWithPath: "/tmp/limpid-seed")
        )
        #expect(session.activeTabID == seed.id)
        let next = session.openTab(container: .group(group.id))
        #expect(next.workingDirectory == "/tmp/limpid-seed")
    }

    @Test("openTab .group inheritPrevious prefers the active tab's live pwd over its launch cwd")
    func openTab_groupInherit_prefersLivePwd() {
        let session = WindowSession()
        let group = session.addGroup(name: "G")
        let seed = session.openTab(
            container: .group(group.id),
            workingDirectory: URL(fileURLWithPath: "/tmp/limpid-seed")
        )
        // Simulate the shell `cd`-ing: libghostty's PWD action updates
        // `pwd`, which must win over the stale launch `workingDirectory`.
        if let idx = session.tabs.firstIndex(where: { $0.id == seed.id }) {
            session.tabs[idx].pwd = "/tmp/limpid-after-cd"
        }
        let next = session.openTab(container: .group(group.id))
        #expect(next.workingDirectory == "/tmp/limpid-after-cd")
    }

    // MARK: - openTab cwd resolution (.loose / Quick Tabs)

    @Test("openTab .loose reads the injected Quick Tabs defaults")
    func openTab_loose_usesProviderHome() {
        let session = WindowSession()
        session.quickTabDefaultsProvider = { (.home, nil) }
        let tab = session.openTab(container: .loose)
        #expect(tab.workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test("openTab .loose fixed mode uses the provider's path")
    func openTab_loose_fixedPath() {
        let session = WindowSession()
        let fixed = URL(fileURLWithPath: "/tmp/limpid-quicktab")
        session.quickTabDefaultsProvider = { (.fixed, fixed) }
        let tab = session.openTab(container: .loose)
        #expect(tab.workingDirectory == fixed.path)
    }

    @Test("explicit workingDirectory always wins over the resolved mode")
    func openTab_explicitWD_overridesMode() {
        let session = WindowSession()
        session.quickTabDefaultsProvider = { (.home, nil) }
        let explicit = URL(fileURLWithPath: "/tmp/limpid-explicit")
        let tab = session.openTab(container: .loose, workingDirectory: explicit)
        #expect(tab.workingDirectory == explicit.path)
    }
}
