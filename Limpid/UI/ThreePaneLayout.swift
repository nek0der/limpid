// ThreePaneLayout.swift
// Limpid — window body. In vertical tab mode tab column + terminal column each own their
// entire vertical strip (toolbar on top of the body, single background
// fill). In horizontal tab mode one toolbar spans the primary content
// above the tab bar and terminal. The container column is flush while
// reserved and becomes a shadowed overlay at compact widths, with the tab
// column's background running underneath it.

import AppKit
import SwiftUI

// `WindowVibrancyBackground` now lives in `Limpid/UI/Design/` so the
// Settings window can share the exact same bridge as the main one.

struct ThreePaneLayout: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: AppState
    let app: GhosttyApp
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver
    @Environment(ToastCenter.self) private var toastCenter
    /// Compact windows overlay the container slab instead of reserving a
    /// column for it. This is presentation-only so narrowing a window never
    /// overwrites the user's persisted sidebar preference.
    @State private var isCompactSidebarPresented = false

    var body: some View {
        GeometryReader { geometry in
            let plan = MainWindowLayoutPlan.resolve(.init(
                availableWidth: geometry.size.width,
                requestedSidebarWidth: state.session.sidebarWidth,
                requestedTabWidth: state.session.tabColumnWidth,
                isSidebarHidden: state.session.sidebarHidden,
                isCompactSidebarPresented: isCompactSidebarPresented,
                isTabColumnHorizontal: state.session.tabColumnHorizontal,
                isReviewPresented: state.reviewPresentation.isPresented
            ))

            ZStack(alignment: .topLeading) {
                // Background plane: vertical mode keeps the classic two-column
                // layout; horizontal mode splits toolbar from content so they
                // can have independent widths.
                Group {
                    switch plan.tabOrientation {
                    case .horizontal:
                        HorizontalModeBody(
                            ghosttyApp: app,
                            plan: plan
                        )
                    case .vertical:
                        HStack(spacing: 0) {
                            TabColumn(
                                plan: plan
                            )
                            TerminalColumn(ghosttyApp: app, plan: plan)
                        }
                    }
                }
                .ignoresSafeArea(.container)
                .background(windowBaseFill.ignoresSafeArea())
                .allowsHitTesting(!plan.isCompactSidebarOverlayPresented)
                .accessibilityHidden(plan.isCompactSidebarOverlayPresented)
                if plan.isCompactSidebarOverlayPresented {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissCompactSidebar)
                        .ignoresSafeArea()
                }
                // Overlay plane: at compact widths the sidebar rides over the
                // columns instead of forcing the terminal below its readable
                // width. At wider sizes it resumes its persisted column.
                if plan.isSidebarReserved {
                    ZStack(alignment: .trailing) {
                        ContainerColumnContent()
                            .frame(width: min(plan.sidebarWidth, geometry.size.width))
                            .flushGlassSidebar(
                                isSolid: reduceTransparencyResolver.shouldReduceTransparency,
                                solidFill: containerColumnSolidFill
                            )
                        SidebarResizeHandle(session: state.session)
                    }
                    .ignoresSafeArea(.all, edges: .top)
                } else if plan.usesCompactSidebar {
                    ContainerColumnContent()
                        .frame(width: min(plan.sidebarWidth, geometry.size.width))
                        .flushGlassSidebar(
                            isSolid: reduceTransparencyResolver.shouldReduceTransparency,
                            solidFill: containerColumnSolidFill
                        )
                        .transientLeadingPanelShadow()
                        .ignoresSafeArea(.all, edges: .top)
                        .offset(x: plan.isCompactSidebarOverlayPresented ? 0 : -plan.sidebarWidth)
                        .opacity(reduceMotion && !plan.isCompactSidebarOverlayPresented ? 0 : 1)
                        .allowsHitTesting(plan.isCompactSidebarOverlayPresented)
                        .accessibilityHidden(!plan.isCompactSidebarOverlayPresented)
                        .animation(
                            reduceMotion ? nil : LimpidMotion.sidebarToggle,
                            value: plan.isCompactSidebarOverlayPresented
                        )
                }
                if !plan.isSidebarPresented {
                    FloatingHiddenToolbar()
                        .padding(.leading, LimpidLayout.trafficLightWidth + 10)
                        .padding(.top, LimpidLayout.toolbarContentTopInset)
                        .ignoresSafeArea(.all, edges: .top)
                        .transition(reduceMotion
                            ? .identity
                            : .asymmetric(
                                insertion: .opacity.animation(.easeOut(
                                    duration: LimpidMotion.hiddenSidebarToolbarRevealDuration
                                ).delay(LimpidMotion.hiddenSidebarToolbarRevealDelay)),
                                removal: .opacity.animation(.easeOut(
                                    duration: LimpidMotion.hiddenSidebarToolbarRemovalDuration
                                ))
                            ))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .limpidToggleSidebarPresentation)) { note in
                guard let owner = note.object as? WindowSession, owner === state.session else { return }
                withAnimation(reduceMotion ? nil : LimpidMotion.sidebarToggle) {
                    if plan.usesCompactSidebar {
                        isCompactSidebarPresented.toggle()
                    } else {
                        state.session.sidebarHidden.toggle()
                    }
                }
            }
            .onChange(of: plan.usesCompactSidebar) { _, isCompact in
                if !isCompact {
                    isCompactSidebarPresented = false
                }
            }
            .onChange(of: state.session.activeContainerID) { _, _ in
                if plan.usesCompactSidebar {
                    dismissCompactSidebar()
                }
            }
            .onChange(of: state.reviewPresentation.isPresented) { _, isPresented in
                if isPresented, plan.usesCompactSidebar {
                    dismissCompactSidebar()
                }
            }
        }
        .ignoresSafeArea(.all)
        // Handled here rather than in the toolbar segment because the two
        // layout branches each carry their own copy of that segment; a
        // second listener would toggle review straight back closed.
        .onReceive(NotificationCenter.default.publisher(for: .limpidReviewChanges)) { notification in
            guard let owner = notification.object as? WindowSession, owner === state.session else { return }
            ReviewPresentationCommand.toggle(
                session: state.session,
                presentation: state.reviewPresentation,
                registry: state.registry
            )
        }
        // A paste the user refused at the confirmation sheet delivered nothing.
        // Review has already closed by then, so the store is reached through
        // the pool rather than through the surface that was showing it.
        .onReceive(NotificationCenter.default.publisher(for: .limpidReviewPasteDenied)) { notification in
            guard let receipt = notification.object as? ReviewPasteReceipt else { return }
            state.reviewStores.store(root: receipt.root).unmarkInserted(receipt.commentIDs)
            // Said out loud, because the refusal arrives after review has told
            // the reader it went and usually after review has closed. Without
            // this the only two paths that refuse — the confirmation sheet,
            // and a second request arriving while one is already up — took the
            // comments back in silence.
            toastCenter.show(ToastItem(
                message: String(localized: "Review was not delivered. The comments stay in this review."),
                undo: nil
            ))
        }
    }

    private func dismissCompactSidebar() {
        withAnimation(reduceMotion ? nil : LimpidMotion.sidebarToggle) {
            isCompactSidebarPresented = false
        }
    }

    /// Opaque fill for the container sidebar when transparency is
    /// reduced. One step off the content tone rather than equal to it —
    /// see `LimpidColor.sidebarSolidFill` for why the native window
    /// background cannot carry that separation on its own.
    private var containerColumnSolidFill: Color {
        LimpidColor.sidebarSolidFill
    }

    @ViewBuilder
    private var windowBaseFill: some View {
        if reduceTransparencyResolver.shouldReduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            // Behind-window vibrancy samples whatever sits behind the
            // window. In a fullscreen Space that's the bare wallpaper, so
            // its hue floods the backdrop — a green wallpaper tints the
            // whole window green in dark mode. Swapping the material does
            // NOT fix it: `.behindWindow` pulls the wallpaper pixels in
            // regardless of material. Instead we drain the saturation while
            // fullscreen — the translucent blur stays, but the wallpaper's
            // color collapses to neutral gray, matching the windowed look.
            WindowVibrancyBackground(
                material: .underWindowBackground,
                blendingMode: .behindWindow
            )
            .saturation(state.session.isFullScreen ? 0 : 1)
        }
    }
}

// MARK: - Horizontal tab mode

/// Horizontal tab mode body — one unified toolbar above a horizontal tab strip
/// and terminal content. No vertical-tab width participates in this layout.
private struct HorizontalModeBody: View {
    let ghosttyApp: GhosttyApp
    let plan: MainWindowLayoutPlan
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        VStack(spacing: 0) {
            // Horizontal tabs do not have a vertical tab column. Reserve only
            // the visible sidebar or hidden-sidebar controls, then give the
            // remaining titlebar to one responsive toolbar.
            HStack(spacing: 0) {
                Spacer().frame(width: plan.horizontalToolbarLeadingInset)
                ToolbarTerminalColumnSegment(plan: plan)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: LimpidLayout.topStripHeight)
            .background(terminalColumnTint)

            // Content row — full width, terminal column tint.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if plan.reservedSidebarWidth > 0 {
                        Spacer().frame(width: plan.reservedSidebarWidth)
                    }
                    HorizontalTabBar(container: session.activeContainerID)
                        .frame(maxWidth: .infinity)
                    if !plan.isCompactSidebarOverlayPresented {
                        NewTabToolbarButton()
                            .padding(.trailing, 8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !reduce {
                        LimpidColor.horizontalTabBarBottomDivider.frame(height: 0.5)
                    }
                }
                HStack(spacing: 0) {
                    if plan.reservedSidebarWidth > 0 {
                        Spacer().frame(width: plan.reservedSidebarWidth)
                    }
                    TerminalColumnView(ghosttyApp: ghosttyApp)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(terminalColumnTint)
        }
    }

    private var reduce: Bool {
        reduceTransparencyResolver.shouldReduceTransparency
    }

    private var terminalColumnTint: some View {
        ColumnBackdrop(appearance: settings.settings.appearance, role: .content, reduceTransparency: reduce)
    }
}

// MARK: - Vertical tab mode (classic two-column layout)

/// tab column — background fills from the window's left edge to the
/// right edge of the tab column content area, so the column reads as a single
/// surface that extends *under* the container sidebar. The tab column toolbar /
/// body content is offset right past the sidebar so it never collides.
/// The right edge carries a drag-resize divider; double-click resets.
private struct TabColumn: View {
    let plan: MainWindowLayoutPlan
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: plan.reservedSidebarWidth)
                    ToolbarTabColumnSegment(
                        showsContainerIdentity: plan.regularContainerIdentityPlacement == .tabToolbar,
                        showsNewTab: !plan.isCompactSidebarOverlayPresented
                    )
                }
                .frame(
                    width: plan.reservedSidebarWidth + plan.tabColumnWidth,
                    height: LimpidLayout.topStripHeight
                )
                HStack(spacing: 0) {
                    Spacer().frame(width: plan.reservedSidebarWidth)
                    TabColumnView()
                }
            }
            TabColumnResizeHandle(
                session: session,
                displayedWidth: plan.tabColumnWidth,
                minWidth: plan.tabColumnMinimumWidth,
                maxWidth: plan.tabColumnMaximumWidth
            )
        }
        .frame(width: plan.reservedSidebarWidth + plan.tabColumnWidth)
        // Glass mode separates the columns with tint alone; a rule at
        // this flush seam reads as a shadow. The opaque tones are only
        // one step apart, so Reduce Transparency keeps a hairline.
        .overlay(alignment: .trailing) {
            if reduceTransparencyResolver.shouldReduceTransparency {
                LimpidColor.tabColumnTrailingDividerOpaque.frame(width: 0.5)
            }
        }
        .background(ColumnBackdrop(
            appearance: settings.settings.appearance,
            role: .list,
            reduceTransparency: reduceTransparencyResolver.shouldReduceTransparency
        ))
    }

}

/// terminal column — terminal pane area with its own toolbar on top.
private struct TerminalColumn: View {
    let ghosttyApp: GhosttyApp
    let plan: MainWindowLayoutPlan
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        VStack(spacing: 0) {
            ToolbarTerminalColumnSegment(plan: plan)
                .frame(height: LimpidLayout.topStripHeight)
            TerminalColumnView(ghosttyApp: ghosttyApp)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(ColumnBackdrop(
            appearance: settings.settings.appearance,
            role: .content,
            reduceTransparency: reduceTransparencyResolver.shouldReduceTransparency
        ))
    }
}

/// Backdrop for the flush tab and terminal columns. The fill depends on the
/// user's Reduce Transparency state:
///
/// - **Off (default):** the stock translucent column tints
///   (`tabColumnBackground` / `terminalColumnBackground`) wash over the window's
///   behind-window glass, so the panes read as Liquid Glass.
/// - **On:** translucency is undesirable, so the tab column takes the
///   opaque `tabColumnSolidFill` and the terminal column the native
///   `windowBackgroundColor`. They used to share the window tone and
///   lean on a hairline, but once the sidebar went flush it shared that
///   tone too, and light mode resolved all three to one white surface.
private struct ColumnBackdrop: View {
    enum Role { case list, content }
    let appearance: AppearanceSettings
    let role: Role
    let reduceTransparency: Bool

    var body: some View {
        if reduceTransparency {
            solidTint.opacity(appearance.backgroundOpacity)
        } else {
            stockTint.opacity(appearance.backgroundOpacity * 0.5)
        }
    }

    private var stockTint: Color {
        role == .list ? LimpidColor.tabColumnBackground : LimpidColor.terminalColumnBackground
    }

    private var solidTint: Color {
        role == .list ? LimpidColor.tabColumnSolidFill : Color(nsColor: .windowBackgroundColor)
    }
}
