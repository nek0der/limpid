// SettingsSearchIndex.swift
// Limpid — locale-aware, deterministic matching for Settings search.

import Foundation

struct SettingsSearchIndex {
    let entries: [SettingsSearchEntry]
    let locale: Locale

    init(entries: [SettingsSearchEntry] = SettingsSearchCatalog.entries, locale: Locale) {
        self.entries = entries
        self.locale = locale
    }

    /// Finds entries that contain every query token in at least one indexed field.
    func search(_ query: String) -> [SettingsSearchEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmedQuery.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        return entries.compactMap { entry in
            let fields = fields(for: entry)
            guard tokens.allSatisfy({ token in fields.contains { $0.value.localizedStandardContains(token) } }) else {
                return nil
            }
            return SearchHit(entry: entry, score: score(for: entry, query: trimmedQuery, fields: fields))
        }
        .sorted(by: Self.sort)
        .map(\.entry)
    }

    private func fields(for entry: SettingsSearchEntry) -> [SearchField] {
        let currentTitle = entry.title.settingsResolved(locale: locale)
        let englishTitle = entry.title.settingsResolved(locale: Locale(identifier: "en"))
        let currentGroup = entry.groupTitle.settingsResolved(locale: locale)
        let englishGroup = entry.groupTitle.settingsResolved(locale: Locale(identifier: "en"))
        let currentSection = sectionTitle(for: entry.section, locale: locale)
        let englishSection = sectionTitle(for: entry.section, locale: Locale(identifier: "en"))
        let currentKeywords = entry.keywords.map { $0.settingsResolved(locale: locale) }
        let englishKeywords = entry.keywords.map {
            $0.settingsResolved(locale: Locale(identifier: "en"))
        }

        return [
            SearchField(value: currentTitle, score: 0),
            SearchField(value: englishTitle, score: 50),
            SearchField(value: currentGroup, score: 30),
            SearchField(value: englishGroup, score: 50),
            SearchField(value: currentSection, score: 30),
            SearchField(value: englishSection, score: 50)
        ] + currentKeywords.map { SearchField(value: $0, score: 40) }
            + englishKeywords.map { SearchField(value: $0, score: 50) }
            + entry.technicalAliases.map { SearchField(value: $0, score: 50) }
    }

    private func score(for entry: SettingsSearchEntry, query: String, fields: [SearchField]) -> Int {
        let currentTitle = entry.title.settingsResolved(locale: locale)
        if let titleRange = currentTitle.localizedStandardRange(of: query) {
            if titleRange == currentTitle.startIndex..<currentTitle.endIndex {
                return 0
            }
            if titleRange.lowerBound == currentTitle.startIndex {
                return 10
            }
            return 20
        }
        return fields.filter { $0.value.localizedStandardContains(query) }
            .map(\.score)
            .min() ?? 50
    }

    private func sectionTitle(for section: SettingsSection, locale: Locale) -> String {
        section.title.settingsResolved(locale: locale)
    }

    private struct SearchField {
        let value: String
        let score: Int
    }

    private struct SearchHit {
        let entry: SettingsSearchEntry
        let score: Int
    }

    private static func sort(_ lhs: SearchHit, _ rhs: SearchHit) -> Bool {
        if lhs.entry.section != rhs.entry.section {
            return lhs.entry.section.allCasesIndex < rhs.entry.section.allCasesIndex
        }
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        if lhs.entry.order != rhs.entry.order {
            return lhs.entry.order < rhs.entry.order
        }
        return lhs.entry.id < rhs.entry.id
    }
}

private extension SettingsSection {
    var allCasesIndex: Int {
        SettingsSection.allCases.firstIndex(of: self) ?? .max
    }
}
