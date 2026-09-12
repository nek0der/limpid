// SettingsSearchCatalogTests.swift
// Limpid — integrity coverage for Settings search destinations.

import Testing
@testable import Limpid

@Suite("SettingsSearchCatalog")
struct SettingsSearchCatalogTests {
    @Test("Every entry has a unique ID")
    func entries_haveUniqueIDs() {
        let ids = SettingsSearchCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every shortcut action has one search entry")
    func entries_includeEveryShortcutAction() {
        let ids = Set(SettingsSearchCatalog.entries.map(\.id))
        for action in LimpidShortcutAction.allCases {
            #expect(ids.contains("keyboard.shortcut.\(action.rawValue)"))
        }
    }

    @Test("Entries cover every Settings category")
    func entries_coverEverySection() {
        let sections = Set(SettingsSearchCatalog.entries.map(\.section))
        #expect(sections == Set(SettingsSection.allCases))
    }

    @Test("Entries retain a stable order inside each category")
    func entries_haveUniqueOrdersWithinSections() {
        for section in SettingsSection.allCases {
            let orders = SettingsSearchCatalog.entries
                .filter { $0.section == section }
                .map(\.order)
            #expect(Set(orders).count == orders.count, "duplicate order in \(section.rawValue)")
        }
    }

    @Test("Major settings and actions are indexed")
    func entries_includeMajorSettingsAndActions() {
        let ids = Set(SettingsSearchCatalog.entries.map(\.id))
        let expected = [
            "general.display-language",
            "appearance.theme",
            "font.family",
            "terminal.scrollback",
            "tabs-and-panes.minimum-pane-size",
            "integrations.ghostty-config",
            "review.instructions",
            "advanced.restore-all-defaults"
        ]
        for id in expected {
            #expect(ids.contains(id), "missing \(id)")
        }
    }
}
