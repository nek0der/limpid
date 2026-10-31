// SessionSnapshotTests.swift
// Weir — the session snapshot's round-trip, its forward-compatible decoding, and what a restore resets.

import Foundation
import Testing
@testable import Weir

@Suite("SessionSnapshot", .tags(.persistence))
@MainActor
struct SessionSnapshotTests {

    @Test("round-trip keeps scratch and project tabs, with the projects as containers")
    func roundTrip_keepsScratchAndProjectTabs() throws {
        let s = WorkspaceSession()
        let project = s.addOrActivateProject(rootURL: URL(fileURLWithPath: "/tmp/round-trip-test"))
        let scratchTab = s.openTab(container: .loose)
        _ = s.openTab(container: .project(project.id))

        let snapshot = s.makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kinds = try #require(object["containers"] as? [[String: Any]]).compactMap { $0["kind"] as? String }
        let restored = WorkspaceSession()
        restored.restore(from: decoded)

        #expect(decoded.version == SessionSnapshot.currentVersion)
        #expect(decoded.windows == snapshot.windows)
        // The projects keep the shape the shell worktree hook reads.
        #expect(kinds == ["project"])
        #expect(restored.projects.count == 1)
        #expect(restored.tabs.count == 2)
        #expect(restored.tabs.first { $0.id == scratchTab.id }?.container == .loose)
        #expect(restored.tabs.contains { $0.container == .project(project.id) })
    }

    /// Version 6 never writes a group, but a container of a kind this build
    /// does not know, a group's or a newer build's, costs only itself: the
    /// file still loads, with that container passed over and its tabs
    /// among the scratch tabs.
    @Test("a container of an unknown kind is passed over, and its tabs become scratch tabs")
    func decode_unknownContainerKind_skipsIt_andItsTabsGoToScratch() throws {
        let s = WorkspaceSession()
        let project = s.addOrActivateProject(rootURL: URL(fileURLWithPath: "/tmp/unknown-kind-test"))
        let projectTab = s.openTab(container: .project(project.id))
        let groupTab = s.openTab(container: .loose)
        let futureTab = s.openTab(container: .loose)
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(s.makeSnapshot())) as? [String: Any]
        )
        let groupID = UUID().uuidString
        let futureID = UUID().uuidString
        var containers = try #require(json["containers"] as? [[String: Any]])
        containers.insert(["kind": "group", "group": ["id": groupID, "name": "Servers", "isExpanded": true]], at: 0)
        containers.append(["kind": "workspace", "workspace": ["id": futureID]])
        json["containers"] = containers
        var tabs = try #require(json["tabs"] as? [String: Any])
        for (tab, container) in [
            (groupTab, ["group": ["_0": groupID]]),
            (futureTab, ["workspace": ["id": futureID]])
        ] {
            var object = try #require(tabs[tab.id.uuidString] as? [String: Any])
            object["container"] = container
            tabs[tab.id.uuidString] = object
        }
        json["tabs"] = tabs

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        let restored = WorkspaceSession()
        restored.restore(from: decoded)

        #expect(decoded.version == SessionSnapshot.currentVersion)
        #expect(decoded.projects.map(\.id) == [project.id])
        #expect(restored.tabs.map(\.id) == [projectTab.id, groupTab.id, futureTab.id])
        #expect(restored.tabs.first { $0.id == projectTab.id }?.container == .project(project.id))
        #expect(restored.looseTabs.map(\.id) == [groupTab.id, futureTab.id])
        // Written back, only the project is a container.
        let rewritten = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.makeSnapshot())) as? [String: Any]
        )
        let kinds = try #require(rewritten["containers"] as? [[String: Any]]).compactMap { $0["kind"] as? String }
        #expect(kinds == ["project"])
    }

    @Test("activeContainer survives encode → restore via WorkspaceSession.restore(from:)")
    func restore_preservesActiveContainer() {
        let s = WorkspaceSession()
        let project = s.addOrActivateProject(rootURL: URL(fileURLWithPath: "/tmp/active-container-test"))
        s.setActiveContainer(.project(project.id))

        let snap = s.makeSnapshot()
        let restored = WorkspaceSession()
        restored.restore(from: snap)

        #expect(restored.primarySelection.activeContainerID == .project(project.id))
    }

    @Test("an active container that no longer exists is reported as a repair")
    func restore_missingActiveContainer_reportsRecovery() {
        let s = WorkspaceSession()
        _ = s.openTab(container: .loose)
        var snap = s.makeSnapshot()
        snap.windows[0].activeTabID = nil
        snap.windows[0].activeContainerID = .project(UUID())

        let restored = WorkspaceSession()
        let issue = restored.restore(from: snap)

        #expect(issue == .recovered(droppedTabCount: 0, didResetActiveContainer: true))
        #expect(restored.primarySelection.activeContainerID == .loose)
    }

    @Test("transient pane state resets on restore; unread persists")
    func restore_resetsTransientPaneStateButKeepsUnread() throws {
        let s = WorkspaceSession()
        let tab = s.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        s.setBell(paneID: paneID, ringing: true)
        s.setChildExited(paneID: paneID, code: 137)
        s.setWorkingDirectory(paneID: paneID, path: "/tmp/transient")
        s.markUnread(paneID: paneID)

        let snap = s.makeSnapshot()
        let restored = WorkspaceSession()
        restored.restore(from: snap)

        #expect(restored.isBellRinging(paneID: paneID) == false)
        #expect(restored.childExitCode(paneID: paneID) == nil)
        #expect(restored.workingDirectory(paneID: paneID) == nil)
        #expect(restored.paneState(paneID).unreadCount == 1)
    }

    // MARK: - ContainerID forward-compat decoder

    @Test("each ContainerID case survives a Codable round-trip")
    func containerID_roundTrip_preservesEachCase() throws {
        let project = UUID()
        let worktree = UUID()
        let cases: [ContainerID] = [
            .loose,
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

    /// A container this build cannot read keeps its tab, among the scratch
    /// tabs, rather than costing the whole snapshot: a newer build's kind,
    /// a group's (written before groups became scratch tabs), or a
    /// known kind whose value is wrong-shaped.
    @Test("a ContainerID this build cannot read decodes as .loose", arguments: [
        #"{"workspace":{"id":"11111111-1111-1111-1111-111111111111"}}"#,
        #"{"group":{"_0":"11111111-1111-1111-1111-111111111111"}}"#,
        #"{"project":{"_0":"not-a-uuid"}}"#
    ])
    func containerID_unreadable_fallsBackToLoose(json: String) throws {
        let restored = try JSONDecoder().decode(ContainerID.self, from: Data(json.utf8))
        #expect(restored == .loose)
        #expect(restored == ContainerID.unknownFallback)
    }

    // MARK: - Forward-compat decoders

    /// A tab whose kind is missing, or one a newer build wrote, opens as
    /// a terminal.
    @Test("a Tab without a kind this build knows decodes as .terminal", arguments: [nil, "future-editor-variant"])
    func tab_unknownOrMissingKind_decodesAsTerminal(kind: String?) throws {
        let session = WorkspaceSession()
        let tab = session.openTab(container: .loose)

        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any]
        )
        json["kind"] = kind
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.kind == .terminal)
    }

    /// A worktree's admission is saved with the session and read back.
    @Test("a worktree's admission survives a save and a restore", arguments: [
        WorktreeAdmission.created, .opened, .discovered
    ])
    func worktreeAdmission_survivesASaveAndARestore(admission: WorktreeAdmission) throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let row = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: admission)

        let restored = WorkspaceSession()
        try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(session.makeSnapshot())))

        #expect(restored.worktree(projectID: project.id, worktreeID: row.id)?.admission == admission)
    }

    /// A worktree with no admission (every file from before admissions were
    /// kept, or one whose value this build does not know) reads as not yet
    /// admitted, the rest of the row and the file intact; one not yet
    /// admitted is written without the key.
    /// `admissionJSON` is the key's value as JSON text; `nil` leaves the key out.
    @Test("a worktree with no admission, an unknown one, or one of another type reads as not yet admitted", arguments: [
        nil, "\"archived\"", "3", "null"
    ])
    func worktree_unreadableAdmission_readsAsNone(admissionJSON: String?) throws {
        let row = WorktreeFixture.make(label: "feat", isHidden: true, admission: .created)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        json["admission"] = try admissionJSON.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed)
        }

        let decoded = try JSONDecoder().decode(Worktree.self, from: JSONSerialization.data(withJSONObject: json))
        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])

        #expect(decoded.admission == nil)
        #expect(decoded.id == row.id)
        #expect(decoded.label == "feat")
        #expect(decoded.isHidden)
        #expect(written["admission"] == nil)
    }

    /// Only `admission` is lenient: a worktree missing a key it always had
    /// still fails, as it did with the synthesized decoder.
    @Test("a worktree missing isHidden still fails to decode")
    func worktree_missingIsHidden_stillFails() throws {
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(WorktreeFixture.make())) as? [String: Any]
        )
        json["isHidden"] = nil
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Worktree.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test("Snapshot wire format encodes tabs as a dictionary keyed by id + a tabOrder array")
    func snapshot_tabsWireShape_isDictPlusOrder() throws {
        let session = WorkspaceSession()
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
        let session = WorkspaceSession()
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

    @Test("a root field this build does not know survives a restore and a save")
    func aRootFieldThisBuildDoesNotKnow_survivesARestoreAndSave() throws {
        let session = WorkspaceSession()
        session.openTabInActiveScope()
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session.makeSnapshot())) as? [String: Any]
        )
        // A newer Weir's field, as a rollback finds it.
        json["projectViewsFromTheFuture"] = ["kept": true]
        json["futureCloudSyncToken"] = "abc-123-def"
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.unknownFields["futureCloudSyncToken"] == .string("abc-123-def"))

        let restored = WorkspaceSession()
        restored.restore(from: decoded)
        let saved = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.makeSnapshot())) as? [String: Any]
        )

        #expect((saved["projectViewsFromTheFuture"] as? [String: Any])?["kept"] as? Bool == true)
        #expect(saved["futureCloudSyncToken"] as? String == "abc-123-def")
    }

    @Test("a second restore replaces what the first carried rather than adding to it")
    func aSecondRestore_replacesTheCarriedRootFields() throws {
        let session = WorkspaceSession()
        session.openTabInActiveScope()
        let plain = try JSONEncoder().encode(session.makeSnapshot())
        var json = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        json["fromTheFuture"] = 1
        let carrying = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))

        let restored = WorkspaceSession()
        restored.restore(from: carrying)
        #expect(restored.carriedRootFields["fromTheFuture"] != nil)
        try restored.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: plain))

        #expect(restored.carriedRootFields.isEmpty)
    }

    @Test("a known key set among the unknown fields is written from its field alone")
    func aKnownKeyAmongTheUnknownFields_isNotWritten() throws {
        let session = WorkspaceSession()
        session.openTabInActiveScope()
        var snapshot = session.makeSnapshot()
        snapshot.unknownFields["recentProjectPaths"] = .string("stale")
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        #expect(object["recentProjectPaths"] is [Any])
    }

    @Test("a root field this build knows is written once, from the session, not carried")
    func aKnownRootField_isNotWrittenTwice() throws {
        let session = WorkspaceSession()
        session.openTabInActiveScope()
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(session.makeSnapshot()))

        let restored = WorkspaceSession()
        restored.restore(from: decoded)

        #expect(restored.carriedRootFields.isEmpty)
        #expect(restored.makeSnapshot().unknownFields.isEmpty)
    }
}
