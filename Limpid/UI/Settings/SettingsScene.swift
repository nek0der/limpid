// SettingsScene.swift
// Limpid — Settings window body, modeled on `ThreePaneLayout` so
// Settings reads like the main window minus a column: detail pane
// fills the whole window as a background plane, sidebar floats
// above as a Liquid Glass slab. Traffic lights land *inside* the
// slab (same `repositionTrafficLights` trick the main window uses)
// so the toolbar feels integrated, not stuck above the sidebar.
//
// Settings hosts itself in `Window(id:)` + `.windowStyle(
// .hiddenTitleBar)` (see LimpidApp). `limpidSettingsToolbar()`
// applies the transparent title bar + repositions the traffic
// lights to land inside the slab.

import SwiftUI

struct SettingsScene: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver
    @State private var selection: SettingsSection = .general

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

            // Floating Liquid Glass slab with the section list.
            // Same `liquidGlassPanel` + insets the main window uses
            // on container column, so the visual rhythm matches across windows.
            SettingsSidebarSlab(selection: $selection)
                .frame(width: Self.sidebarWidth)
                .liquidGlassPanel(
                    cornerRadius: 10,
                    isSolid: reduceTransparencyResolver.shouldReduceTransparency
                )
                .padding(.leading, LimpidLayout.containerColumnInsetH)
                .padding(.top, LimpidLayout.containerColumnInsetV)
                .padding(.bottom, LimpidLayout.containerColumnInsetV)
                .ignoresSafeArea(.all, edges: .top)
        }
        .ignoresSafeArea(.all)
        .frame(minWidth: 720, minHeight: 480)
        .environment(\.locale, settings.appLanguage.locale ?? .current)
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
        .limpidSettingsToolbar()
    }

    /// Footprint reserved on the detail pane's leading edge so the
    /// floating slab doesn't cover content. Includes the slab's
    /// rim margin and a small gutter.
    static var leadingInset: CGFloat {
        LimpidLayout.containerColumnInsetH + sidebarWidth + 8
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
        switch selection {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .font: FontPane()
        case .terminal: TerminalPane()
        case .keyboard: KeyboardPane()
        case .advanced: AdvancedPane()
        }
    }
}

/// Contents of the floating slab: a top spacer reserving the
/// traffic-light row, then the section list. Mirrors `ContainerColumnContent`
/// but slimmed down — Settings doesn't need an in-slab toolbar row.
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
    @Environment(\.limpidAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            // Reserve the traffic-light row inside the slab. The
            // triad sits at y≈22 (see `repositionTrafficLights`);
            // 36pt gives ~14pt of breathing room below it before
            // the first list row.
            Spacer().frame(height: 36)
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .tint(accent)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}
