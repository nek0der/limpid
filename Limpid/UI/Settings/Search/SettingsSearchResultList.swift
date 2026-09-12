// SettingsSearchResultList.swift
// Limpid — Sidebar results for cross-pane Settings search.

import SwiftUI

struct SettingsSearchResultList: View {
    let query: String
    let results: [SettingsSearchEntry]
    @Binding var selectedID: String?
    let onActivate: (SettingsSearchEntry) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion
    @FocusState private var isResultListFocused: Bool

    var body: some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No Settings Found")
                    .font(.headline)
                Text(query)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
            .accessibilityElement(children: .combine)
        } else {
            ScrollViewReader { proxy in
                List(selection: $selectedID) {
                    ForEach(SettingsSection.allCases) { section in
                        let sectionResults = results.filter { $0.section == section }
                        if !sectionResults.isEmpty {
                            Section {
                                ForEach(sectionResults) { entry in
                                    Button {
                                        selectedID = entry.id
                                        onActivate(entry)
                                        isResultListFocused = true
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.title)
                                                .lineLimit(1)
                                            Text(entry.groupTitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .tag(entry.id)
                                    .id(entry.id)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(accessibilityLabel(for: entry))
                                }
                            } header: {
                                Label(section.title, systemImage: section.icon)
                                    .padding(.bottom, 6)
                            }
                        }
                    }
                }
                .focused($isResultListFocused)
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: selectedID) { _, newID in
                    guard let newID else { return }
                    if shouldReduceMotion {
                        proxy.scrollTo(newID, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func accessibilityLabel(for entry: SettingsSearchEntry) -> Text {
        let title = entry.title.settingsResolved(locale: locale)
        let section = entry.section.title.settingsResolved(locale: locale)
        let group = entry.groupTitle.settingsResolved(locale: locale)
        return Text(verbatim: "\(title), \(section), \(group)")
    }
}
