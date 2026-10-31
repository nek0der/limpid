// PlanUsagePanel.swift
// Weir — the rail's plan usage button and the floating panel it opens: each agent's limit windows.

import SwiftUI

/// The rail's usage icon: a mark while a window nears or reaches its limit,
/// and the usage panel beside the rail on a click.
struct RailPlanUsageButton: View {
    @Environment(PlanUsageStore.self) private var store
    @Environment(ProjectWindowState.self) private var window
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.locale) private var locale

    var body: some View {
        // The mark drops once a window's reset time passes, which no record
        // change announces.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let level = store.level(at: context.date)
            RailButton(
                systemImage: "timer",
                name: "Plan Usage",
                shortcut: nil,
                isSelected: window.planUsage.isPresented,
                badge: PlanUsageText.railBadge(level),
                help: PlanUsageText.railHelp(level, locale: locale),
                badgeLabel: PlanUsageText.levelLabel(level, locale: locale)
            ) {
                window.togglePlanUsage(session: session)
            }
        }
    }
}

/// Window-level host of the plan usage panel: the same detached, arrowless
/// panel as the notification history and the command palette, beside the
/// rail button it was opened from. A press anywhere outside it or Escape
/// closes it.
struct PlanUsageOverlay: View {
    let state: AppState
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The panel's frame in global coordinates, in which the rail button's is
    /// given too, for telling a press on the button from one elsewhere.
    @State private var panelFrame: CGRect = .zero

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        Group {
            if window.planUsage.isPresented,
               let anchor = window.planUsage.anchor,
               anchor.frame.width > 0
            {
                GeometryReader { overlayGeo in
                    let overlayOrigin = overlayGeo.frame(in: .global).origin
                    let place = PlanUsagePlacement.place(
                        anchor: RailPanelAnchor(
                            frame: anchor.frame.offsetBy(dx: -overlayOrigin.x, dy: -overlayOrigin.y),
                            columnTop: anchor.columnTop - overlayOrigin.y,
                            columnBottom: anchor.columnBottom - overlayOrigin.y
                        ),
                        container: overlayGeo.size,
                        metrics: .init(width: Layout.railPanelWidth, inset: Layout.spaceM, gap: Layout.spaceSnug)
                    )
                    // As tall as what it shows, which a window of any
                    // ordinary height has room for; a window too short for
                    // it scrolls the panel instead of pushing it past the
                    // columns' top. A cap alone (`frame(maxHeight:)`) would
                    // stretch the surface to the cap.
                    ViewThatFits(in: .vertical) {
                        surfaced(PlanUsagePanel().fixedSize(horizontal: false, vertical: true), anchor: anchor)
                        surfaced(ScrollView { PlanUsagePanel() }, anchor: anchor)
                    }
                    .frame(height: place.maximumHeight, alignment: .bottom)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text("Plan Usage"))
                    .padding(.leading, place.leading)
                    .padding(.bottom, overlayGeo.size.height - place.bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .ignoresSafeArea()
                // Here rather than on the panel, which is built twice to
                // pick the one that fits: it runs once while the panel is
                // up, and ends with it, whether it closes or its window does.
                .task { await state.planUsageStore.followCodex() }
                .modalTransition(.floatingPanel, reduceMotion: reduceMotion)
                .zIndex(100)
            }
        }
        .animation(
            ModalMotion.floatingPanel.animation(reduceMotion: reduceMotion),
            value: window.planUsage.isPresented
        )
        // One layer is open at a time: the palette and the notification
        // history take the panel's place when they open.
        .onChange(of: state.session.commandPaletteState?.windowID == window.id) { _, isPresented in
            if isPresented {
                window.planUsage.isPresented = false
            }
        }
        .onChange(of: window.notificationHistory.isPresented) { _, isPresented in
            if isPresented {
                window.planUsage.isPresented = false
            }
        }
        // The terminal gets the keyboard back, unless what closed the panel
        // was another layer opening, which holds it now.
        .onChange(of: window.planUsage.isPresented) { wasPresented, isPresented in
            guard wasPresented, !isPresented,
                  !window.isAnotherLayerOpen(than: .planUsage, session: state.session)
            else { return }
            KeyboardHandoff.returnToFocusedPane(
                in: window.id,
                session: state.session,
                registry: registry,
                keeper: .terminal,
                timing: .now
            )
        }
    }

    /// The panel on the floating panels' surface, with the window's clicks
    /// and keys watched as the other floating panels watch them
    /// (`FloatingPanelEventMonitor`): an AppKit monitor sees a press wherever
    /// it lands, the terminal included, which a tap target laid over the
    /// window does not, and the press still reaches what it landed on. A
    /// press on the rail button is left to the button, which closes the
    /// panel itself; counted as outside, it would close the panel and the
    /// button would open it again.
    private func surfaced(_ content: some View, anchor: RailPanelAnchor) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: WeirLayout.floatingPanelCornerRadius, style: .continuous))
            .floatingPanelSurface(cornerRadius: WeirLayout.floatingPanelCornerRadius)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
            .background {
                FloatingPanelEventMonitor(
                    onPointerPressedOutside: { window.planUsage.isPresented = false },
                    onKey: { key in
                        guard key.isEscape else { return false }
                        window.planUsage.isPresented = false
                        return true
                    },
                    anchorInPanel: anchor.frame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
                )
            }
    }
}

/// The usage panel: Claude Code's windows as its status line last reported
/// them, then Codex's, which the overlay asks Codex for while it is shown.
struct PlanUsagePanel: View {
    @Environment(PlanUsageStore.self) private var store
    @Environment(\.locale) private var locale

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: Layout.spaceL) {
                header
                PlanUsageSectionView(section: PlanUsageText.claudeSection(store.claude, now: context.date, locale: locale))
                Divider()
                PlanUsageSectionView(section: PlanUsageText.codexSection(
                    store.codex,
                    last: store.lastCodexUsage,
                    now: context.date,
                    locale: locale
                ))
            }
            .padding(Layout.spaceL)
            .frame(width: Layout.railPanelWidth, alignment: .leading)
        }
    }

    private var header: some View {
        HStack {
            Text("Plan Usage")
                .font(.supervision(.title, weight: .semibold))
            Spacer()
            let isReading = store.codex == .reading
            Button {
                Task { await store.refreshCodex() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isReading)
            // A read under way turns the button into a spinner in its own
            // place, so nothing in the panel moves while Codex answers.
            .opacity(isReading ? 0 : 1)
            .overlay {
                if isReading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .accessibilityLabel(isReading ? Text("Reading…") : Text("Refresh"))
            .help(Text("Refresh"))
        }
    }
}

/// One agent: its name, how old the values are, its windows, its reset
/// credits, and a note.
private struct PlanUsageSectionView: View {
    let section: PlanUsageSection

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spaceS) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: section.title)
                    .font(.supervision(.label, weight: .semibold))
                Spacer()
                if let observedAt = section.observedAt {
                    Text(observedAt, format: .relative(presentation: .named))
                        .font(.supervision(.caption))
                        .foregroundStyle(section.isStale ? SupervisionTokens.waitingText.color : SupervisionTokens.muted.color)
                }
            }
            ForEach(section.rows, id: \.kind) { row in
                PlanUsageRowView(row: row)
            }
            .opacity(section.isDimmed ? SupervisionTokens.disabledOpacity : 1)
            if let resetCredits = section.resetCredits {
                Text(verbatim: resetCredits)
                    .font(.supervision(.caption))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .opacity(section.isDimmed ? SupervisionTokens.disabledOpacity : 1)
            }
            if let note = section.note {
                Text(note)
                    .font(.supervision(.caption))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A window: its name, the share used, a bar, and when it resets.
private struct PlanUsageRowView: View {
    let row: PlanUsageRow
    @Environment(\.locale) private var locale

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spaceXS) {
            HStack {
                Text(row.name)
                    .font(.supervision(.row))
                Spacer()
                if row.hasReset {
                    Text(PlanUsageText.reset)
                        .font(.supervision(.row))
                        .foregroundStyle(SupervisionTokens.muted.color)
                } else {
                    Text(verbatim: "\(row.percent)%")
                        .font(.supervision(.row, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(row.level == .atLimit ? SupervisionTokens.stoppedText.color : SupervisionTokens.text.color)
                }
            }
            PlanUsageBar(fraction: Double(row.percent) / 100, color: barColor)
            if let resetText = row.resetText {
                Text(verbatim: resetText)
                    .font(.supervision(.caption))
                    .foregroundStyle(SupervisionTokens.muted.color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(row.name))
        .accessibilityValue(Text(verbatim: PlanUsageText.spokenValue(row, locale: locale)))
    }

    /// The waiting and stopped colors as a window nears and reaches its
    /// limit. The share is written beside the bar, so the color is never
    /// the only sign.
    private var barColor: Color {
        switch row.level {
        case .normal: SupervisionTokens.unread.color
        case .nearLimit: SupervisionTokens.waiting.color
        case .atLimit: SupervisionTokens.stopped.color
        }
    }
}

private struct PlanUsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(SupervisionTokens.line.color)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: WeirLayout.Supervision.usageBarHeight)
        .accessibilityHidden(true)
    }
}
