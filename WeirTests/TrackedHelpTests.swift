// TrackedHelpTests.swift
// Weir — the tooltip AppKit tracks itself: carried by a view of its own, which takes no click and keeps its place as the words change.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@MainActor
struct TrackedHelpTests {
    @Observable
    final class Words {
        var text = "zsh\nShell"
    }

    struct Tab: View {
        let words: Words

        var body: some View {
            Text(verbatim: "zsh")
                .frame(width: 120, height: 28)
                .trackedHelp(words.text)
        }
    }

    private static func helpViews(in view: NSView) -> [TrackedHelpView] {
        descendants(of: view).compactMap { $0 as? TrackedHelpView }
    }

    @Test func theTooltip_isOnAnAppKitView_overTheWholeView_thatTakesNoClick() async throws {
        let words = Words()
        let hosting = NSHostingView(rootView: Tab(words: words))
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        hosting.layoutSubtreeIfNeeded()

        let help = try #require(Self.helpViews(in: hosting).first)
        #expect(help.toolTip == "zsh\nShell")
        #expect(help.frame.size == NSSize(width: 120, height: 28), "the tooltip covers the tab, not a part of it")
        #expect(help.hitTest(NSPoint(x: 60, y: 14)) == nil, "a click reaches the tab")
        #expect(!help.isAccessibilityElement(), "the tab says what it is")

        // New words reach the same view, so a tooltip on screen keeps the
        // tracking area that hides it.
        words.text = "zsh\nShell · Running"
        await settle(hosting, timeout: .seconds(5)) { Self.helpViews(in: hosting).first?.toolTip == words.text }
        let after = try #require(Self.helpViews(in: hosting).first)
        #expect(after === help)
        #expect(after.toolTip == "zsh\nShell · Running")
    }
}
