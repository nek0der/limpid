// SettingsSearchResultList.swift
// Weir — Sidebar results for cross-pane Settings search.

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
            SupervisionEmptyState(.noSettingsFound(query: query), size: .regular)
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
                                                .foregroundStyle(SettingsFootnote.style.color)
                                                .lineLimit(1)
                                        }
                                        // Indent to the header's title so results read
                                        // as children of their section (the icon column
                                        // stays empty).
                                        .padding(
                                            .leading,
                                            SettingsSidebarRowLabel.iconSlot + SettingsSidebarRowLabel.titleSpacing
                                        )
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
                                // The list's header inset sits 2pt left of the
                                // sidebar rows' cell inset; nudge so the icons
                                // share one column across both lists. The
                                // sidebar list style paints headers in the
                                // tertiary color, too faint to read as a
                                // section name here; secondary keeps the
                                // hierarchy against the primary result titles.
                                SettingsSidebarRowLabel(section: section)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 2)
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
                        withAnimation(WeirMotion.selectionScroll) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func accessibilityLabel(for entry: SettingsSearchEntry) -> Text {
        let title = entry.title.resolved(in: locale)
        let section = entry.section.title.resolved(in: locale)
        let group = entry.groupTitle.resolved(in: locale)
        // Joined in the string catalog, as VoiceOver pauses at the
        // ideographic comma in Japanese and at ", " in English.
        return Text(LocalizedStringResource(
            "settings.search.resultAccessibilityLabel",
            defaultValue: "\(title), \(section), \(group)",
            comment: "Settings search: VoiceOver label of a result row; the setting, its section, its group"
        ))
    }
}
