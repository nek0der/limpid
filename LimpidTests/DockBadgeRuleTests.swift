// DockBadgeRuleTests.swift
// Limpid — what the Dock badge shows: the attention count, or a dot for other news.

import Foundation
import Testing
@testable import Limpid

struct DockBadgeRuleTests {
    @Test(arguments: [
        (0, false, DockBadge.none),
        (0, true, .dot),
        (3, false, .count(3)),
        // The count wins: other news never adds to the number.
        (3, true, .count(3))
    ])
    func theBadge_followsTheAttentionCount(_ count: Int, _ hasOtherNews: Bool, _ expected: DockBadge) {
        #expect(DockBadge.badge(attentionCount: count, hasOtherNews: hasOtherNews) == expected)
    }

    @Test func theLabel_isWhatAppKitShows() {
        #expect(DockBadge.none.label == nil)
        #expect(DockBadge.count(12).label == "12")
        #expect(DockBadge.dot.label == "\u{2022}")
    }

    @Test(arguments: [NotificationEntry.Kind.desktop, .commandFinished, .bell])
    @MainActor
    func anUnreadCommandEntry_isOtherNews(_ kind: NotificationEntry.Kind) throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            #expect(!history.hasUnreadCommandEntries)

            let entry = NotificationEntry.test(kind: kind, title: "make", body: "")
            history.record(entry)
            #expect(history.hasUnreadCommandEntries)

            history.markRead(entry.id)
            #expect(!history.hasUnreadCommandEntries)
        }
    }

    @Test(arguments: [NotificationEntry.Kind.agentFinished, .agentNeedsInput, .agentError])
    @MainActor
    func anAgentEntry_isLeftToTheAttentionList(_ kind: NotificationEntry.Kind) throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            history.record(NotificationEntry.test(kind: kind, title: "Done", body: ""))
            #expect(!history.hasUnreadCommandEntries)
        }
    }

    @Test @MainActor func dockBadge_readsQueueCount() async throws {
        try await withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
            let count = Counter()
            let shown = BadgeRecorder()
            let sync = DockBadgeSync(
                historyStore: history,
                session: session,
                attentionCount: { count.value },
                setBadge: { shown.badges.append($0) }
            )
            await shown.waitFor(.none)

            count.value = 2
            await shown.waitFor(.count(2))

            // Back to zero: a bell or a command left a pane unread, and the
            // Dock shows a dot until the pane is looked at.
            count.value = 0
            session.markUnread(paneID: paneID)
            await shown.waitFor(.dot)
            session.clearUnread(paneID: paneID)
            await shown.waitFor(.none)

            // A command's notification not yet read in the history.
            let entry = NotificationEntry.test(title: "done", body: "")
            history.record(entry)
            await shown.waitFor(.dot)
            history.markRead(entry.id)
            await shown.waitFor(.none)
            #expect(sync.badge == .none)
        }
    }
}

/// The attention count a test sets, observed like the real list.
@MainActor
@Observable
private final class Counter {
    var value = 0
}

/// What `DockBadgeSync` pushed, in order.
@MainActor
private final class BadgeRecorder {
    var badges: [DockBadge] = []

    /// Waits until the latest badge pushed is `badge`, with a deadline so
    /// a broken path fails the expectation instead of hanging the suite.
    func waitFor(_ badge: DockBadge) async {
        await pollUntil(interval: .milliseconds(5)) { badges.last == badge }
        #expect(badges.last == badge)
    }
}
