// LiveLocaleAndAccentTests.swift
// Weir — a main window's root follows the language and accent picked in Settings without a relaunch.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@MainActor
struct LiveLocaleAndAccentTests {
    /// What the hosted root last saw, written from inside its `body`.
    @MainActor
    private final class Seen {
        var locale: Locale?
        var accent: Color?
    }

    private struct Probe: View {
        let seen: Seen
        @Environment(\.locale) private var locale
        @Environment(\.weirAccent) private var accent

        var body: some View {
            seen.locale = locale
            seen.accent = accent
            return Color.clear.frame(width: 10, height: 10)
        }
    }

    /// The root is built once, as a window controller builds it; a later
    /// change in the store still reaches what it holds.
    @Test func aChangedLanguageAndAccent_reachTheRootWithoutRebuildingIt() async throws {
        try await withTempDir { directory in
            let store = try SettingsStore.inEnglish(in: directory)
            store.appLanguage = .english
            store.settings.appearance.accentColor = .blue
            let seen = Seen()
            let host = NSHostingView(rootView: LiveLocaleAndAccent(settingsStore: store) {
                Probe(seen: seen)
            })
            host.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
            host.layoutSubtreeIfNeeded()
            #expect(seen.locale?.language.languageCode == .english)
            #expect(seen.accent == WeirColor.accent(for: .blue))

            // One at a time, so each is shown to reach the root on its own
            // rather than riding along with the other's redraw.
            store.settings.appearance.accentColor = .green
            await pollUntil(interval: .milliseconds(10)) {
                host.layoutSubtreeIfNeeded()
                return seen.accent == WeirColor.accent(for: .green)
            }
            #expect(seen.accent == WeirColor.accent(for: .green))
            #expect(seen.locale?.language.languageCode == .english)

            store.appLanguage = .japanese
            await pollUntil(interval: .milliseconds(10)) {
                host.layoutSubtreeIfNeeded()
                return seen.locale?.language.languageCode == .japanese
            }
            #expect(seen.locale?.language.languageCode == .japanese)
            #expect(seen.accent == WeirColor.accent(for: .green))
        }
    }
}
