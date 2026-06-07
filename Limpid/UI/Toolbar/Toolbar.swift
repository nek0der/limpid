// Toolbar.swift
// Limpid — single top toolbar split into three segments that align
// horizontally with container / tab / terminal column below. Mirrors Notes 2026's toolbar:
//   ● ● ●  [+] [▭|]    [container] [⋯]  [+Tab] […actions…] [⋯] [search]
//
// Each segment is a small SwiftUI HStack; the parent layout (`ThreePaneLayout`)
// pins them to the right widths so the toolbar stays in lockstep with
// the columns underneath.

import AppKit
import Sparkle
import SwiftUI

// MARK: - tab column toolbar segment

/// tab column top toolbar — Notes 2026 puts the folder name and "X notes"
/// subtitle here, with a `…` action menu pinned right. We mirror the
/// same shape: container name, subtitle (path / count / git overlay),
/// and a trailing actions button.
struct ToolbarTabColumnSegment: View {
    @Environment(WindowSession.self) private var session
    @Environment(NotificationHistoryStore.self) private var historyStore
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.claudeSessionTracker) private var claudeSessionTracker
    @Environment(\.codexSessionTracker) private var codexSessionTracker
    @Environment(\.cwdEventTracker) private var cwdEventTracker

    var body: some View {
        ToolbarRow(position: .tab) {
            HStack(alignment: .center, spacing: 8) {
                if !session.sidebarHidden {
                    ToolbarContainerTitle()
                }
                Spacer()
                ToolbarActionCapsule {
                    // New Tab sits left of the ellipsis menu so the
                    // most-frequent action lives next to the tab
                    // list itself — used to be on the far-right terminal column
                    // toolbar, which meant a long cursor trip from
                    // the tabs. The action capsule stays one
                    // grouping so the tab column toolbar doesn't fragment.
                    ToolbarCapsuleButton(
                        systemImage: "plus",
                        help: "New Tab (⌘T)"
                    ) {
                        TabActions.newTab(session)
                    }
                    ToolbarCapsuleDivider()
                    ToolbarCapsuleMenuButton(
                        systemImage: "ellipsis",
                        help: "Container Actions"
                    ) {
                        Button(role: .destructive) {
                            TabActions.closeAllTabsInActiveContainer(
                                session,
                                registry: registry,
                                claudeSessionTracker: claudeSessionTracker,
                                codexSessionTracker: codexSessionTracker,
                                cwdEventTracker: cwdEventTracker
                            )
                        } label: {
                            Label("Close All Tabs", systemImage: "xmark")
                        }
                        .disabled(session.tabs(in: session.activeContainerID).isEmpty)
                        Divider()
                        Button {
                            session.clearAllUnread()
                            historyStore.markAllRead()
                        } label: {
                            Label("Mark All as Read", systemImage: "checkmark.circle")
                        }
                    }
                }
                .padding(.trailing, 8)
            }
        }
    }
}

// MARK: - terminal column toolbar segment

struct ToolbarTerminalColumnSegment: View {
    @Environment(WindowSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(UpdateStateModel.self) private var updateState
    @Environment(\.sparkleUpdater) private var updater
    @Environment(\.surfaceRegistry) private var registry

    var body: some View {
        ToolbarRow(position: .terminal) {
            terminalColumnContent
        }
    }

    private var terminalColumnContent: some View {
        HStack(spacing: 8) {
            if session.sidebarHidden {
                ToolbarContainerTitle()
                    .frame(minWidth: 200, alignment: .leading)
            }

            ToolbarPaletteField()

            Spacer(minLength: 0)

            if updateState.showsBadge, let updater {
                ToolbarUpdateButton(updater: updater)
            }
            ToolbarActionCapsule {
                ToolbarCapsuleButton(
                    systemImage: "chevron.backward",
                    help: "Go Back",
                    isEnabled: session.canNavigateBack
                ) {
                    session.navigateBack()
                }
                ToolbarCapsuleDivider()
                ToolbarCapsuleButton(
                    systemImage: "chevron.forward",
                    help: "Go Forward",
                    isEnabled: session.canNavigateForward
                ) {
                    session.navigateForward()
                }
            }
            ToolbarActionCapsule {
                ToolbarCapsuleButton(
                    systemImage: "rectangle.split.2x1",
                    help: "Split Right (⌘D)",
                    isEnabled: session.activeTab != nil
                ) {
                    PaneActions.split(
                        session,
                        direction: .horizontal,
                        registry: registry,
                        minPaneSize: settings.settings.terminal.minPaneSize,
                        toastCenter: toastCenter
                    )
                }
                ToolbarCapsuleDivider()
                ToolbarCapsuleButton(
                    systemImage: "rectangle.split.1x2",
                    help: "Split Down (⌘⇧D)",
                    isEnabled: session.activeTab != nil
                ) {
                    PaneActions.split(
                        session,
                        direction: .vertical,
                        registry: registry,
                        minPaneSize: settings.settings.terminal.minPaneSize,
                        toastCenter: toastCenter
                    )
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

/// State-driven affordance rendered in the terminal column toolbar whenever the
/// updater isn't `.idle`. The badge icon, tint, and animation switch
/// based on `UpdateState` so the toolbar tells the user at-a-glance
/// what phase the update is in (available → downloading → installing
/// → done). Tap opens `UpdatePopover`, which is also state-driven.
///
/// We intentionally keep this as its own capsule (not a member of
/// the back/forward capsule) so the affordance reads as distinct
/// from navigation — the visual rhythm becomes
/// `[update] [< | >] [split | split]`, with the tinted box pulling
/// the eye independently of the chevrons.
struct ToolbarUpdateButton: View {
    let updater: SPUUpdater

    @Environment(UpdateStateModel.self) private var model
    @Environment(\.limpidAccent) private var accent
    @State private var isOpen = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            badgeIcon
                .font(.system(size: LimpidLayout.toolbarIconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(
                    width: LimpidLayout.toolbarCapsuleButtonWidth,
                    height: LimpidLayout.toolbarCapsuleButtonHeight
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(tintColor.opacity(isHovering ? 0.85 : 0.65)),
            in: Capsule()
        )
        .overlay(Capsule().stroke(LimpidColor.toolbarHairline, lineWidth: 0.5))
        .onHover { isHovering = $0 }
        .help(Text(helpText))
        // VoiceOver reads the SF Symbol name as the primary label
        // without this — every update-button state would otherwise
        // voice as the glyph name ("shippingbox.fill, button") instead
        // of the actual state. Mirror the tooltip text into the AX
        // label so both surfaces stay in sync from one call site.
        // `helpText` already routes through the string catalog, so
        // ja users get the translated state.
        .accessibilityLabel(Text(helpText))
        // During `.downloading` / `.extracting` the percentage in the
        // ring is the actually-useful number — voice it as the AX
        // value so screen-reader users know how far through the
        // update they are.
        .accessibilityValue(Text(progressValueText))
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            UpdatePopover(updater: updater) {
                isOpen = false
            }
            .limpidAccentPropagated(accent)
        }
    }

    /// Pick a SwiftUI view for the current state. Progress states embed
    /// a `ProgressRing` (drawn over the capsule); the rest are plain
    /// SF Symbols.
    @ViewBuilder
    private var badgeIcon: some View {
        switch model.state {
        case .checking:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeating)
        case let .downloading(_, expected, received, _):
            ProgressRing(progress: ratio(received: received, expected: expected))
        case let .extracting(progress):
            ProgressRing(progress: progress)
        case .installing:
            Image(systemName: "arrow.down.circle.fill")
                .symbolEffect(.pulse, options: .repeating)
        case .installed:
            Image(systemName: "checkmark.circle.fill")
        case .notFound:
            Image(systemName: "checkmark.circle")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        case .available, .readyToInstall, .idle:
            Image(systemName: "shippingbox.fill")
        }
    }

    /// Tint color tracks state severity — accent for normal flow,
    /// green for completion, red for errors. Keeps the urgency
    /// signal readable without text.
    private var tintColor: Color {
        switch model.state {
        case .error: .red
        case .installed, .notFound: .green
        default: accent
        }
    }

    private var helpText: String {
        switch model.state {
        case .idle:
            ""
        case .checking:
            String(localized: "Checking for updates…")
        case let .available(item, _):
            String(localized: "Update available: \(item.displayVersion)")
        case let .downloading(item, _, _, _):
            String(localized: "Downloading \(item.displayVersion)…")
        case .extracting:
            String(localized: "Preparing update…")
        case let .readyToInstall(item, _):
            String(localized: "Ready to install \(item.displayVersion)")
        case .installing:
            String(localized: "Installing update…")
        case .installed:
            String(localized: "Update installed")
        case .notFound:
            String(localized: "You're up to date")
        case .error:
            String(localized: "Update failed")
        }
    }

    private func ratio(received: UInt64, expected: UInt64?) -> Double {
        guard let expected, expected > 0 else { return 0 }
        return min(1.0, Double(received) / Double(expected))
    }

    /// Locale-aware progress value voiced by VoiceOver during a
    /// download / extract. Empty in every other state — SwiftUI
    /// suppresses `accessibilityValue` when the text is empty so the
    /// glyph-only states (`.idle`, `.installed`, `.error`) read as a
    /// plain button.
    private var progressValueText: String {
        switch model.state {
        case let .downloading(_, expected, received, _):
            ratio(received: received, expected: expected)
                .formatted(.percent.precision(.fractionLength(0)))
        case let .extracting(progress):
            progress.formatted(.percent.precision(.fractionLength(0)))
        default:
            ""
        }
    }
}

/// Thin progress ring rendered inside the toolbar capsule. Two
/// strokes — faint track + accent foreground — match macOS 26's
/// inline progress styling without needing a full `ProgressView`.
struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .frame(width: 14, height: 14)
    }
}

/// Shared container title block — icon + name (bold) + subtitle
/// (path / count) + optional git overlay. Used by BOTH the tab column toolbar
/// (when the sidebar is shown) and the terminal column toolbar (when the sidebar
/// is hidden), so the two never drift apart visually.
struct ToolbarContainerTitle: View {
    @Environment(WindowSession.self) private var session

    var body: some View {
        let presentation = ContainerPresentation(
            container: session.activeContainerID,
            session: session
        )
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: presentation.icon)
                .font(.system(size: 12))
                .foregroundStyle(presentation.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
            // Git dirty / ahead-behind would clutter the title, so we
            // surface it elsewhere (currently nowhere — the tab column mode
            // switcher used to host it, but the switcher was removed
            // when Log/Diff/Stash placeholders went away).
        }
        .padding(.leading, 14)
    }
}

/// Visual body of every toolbar capsule cell — 32×28 icon with hover
/// fill. Shared between `ToolbarCapsuleButton` (tap action) and
/// `ToolbarCapsuleMenuButton` (drop-down menu) so the two never drift
/// out of sync (icon weight, color, hit area, hover treatment).
struct ToolbarCapsuleLabel: View {
    let systemImage: String
    let isEnabled: Bool
    let isHovering: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: LimpidLayout.toolbarIconSize, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(width: LimpidLayout.toolbarCapsuleButtonWidth, height: LimpidLayout.toolbarCapsuleButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: LimpidLayout.toolbarCapsuleHoverCorner, style: .continuous)
                    .fill(isHovering && isEnabled ? LimpidColor.rowHoverFill : .clear)
            )
            .contentShape(Rectangle())
    }
}

/// Button used inside an action capsule. Hover fill uses a rounded
/// rect so it reads cleanly when the button stands on its own (e.g.
/// the container column toolbar where buttons aren't inside a capsule). Inside a
/// capsule the surrounding `clipShape(Capsule())` clips this rect to
/// the capsule outline, so the same code works for both layouts.
struct ToolbarCapsuleButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ToolbarCapsuleLabel(
                systemImage: systemImage,
                isEnabled: isEnabled,
                isHovering: isHovering
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        // `.help(_:)` only populates the tooltip / hint surface
        // (NSAccessibility.help). VoiceOver still reads the SF Symbol
        // name as the primary label without this — every chrome
        // button on the toolbar would otherwise voice as "xmark, button"
        // etc. Mirror the tooltip text into the accessibility label
        // so both surfaces stay in sync from one call site.
        .accessibilityLabel(Text(help))
    }
}

/// Menu-triggering twin of `ToolbarCapsuleButton`. Uses the same
/// `ToolbarCapsuleLabel` so the visual footprint (size, color, hover)
/// stays identical to its tap-action siblings, while the click pops
/// open a `Menu`.
struct ToolbarCapsuleMenuButton<MenuContent: View>: View {
    let systemImage: String
    let help: LocalizedStringKey
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovering = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            ToolbarCapsuleLabel(
                systemImage: systemImage,
                isEnabled: true,
                isHovering: isHovering
            )
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// Vertical hairline used between buttons inside a segmented capsule.
struct ToolbarCapsuleDivider: View {
    var body: some View {
        Rectangle()
            .fill(LimpidColor.toolbarHairline)
            .frame(width: LimpidLayout.toolbarCapsuleDividerWidth, height: LimpidLayout.toolbarCapsuleDividerHeight)
    }
}

/// Liquid Glass action capsule — single shared component used by both
/// the container column toolbar (add / bell / sidebar) and the terminal column toolbar (new tab /
/// split row / split col). Caller provides the buttons + dividers via
/// the trailing closure; the capsule supplies clip shape, glass
/// material, stroke, and shadow.
struct ToolbarActionCapsule<Content: View>: View {
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .clipShape(Capsule())
        .modifier(ToolbarGlassBackground(
            shape: Capsule(),
            solid: reduceTransparencyResolver.shouldReduceTransparency
        ))
        .overlay(Capsule().stroke(LimpidColor.toolbarHairline, lineWidth: 0.5))
    }
}

/// Single-button glass tile. Same materials/stroke/shadow as
/// `ToolbarActionCapsule` but uses a rounded square shape so a lone
/// button doesn't render as a near-perfect circle (Capsule applied to
/// a 32×28 frame collapses to that). Used for the tab column toolbar ellipsis
/// menu and any other one-off toolbar button.
struct ToolbarActionTile<Content: View>: View {
    @Environment(ReduceTransparencyResolver.self) private var reduceTransparencyResolver
    @ViewBuilder let content: () -> Content
    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .clipShape(shape)
        .modifier(ToolbarGlassBackground(
            shape: shape,
            solid: reduceTransparencyResolver.shouldReduceTransparency
        ))
        .overlay(shape.stroke(LimpidColor.toolbarHairline, lineWidth: 0.5))
    }
}

/// Toolbar capsule / tile glass with a solid fallback. The system
/// `.glassEffect` honors the macOS Reduce Transparency accessibility
/// flag, but it does NOT honor Limpid's user-facing Transparency
/// setting in `LimpidSettings.appearance` — `ReduceTransparencyResolver`
/// folds the two and exposes the combined verdict. Without this
/// modifier the container slab would paint solid while the floating
/// toolbar capsules next to it kept the frosted glass, leaving a
/// visibly inconsistent half-toggle for users who flipped Settings →
/// Transparency off without the system flag.
private struct ToolbarGlassBackground<S: Shape>: ViewModifier {
    let shape: S
    let solid: Bool

    func body(content: Content) -> some View {
        if solid {
            content.background(
                shape.fill(Color(nsColor: .windowBackgroundColor))
            )
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

// MARK: - Toolbar shared button

struct ToolbarIconButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: LimpidLayout.toolbarIconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? LimpidColor.rowHoverFill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
