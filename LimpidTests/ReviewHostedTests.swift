// ReviewHostedTests.swift
// Limpid — a view hosted in a review row takes the window's accent, language, and transparency again.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@MainActor
struct ReviewHostedTests {
    /// What a hosted view read from its environment as it was drawn.
    @MainActor
    final class Seen {
        var accent: Color?
        var locale: Locale?
        var surfaceOpacity: Double?
    }

    private struct Probe: View {
        let seen: Seen
        @Environment(\.limpidAccent) private var accent
        @Environment(\.locale) private var locale
        @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity

        var body: some View {
            seen.accent = accent
            seen.locale = locale
            seen.surfaceOpacity = surfaceOpacity
            return Color.clear.frame(width: 10, height: 10)
        }
    }

    /// The file header's checkbox missed the accent once: the table's rows
    /// are AppKit, and only the language and the opacity were handed over.
    @Test func aHostedView_takesTheAccentTheLanguageAndTheOpacity() async {
        let seen = Seen()
        let environment = ReviewHostedEnvironment(locale: Locale(identifier: "ja"), surfaceOpacity: 0.4, accent: .orange)
        let host = NSHostingView(rootView: ReviewHosted(environment: environment, content: Probe(seen: seen)))
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)

        await settle(host) { seen.accent != nil }

        #expect(seen.accent == .orange)
        #expect(seen.locale == Locale(identifier: "ja"))
        #expect(seen.surfaceOpacity == 0.4)
    }
}
