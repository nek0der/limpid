// ThreePaneLayout.swift
// Limpid — window body. L2 + L3 each own their entire vertical strip
// (chrome on top of the body, single background fill). L1 floats over
// L2's left edge as a Liquid Glass slab. No top chrome bar — every
// chrome segment lives inside its column so the column backgrounds
// reach the very top of the window.

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
            // Background plane: L2 + L3 columns, each carrying its own
            // chrome strip at the top.
            HStack(spacing: 0) {
                L2Column()
                L3Column(ghosttyApp: app)
            }
            .ignoresSafeArea(.container)
            // Liquid Glass base under the entire window body — promotes
            // the L2 / L3 column tints (which are themselves translucent)
            // to true Liquid Glass on macOS 26. Without this layer the
            // window is simply clear and we see bare wallpaper instead
            // of the glass refraction. Falls back to a solid window
            // background when Reduce Transparency is on.
            .background(windowBaseFill.ignoresSafeArea())
            // Overlay plane: L1 slab (or, if hidden, the floating chrome
            // capsule). The slab starts at y=0 so its chrome row lines
            // up vertically with the AppKit traffic-light strip.
            if !state.session.sidebarHidden {
                // Slab has a small top margin from the window edge.
                // L1 chrome inside the slab + L2 / L3 chromes outside
                // it all share the same `chromeTopInset` so action
                // buttons + titles land on the same y as the AppKit
                // traffic-light row.
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
                    // Align the capsule's vertical center with the
                    // traffic-light row (≈ y=28 from window top).
                    // Capsule visual height ≈ 28pt → top inset 14pt.
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
            // Real `NSVisualEffectView` with `.behindWindow` blending —
            // SwiftUI's `.regularMaterial` only blends within the app,
            // so on a clear `NSWindow` you'd see neither wallpaper nor
            // a glass refraction. The VEV reads the pixels behind the
            // window (desktop, other apps) and blurs them, which is
            // what gives the column tints their Liquid Glass look on
            // macOS 26.
            WindowVibrancyBackground(
                material: .underWindowBackground,
                blendingMode: .behindWindow
            )
        }
    }
}

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
        // Tint sits *over* the behind-window Liquid Glass material
        // (see `ThreePaneLayout.windowBaseFill`). Cap its alpha so
        // the glass blur underneath stays visible — without the
        // cap, the user's `backgroundOpacity` slider at default
        // 0.92 paints a near-solid colour and the glass disappears.
        // ×0.5 keeps the colour clearly readable while letting the
        // wallpaper diffuse through.
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
            // ×0.5 cap mirrors `L2Column` — see comment there.
            (settings.settings.appearance.windowTint.fillColor ?? LimpidColor.l3Background)
                .opacity(settings.settings.appearance.backgroundOpacity * 0.5)
        )
    }
}

/// X position of the L1 slab's right edge for the given session.
/// L2 content should start exactly here so the visible "L2 left edge"
/// (the column area not covered by the slab overlay) lines up with
/// the L2 content's actual leading edge — otherwise row backgrounds
/// look offset to the right of the visual gutter.
@MainActor
enum L1Footprint {
    static func width(for session: WindowSession) -> CGFloat {
        LimpidLayout.l1InsetH + session.sidebarWidth
    }
}
