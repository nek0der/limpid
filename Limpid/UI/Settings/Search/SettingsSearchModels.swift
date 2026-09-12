// SettingsSearchModels.swift
// Limpid — value types shared by the Settings search catalog and index.

import Foundation

/// One setting or deliberate settings action that can be reached from search.
///
/// This is intentionally independent of SwiftUI state. The sidebar uses the
/// entry ID to request a reveal after it has selected `section`.
struct SettingsSearchEntry: Identifiable, Equatable {
    /// Stable anchor name, shared with the setting row's reveal target.
    let id: String
    /// The Settings sidebar category that owns the target row.
    let section: SettingsSection
    /// The visible section heading inside the destination pane.
    let groupTitle: LocalizedStringResource
    /// The primary label displayed in the search result.
    let title: LocalizedStringResource
    /// Localized synonyms that improve discovery without indexing explanatory copy.
    let keywords: [LocalizedStringResource]
    /// Product and command-line names that must not be translated.
    let technicalAliases: [String]
    /// Stable display order within `section`.
    let order: Int

    init(
        id: String,
        section: SettingsSection,
        groupTitle: LocalizedStringResource,
        title: LocalizedStringResource,
        keywords: [LocalizedStringResource] = [],
        technicalAliases: [String] = [],
        order: Int
    ) {
        self.id = id
        self.section = section
        self.groupTitle = groupTitle
        self.title = title
        self.keywords = keywords
        self.technicalAliases = technicalAliases
        self.order = order
    }
}

extension LocalizedStringResource {
    func settingsResolved(locale: Locale) -> String {
        var resource = self
        resource.locale = locale
        return String(localized: resource)
    }
}
