// ConversationMenuLayoutTests.swift
// Limpid — what chooses a conversation holds still: the review tab's scope menu over its notes, and the panel's filter.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

/// The review tab chooses a conversation in its one scope menu, which keeps
/// its place whatever the notes under it say, so a choice never moves the
/// menu from under the pointer. The changes panel's filter lists every
/// conversation of the worktree, and holds still however long the counts
/// above it read.
@MainActor
struct ConversationMenuLayoutTests {
    private static func key(_ id: String) -> ConversationKey {
        ConversationKey(provider: .claude, conversationID: id, isFallback: false)
    }

    // MARK: - The review tab

    /// The notes come and go with the choice ("Includes 2 viewed turns",
    /// what a turn's diff is); the menu above them does not move.
    @Test func reviewScopeMenu_keepsItsPlace_whateverTheNotesSay() async throws {
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        let noteSets: [[String]] = [
            [],
            [ReviewTabText.turnDiffNote(locale: en)],
            [ReviewTabText.includesViewedTurns(2, locale: ja) ?? "", ReviewTabText.turnDiffNote(locale: ja)]
        ]
        let conversation = ConversationChoice(conversation: Self.key("a"), ordinal: 4, unviewedCount: 1)
        for width: CGFloat in [LimpidLayout.reviewMinWidth, 520, 730] {
            var frames: [CGRect] = []
            for (index, notes) in noteSets.enumerated() {
                try await frames.append(scopeFrame(notes: notes, conversation: index == 1 ? conversation : nil, width: width))
            }
            let first = try #require(frames.first)
            for other in frames.dropFirst() {
                #expect(other.origin == first.origin && other.height == first.height, "at \(width)")
            }
        }
    }

    private func scopeFrame(notes: [String], conversation: ConversationChoice?, width: CGFloat) async throws -> CGRect {
        let recorder = FrameRecorder()
        let view = ReviewTabScopeLayout(notes: notes) {
            ReviewTabScopePicker(current: "Unviewed Turns (T3–T6)", conversation: conversation) { [] }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { recorder.frame = $0 }
        } trailing: {
            Button("Refresh") {}
        }
        // At the top of the window, as the tab draws it at the top of its
        // column; centered, the menu would move with the notes' height.
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.locale, Locale(identifier: "en"))
        return try await settled(view, width: width) { recorder.frame }
    }

    private func settled(_ view: some View, width: CGFloat, frame: @escaping () -> CGRect?) async throws -> CGRect {
        let (window, host) = hostedInWindow(view, width: width, height: 240)
        defer { window.close() }
        let settled = await settledValue(in: host) { frame() }
        return try #require(settled)
    }

    // MARK: - The panel's head

    /// With a filter, the counts always take a line of their own: how long
    /// they are never moves the filter under them, whichever conversation
    /// it shows.
    @Test func panelFilter_keepsItsFrame_whateverTheCountsSay() async throws {
        #expect(ChangesSummaryPlacement.placement(hasFilter: true) == .ownLine)
        #expect(ChangesSummaryPlacement.placement(hasFilter: false) == .besideWhileItFits)
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        let summaries = [
            ChangesPanelText.summary(turns: 2, unviewed: 0, locale: en),
            ChangesPanelText.summary(turns: 128, unviewed: 37, locale: en),
            ChangesPanelText.summary(turns: 1, unviewed: 1, locale: ja),
            ChangesPanelText.summary(turns: 12, unviewed: 3, locale: ja)
        ]
        for width: CGFloat in [300, 320, 360, 420] {
            var frames: [CGRect] = []
            for (index, summary) in summaries.enumerated() {
                try await frames.append(filterFrame(summary: summary, selected: index % 2 == 0 ? nil : "b", width: width))
            }
            let first = try #require(frames.first)
            for other in frames.dropFirst() {
                // The label's width follows the conversation shown; its
                // place and height do not.
                #expect(other.origin == first.origin && other.height == first.height, "at \(width)")
            }
        }
    }

    private func filterFrame(summary: String, selected: String?, width: CGFloat) async throws -> CGRect {
        let agents = [
            ConversationChoice(conversation: Self.key("a"), ordinal: 1, unviewedCount: 1),
            ConversationChoice(conversation: Self.key("b"), ordinal: 2, unviewedCount: 0)
        ]
        let recorder = FrameRecorder()
        let view = ChangesPanelHeadLayout(summary: summary, hasFilter: true) {
            Text(verbatim: "Changes")
                .font(LimpidFont.Supervision.surfaceHeading)
                .fixedSize()
        } buttons: {
            Button("Review Unviewed") {}
                .buttonStyle(.supervisionSecondary(size: .compact))
        } filter: {
            ChangesConversationFilter(filter: selected.map(Self.key), conversations: agents, onSelect: { _ in })
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { recorder.frame = $0 }
        }
        .padding(LimpidLayout.Supervision.changesHeadInsets)
        // At the top of the window, as the panel draws its head.
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.locale, Locale(identifier: "en"))

        let (window, host) = hostedInWindow(view, width: width, height: 240)
        defer { window.close() }
        let frame = await settledValue(in: host) { recorder.frame }
        return try #require(frame)
    }
}
