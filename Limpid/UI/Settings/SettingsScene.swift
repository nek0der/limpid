// SettingsScene.swift
// Limpid — Settings window body, modeled on `ThreePaneLayout` so
// Settings reads like the main window minus a column: detail pane
// fills the whole window as a background plane, and the sidebar sits
// flush against the leading edge as a Liquid Glass surface. Traffic
// lights land inside the sidebar, on the same strip midline and at the
// same left margin the main window gives them, so the toolbar feels
// integrated rather than stuck above the sidebar.
//
// Settings hosts itself in `Window(id:)` + `.windowStyle(
// .hiddenTitleBar)` (see LimpidApp). `limpidSettingsToolbar()`
// applies the transparent title bar and places the traffic lights the
// same way the main window does.

import SwiftUI

struct SettingsScene: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver
    @AppStorage("settings.last-section") private var selectedSectionRaw = SettingsSection.general.rawValue
    @State private var searchText = ""
    @State private var selectedSearchResultID: String?
    @State private var revealRequest: SettingsRevealRequest?
    @State private var revealSequence: UInt = 0
    @State private var searchFocusRequest: UInt = 0

    /// Slab width — matches the proportions of the main window's container column.
    private static let sidebarWidth: CGFloat = 210

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background plane: detail pane fills the whole window.
            // Its content is offset right of the slab (see
            // `SettingsForm`'s leading inset) so the slab overlays
            // empty backdrop, not real controls.
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Same behind-window Liquid Glass base the main
                // window paints — desktop wallpaper diffuses
                // through, slab tints sit on top. Reduce-Transparency
                // mode swaps in a solid `windowBackgroundColor` so
                // the pane stays readable when the user opted out.
                .background(settingsBaseFill.ignoresSafeArea())
                .ignoresSafeArea(.container)
                // Tag the Settings window so the update driver treats
                // it as a valid inline target. GeneralPane renders its
                // own `UpdatePopover`; without this marker the driver
                // would layer Sparkle's standard modal on top whenever
                // the main window is hidden.
                .background(LimpidSettingsWindowMarker())

            // Flush glass sidebar with the section list — the same
            // treatment the main window gives its container sidebar, so
            // the visual rhythm matches across windows.
            SettingsSidebarSlab(
                selection: selectedSectionBinding,
                searchText: $searchText,
                selectedSearchResultID: $selectedSearchResultID,
                searchResults: searchResults,
                searchFocusRequest: searchFocusRequest,
                onActivateResult: activateSearchResult,
                onMoveSelection: moveSearchSelection,
                onSubmit: submitSearch,
                onCancel: clearSearchSelection
            )
            .frame(width: Self.sidebarWidth)
            .flushGlassSidebar(
                isSolid: reduceTransparencyResolver.shouldReduceTransparency,
                solidFill: LimpidColor.sidebarSolidFill
            )
            .ignoresSafeArea(.all, edges: .top)
        }
        .ignoresSafeArea(.all)
        .frame(minWidth: 720, minHeight: 480)
        .environment(\.locale, settings.appLanguage.locale ?? .current)
        .environment(\.settingsRevealRequest, revealRequest)
        // Force the entire Settings tree to rebuild when the user
        // picks a new language. `.environment(\.locale, …)` on its
        // own isn't enough on macOS 26 — already-rendered Text
        // nodes (especially Form labels and `String(localized:)`
        // pre-resolved strings like `AppLanguage.localizedTitle`)
        // don't re-look-up their `LocalizedStringKey` on locale
        // change, so the Settings window keeps showing the old
        // language until reopened. `.id(appLanguage)` makes SwiftUI
        // tear down + rebuild the subtree with the fresh locale.
        .id(settings.appLanguage)
        .focusedSceneValue(
            \.settingsSearchFocusAction,
            SettingsSearchFocusAction {
                searchFocusRequest &+= 1
            }
        )
        .onChange(of: searchText) { _, newValue in
            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                clearSearchSelection()
                return
            }
            if let selectedSearchResultID,
               !searchResults.contains(where: { $0.id == selectedSearchResultID })
            {
                self.selectedSearchResultID = nil
            }
        }
        .limpidSettingsToolbar()
    }

    /// Footprint reserved on the detail pane's leading edge so the
    /// sidebar doesn't cover content, plus a small gutter.
    static var leadingInset: CGFloat {
        sidebarWidth + 8
    }

    private var selectedSection: SettingsSection {
        SettingsSection(rawValue: selectedSectionRaw) ?? .general
    }

    private var selectedSectionBinding: Binding<SettingsSection> {
        Binding(
            get: { selectedSection },
            set: { selectedSectionRaw = $0.rawValue }
        )
    }

    private var searchResults: [SettingsSearchEntry] {
        SettingsSearchIndex(
            locale: settings.appLanguage.locale ?? .current
        ).search(searchText)
    }

    @ViewBuilder
    private var settingsBaseFill: some View {
        // Mirror the main window: behind-window glass in the default
        // appearance, and the native opaque window-background tone (the
        // same surface System Settings uses) when transparency is
        // reduced — there the glass would be stripped by the OS anyway.
        if reduceTransparencyResolver.shouldReduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            WindowVibrancyBackground(
                material: .underWindowBackground,
                blendingMode: .behindWindow
            )
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedSection {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .font: FontPane()
        case .terminal: TerminalPane()
        case .tabsAndPanes: TabsAndPanesPane()
        case .keyboard: KeyboardPane()
        case .integrations: IntegrationsPane()
        case .review: ReviewSettingsPane()
        case .advanced: AdvancedPane()
        }
    }

    private func activateSearchResult(_ entry: SettingsSearchEntry) {
        selectedSearchResultID = entry.id
        selectedSectionRaw = entry.section.rawValue
        revealSequence &+= 1
        revealRequest = SettingsRevealRequest(
            sequence: revealSequence,
            entryID: entry.id,
            section: entry.section
        )
    }

    private func moveSearchSelection(_ delta: Int) {
        selectedSearchResultID = SettingsSearchNavigation.movedSelection(
            from: selectedSearchResultID,
            by: delta,
            in: searchResults
        )
    }

    private func submitSearch() {
        guard let entry = SettingsSearchNavigation.submittedEntry(
            selectedID: selectedSearchResultID,
            in: searchResults
        ) else { return }
        activateSearchResult(entry)
    }

    private func clearSearchSelection() {
        selectedSearchResultID = nil
        revealRequest = nil
    }
}

/// Contents of the sidebar: a top spacer reserving the traffic-light
/// row, then the section list. Mirrors `ContainerColumnContent` but
/// slimmed down — Settings doesn't need an in-sidebar toolbar row.
///
/// We do NOT recolor the sidebar selection pill. macOS 26 Tahoe's
/// `.listStyle(.sidebar)` ignores `.tint(_:)` for the selection
/// background and samples `NSColor.controlAccentColor` directly.
/// The only way around it is to drop `List(selection:)` and rebuild
/// the sidebar from `ScrollView + LazyVStack + Button`. The
/// cost-benefit doesn't justify that today; `\.limpidAccent`
/// reaches every other toolbar point (Toggle, Slider, drop targets,
/// focus rings) and the sidebar stays on the OS System Accent.
///
/// The `.tint(accent)` below is a forward-marker for when (if) Apple
/// publishes an official override API — it costs nothing today.
private struct SettingsSidebarSlab: View {
    @Binding var selection: SettingsSection
    @Binding var searchText: String
    @Binding var selectedSearchResultID: String?
    let searchResults: [SettingsSearchEntry]
    let searchFocusRequest: UInt
    let onActivateResult: (SettingsSearchEntry) -> Void
    let onMoveSelection: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @Environment(\.limpidAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            // Reserve the traffic-light row. The triad occupies
            // window-y 19–33 (see `repositionTrafficLights`), and the
            // sidebar starts at the window top now that it is flush, so
            // the reservation is measured from there. Reusing
            // `topStripHeight` is what the main window's toolbar row
            // spends, so the two windows open their lists at the same
            // height — `List(.sidebar)` adds an inset of its own on top
            // of it, which is why this is a shared starting point
            // rather than a shared baseline.
            Spacer().frame(height: LimpidLayout.topStripHeight)
            SettingsSearchField(
                text: $searchText,
                focusRequest: searchFocusRequest,
                onMoveSelection: onMoveSelection,
                onSubmit: onSubmit,
                onCancel: onCancel
            )
            .frame(height: 24)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                List(SettingsSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
                .tint(accent)
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                SettingsSearchResultList(
                    query: searchText,
                    results: searchResults,
                    selectedID: $selectedSearchResultID,
                    onActivate: onActivateResult
                )
                .tint(accent)
            }
        }
    }
}
