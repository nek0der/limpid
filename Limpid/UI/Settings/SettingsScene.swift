// SettingsScene.swift
// Limpid — the Settings window: the section sidebar over the detail pane.
//
// The detail pane fills the whole window as a background plane, and the sidebar sits
// flush against the leading edge as a Liquid Glass surface. Traffic
// lights land inside the sidebar, on the same strip midline and at the
// same left margin the main window gives them, so the toolbar feels
// integrated rather than stuck above the sidebar.
//
// Settings hosts itself in `Window(id:)` + `.windowStyle(
// .hiddenTitleBar)` (see LimpidApp). `limpidSettingsToolbar()`
// applies the transparent title bar and places the traffic lights the
// same way the main window does.

import AppKit
import SwiftUI

struct SettingsScene: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver
    @AppStorage(SettingsSection.lastSectionDefaultsKey) private var selectedSectionRaw = SettingsSection.general.rawValue
    @State private var searchText = ""
    @State private var selectedSearchResultID: String?
    @State private var revealRequest: SettingsRevealRequest?
    @State private var revealSequence: UInt = 0
    @State private var searchFocusRequest: UInt = 0

    /// Slab width — matches the proportions of the main window's container
    /// column. The detail pane reserves the same width on its leading edge
    /// so the sidebar doesn't cover content.
    static let sidebarWidth: CGFloat = 210

    /// The window's only width; see the frame in `body`.
    static let windowWidth: CGFloat = 820

    /// The height the window opens at, and keeps as panes are switched:
    /// the content's ideal height whatever pane is shown, so a pane with
    /// more rows scrolls inside the window rather than growing it.
    /// With `.windowResizability(.contentSize)` the window follows the
    /// content's ideal size, and a form's ideal height is its whole
    /// content, so without this the window grew to a tall pane's rows and
    /// stayed there, half empty, on a short one.
    static let windowHeight: CGFloat = 540

    /// The least height the window can be dragged to.
    static let minimumWindowHeight: CGFloat = 480

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
                .background(LimpidWindowRoleMarker(role: .settings))

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
        // One width, as System Settings has: the grouped form caps its
        // column, while the title bar over it stays at the leading edge,
        // so a wider window would pull the column out from under its
        // title. With `.windowResizability(.contentSize)` this frame is
        // the window's own limits, so only the height can be dragged.
        // A frame saved while the window could still widen comes back at
        // its old width, so the window is also set to this width as it
        // opens (`SettingsWindowWidth`).
        .settingsWindowFrame()
        // No rebuild on a language switch: `Text`, `Toggle`, `Picker`
        // and the rest resolve their resources against `\.locale` and
        // redraw in place when it changes. Text that has to be a
        // `String` resolves with this same locale.
        .environment(\.locale, settings.appLocale)
        .environment(\.settingsRevealRequest, revealRequest)
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
        .limpidSettingsToolbar(onWindow: SettingsWindowWidth.fit)
    }

    /// Gap between the sidebar and the detail pane's content. It is a
    /// content margin on the form rather than extra reserved width, so the
    /// title bar still reaches the sidebar's edge.
    static let detailGutter: CGFloat = 8

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
            locale: settings.appLocale
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
        case .quickTerminal: QuickTerminalPane()
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

extension View {
    /// The settings window's frame: one width, and one ideal height
    /// whatever pane is shown, with only the height free to drag above its
    /// minimum. Applied to the scene, and to a pane on its own in tests,
    /// where the ideal size is what the hosting view fits.
    func settingsWindowFrame() -> some View {
        frame(width: SettingsScene.windowWidth)
            .frame(
                minHeight: SettingsScene.minimumWindowHeight,
                idealHeight: SettingsScene.windowHeight,
                maxHeight: .infinity
            )
    }
}

/// Puts the settings window at `SettingsScene.windowWidth` when it opens.
/// The content's fixed width makes it the window's only width from then on,
/// but a frame AppKit saved while the window could still widen (before the
/// width was fixed) is restored as it was, and we do not leave it to the
/// size limits to pull that back in.
enum SettingsWindowWidth {
    /// `frame` at `width`, with its top-left corner where it was, as AppKit
    /// keeps a window's title bar when it resizes one. `nil` when the frame
    /// already has that width. AppKit's origin is the bottom-left corner, so
    /// keeping the origin and the height keeps the top-left one.
    static func frame(_ frame: CGRect, width: CGFloat) -> CGRect? {
        guard frame.width != width else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
    }

    /// Sets `window` to the fixed width. Run once as the window gets its
    /// content, and again on the next turn of the main queue, after SwiftUI
    /// has applied the frame it restores.
    @MainActor
    static func fit(_ window: NSWindow) {
        apply(to: window)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            MainActor.assumeIsolated {
                apply(to: window)
            }
        }
    }

    @MainActor
    private static func apply(to window: NSWindow) {
        let content = CGRect(x: 0, y: 0, width: SettingsScene.windowWidth, height: 1)
        let width = window.frameRect(forContentRect: content).width
        guard let fitted = frame(window.frame, width: width) else { return }
        window.setFrame(fitted, display: true)
    }
}

/// Contents of the sidebar: a top spacer reserving the traffic-light
/// row, then the section list. Settings doesn't need an in-sidebar
/// toolbar row.
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
            // The translucent capsule System Settings shows for its
            // sidebar search; see `SettingsSearchNSField` for why the
            // field itself does not paint it.
            SettingsSearchField(
                text: $searchText,
                focusRequest: searchFocusRequest,
                onMoveSelection: onMoveSelection,
                onSubmit: onSubmit,
                onCancel: onCancel
            )
            .frame(height: 28)
            .background(.thinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(LimpidColor.glassHairline, lineWidth: 0.5)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                List(SettingsSection.allCases, selection: $selection) { section in
                    SettingsSidebarRowLabel(section: section)
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
