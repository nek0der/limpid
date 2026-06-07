// SessionSnapshotTests.swift
// Limpid — schema v5 round-trip and transient pane-state reset semantics.
// The store debounces writes so this suite goes through the in-memory
// snapshot codec rather than the disk persistence layer
// (SessionSnapshotRoundTripTests covers the file-IO leg).

import Foundation
import Testing
@testable import Limpid

@Suite("SessionSnapshot", .tags(.persistence))
@MainActor
struct SessionSnapshotTests {

    @Test("current schema version is 5")
    func currentVersion_isV5() {
        #expect(SessionSnapshot.currentVersion == 5)
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

        #expect(restored.version == 5)
        // The unified `containers[]` array must split back into the typed
        // group / project arrays the in-memory session expects.
        #expect(restored.groups.count == 1)
        #expect(restored.projects.count == 1)
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

    @Test("a legacy groups/projects payload yields a fresh session")
    func restore_legacyShapedPayload_yieldsFreshSession() {
        // Pre-v5 state.json carried separate `groups[]` / `projects[]` keys
        // and no `containers[]`, so it no longer decodes at all — `try?`
        // swallows the error and the session stays empty. Either way an old
        // on-disk shape must never corrupt a launch.
        let legacy = Data("""
        {"version": 3, "groups": [], "projects": [], "tabs": [],
         "activeTabID": null, "sidebarWidth": 220, "sidebarHidden": false,
         "recentProjectPaths": []}
        """.utf8)
        let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: legacy)
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

    // MARK: - ContainerID forward-compat decoder

    @Test("each ContainerID case survives a Codable round-trip")
    func containerID_roundTrip_preservesEachCase() throws {
        let project = UUID()
        let worktree = UUID()
        let group = UUID()
        let cases: [ContainerID] = [
            .loose,
            .group(group),
            .project(project),
            .worktree(projectID: project, worktreeID: worktree)
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in cases {
            let data = try encoder.encode(value)
            let restored = try decoder.decode(ContainerID.self, from: data)
            #expect(restored == value)
        }
    }

    @Test("an unknown ContainerID discriminator decodes as .loose (forward-compat)")
    func containerID_unknownKind_fallsBackToLoose() throws {
        // Simulate a state.json written by a future Limpid that added
        // a `.workspace` case (or any other unknown discriminator).
        // The defensive decoder must keep the tab in the snapshot
        // instead of throwing and dropping it.
        let future = #"{"workspace":{"id":"11111111-1111-1111-1111-111111111111"}}"#
        let data = Data(future.utf8)
        let restored = try JSONDecoder().decode(ContainerID.self, from: data)
        #expect(restored == .loose)
        #expect(restored == ContainerID.unknownFallback)
    }

    @Test("a malformed ContainerID payload decodes as .loose rather than throwing")
    func containerID_malformedPayload_fallsBackToLoose() throws {
        // The discriminator is known but the associated value is
        // wrong-shaped. Forward-compat fallback is preferred over
        // throwing — the alternative quarantines the whole snapshot
        // and the user loses every tab.
        let broken = #"{"group":{"_0":"not-a-uuid"}}"#
        let data = Data(broken.utf8)
        let restored = try JSONDecoder().decode(ContainerID.self, from: data)
        #expect(restored == .loose)
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

    // MARK: - Forward-compat decoders

    @Test("Tab without a kind field decodes as .terminal")
    func tab_missingKind_defaultsToTerminal() throws {
        let session = WindowSession()
        let tab = session.openTab(container: .loose)

        let data = try JSONEncoder().encode(tab)
        var json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json.removeValue(forKey: "kind")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Tab.self, from: stripped)
        #expect(decoded.kind == .terminal)
    }

    @Test("Tab with an unknown kind raw value falls back to .terminal")
    func tab_unknownKind_fallsBackToTerminal() throws {
        let session = WindowSession()
        let tab = session.openTab(container: .loose)

        let data = try JSONEncoder().encode(tab)
        var json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json["kind"] = "future-editor-variant"
        let modified = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Tab.self, from: modified)
        #expect(decoded.kind == .terminal)
    }

    @Test("Snapshot drops a Container with an unknown kind without failing the load")
    func snapshot_unknownContainerKind_isDroppedNotFatal() throws {
        let session = WindowSession()
        _ = session.addGroup(name: "Servers")

        let snap = session.makeSnapshot()
        let data = try JSONEncoder().encode(snap)
        var json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var containers = try #require(json["containers"] as? [[String: Any]])
        containers.append(["kind": "future-monorepo", "data": [:]])
        json["containers"] = containers
        let modified = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: modified)
        // The known `.group` survives; the unknown kind is dropped.
        #expect(decoded.groups.count == 1)
        #expect(decoded.projects.isEmpty)
    }

    @Test("Snapshot wire format encodes tabs as a dictionary keyed by id + a tabOrder array")
    func snapshot_tabsWireShape_isDictPlusOrder() throws {
        let session = WindowSession()
        let first = session.openTab(container: .loose)
        let second = session.openTab(container: .loose)

        let data = try JSONEncoder().encode(session.makeSnapshot())
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let tabsByID = try #require(json["tabs"] as? [String: Any])
        #expect(tabsByID[first.id.uuidString.lowercased()] != nil
            || tabsByID[first.id.uuidString] != nil)
        #expect(tabsByID[second.id.uuidString.lowercased()] != nil
            || tabsByID[second.id.uuidString] != nil)

        let order = try #require(json["tabOrder"] as? [String])
        #expect(order.count == 2)
        // Order matches the open-order: first tab id leads.
        #expect(order.first?.lowercased() == first.id.uuidString.lowercased())
    }

    @Test("Snapshot tolerates extra ids in tabOrder that the tabs dict doesn't carry")
    func snapshot_tabOrderWithMissingIds_dropsThem() throws {
        let session = WindowSession()
        let tab = session.openTab(container: .loose)

        let data = try JSONEncoder().encode(session.makeSnapshot())
        var json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var order = try #require(json["tabOrder"] as? [String])
        order.append(UUID().uuidString) // phantom id with no tab body
        json["tabOrder"] = order
        let modified = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: modified)
        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs.first?.id == tab.id)
    }

    @Test("Snapshot preserves unknown root-level keys across decode → encode")
    func snapshot_unknownRootKey_roundTrips() throws {
        let session = WindowSession()
        session.openTabInActiveScope()

        let snap = session.makeSnapshot()
        let data = try JSONEncoder().encode(snap)
        var json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // Pretend a newer Limpid wrote a brand-new top-level key.
        json["futureCloudSyncToken"] = "abc-123-def"
        let modified = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: modified)
        #expect(decoded.unknownFields["futureCloudSyncToken"] == .string("abc-123-def"))

        let reencoded = try JSONEncoder().encode(decoded)
        let asAny = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        #expect(asAny?["futureCloudSyncToken"] as? String == "abc-123-def")
    }
}
