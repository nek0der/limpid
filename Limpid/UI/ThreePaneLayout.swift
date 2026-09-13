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
    @Environment(\.limpidAccent) private var limpidAccent
    /// Compact windows overlay the container slab instead of reserving a
    /// column for it. This is presentation-only so narrowing a window never
    /// overwrites the user's persisted sidebar preference.
    @State private var isCompactSidebarPresented = false
    /// The New Tab control is hidden while its owning column changes position.
    @State private var isSidebarTransitioning = false
    @State private var sidebarTransitionTask: Task<Void, Never>?
    /// Window-owned so an explicit command can present the sheet even while
    /// the always-mounted sidebar is disabled offscreen.
    @State private var creatingWorktreeFor: UUID?

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
                            plan: plan,
                            isSidebarTransitioning: isSidebarTransitioning
                        )
                    case .vertical:
                        HStack(spacing: 0) {
                            TabColumn(
                                plan: plan,
                                isSidebarTransitioning: isSidebarTransitioning
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
                // Keep one surface mounted across every presentation. Layout
                // reservation changes underneath it while offset owns the
                // visual lifecycle, so neither regular nor compact dismissal
                // depends on SwiftUI retaining a conditionally removed view.
                ZStack(alignment: .trailing) {
                    ContainerColumnContent(
                        isPresentationEnabled: plan.isSidebarPresented,
                        creatingWorktreeFor: $creatingWorktreeFor
                    )
                    if plan.isSidebarReserved {
                        SidebarResizeHandle(session: state.session)
                    }
                }
                .frame(width: min(plan.sidebarWidth, geometry.size.width))
                .flushGlassSidebar(
                    isSolid: reduceTransparencyResolver.shouldReduceTransparency,
                    solidFill: containerColumnSolidFill
                )
                .transientLeadingPanelShadow(isVisible: plan.usesCompactSidebar)
                .ignoresSafeArea(.all, edges: .top)
                .offset(x: reduceMotion ? 0 : plan.sidebarLeadingOffset)
                .opacity(plan.isSidebarPresented ? 1 : 0)
                .allowsHitTesting(plan.isSidebarPresented)
                .accessibilityHidden(!plan.isSidebarPresented)
                .animation(
                    reduceMotion ? nil : LimpidMotion.sidebarToggle,
                    value: plan.isSidebarPresented
                )
                // Keep titlebar controls in window coordinates. The sidebar
                // surface moves underneath instead of dragging the controls
                // across the traffic lights.
                FloatingSidebarToolbar(isSidebarPresented: plan.isSidebarPresented)
                    .padding(.leading, LimpidLayout.trafficLightWidth + 10)
                    .padding(.top, LimpidLayout.toolbarContentTopInset)
                    .ignoresSafeArea(.all, edges: .top)
            }
            .onReceive(NotificationCenter.default.publisher(for: .limpidToggleSidebarPresentation)) { note in
                guard let owner = note.object as? WindowSession, owner === state.session else { return }
                if plan.isSidebarPresented {
                    state.historyPresentation.isPresented = false
                }
                beginSidebarTransition()
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
            .onChange(of: plan.isSidebarPresented) { _, isPresented in
                if !isPresented {
                    // The sidebar remains mounted offscreen, so its hovered
                    // rows do not receive `onDisappear` as a cleanup signal.
                    state.prHoverPresentation.reset()
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
        .onDisappear {
            sidebarTransitionTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .limpidCreateWorktreeRequested)) { note in
            guard let owner = note.object as? WindowSession, owner === state.session else { return }
            creatingWorktreeFor = state.session.activeContainerID.projectID
                ?? state.session.projects.first?.id
        }
        .sheet(item: Binding(
            get: { creatingWorktreeFor.map { IdentifiedUUID(id: $0) } },
            set: { creatingWorktreeFor = $0?.id }
        )) { wrapped in
            CreateWorktreeSheet(projectID: wrapped.id)
                .environment(state.session)
                .limpidAccentPropagated(limpidAccent)
        }
        // Handled here rather than in the toolbar segment because the two
        // layout branches each carry their own copy of that segment; a
        // second listener would toggle review straight back closed.
        .onReceive(NotificationCenter.default.publisher(for: .limpidReviewChanges)) { notification in
            guard let owner = notification.object as? WindowSession, owner === state.session else { return }
            ReviewPresentationCommand.toggle(
                session: state.session,
                attention: state.attention,
                presentation: state.reviewPresentation,
                registry: state.registry
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .limpidReviewTurn)) { notification in
            guard let owner = notification.object as? WindowSession, owner === state.session else { return }
            ReviewPresentationCommand.openTurn(
                session: state.session,
                attention: state.attention,
                presentation: state.reviewPresentation
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
        guard isCompactSidebarPresented else { return }
        beginSidebarTransition()
        withAnimation(reduceMotion ? nil : LimpidMotion.sidebarToggle) {
            isCompactSidebarPresented = false
        }
    }

    private func beginSidebarTransition() {
        sidebarTransitionTask?.cancel()
        guard !reduceMotion else {
            isSidebarTransitioning = false
            return
        }
        isSidebarTransitioning = true
        sidebarTransitionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(LimpidMotion.sidebarToggleDuration))
            } catch {
                return
            }
            withAnimation(LimpidMotion.sidebarToggleAccessoryReveal) {
                isSidebarTransitioning = false
            }
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

private struct IdentifiedUUID: Identifiable {
    let id: UUID
}

// MARK: - Horizontal tab mode

/// Horizontal tab mode body — one unified toolbar above a horizontal tab strip
/// and terminal content. No vertical-tab width participates in this layout.
private struct HorizontalModeBody: View {
    let ghosttyApp: GhosttyApp
    let plan: MainWindowLayoutPlan
    let isSidebarTransitioning: Bool
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
                    if !plan.isCompactSidebarOverlayPresented, !isSidebarTransitioning {
                        NewTabToolbarButton()
                            .padding(.trailing, 8)
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
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
    let isSidebarTransitioning: Bool
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
                        showsNewTab: !plan.isCompactSidebarOverlayPresented && !isSidebarTransitioning
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
