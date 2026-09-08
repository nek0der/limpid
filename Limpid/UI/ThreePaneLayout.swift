// ThreePaneLayout.swift
// Limpid — window body. In vertical tab mode tab column + terminal column each own their
// entire vertical strip (toolbar on top of the body, single background
// fill). In horizontal tab mode toolbar and content split into
// independent rows so the tab bar + terminal can span the full width
// while the toolbar keeps the tab/terminal column boundary. The container
// column is a flush Liquid Glass sidebar on the window's leading edge in
// both modes, with the tab column's background running underneath it.

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

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background plane: vertical mode keeps the classic two-column
            // layout; horizontal mode splits toolbar from content so they
            // can have independent widths.
            Group {
                if state.session.tabColumnHorizontal {
                    HorizontalModeBody(ghosttyApp: app)
                } else {
                    HStack(spacing: 0) {
                        TabColumn()
                        TerminalColumn(ghosttyApp: app)
                    }
                }
            }
            .ignoresSafeArea(.container)
            .background(windowBaseFill.ignoresSafeArea())
            // Overlay plane: container sidebar (or, if hidden, the floating
            // toolbar capsule). The sidebar is flush to the window's leading,
            // top and bottom edges, so its toolbar row lines up vertically
            // with the AppKit traffic-light strip without any compensation.
            if !state.session.sidebarHidden {
                ZStack(alignment: .trailing) {
                    ContainerColumnContent()
                        .frame(width: state.session.sidebarWidth)
                        .flushGlassSidebar(
                            isSolid: reduceTransparencyResolver.shouldReduceTransparency,
                            solidFill: containerColumnSolidFill
                        )
                    SidebarResizeHandle(session: state.session)
                }
                .ignoresSafeArea(.all, edges: .top)
                // Lateral slides of large surfaces are a classic
                // vestibular trigger (WCAG 2.3.3); drop the move half
                // when Reduce Motion is on and let the opacity carry
                // the transition. Same posture as the system's own
                // Sidebar reveal under that setting.
                .transition(reduceMotion
                    ? .opacity
                    : .move(edge: .leading).combined(with: .opacity))
            } else {
                FloatingHiddenToolbar()
                    .padding(.leading, LimpidLayout.trafficLightWidth + 18)
                    .padding(.top, LimpidLayout.toolbarContentTopInset)
                    .ignoresSafeArea(.all, edges: .top)
                    .transition(.opacity)
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

/// Horizontal tab mode body — toolbar and content are independent rows.
/// The toolbar row carries the tab/terminal column tints but no boundary rule, and the
/// content row spans full width so the tab bar and terminal get maximum
/// real estate.
private struct HorizontalModeBody: View {
    let ghosttyApp: GhosttyApp
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar row — tab column toolbar at its usual width, terminal column toolbar fills rest.
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: leadingInset)
                    ToolbarTabColumnSegment()
                }
                .frame(width: leadingInset + tabColumnBoxWidth)
                .background(tabColumnTint)
                // Glass mode separates the columns by their distinct
                // tints, so the toolbar row keeps its hairline. The
                // opaque tones carry the same separation on their own,
                // so the rule would read as an arbitrary line there —
                // drop it.
                .overlay(alignment: .trailing) {
                    if !reduce {
                        LimpidColor.tabColumnTrailingDivider.frame(width: 0.5)
                    }
                }

                ToolbarTerminalColumnSegment()
                    .frame(maxWidth: .infinity)
                    .background(terminalColumnTint)
            }
            .frame(height: LimpidLayout.topStripHeight)

            // Content row — full width, terminal column tint.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if !session.sidebarHidden {
                        Spacer().frame(width: ContainerColumnFootprint.width(for: session))
                    }
                    HorizontalTabBar(container: session.activeContainerID)
                        .frame(maxWidth: .infinity)
                }
                .overlay(alignment: .bottom) {
                    if !reduce {
                        LimpidColor.tabColumnTrailingDivider.frame(height: 0.5)
                    }
                }
                HStack(spacing: 0) {
                    if !session.sidebarHidden {
                        Spacer().frame(width: ContainerColumnFootprint.width(for: session))
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

    private var leadingInset: CGFloat {
        session.sidebarHidden ? 0 : ContainerColumnFootprint.width(for: session)
    }

    /// When the sidebar is hidden, the tab column box widens just enough that the
    /// trailing action capsule (+ / …) lands clear of the floating
    /// bell + sidebar-toggle capsule. We grow the *box*, not the
    /// `leadingInset`, so the tab column tab bar below still starts at x=0
    /// instead of jumping inwards.
    private var tabColumnBoxWidth: CGFloat {
        session.sidebarHidden
            ? max(session.tabColumnWidth, ContainerColumnFootprint.minTabColumnWidthCollapsed)
            : session.tabColumnWidth
    }

    private var tabColumnTint: some View {
        ColumnBackdrop(appearance: settings.settings.appearance, role: .list, reduceTransparency: reduce)
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
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: leadingInset)
                    ToolbarTabColumnSegment()
                }
                .frame(width: leadingInset + tabColumnBoxWidth, height: LimpidLayout.topStripHeight)
                HStack(spacing: 0) {
                    Spacer().frame(width: leadingInset)
                    TabColumnView()
                }
            }
            TabColumnResizeHandle(session: session)
        }
        .frame(width: leadingInset + tabColumnBoxWidth)
        // Glass mode leans on the column tints (dark divider is clear).
        // The opaque tones are a step apart rather than one shade, but
        // a single step is thin at this size, so the seam keeps a
        // visible hairline there.
        .overlay(alignment: .trailing) {
            divider.frame(width: 0.5)
        }
        .background(ColumnBackdrop(
            appearance: settings.settings.appearance,
            role: .list,
            reduceTransparency: reduceTransparencyResolver.shouldReduceTransparency
        ))
    }

    private var divider: Color {
        reduceTransparencyResolver.shouldReduceTransparency
            ? LimpidColor.tabColumnTrailingDividerOpaque
            : LimpidColor.tabColumnTrailingDivider
    }

    private var leadingInset: CGFloat {
        session.sidebarHidden ? 0 : ContainerColumnFootprint.width(for: session)
    }

    /// Same trick as horizontal mode: widen the tab column box (not the leading
    /// inset) when the sidebar is hidden, so the toolbar action capsule
    /// has room to clear the floating bell + sidebar-toggle while the tab column
    /// list rows stay flush to the window's left edge.
    private var tabColumnBoxWidth: CGFloat {
        session.sidebarHidden
            ? max(session.tabColumnWidth, ContainerColumnFootprint.minTabColumnWidthCollapsed)
            : session.tabColumnWidth
    }
}

/// terminal column — terminal pane area with its own toolbar on top.
private struct TerminalColumn: View {
    let ghosttyApp: GhosttyApp
    @Environment(SettingsStore.self) private var settings
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        VStack(spacing: 0) {
            ToolbarTerminalColumnSegment()
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

/// X position of the container sidebar's right edge for the given
/// session. The sidebar starts at the window's leading edge, so its
/// width is the whole footprint.
@MainActor
enum ContainerColumnFootprint {
    static func width(for session: WindowSession) -> CGFloat {
        session.sidebarWidth
    }

    /// Minimum tab column box width when the sidebar is hidden. Sized so the
    /// trailing action capsule (+ / …) inside `ToolbarTabColumnSegment` lands
    /// past the right edge of the `FloatingHiddenToolbar` capsule
    /// (rendered at `trafficLightWidth + 18`), with a breathing gap
    /// between the two. The tab column box widens to this whenever the user's
    /// `tabColumnWidth` would otherwise be too narrow to fit both capsules.
    static var minTabColumnWidthCollapsed: CGFloat {
        let capsule = 2 * LimpidLayout.toolbarCapsuleButtonWidth
            + LimpidLayout.toolbarCapsuleDividerWidth
        let floatingToolbarRightEdge = LimpidLayout.trafficLightWidth + 18 + capsule
        let toolbarGap: CGFloat = 12
        let actionCapsuleTrailing: CGFloat = 8
        return floatingToolbarRightEdge + toolbarGap + capsule + actionCapsuleTrailing
    }
}
