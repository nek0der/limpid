// Toolbar.swift
// Limpid — one main-window toolbar whose segments align with the
// container, tab, and terminal columns below.
//
// Each segment is a small SwiftUI HStack; the parent layout (`ThreePaneLayout`)
// pins them to the right widths so the toolbar stays in lockstep with
// the columns underneath.

import AppKit
import Sparkle
import SwiftUI

// MARK: - tab column toolbar segment

/// The vertical tab column owns its context and New Tab action.
struct ToolbarTabColumnSegment: View {
    let showsContainerIdentity: Bool
    let showsNewTab: Bool

    var body: some View {
        ToolbarRow {
            HStack(alignment: .center) {
                if showsContainerIdentity {
                    ToolbarContainerTitle()
                }
                Spacer()
                if showsNewTab {
                    NewTabToolbarButton()
                        .padding(.trailing, LimpidLayout.columnResizeHandleWidth)
                }
            }
        }
    }
}

/// Shared New Tab control used by whichever tab presentation is active.
struct NewTabToolbarButton: View {
    @Environment(WindowSession.self) private var session

    var body: some View {
        ToolbarIconButton(systemImage: "plus", help: "New Tab (⌘T)") {
            TabActions.newTab(session)
        }
    }
}

// MARK: - terminal column toolbar segment

struct ToolbarTerminalColumnSegment: View {
    let plan: MainWindowLayoutPlan
    @Environment(WindowSession.self) private var session
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(UpdateStateModel.self) private var updateState
    @Environment(NotificationHistoryStore.self) private var historyStore
    @Environment(\.sparkleUpdater) private var updater
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.claudeSessionTracker) private var claudeSessionTracker
    @Environment(\.codexSessionTracker) private var codexSessionTracker
    @Environment(\.cwdEventTracker) private var cwdEventTracker

    var body: some View {
        ToolbarRow {
            ViewThatFits(in: .horizontal) {
                terminalColumnContent
                    .frame(minWidth: plan.regularToolbarMinimumWidth)
                compactTerminalColumnContent
            }
        }
    }

    private var terminalColumnContent: some View {
        HStack(spacing: LimpidLayout.toolbarControlSpacing) {
            if plan.regularContainerIdentityPlacement == .terminalToolbar {
                ToolbarContainerTitle()
                    .frame(minWidth: LimpidLayout.toolbarContainerTitleMinWidth, alignment: .leading)
            }
            ToolbarPaletteField()
            Spacer(minLength: 0)
            reviewButton
            if updateState.showsBadge, let updater {
                ToolbarUpdateButton(updater: updater)
            }
            HStack(spacing: 2) {
                ToolbarIconButton(
                    systemImage: "chevron.backward",
                    help: "Go Back",
                    isEnabled: session.canNavigateBack
                ) {
                    session.navigateBack()
                }
                ToolbarGroupDivider()
                ToolbarIconButton(
                    systemImage: "chevron.forward",
                    help: "Go Forward",
                    isEnabled: session.canNavigateForward
                ) {
                    session.navigateForward()
                }
            }
            HStack(spacing: 2) {
                ToolbarIconButton(
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
                ToolbarGroupDivider()
                ToolbarIconButton(
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
            actionsMenu(density: .regular)
        }
        .padding(.horizontal, 12)
    }

    /// Narrow-window toolbar. The command palette and review state remain
    /// visible; navigation and split commands retain their menu entries and
    /// keyboard shortcuts without forcing five fixed-width capsules offscreen.
    private var compactTerminalColumnContent: some View {
        HStack(spacing: LimpidLayout.toolbarControlSpacing) {
            ToolbarPaletteField()
            Spacer(minLength: 0)
            reviewButton
            if updateState.showsBadge, let updater {
                ToolbarUpdateButton(updater: updater)
            }
            actionsMenu(density: .compact)
        }
        .padding(.horizontal, 12)
    }

    /// Review is a primary mode switch, so it remains directly reachable at
    /// every width while its surrounding treatment matches other icon buttons.
    private var reviewButton: some View {
        ToolbarIconButton(
            systemImage: ReviewPresentation.symbol,
            help: reviewPresentation.isPresented ? "Close Review" : "Review Changes",
            isEnabled: ReviewAgents.canReview(
                session: session,
                presentation: reviewPresentation
            )
        ) {
            ReviewPresentationCommand.toggle(
                session: session,
                presentation: reviewPresentation,
                registry: registry
            )
        }
    }

    /// One stable overflow owns secondary actions. Compact mode puts frequent
    /// navigation and split commands ahead of the destructive tab action.
    private func actionsMenu(density: ToolbarDensity) -> some View {
        ToolbarIconMenuButton(systemImage: "ellipsis", help: "Actions") {
            if density == .compact {
                Button {
                    session.navigateBack()
                } label: {
                    Label("Go Back", systemImage: "chevron.backward")
                }
                .disabled(!session.canNavigateBack)
                Button {
                    session.navigateForward()
                } label: {
                    Label("Go Forward", systemImage: "chevron.forward")
                }
                .disabled(!session.canNavigateForward)
                Divider()
                Button {
                    split(.horizontal)
                } label: {
                    Label("Split Right", systemImage: "rectangle.split.2x1")
                }
                .disabled(session.activeTab == nil)
                Button {
                    split(.vertical)
                } label: {
                    Label("Split Down", systemImage: "rectangle.split.1x2")
                }
                .disabled(session.activeTab == nil)
                Divider()
            }
            Button {
                session.clearAllUnread()
                historyStore.markAllRead()
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
            Divider()
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
        }
    }

    private func split(_ direction: SplitDirection) {
        PaneActions.split(
            session,
            direction: direction,
            registry: registry,
            minPaneSize: settings.settings.terminal.minPaneSize,
            toastCenter: toastCenter
        )
    }
}

private enum ToolbarDensity: Equatable {
    case regular
    case compact
}

/// State-driven affordance rendered in the terminal column toolbar whenever the
/// updater isn't `.idle`. The badge icon, tint, and animation switch
/// based on `UpdateState` so the toolbar tells the user at-a-glance
/// what phase the update is in (available → downloading → installing
/// → done). Tap opens `UpdatePopover`, which is also state-driven.
///
/// Unlike ordinary toolbar icons, the update control keeps a tinted glass badge
/// because its color communicates progress, completion, or failure.
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
                    width: LimpidLayout.toolbarButtonWidth,
                    height: LimpidLayout.toolbarButtonHeight
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(tintColor.opacity(isHovering ? 0.85 : 0.65)),
            in: Capsule()
        )
        .clipShape(Capsule())
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

/// Shared container title block. `MainWindowLayoutPlan` assigns its regular
/// presentation to one toolbar; compact presentation omits the title.
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

/// Visual body shared by toolbar buttons and menus. The toolbar surface carries
/// the glass; individual controls show a background only while hovering.
struct ToolbarIconLabel: View {
    let systemImage: String
    let isEnabled: Bool
    let isHovering: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: LimpidLayout.toolbarIconSize, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(width: LimpidLayout.toolbarButtonWidth, height: LimpidLayout.toolbarButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: LimpidLayout.toolbarButtonHoverCorner, style: .continuous)
                    .fill(isHovering && isEnabled ? LimpidColor.rowHoverFill : .clear)
            )
            .contentShape(Rectangle())
    }
}

/// Consistent borderless icon button used across the main-window toolbar.
struct ToolbarIconButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ToolbarIconLabel(
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

/// Menu-triggering twin of `ToolbarIconButton`. Uses the same
/// `ToolbarIconLabel` so the visual footprint (size, color, hover)
/// stays identical to its tap-action siblings, while the click pops
/// open a `Menu`.
struct ToolbarIconMenuButton<MenuContent: View>: View {
    let systemImage: String
    let help: LocalizedStringKey
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovering = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            ToolbarIconLabel(
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

/// A quiet separator between related toolbar controls.
struct ToolbarGroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(LimpidColor.toolbarHairline)
            .frame(width: LimpidLayout.toolbarSeparatorWidth, height: LimpidLayout.toolbarSeparatorHeight)
    }
}
