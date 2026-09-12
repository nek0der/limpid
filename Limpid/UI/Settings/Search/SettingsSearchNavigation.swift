// SettingsSearchNavigation.swift
// Limpid — Pure selection rules for keyboard navigation in Settings search.

enum SettingsSearchNavigation {
    static func movedSelection(
        from selectedID: String?,
        by delta: Int,
        in results: [SettingsSearchEntry]
    ) -> String? {
        guard !results.isEmpty else { return nil }
        guard let selectedID,
              let currentIndex = results.firstIndex(where: { $0.id == selectedID })
        else {
            return delta < 0 ? results.last?.id : results.first?.id
        }
        let newIndex = min(max(currentIndex + delta, 0), results.count - 1)
        return results[newIndex].id
    }

    static func submittedEntry(
        selectedID: String?,
        in results: [SettingsSearchEntry]
    ) -> SettingsSearchEntry? {
        selectedID.flatMap { id in
            results.first { $0.id == id }
        } ?? results.first
    }
}
