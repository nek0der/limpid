// ChromeBar.swift
// Limpid — single top toolbar split into three segments that align
// horizontally with L1 / L2 / L3 below. Mirrors Notes 2026's chrome:
//   ● ● ●  [+] [▭|]    [container] [⋯]  [+Tab] […actions…] [⋯] [🔍]
//
// Each segment is a small SwiftUI HStack; the parent layout (`ThreePaneLayout`)
// pins them to the right widths so the chrome stays in lockstep with
// the columns underneath.

import AppKit
import Sparkle
import SwiftUI

// MARK: - L2 chrome segment

/// L2 top chrome — Notes 2026 puts the folder name and "X notes"
/// subtitle here, with a `…` action menu pinned right. We mirror the
/// same shape: container name, subtitle (path / count / git overlay),
/// and a trailing actions button.
struct ChromeL2Segment: View {
    @Environment(WindowSession.self) private var session
    @Environment(NotificationHistoryStore.self) private var historyStore
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.claudeSessionTracker) private var claudeSessionTracker
    @Environment(\.codexSessionTracker) private var codexSessionTracker

    var body: some View {
        ChromeRow(position: .l2) {
            HStack(alignment: .center, spacing: 8) {
                if !session.sidebarHidden {
                    ChromeContainerTitle()
                }
                Spacer()
                ChromeActionCapsule {
                    // New Tab sits left of the ellipsis menu so the
                    // most-frequent action lives next to the tab
                    // list itself — used to be on the far-right L3
                    // chrome, which meant a long cursor trip from
                    // the tabs. The action capsule stays one
                    // grouping so the L2 chrome doesn't fragment.
                    ChromeCapsuleButton(
                        systemImage: "plus",
                        help: "New Tab (⌘T)"
                    ) {
                        TabActions.newTab(session)
                    }
                    ChromeCapsuleDivider()
                    ChromeCapsuleMenuButton(
                        systemImage: "ellipsis",
                        help: "Container Actions"
                    ) {
                        Button(role: .destructive) {
                            TabActions.closeAllTabsInActiveContainer(
                                session,
                                registry: registry,
                                claudeSessionTracker: claudeSessionTracker,
                                codexSessionTracker: codexSessionTracker
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

// MARK: - L3 chrome segment

struct ChromeL3Segment: View {
    @Environment(WindowSession.self) private var session
    @Environment(UpdateStateModel.self) private var updateState
    @Environment(\.sparkleUpdater) private var updater

    var body: some View {
        ChromeRow(position: .l3) {
            l3Content
        }
    }

    private var l3Content: some View {
        HStack(spacing: 8) {
            if session.sidebarHidden {
                ChromeContainerTitle()
            }

            ChromePaletteField()

            Spacer(minLength: 0)

            if updateState.showsBadge, let updater {
                ChromeUpdateButton(updater: updater)
            }
            ChromeActionCapsule {
                ChromeCapsuleButton(
                    systemImage: "chevron.backward",
                    help: "Go Back",
                    isEnabled: session.canNavigateBack
                ) {
                    session.navigateBack()
                }
                ChromeCapsuleDivider()
                ChromeCapsuleButton(
                    systemImage: "chevron.forward",
                    help: "Go Forward",
                    isEnabled: session.canNavigateForward
                ) {
                    session.navigateForward()
                }
            }
            ChromeActionCapsule {
                ChromeCapsuleButton(
                    systemImage: "rectangle.split.2x1",
                    help: "Split Right (⌘D)",
                    isEnabled: session.activeTab != nil
                ) {
                    TabActions.split(session, direction: .horizontal)
                }
                ChromeCapsuleDivider()
                ChromeCapsuleButton(
                    systemImage: "rectangle.split.1x2",
                    help: "Split Down (⌘⇧D)",
                    isEnabled: session.activeTab != nil
                ) {
                    TabActions.split(session, direction: .vertical)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

/// State-driven affordance rendered in the L3 chrome whenever the
/// updater isn't `.idle`. The badge icon, tint, and animation switch
/// based on `UpdateState` so the chrome tells the user at-a-glance
/// what phase the update is in (available → downloading → installing
/// → done). Tap opens `UpdatePopover`, which is also state-driven.
///
/// We intentionally keep this as its own capsule (not a member of
/// the back/forward capsule) so the affordance reads as distinct
/// from navigation — the visual rhythm becomes
/// `[update] [< | >] [split | split]`, with the tinted box pulling
/// the eye independently of the chevrons.
struct ChromeUpdateButton: View {
    let updater: SPUUpdater

    @Environment(UpdateStateModel.self) private var model
    @State private var isOpen = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            badgeIcon
                .font(.system(size: LimpidLayout.chromeIconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(
                    width: LimpidLayout.chromeCapsuleButtonWidth,
                    height: LimpidLayout.chromeCapsuleButtonHeight
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(tintColor.opacity(isHovering ? 0.85 : 0.65)),
            in: Capsule()
        )
        .overlay(Capsule().stroke(LimpidColor.chromeHairline, lineWidth: 0.5))
        .onHover { isHovering = $0 }
        .help(Text(helpText))
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            UpdatePopover(updater: updater) {
                isOpen = false
            }
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

    /// Tint color tracks state severity ── accent for normal flow,
    /// green for completion, red for errors. Keeps the urgency
    /// signal readable without text.
    private var tintColor: Color {
        switch model.state {
        case .error: .red
        case .installed, .notFound: .green
        default: .accentColor
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
}

/// Thin progress ring rendered inside the chrome capsule. Two
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
/// (path / count) + optional git overlay. Used by BOTH the L2 chrome
/// (when the sidebar is shown) and the L3 chrome (when the sidebar
/// is hidden), so the two never drift apart visually.
struct ChromeContainerTitle: View {
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
            // surface it elsewhere (currently nowhere — the L2 mode
            // switcher used to host it, but the switcher was removed
            // when Log/Diff/Stash placeholders went away).
        }
        .padding(.leading, 14)
    }
}

/// Visual body of every chrome capsule cell — 32×28 icon with hover
/// fill. Shared between `ChromeCapsuleButton` (tap action) and
/// `ChromeCapsuleMenuButton` (drop-down menu) so the two never drift
/// out of sync (icon weight, color, hit area, hover treatment).
struct ChromeCapsuleLabel: View {
    let systemImage: String
    let isEnabled: Bool
    let isHovering: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: LimpidLayout.chromeIconSize, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(width: LimpidLayout.chromeCapsuleButtonWidth, height: LimpidLayout.chromeCapsuleButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: LimpidLayout.chromeCapsuleHoverCorner, style: .continuous)
                    .fill(isHovering && isEnabled ? LimpidColor.rowHoverFill : .clear)
            )
            .contentShape(Rectangle())
    }
}

/// Button used inside an action capsule. Hover fill uses a rounded
/// rect so it reads cleanly when the button stands on its own (e.g.
/// the L1 chrome where buttons aren't inside a capsule). Inside a
/// capsule the surrounding `clipShape(Capsule())` clips this rect to
/// the capsule outline, so the same code works for both layouts.
struct ChromeCapsuleButton: View {
    let systemImage: String
    let help: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ChromeCapsuleLabel(
                systemImage: systemImage,
                isEnabled: isEnabled,
                isHovering: isHovering
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Menu-triggering twin of `ChromeCapsuleButton`. Uses the same
/// `ChromeCapsuleLabel` so the visual footprint (size, color, hover)
/// stays identical to its tap-action siblings, while the click pops
/// open a `Menu`.
struct ChromeCapsuleMenuButton<MenuContent: View>: View {
    let systemImage: String
    let help: String
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovering = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            ChromeCapsuleLabel(
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
    }
}

/// Vertical hairline used between buttons inside a segmented capsule.
struct ChromeCapsuleDivider: View {
    var body: some View {
        Rectangle()
            .fill(LimpidColor.chromeHairline)
            .frame(width: LimpidLayout.chromeCapsuleDividerWidth, height: LimpidLayout.chromeCapsuleDividerHeight)
    }
}

/// Liquid Glass action capsule — single shared component used by both
/// the L1 chrome (add / bell / sidebar) and the L3 chrome (new tab /
/// split row / split col). Caller provides the buttons + dividers via
/// the trailing closure; the capsule supplies clip shape, glass
/// material, stroke, and shadow.
struct ChromeActionCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .clipShape(Capsule())
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().stroke(LimpidColor.chromeHairline, lineWidth: 0.5))
    }
}

/// Single-button glass tile. Same materials/stroke/shadow as
/// `ChromeActionCapsule` but uses a rounded square shape so a lone
/// button doesn't render as a near-perfect circle (Capsule applied to
/// a 32×28 frame collapses to that). Used for the L2 chrome ellipsis
/// menu and any other one-off chrome button.
struct ChromeActionTile<Content: View>: View {
    @ViewBuilder let content: () -> Content
    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay(shape.stroke(LimpidColor.chromeHairline, lineWidth: 0.5))
    }
}

// MARK: - Chrome shared button

struct ChromeIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: LimpidLayout.chromeIconSize, weight: .medium))
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
    }
}
