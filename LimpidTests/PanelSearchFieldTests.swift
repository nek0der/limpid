// PanelSearchFieldTests.swift
// Limpid — the search field All Projects and the keyboard shortcuts panel share stands at one height.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

/// The panels' one search field stands at its token's height whatever its
/// placeholder, so All Projects' filter and the shortcuts search match.
@MainActor
struct PanelSearchFieldTests {
    private struct Host: View {
        let prompt: Text
        @State private var text = ""
        @FocusState private var isFocused: Bool

        var body: some View {
            PanelSearchField(text: $text, prompt: prompt, isFocused: $isFocused)
                .frame(width: 240)
        }
    }

    @Test func bothPanelsFields_standAtTheTokensHeight() {
        for prompt in [Text("Search shortcuts"), Text("Filter by project, branch, or name")] {
            let host = NSHostingView(rootView: Host(prompt: prompt))
            #expect(host.fittingSize.height == LimpidLayout.Supervision.panelSearchFieldHeight)
        }
    }

    /// The shared face keeps each field's own size: a fixed height for the
    /// panel and the review rail, the line plus its insets for a dropdown.
    @Test func searchFieldFace_keepsEachFieldsSize() {
        let line = Text(verbatim: "Filter").font(.supervision(.caption))
        let lineHeight = NSHostingView(rootView: line).fittingSize.height

        let rail = NSHostingView(rootView: line.searchFieldFace(.rail).frame(width: 200))
        #expect(rail.fittingSize.height == LimpidLayout.Supervision.railSearchFieldHeight)

        let panel = NSHostingView(rootView: line.searchFieldFace(.panel).frame(width: 200))
        #expect(panel.fittingSize.height == LimpidLayout.Supervision.panelSearchFieldHeight)

        let insets = LimpidLayout.Supervision.dropdownSearchInsets
        let dropdown = NSHostingView(rootView: line.searchFieldFace(.dropdown(well: .gray)).frame(width: 200))
        #expect(dropdown.fittingSize.height == lineHeight + insets.top + insets.bottom)
    }
}
