// SessionSnapshotV6MigrationTests.swift
// Weir — a version 5 state.json brought to 6: groups become scratch tabs, the root selection becomes window records.

import Foundation
import Testing
@testable import Weir

@Suite(.tags(.persistence))
@MainActor
struct SessionSnapshotV6MigrationTests {
    /// A group as a version 5 build wrote it in `containers`. Today's
    /// types know no group, so the tests spell the wire shape out; the
    /// synthesized encoding leaves an absent color or folder out, as
    /// version 5 did.
    private struct Group5: Encodable {
        let id = UUID()
        var name: String
        var paletteIndex: Int?
        var isExpanded = true
        var cwdMode: WorkingDirectoryMode = .inheritPrevious
        var cwdPath: URL?

        init(name: String, paletteIndex: Int? = nil, cwdMode: WorkingDirectoryMode = .inheritPrevious, cwdPath: URL? = nil) {
            self.name = name
            self.paletteIndex = paletteIndex
            self.cwdMode = cwdMode
            self.cwdPath = cwdPath
        }
    }

    /// A tab of a version 5 document, with the group it is in, which
    /// `Tab` can no longer name.
    private struct Tab5 {
        let tab: Tab
        var groupID: UUID?

        var id: UUID {
            tab.id
        }
    }

    /// A version 5 document as a version 5 build wrote it: groups and
    /// projects in `containers`, the selection and layout at the root.
    private struct Version5 {
        var groups: [Group5] = []
        var projects: [Project] = []
        var tabs: [Tab5] = []
        var order: [UUID]?
        var root: [String: Any] = [
            "sidebarWidth": 260, "sidebarHidden": true, "tabColumnHorizontal": false,
            "tabColumnWidth": 222, "attentionHeightFraction": 0.4,
            "windowFrame": ["x": 10, "y": 20, "width": 1100, "height": 700]
        ]
        /// Elements of any JSON type, so a test can put in one that is
        /// not a record.
        var windows: [Any]?
        /// Fields a later build added to every tab.
        var extraTabFields: [String: Any] = [:]

        func data() throws -> Data {
            var object = root
            object["version"] = 5
            object["containers"] = try groups.map { try ["kind": "group", "group": Self.object($0)] }
                + projects.map { try Self.object(Container.project($0)) }
            object["tabs"] = try Dictionary(uniqueKeysWithValues: tabs.map { tab in
                var fields = try Self.object(tab.tab) as? [String: Any] ?? [:]
                if let groupID = tab.groupID {
                    fields["container"] = Self.json(group: groupID)
                }
                fields.merge(extraTabFields) { _, extra in extra }
                return (tab.id.uuidString, fields)
            })
            object["tabOrder"] = (order ?? tabs.map(\.id)).map(\.uuidString)
            object["recentProjectPaths"] = []
            object["windows"] = windows
            return try JSONSerialization.data(withJSONObject: object)
        }

        static func object(_ value: some Encodable) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }

        static func json(_ container: ContainerID) throws -> Any {
            try object(container)
        }

        /// A group's container, as version 5 wrote it.
        static func json(group id: UUID) -> Any {
            ["group": ["_0": id.uuidString]]
        }
    }

    private static func tab(_ title: String, in container: ContainerID) -> Tab5 {
        Tab5(tab: Tab.newWithSinglePane(title: title, workingDirectory: nil, container: container).tab)
    }

    private static func tab(_ title: String, inGroup groupID: UUID) -> Tab5 {
        var tab = tab(title, in: .loose)
        tab.groupID = groupID
        return tab
    }

    private static func migrated(_ v5: Version5) throws -> SessionSnapshot {
        let data = try SessionSnapshotV5.migrate(v5.data())
        return try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// The migrated session as the store writes it: the step's result
    /// decoded and encoded again (`SessionStore.loadMigrated`).
    private static func written(_ snapshot: SessionSnapshot) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: PersistenceCoders.makeEncoder().encode(snapshot)) as? [String: Any])
    }

    // MARK: - Groups

    @Test func groups_becomeScratchTabs_withPrefixColorCwd() throws {
        let fixed = URL(fileURLWithPath: "/tmp/servers")
        let prod = Group5(name: "prod", paletteIndex: 3, cwdMode: .fixed, cwdPath: fixed)
        let ssh = Self.tab("ssh", inGroup: prod.id)
        var v5 = Version5(groups: [prod], tabs: [ssh])
        v5.root["activeTabID"] = ssh.id.uuidString
        v5.root["activeContainerID"] = Version5.json(group: prod.id)

        let snapshot = try Self.migrated(v5)

        let moved = try #require(snapshot.tabs.first)
        #expect(moved.container == .loose)
        #expect(moved.namePrefix == "prod")
        #expect(moved.displayTitle == "prod · ssh")
        #expect(moved.paletteIndex == 3)
        #expect(moved.cwdMode == .fixed)
        #expect(moved.cwdPath == fixed)
        // A scratch tab the person was on stays selected, as a scratch tab.
        #expect(snapshot.windows.first?.activeTabID == ssh.id)
        #expect(snapshot.windows.first?.activeContainerID == .loose)
        #expect(snapshot.windows.first?.projectID == nil)
    }

    @Test func groupTabs_followTheScratchTabs_byGroupThenTabOrder() throws {
        let first = Group5(name: "a")
        let second = Group5(name: "b")
        let scratch = Self.tab("scratch", in: .loose)
        let b1 = Self.tab("b1", inGroup: second.id)
        let a1 = Self.tab("a1", inGroup: first.id)
        let a2 = Self.tab("a2", inGroup: first.id)
        let later = Self.tab("later scratch", in: .loose)
        let v5 = Version5(groups: [first, second], tabs: [b1, a1, scratch, a2, later])

        let snapshot = try Self.migrated(v5)

        #expect(snapshot.tabs.map(\.id) == [scratch.id, later.id, a1.id, a2.id, b1.id])
    }

    @Test func orphanGroupTab_becomesScratchTab() throws {
        let orphan = Self.tab("orphan", inGroup: UUID())

        let snapshot = try Self.migrated(Version5(tabs: [orphan]))

        let moved = try #require(snapshot.tabs.first)
        #expect(moved.container == .loose)
        #expect(moved.namePrefix == nil)
        #expect(moved.paletteIndex == nil)
        #expect(moved.cwdMode == nil)
    }

    @Test func aGroupWithoutAFolderDefault_keepsItsContinueWhereYouAre() throws {
        var group = Group5(name: "plain")
        group.paletteIndex = nil
        let tab = Self.tab("t", inGroup: group.id)

        let snapshot = try Self.migrated(Version5(groups: [group], tabs: [tab]))

        #expect(snapshot.tabs.first?.cwdMode == .inheritPrevious)
        #expect(snapshot.tabs.first?.paletteIndex == nil)
    }

    /// How a version 5 group spelled its working-directory mode.
    enum GroupCwdMode: String, CaseIterable, Sendable {
        /// No key: a group saved before the mode existed.
        case absent
        /// `null`, which version 5 read as absent (`decodeIfPresent`).
        case null
        /// A value that names no mode, which version 5 refused.
        case notAName
        /// "Continue where the active tab is", written out.
        case inheritPrevious
    }

    /// A tab whose shell moved away from where it opened, after the
    /// migration and again after the store wrote and read it back, keeps
    /// starting its new panes where it is, as its group had it, however the
    /// group spelled its default.
    @Test(arguments: GroupCwdMode.allCases)
    func aGroupWithoutAFolderDefault_keepsTheTabsCurrentFolder(_ mode: GroupCwdMode) throws {
        let group = Group5(name: "plain")
        var tab = Self.tab("t", inGroup: group.id)
        var moved = tab.tab
        moved.workingDirectory = "/tmp/opened-here"
        moved.pwd = "/tmp/moved-here"
        tab = Tab5(tab: moved, groupID: group.id)
        var object = try #require(
            JSONSerialization.jsonObject(with: Version5(groups: [group], tabs: [tab]).data()) as? [String: Any]
        )
        var containers = try #require(object["containers"] as? [[String: Any]])
        var fields = try #require(containers[0]["group"] as? [String: Any])
        switch mode {
        case .absent: fields.removeValue(forKey: "cwdMode")
        case .null: fields["cwdMode"] = NSNull()
        case .notAName: fields["cwdMode"] = 3
        case .inheritPrevious: fields["cwdMode"] = "inheritPrevious"
        }
        containers[0]["group"] = fields
        object["containers"] = containers

        let data = try SessionSnapshotV5.migrate(JSONSerialization.data(withJSONObject: object))
        let snapshot = try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: data)
        let reread = try PersistenceCoders.makeDecoder().decode(
            SessionSnapshot.self, from: PersistenceCoders.makeEncoder().encode(snapshot)
        )

        for migrated in [snapshot, reread] {
            let result = try #require(migrated.tabs.first)
            #expect(result.cwdMode == .inheritPrevious)
            #expect(result.newPaneWorkingDirectory == "/tmp/moved-here")
        }
    }

    // MARK: - The root

    @Test func migratedRootKeys_areNotKeptAsUnknownFields() throws {
        let tab = Self.tab("t", in: .loose)
        var version5 = Version5(tabs: [tab])
        version5.root["activeTabID"] = tab.id.uuidString
        version5.root["activeContainerID"] = try Version5.json(.loose)
        #expect(Set(SessionSnapshotV5.movedRootKeys).isSubset(of: version5.root.keys))
        let data = try SessionSnapshotV5.migrate(version5.data())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in SessionSnapshotV5.movedRootKeys {
            #expect(object[key] == nil, "\(key)")
        }

        let snapshot = try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: data)
        #expect(snapshot.version == 6)
        #expect(snapshot.unknownFields.isEmpty)
    }

    @Test func singleWindow_isCreatedForActiveProject() throws {
        let project = Project(name: "repo", rootURL: URL(fileURLWithPath: "/tmp/repo"))
        let worktree = ContainerID.worktree(projectID: project.id, worktreeID: UUID())
        var v5 = Version5(projects: [project])
        v5.root["activeContainerID"] = try Version5.json(worktree)

        let snapshot = try Self.migrated(v5)

        #expect(snapshot.windows.count == 1)
        let record = try #require(snapshot.windows.first)
        #expect(record.projectID == project.id)
        #expect(record.activeContainerID == worktree)
        #expect(record.frame == WindowFrame(CGRect(x: 10, y: 20, width: 1100, height: 700)))
        #expect(record.sidebarHidden)
    }

    /// The root's tab column (its orientation and width) is dropped, since
    /// version 6 has only the pane strip, and the sidebar starts at its
    /// default width rather than the root's.
    @Test func theTabColumn_isDropped_andTheSidebarStartsAtItsDefault() throws {
        var v5 = Version5()
        v5.root["tabColumnHorizontal"] = false

        let snapshot = try Self.migrated(v5)
        let record = try #require(snapshot.windows.first)

        #expect(record.sidebarWidth == 304)
        let object = try Self.written(snapshot)
        let written = try #require((object["windows"] as? [[String: Any]])?.first)
        #expect(written["tabOrientation"] == nil)
        #expect(written["tabColumnWidth"] == nil)
        #expect(object["tabColumnHorizontal"] == nil)
        #expect(object["tabColumnWidth"] == nil)
    }

    @Test func windowsSavedBeforeTheMove_keepTheirOwn_butThePrimaryFollowsTheRoot() throws {
        let project = Project(name: "repo", rootURL: URL(fileURLWithPath: "/tmp/repo"))
        let other = Project(name: "other", rootURL: URL(fileURLWithPath: "/tmp/other"))
        var v5 = Version5(projects: [project, other])
        v5.root["activeContainerID"] = try Version5.json(.project(project.id))
        let otherContainer = try Version5.json(.project(other.id))
        v5.windows = [
            [
                "activeContainerID": otherContainer, "projectID": other.id.uuidString,
                "frame": ["x": 0, "y": 0, "width": 500, "height": 500],
                "sidebarWidth": 999, "tabColumnWidth": 111, "isChangesPanelPresented": true, "isFront": true
            ],
            [
                "activeContainerID": otherContainer, "projectID": other.id.uuidString,
                "sidebarWidth": 280, "tabOrientation": "column", "tabColumnWidth": 111
            ]
        ]

        let snapshot = try Self.migrated(v5)

        #expect(snapshot.windows.count == 2)
        let primary = snapshot.windows[0]
        #expect(primary.projectID == project.id)
        #expect(primary.frame == WindowFrame(CGRect(x: 10, y: 20, width: 1100, height: 700)))
        #expect(primary.sidebarWidth == 304)
        #expect(primary.isChangesPanelPresented)
        #expect(primary.isFront)
        let later = snapshot.windows[1]
        #expect(later.projectID == other.id)
        #expect(later.sidebarWidth == 280)
        // A later window that had its tabs in the column is written with
        // neither the column nor its width.
        let written = try #require(Self.written(snapshot)["windows"] as? [[String: Any]])
        #expect(written.allSatisfy { $0["tabOrientation"] == nil && $0["tabColumnWidth"] == nil })
    }

    /// A later element that is not a record costs only itself: the windows
    /// around it keep theirs.
    @Test func aWindowThatIsNotARecord_costsOnlyItself() throws {
        let project = Project(name: "repo", rootURL: URL(fileURLWithPath: "/tmp/repo"))
        let other = Project(name: "other", rootURL: URL(fileURLWithPath: "/tmp/other"))
        var v5 = Version5(projects: [project, other])
        v5.root["activeContainerID"] = try Version5.json(.project(project.id))
        let otherRecord: [String: Any] = try [
            "activeContainerID": Version5.json(.project(other.id)), "projectID": other.id.uuidString, "sidebarWidth": 280
        ]
        v5.windows = [["isChangesPanelPresented": true], NSNull(), otherRecord]

        let snapshot = try Self.migrated(v5)

        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first?.projectID == project.id)
        #expect(snapshot.windows.first?.isChangesPanelPresented == true)
        #expect(snapshot.windows.last?.projectID == other.id)
        #expect(snapshot.windows.last?.sidebarWidth == 280)
    }

    /// A first element that is not a record leaves the primary on the root
    /// alone, and the later windows keep theirs.
    @Test func aFirstWindowThatIsNotARecord_leavesThePrimaryOnTheRoot() throws {
        let project = Project(name: "repo", rootURL: URL(fileURLWithPath: "/tmp/repo"))
        let other = Project(name: "other", rootURL: URL(fileURLWithPath: "/tmp/other"))
        var v5 = Version5(projects: [project, other])
        v5.root["activeContainerID"] = try Version5.json(.project(project.id))
        v5.windows = try ["not a record", ["activeContainerID": Version5.json(.project(other.id)), "projectID": other.id.uuidString]]

        let snapshot = try Self.migrated(v5)

        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.first?.projectID == project.id)
        #expect(snapshot.windows.first?.sidebarWidth == 304)
        #expect(snapshot.windows.last?.projectID == other.id)
    }

    // MARK: - Projects and the store

    @Test func projects_keepTheirContainersShape() throws {
        let project = Project(name: "repo", rootURL: URL(fileURLWithPath: "/tmp/repo"))
        let data = try SessionSnapshotV5.migrate(Version5(groups: [Group5(name: "g")], projects: [project]).data())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let containers = try #require(object["containers"] as? [[String: Any]])

        #expect(containers.count == 1)
        #expect(containers.first?["kind"] as? String == "project")
        #expect((containers.first?["project"] as? [String: Any])?["rootURL"] != nil)
    }

    @Test func aVersion5File_isBackedUpOnce_andWrittenAsVersion6() throws {
        try withTempDir { dir in
            let group = Group5(name: "prod", paletteIndex: 1)
            let original = try Version5(groups: [group], tabs: [Self.tab("ssh", inGroup: group.id)]).data()
            let file = dir.appendingPathComponent("state.json")
            try original.write(to: file)

            guard case let .loaded(snapshot) = SessionStore(directory: dir).load() else {
                Issue.record("expected the version 5 file to load")
                return
            }
            #expect(snapshot.tabs.first?.namePrefix == "prod")
            let written = try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: file))
            #expect(written.version == 6)
            #expect(try Data(contentsOf: dir.appendingPathComponent("state.json.pre-v6")) == original)

            // Read again: already version 6, nothing more is set aside.
            guard case .loaded = SessionStore(directory: dir).load() else {
                Issue.record("expected the version 6 file to load")
                return
            }
            let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".pre-v6") }
            #expect(backups == ["state.json.pre-v6"])
        }
    }

    /// A version 5 file without its shape (no containers or tabs) makes
    /// the step throw, which the store sets aside unchanged
    /// (`SessionStoreTests.throwingStep_movesTheFileAsideUnchanged`).
    @Test func aVersion5FileWithoutItsShape_makesTheStepThrow() {
        #expect(throws: (any Error).self) {
            try SessionSnapshotV5.migrate(Data(#"{"version":5,"something":"else"}"#.utf8))
        }
    }

    // MARK: - Tabs and windows the step must not lose

    @Test func aGroupTabTheOrderLeavesOut_movesToo_asDoesOneWithNoOrderAtAll() throws {
        let group = Group5(name: "g")
        let listed = Self.tab("listed", inGroup: group.id)
        let unlisted = Self.tab("unlisted", inGroup: group.id)
        var withOrder = Version5(groups: [group], tabs: [listed, unlisted])
        withOrder.order = [listed.id]

        let ordered = try Self.migrated(withOrder)
        #expect(ordered.tabs.map(\.id) == [listed.id, unlisted.id])
        #expect(ordered.tabs.allSatisfy { $0.container == .loose && $0.namePrefix == "g" })

        var object = try #require(JSONSerialization.jsonObject(with: withOrder.data()) as? [String: Any])
        object.removeValue(forKey: "tabOrder")
        let migrated = try SessionSnapshotV5.migrate(JSONSerialization.data(withJSONObject: object))
        let unordered = try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: migrated)
        #expect(Set(unordered.tabs.map(\.id)) == [listed.id, unlisted.id])
        #expect(unordered.tabs.allSatisfy { $0.container == .loose })
    }

    @Test func aLaterWindowOnAGroup_isOnTheScratchTabs() throws {
        let group = Group5(name: "g")
        let project = Project(name: "repo", rootURL: URL(fileURLWithPath: "/tmp/repo"))
        var version5 = Version5(groups: [group], projects: [project])
        let onGroup = Version5.json(group: group.id)
        version5.windows = [[:], ["activeContainerID": onGroup, "projectID": project.id.uuidString]]

        let snapshot = try Self.migrated(version5)

        #expect(snapshot.windows.last?.activeContainerID == .loose)
        #expect(snapshot.windows.last?.projectID == project.id)
    }

    @Test func aPrimaryOnTheScratchTabs_keepsTheProjectItsSavedWindowKept() throws {
        let project = Project(name: "repo", rootURL: URL(fileURLWithPath: "/tmp/repo"))
        var version5 = Version5(projects: [project])
        let scratch = try Version5.json(.loose)
        version5.root["activeContainerID"] = scratch
        version5.windows = [["activeContainerID": scratch, "projectID": project.id.uuidString]]

        let snapshot = try Self.migrated(version5)

        #expect(snapshot.windows.first?.projectID == project.id)

        // A saved record that was on a project is older than the root,
        // which has moved to the scratch tabs since: it names nothing.
        version5.windows = try [["activeContainerID": Version5.json(.project(project.id)), "projectID": project.id.uuidString]]
        #expect(try Self.migrated(version5).windows.first?.projectID == nil)
    }

    @Test func aTabFieldALaterBuildAdded_passesThroughTheStep() throws {
        let tab = Self.tab("t", in: .loose)
        var version5 = Version5(tabs: [tab])
        version5.extraTabFields = ["futureField": "kept"]

        let data = try SessionSnapshotV5.migrate(version5.data())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tabs = try #require(object["tabs"] as? [String: Any])
        let migrated = try #require(tabs[tab.id.uuidString] as? [String: Any])

        #expect(migrated["futureField"] as? String == "kept")
    }

    /// And through the store, which decodes the step's result and writes it
    /// again: the field is still in the file it writes.
    @Test func aTabFieldALaterBuildAdded_isInTheFileTheStoreWrites() throws {
        try withTempDir { dir in
            let tab = Self.tab("t", in: .loose)
            var version5 = Version5(tabs: [tab])
            version5.extraTabFields = ["futureField": "kept"]
            let file = dir.appendingPathComponent("state.json")
            try version5.data().write(to: file)

            guard case .loaded = SessionStore(directory: dir).load() else {
                Issue.record("expected the version 5 file to load")
                return
            }
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let tabs = try #require(object["tabs"] as? [String: Any])
            let written = try #require(tabs[tab.id.uuidString] as? [String: Any])
            #expect(written["futureField"] as? String == "kept")
        }
    }

    /// A value of the wrong type fails the read of the migrated file,
    /// which the store sets aside (`SessionStoreTests.stepThatDoesNotDecode_leavesNoCopy`),
    /// rather than being dropped with the rest of the group read.
    @Test func aValueOfTheWrongType_failsTheRead_ratherThanBeingDropped() throws {
        let group = Group5(name: "g")
        var object = try #require(
            JSONSerialization.jsonObject(with: Version5(groups: [group], tabs: [Self.tab("t", inGroup: group.id)]).data())
                as? [String: Any]
        )
        var containers = try #require(object["containers"] as? [[String: Any]])
        var groupObject = try #require(containers[0]["group"] as? [String: Any])
        groupObject["paletteIndex"] = "3"
        containers[0]["group"] = groupObject
        object["containers"] = containers
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self) {
            try PersistenceCoders.makeDecoder().decode(SessionSnapshot.self, from: SessionSnapshotV5.migrate(data))
        }
    }

    @Test func aMigratedSession_opensAtTheSidebarDefault_onTheMovedTab() throws {
        let group = Group5(name: "prod")
        let ssh = Self.tab("ssh", inGroup: group.id)
        var version5 = Version5(groups: [group], tabs: [ssh])
        version5.root["activeTabID"] = ssh.id.uuidString
        version5.root["activeContainerID"] = Version5.json(group: group.id)

        let session = WorkspaceSession()
        try session.restore(from: Self.migrated(version5))

        #expect(session.primarySelection.sidebarWidth == 304)
        #expect(session.primarySelection.activeTabID == ssh.id)
        #expect(session.primarySelection.activeContainerID == .loose)
        #expect(session.activeTab(in: session.primaryWindowID)?.displayTitle == "prod · ssh")
    }

    // MARK: - The window's chrome

    /// A file with no window record, as the build that kept the chrome with
    /// each project wrote one: the window takes the chrome its project's
    /// view kept.
    @Test func aWindowWithNoRecord_takesTheChromeItsProjectsViewKept() throws {
        let a = Project(name: "a", rootURL: WorkspaceSessionFixture.projectRootURL("chrome-a"))
        let b = Project(name: "b", rootURL: WorkspaceSessionFixture.projectRootURL("chrome-b"))
        let aTab = Tab.newWithSinglePane(title: "a", workingDirectory: nil, container: .project(a.id)).0
        let bTab = Tab.newWithSinglePane(title: "b", workingDirectory: nil, container: .project(b.id)).0
        let view = ProjectView(
            projectID: a.id,
            activeContainerID: .project(a.id),
            activeTabID: aTab.id,
            sidebarWidth: 399,
            sidebarHidden: true,
            isChangesPanelPresented: false,
            changesPanelWidth: 555
        )
        let data = try JSONEncoder().encode(SessionSnapshot(projects: [a, b], tabs: [aTab, bTab], windows: [], projectViews: [view]))
        let session = WorkspaceSession()
        try session.restore(from: JSONDecoder().decode(SessionSnapshot.self, from: data))
        let selection = session.primarySelection

        #expect(selection.shownProjectID == a.id)
        #expect(selection.sidebarWidth == 399)
        #expect(selection.sidebarHidden)
        #expect(!selection.isChangesPanelPresented)
        #expect(selection.changesPanelWidth == 555)
        // The window holds the project now: its view goes.
        #expect(session.projectViews.isEmpty)
    }
}
