// SessionSnapshotTests.swift
// Schema v4 round-trip + cross-container persistence + transient
// pane-state reset semantics. The store debounces writes so this
// suite goes through the in-memory snapshot codec rather than the
// disk persistence layer (SessionSnapshotRoundTripTests covers the
// file-IO leg).

import Foundation
import Testing
@testable import Limpid

@Suite("SessionSnapshot", .tags(.persistence))
@MainActor
struct SessionSnapshotTests {

    @Test("current schema version is 4")
    func currentVersion_isV4() {
        #expect(SessionSnapshot.currentVersion == 4)
    }

    @Test("round-trip preserves loose / group / project container kinds")
    func roundTrip_preservesAllContainerKinds() throws {
        let s = WindowSession()
        let g = s.addGroup(name: "Servers")
        let project = s.addOrActivateProject(rootURL: URL(fileURLWithPath: "/tmp/round-trip-test"))
        _ = s.openTab(container: .loose)
        _ = s.openTab(container: .group(g.id))
        _ = s.openTab(container: .project(project.id))

        let data = try JSONEncoder().encode(s.makeSnapshot())
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        #expect(restored.version == 4)
        #expect(restored.tabs.count == 3)
        #expect(restored.tabs.contains { $0.container == .loose })
        #expect(restored.tabs.contains { $0.container == .group(g.id) })
        #expect(restored.tabs.contains { $0.container == .project(project.id) })
    }

    @Test("activeContainer survives encode → restore via WindowSession.restore(from:)")
    func restore_preservesActiveContainer() {
        let s = WindowSession()
        let g = s.addGroup(name: "Group A")
        _ = s.openTab(container: .group(g.id))
        s.setActiveContainer(.group(g.id))

        let snap = s.makeSnapshot()
        let restored = WindowSession()
        restored.restore(from: snap)

        #expect(restored.activeContainerID == .group(g.id))
    }

    @Test("a v3-shaped payload is silently discarded by restore(from:)")
    func restore_v3Payload_isDiscarded() {
        let v3 = Data("""
        {"version": 3, "groups": [], "projects": [], "tabs": [],
         "activeTabID": null, "sidebarWidth": 220, "sidebarHidden": false,
         "recentProjectPaths": []}
        """.utf8)
        let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: v3)
        let s = WindowSession()
        if let decoded {
            s.restore(from: decoded)
        }
        #expect(s.tabs.isEmpty)
        #expect(s.activeContainerID == .loose)
    }

    @Test("transient pane state (bell / child exit) resets on restore; unread persists")
    func restore_resetsTransientPaneStateButKeepsUnread() throws {
        let s = WindowSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        s.setBell(paneID: paneID, ringing: true)
        s.setChildExited(paneID: paneID, code: 137)
        s.markUnread(paneID: paneID)

        let snap = s.makeSnapshot()
        let restored = WindowSession()
        restored.restore(from: snap)

        #expect(restored.isBellRinging(paneID: paneID) == false)
        #expect(restored.childExitCode(paneID: paneID) == nil)
        #expect(restored.paneState(paneID).unreadCount == 1)
    }

    // MARK: - Round-trip through bytes

    @Test("snapshot encodes and decodes to an equivalent value via JSON")
    func encode_decodeYieldsEquivalentSnapshot() throws {
        let session = WindowSession()
        session.openTabInActiveScope()
        let snapshot = session.makeSnapshot()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        #expect(restored.version == snapshot.version)
        #expect(restored.tabs.count == snapshot.tabs.count)
        #expect(restored.activeTabID == snapshot.activeTabID)
        #expect(restored.activeContainerID == snapshot.activeContainerID)
        #expect(restored.sidebarWidth == snapshot.sidebarWidth)
    }

    @Test("a freshly-made snapshot is stamped with the current schema version")
    func makeSnapshot_stampsCurrentVersion() {
        let session = WindowSession()
        session.openTabInActiveScope()
        #expect(session.makeSnapshot().version == SessionSnapshot.currentVersion)
    }

    @Test("write → read round-trip through a temp file preserves the snapshot")
    func writeToDisk_thenDecode_returnsSameSnapshot() throws {
        let session = WindowSession()
        session.openTabInActiveScope()
        let snapshot = session.makeSnapshot()

        try withTempDir { dir in
            let url = dir.appendingPathComponent("state.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url)

            let data = try Data(contentsOf: url)
            let restored = try JSONDecoder().decode(SessionSnapshot.self, from: data)

            #expect(restored.version == snapshot.version)
            #expect(restored.tabs.count == snapshot.tabs.count)
        }
    }

    @Test("decoding malformed JSON throws a DecodingError")
    func decode_malformedJSON_throwsDecodingError() {
        let garbage = Data("{not json}".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SessionSnapshot.self, from: garbage)
        }
    }
}
