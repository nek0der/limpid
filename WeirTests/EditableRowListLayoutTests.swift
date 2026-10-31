// EditableRowListLayoutTests.swift
// Weir — Project Settings' editable lists set each row's words from the leading edge, inside a grouped form.

import AppKit
import SwiftUI
import Testing
@testable import Weir

/// A grouped form lays a text field out as a value beside its label, in
/// the trailing column with its words set against the trailing edge, even
/// when the label is empty. A command or a path is read from its start, so
/// each list row's field spans the row and starts at its leading edge, as
/// System Settings' lists and Xcode's build phases set theirs.
@Suite(.hostsWindows)
@MainActor
struct EditableRowListLayoutTests {
    private static let width: CGFloat = 520

    @Test func eachTestCommandRow_startsAtTheLeadingEdge_inAGroupedForm() async {
        var draft = CheckCommandsDraft(commands: ["npm test", "cargo test"], defaults: ["npm test"])
        let list = TestCommandsList(draft: Binding(get: { draft }, set: { draft = $0 }))
        await Self.expectLeadingRows(in: list, texts: ["npm test", "cargo test"])
    }

    @Test func eachFileToCopyRow_startsAtTheLeadingEdge_inAGroupedForm() async {
        var draft = IgnoredFilesDraft(patterns: [".env", "config/local.yml"])
        let list = IgnoredFilesList(draft: Binding(get: { draft }, set: { draft = $0 }), root: nil)
        await Self.expectLeadingRows(in: list, texts: [".env", "config/local.yml"])
    }

    /// Removing the last row leaves the box as tall as it was with one: the
    /// empty list's message takes that row, as an empty table's
    /// placeholder does in System Settings.
    @Test func anEmptyList_isAsTallAsOneRow() {
        var none = CheckCommandsDraft(commands: [], defaults: [])
        var one = CheckCommandsDraft(commands: ["npm test"], defaults: [])
        var noFiles = IgnoredFilesDraft(patterns: [])
        var oneFile = IgnoredFilesDraft(patterns: [".env"])
        let empty = fittingHeight(of: TestCommandsList(draft: Binding(get: { none }, set: { none = $0 })).frame(width: Self.width))
        let single = fittingHeight(of: TestCommandsList(draft: Binding(get: { one }, set: { one = $0 })).frame(width: Self.width))
        let emptyFiles = fittingHeight(of: IgnoredFilesList(draft: Binding(get: { noFiles }, set: { noFiles = $0 }), root: nil)
            .frame(width: Self.width))
        let singleFile = fittingHeight(of: IgnoredFilesList(draft: Binding(get: { oneFile }, set: { oneFile = $0 }), root: nil)
            .frame(width: Self.width))

        #expect(empty > 0)
        #expect(empty == single, "\(empty) empty, \(single) with one row")
        #expect(emptyFiles == singleFile, "\(emptyFiles) empty, \(singleFile) with one row")
    }

    /// Hosts `list` in a grouped form, as Project Settings does, and checks
    /// each row's field: in the leading quarter of the form, at least
    /// three quarters of it wide, and its words set from the leading edge.
    private static func expectLeadingRows(in list: some View, texts: [String]) async {
        let form = Form {
            Section {
                list
            } header: {
                Text(verbatim: "List")
            }
        }
        .formStyle(.grouped)
        let (window, host) = hostedInWindow(form, width: width, height: 400)
        defer { window.close() }
        let fields: () -> [NSTextField] = {
            descendants(of: host).compactMap { $0 as? NSTextField }.filter { texts.contains($0.stringValue) }
        }
        await settle(host) { fields().count == texts.count }
        #expect(fields().count == texts.count, "every row has its field")
        for field in fields() {
            let frame = field.convert(field.bounds, to: host)
            #expect(frame.minX < width / 4, "\(field.stringValue) starts at \(frame.minX)")
            #expect(frame.width > width * 3 / 4, "\(field.stringValue) is \(frame.width) wide")
            #expect([.natural, .left].contains(field.alignment), "\(field.stringValue) is set \(field.alignment.rawValue)")
        }
    }
}
