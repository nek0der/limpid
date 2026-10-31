// SessionSnapshotV5.swift
// Weir — brings a version 5 state.json to version 6: groups become scratch tabs, the root selection becomes window records.

import Foundation
import OSLog

private let log = Logger.weir("persistence.session-v5")

/// The step from schema 5 to 6.
///
/// Worked on the JSON rather than on today's types, which know only the
/// current shape: a tab is passed through untouched apart from the fields
/// the step sets, so what a later build adds to tabs cannot break it.
/// Beyond what it drops on purpose, the step itself keeps everything; the
/// values it writes are spelled out rather than read off today's types, so
/// a later change to a default cannot change what this step did.
///
/// - Groups are not written any more. Their tabs move to the scratch tabs,
///   after the scratch tabs there were, in group order and then tab order,
///   each keeping the group's name as its name prefix, the group's color,
///   and the group's working directory default. A tab of a group that is
///   gone moves there too, plain. The groups' folding and last tab go.
/// - The root's selection and layout become the primary's window record,
///   on the project its selection is in. On a scratch tab it keeps the
///   project that a window saved by a build from before the move still
///   named, as such a window keeps its project while on scratch tabs. Every
///   window starts with the sidebar at the supervision window's default
///   width: the root's width was the old window's container column.
///   The tab column's orientation and width and the Waiting region's
///   height are dropped: a window's tabs are only the pane strip.
/// - The windows a build from before the move saved past the primary are
///   kept as they were. A tab column's orientation and width one holds is
///   read past by `WindowRecord`, which has no tab column, and so is gone
///   from the file written from the step's result
///   (`SessionStore.loadMigrated`). The primary's own record there is
///   older than the root (such a build writes the root and carries
///   `windows` untouched), so only what the root never had is taken from
///   it.
/// - Projects keep their `containers[]` shape, which the shell worktree
///   hook reads.
/// - How many groups and tabs moved goes to the log only: nothing on
///   screen tells it.
enum SessionSnapshotV5 {
    static let step = DocumentMigrationStep(fromVersion: 5) { try migrate($0) }

    enum MigrationError: Error, Equatable {
        /// The document is not the version 5 shape: no object, or no
        /// `containers` or `tabs` where they belong.
        case notVersion5
    }

    /// The root keys version 6 moves into the window records or drops.
    /// Left behind they would be kept as unknown fields and written back
    /// forever.
    static let movedRootKeys = [
        "activeTabID", "activeContainerID", "sidebarWidth", "sidebarHidden",
        "tabColumnHorizontal", "windowFrame", "tabColumnWidth", "attentionHeightFraction"
    ]

    /// What the primary's version 5 record held that the root did not.
    private static let recordOnlyKeys = [
        "isFullScreen", "isChangesPanelPresented", "changesPanelWidth", "changesPanelAgent", "isHidden", "isFront"
    ]

    /// What the step writes, as the version 6 file spells it.
    private static var scratchContainer: [String: Any] {
        ["loose": [String: Any]()]
    }

    private static let continueWhereTheActiveTabIs = "inheritPrevious"
    /// The supervision window's sidebar default when this step was
    /// written.
    private static let sidebarWidth = 304.0

    static func migrate(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = root["containers"] as? [[String: Any]],
              var tabs = root["tabs"] as? [String: Any]
        else { throw MigrationError.notVersion5 }
        let groups = containers.filter { $0["kind"] as? String == "group" }
            .compactMap { $0["group"] as? [String: Any] }
        root["containers"] = containers.filter { $0["kind"] as? String != "group" }

        let order = (root["tabOrder"] as? [String]) ?? []
        let (moved, groupsWithTabs) = moveGroupTabs(&tabs, groups: groups, order: order)
        if !moved.isEmpty {
            log.notice("moved \(moved.count, privacy: .public) tabs of \(groupsWithTabs, privacy: .public) groups to the scratch tabs")
        }
        root["tabs"] = tabs
        root["tabOrder"] = order.filter { !moved.contains($0) } + moved

        // Taken one element at a time: an element that is not a record would
        // otherwise fail the cast of the whole array and cost every window
        // after the primary. One that is not a record is passed on as it is,
        // for version 6 to pass over that window alone.
        let records = (root["windows"] as? [Any]) ?? []
        root["windows"] = [primaryRecord(root: root, saved: records.first as? [String: Any])]
            + records.dropFirst().map { element in (element as? [String: Any]).map(laterRecord) ?? element }
        for key in movedRootKeys {
            root.removeValue(forKey: key)
        }
        root["version"] = 6
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Moves every group tab to the scratch tabs, and returns their IDs in
    /// their new order (by group, then as they were ordered, then the tabs
    /// of groups that are gone) and how many groups had a tab to move.
    private static func moveGroupTabs(
        _ tabs: inout [String: Any],
        groups: [[String: Any]],
        order: [String]
    ) -> (moved: [String], groupsWithTabs: Int) {
        let groupIndex = Dictionary(
            groups.enumerated().compactMap { index, group in (group["id"] as? String).map { ($0, index) } },
            uniquingKeysWith: { first, _ in first }
        )
        // Tabs the order leaves out still move, after those it lists.
        let listed = order + tabs.keys.filter { !order.contains($0) }.sorted()
        var byGroup: [[String]] = Array(repeating: [], count: groups.count)
        var orphans: [String] = []
        for id in listed {
            guard var tab = tabs[id] as? [String: Any], let groupID = groupID(of: tab["container"]) else { continue }
            tab["container"] = scratchContainer
            if let index = groupIndex[groupID] {
                carry(groups[index], into: &tab)
                byGroup[index].append(id)
            } else {
                orphans.append(id)
            }
            tabs[id] = tab
        }
        return (byGroup.flatMap(\.self) + orphans, byGroup.count { !$0.isEmpty })
    }

    /// The group's name as the name prefix, its color, and its working
    /// directory default, which a group without one had as "continue where
    /// the active tab is". Version 5 read a `null` mode as absent too
    /// (`decodeIfPresent`), so `null` takes that default as well, and so
    /// does any value that is not a mode's name: copied as it is, today's
    /// `Tab` would read it as no mode, and the tab's new panes would start
    /// where it opened rather than where it is.
    private static func carry(_ group: [String: Any], into tab: inout [String: Any]) {
        if let name = group["name"] as? String, !name.isEmpty {
            tab["namePrefix"] = name
        }
        if let palette = group["paletteIndex"] {
            tab["paletteIndex"] = palette
        }
        tab["cwdMode"] = group["cwdMode"] as? String ?? continueWhereTheActiveTabIs
        if let path = group["cwdPath"] {
            tab["cwdPath"] = path
        }
    }

    /// The group a version 5 container names: `{"group": {"_0": id}}`.
    private static func groupID(of container: Any?) -> String? {
        ((container as? [String: Any])?["group"] as? [String: Any])?["_0"] as? String
    }

    /// The project a container is in: a project's own or a worktree's.
    private static func projectID(of container: Any?) -> String? {
        guard let container = container as? [String: Any] else { return nil }
        if let project = container["project"] as? [String: Any] {
            return project["_0"] as? String
        }
        return (container["worktree"] as? [String: Any])?["projectID"] as? String
    }

    /// The primary's record from the root, and from `saved` only what the
    /// root never had.
    private static func primaryRecord(root: [String: Any], saved: [String: Any]?) -> [String: Any] {
        var record: [String: Any] = [:]
        for key in recordOnlyKeys {
            record[key] = saved?[key]
        }
        let container = groupID(of: root["activeContainerID"]) == nil
            ? root["activeContainerID"] ?? scratchContainer
            : scratchContainer
        record["activeContainerID"] = container
        // On a scratch tab the window keeps the project it was on, which a
        // saved record that was on the scratch tabs as well still names.
        let savedOnScratch = saved.map { projectID(of: $0["activeContainerID"]) == nil } ?? false
        record["projectID"] = projectID(of: container) ?? (savedOnScratch ? saved?["projectID"] : nil)
        record["activeTabID"] = root["activeTabID"]
        record["frame"] = root["windowFrame"]
        record["sidebarHidden"] = root["sidebarHidden"] ?? false
        record["sidebarWidth"] = sidebarWidth
        return record
    }

    /// A window a supervision run saved past the primary: as it was, with a
    /// group it showed read as the scratch tabs.
    private static func laterRecord(_ saved: [String: Any]) -> [String: Any] {
        var record = saved
        if groupID(of: record["activeContainerID"]) != nil {
            record["activeContainerID"] = scratchContainer
        }
        return record
    }
}
