// ThreePaneLayout.swift
// Limpid — window body. In vertical tab mode L2 + L3 each own their
// entire vertical strip (chrome on top of the body, single background
// fill). In horizontal tab mode chrome and content split into
// independent rows so the tab bar + terminal can span the full width
// while the chrome keeps the L2/L3 column boundary. L1 floats over
// L2's left edge as a Liquid Glass slab in both modes.

import AppKit
import SwiftUI

// `WindowVibrancyBackground` now lives in `Limpid/UI/Design/` so the
// Settings window can share the exact same bridge as the main one.

struct ThreePaneLayout: View {
    let state: AppState
    let app: GhosttyApp
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background plane: vertical mode keeps the classic two-column
            // layout; horizontal mode splits chrome from content so they
            // can have independent widths.
            Group {
                if state.session.l2Horizontal {
                    HorizontalModeBody(ghosttyApp: app)
                } else {
                    HStack(spacing: 0) {
                        L2Column()
                        L3Column(ghosttyApp: app)
                    }
                }
            }
            .ignoresSafeArea(.container)
            .background(windowBaseFill.ignoresSafeArea())
            // Overlay plane: L1 slab (or, if hidden, the floating chrome
            // capsule). The slab starts at y=0 so its chrome row lines
            // up vertically with the AppKit traffic-light strip.
            if !state.session.sidebarHidden {
                ZStack(alignment: .trailing) {
                    L1SlabContent()
                        .frame(width: state.session.sidebarWidth)
                        .liquidGlassSlab(
                            cornerRadius: 10,
                            solid: reduceTransparencyResolver.shouldReduceTransparency
                        )
                    SidebarResizeHandle(session: state.session)
                }
                .padding(.leading, LimpidLayout.l1InsetH)
                .padding(.top, LimpidLayout.l1InsetV)
                .padding(.bottom, LimpidLayout.l1InsetV)
                .ignoresSafeArea(.all, edges: .top)
                .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                FloatingHiddenChrome()
                    .padding(.leading, LimpidLayout.trafficLightWidth + 18)
                    .padding(.top, LimpidLayout.chromeContentTopInset)
                    .ignoresSafeArea(.all, edges: .top)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea(.all)
    }

    @ViewBuilder
    private var windowBaseFill: some View {
        if reduceTransparencyResolver.shouldReduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            WindowVibrancyBackground(
                material: .underWindowBackground,
                blendingMode: .behindWindow
            )
        }
    }
}

// MARK: - Horizontal tab mode

/// Horizontal tab mode body — chrome and content are independent rows.
/// The chrome row preserves the L2/L3 column boundary (with matching
/// tints), while the content row spans full width so the tab bar and
/// terminal get maximum real estate.
private struct HorizontalModeBody: View {
    let ghosttyApp: GhosttyApp
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            // Chrome row — L2 chrome at its usual width, L3 chrome fills rest
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: leadingInset)
                    ChromeL2Segment()
                }
                .frame(width: leadingInset + session.l2Width)
                .background(l2Tint)
                .overlay(alignment: .trailing) {
                    LimpidColor.l2TrailingDivider
                        .frame(width: 0.5)
                }

                ChromeL3Segment()
                    .frame(maxWidth: .infinity)
                    .background(l3Tint)
            }
            .frame(height: LimpidLayout.topStripHeight)

            // Content row — full width, L3 tint
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if !session.sidebarHidden {
                        Spacer().frame(width: L1Footprint.width(for: session))
                    }
                    L2HorizontalTabBar(container: session.activeContainerID)
                        .frame(maxWidth: .infinity)
                }
                .overlay(alignment: .bottom) {
                    LimpidColor.l2TrailingDivider
                        .frame(height: 0.5)
                }
                HStack(spacing: 0) {
                    if !session.sidebarHidden {
                        Spacer().frame(width: L1Footprint.width(for: session))
                    }
                    L3DetailView(ghosttyApp: ghosttyApp)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(l3Tint)
        }
    }

    private var leadingInset: CGFloat {
        session.sidebarHidden ? 0 : L1Footprint.width(for: session)
    }

    private var l2Tint: some View {
        (settings.settings.appearance.windowTint.fillColor ?? LimpidColor.l2Background)
            .opacity(settings.settings.appearance.backgroundOpacity * 0.5)
    }

    private var l3Tint: some View {
        (settings.settings.appearance.windowTint.fillColor ?? LimpidColor.l3Background)
            .opacity(settings.settings.appearance.backgroundOpacity * 0.5)
    }
}

// MARK: - Vertical tab mode (classic two-column layout)

/// L2 column — background fills from the window's left edge to the
/// right edge of the L2 content area, so the column reads as a single
/// surface that extends *under* the floating L1 slab. The L2 chrome /
/// body content is offset right past the slab so it never collides.
/// The right edge carries a drag-resize divider; double-click resets.
private struct L2Column: View {
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: leadingInset)
                    ChromeL2Segment()
                }
                .frame(height: LimpidLayout.topStripHeight)
                HStack(spacing: 0) {
                    Spacer().frame(width: leadingInset)
                    L2View()
                }
            }
            L2ResizeHandle(session: session)
        }
        .frame(width: leadingInset + session.l2Width)
        .overlay(alignment: .trailing) {
            LimpidColor.l2TrailingDivider
                .frame(width: 0.5)
        }
        .background(
            (settings.settings.appearance.windowTint.fillColor ?? LimpidColor.l2Background)
                .opacity(settings.settings.appearance.backgroundOpacity * 0.5)
        )
    }

    private var leadingInset: CGFloat {
        session.sidebarHidden ? 0 : L1Footprint.width(for: session)
    }
}

/// L3 column — terminal pane area with its own chrome on top.
private struct L3Column: View {
    let ghosttyApp: GhosttyApp
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            ChromeL3Segment()
                .frame(height: LimpidLayout.topStripHeight)
            L3DetailView(ghosttyApp: ghosttyApp)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background(
            (settings.settings.appearance.windowTint.fillColor ?? LimpidColor.l3Background)
                .opacity(settings.settings.appearance.backgroundOpacity * 0.5)
        )
    }
}

/// X position of the L1 slab's right edge for the given session.
@MainActor
enum L1Footprint {
    static func width(for session: WindowSession) -> CGFloat {
        LimpidLayout.l1InsetH + session.sidebarWidth
    }
}
