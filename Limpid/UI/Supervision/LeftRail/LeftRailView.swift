// LeftRailView.swift
// Limpid — the left tool window bar: sessions, all projects, history; update, shortcuts, and Settings below.

import Sparkle
import SwiftUI

/// The left rail: the entries to what does not depend on the current
/// session. Its top holds what the work uses (the sessions sidebar, all
/// projects, the notification history); its bottom, help and app-wide
/// entries (an update when there is one, the keyboard shortcuts,
/// Settings), with space between the two. Icons only, each named by its
/// tooltip and VoiceOver label.
struct LeftRailView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    @Environment(NotificationHistoryStore.self) private var historyStore
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(ProjectWindowState.self) private var window
    @Environment(UpdateStateModel.self) private var updateState
    @Environment(\.sparkleUpdater) private var updater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    /// The history control's frame and the rail's top, in global
    /// coordinates: the panel opens beside the one, level with the other.
    @State private var historyButtonFrame: CGRect = .zero
    @State private var railTop: CGFloat = 0

    var body: some View {
        RailColumn {
            // A list, as the sidebar is, rather than the menu's sidebar
            // symbol, which says where a panel goes, not what it holds.
            RailButton(
                systemImage: "list.bullet.rectangle",
                name: WorktreeText.railEntry,
                shortcut: shortcut(.toggleSidebar),
                isSelected: window.isSidebarPresented
            ) {
                window.commands.send(.toggleSidebar)
            }
            RailButton(
                systemImage: LimpidShortcutAction.allProjects.iconName,
                name: "All Projects",
                shortcut: shortcut(.allProjects),
                isSelected: window.isAllProjectsPresented
            ) {
                window.commands.send(.toggleAllProjects)
            }
            // A dot says there is something unread, and no more: a number
            // here reads as a second Needs Attention count. The count is in
            // the tooltip and the VoiceOver value.
            let unread = historyStore.unreadCount
            RailButton(
                systemImage: "bell",
                name: "Notification History",
                shortcut: shortcut(.notificationHistory),
                isSelected: historyPresentation.isPresented,
                badge: NotificationHistoryRailText.badge(unread: unread),
                help: NotificationHistoryRailText.help(shortcut: shortcut(.notificationHistory), unread: unread, locale: locale),
                badgeLabel: NotificationHistoryRailText.unreadCount(unread, locale: locale)
            ) {
                toggleNotificationHistory(historyPresentation, session: session)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                historyButtonFrame = frame
                anchorHistory()
            }
        } bottom: {
            // Only while there is something to say about an update, so
            // the shortcuts below stay in place the rest of the time.
            if updateState.showsBadge, let updater {
                RailUpdateButton(updater: updater)
            }
            RailButton(systemImage: "keyboard", name: "Keyboard Shortcuts", shortcut: shortcut(.keyboardShortcuts)) {
                window.commands.send(.toggleKeyboardShortcuts)
            }
            // The same scene ⌘, opens (`OpenSettingsCommand`), so a person
            // who never learned the key still finds Settings here.
            RailButton(systemImage: "gearshape", name: "Settings", shortcut: OpenSettingsCommand.shortcutDisplay) {
                openWindow(id: LimpidApp.settingsWindowID)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
            railTop = top
            anchorHistory()
        }
    }

    /// The rail runs the body's height, so its top is the columns' top.
    private func anchorHistory() {
        window.historyAnchor = NotificationHistoryAnchor(frame: historyButtonFrame, columnTop: railTop)
    }

    private func shortcut(_ action: LimpidShortcutAction) -> String? {
        settings.settings.keyboard.shortcut(for: action)?.displayString
    }
}

/// A rail's column: its icons from the top, a gap, and its icons at
/// the bottom, running the body's height as the surfaces beside it do. The
/// first icon is centered on the surfaces' heading line and the last on
/// the foot bars' line (`railTopInset`, `railBottomInset`). Both rails lay
/// out through this, so they keep one geometry.
struct RailColumn<Top: View, Bottom: View>: View {
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        VStack(spacing: Layout.railButtonSpacing) {
            top()
            Spacer(minLength: Layout.railGroupMinimumGap)
            bottom()
        }
        .padding(.top, Layout.railTopInset)
        .padding(.bottom, Layout.railBottomInset)
        .frame(width: Layout.railWidth)
        .frame(maxHeight: .infinity)
    }
}

/// One rail icon: 32pt square with 18pt art, quiet until hovered or
/// selected, when it fills and takes the text color.
struct RailButton: View {
    let systemImage: String
    let name: LocalizedStringResource
    /// The key that does the same, shown in the tooltip; `nil` when none
    /// is bound.
    let shortcut: String?
    var isSelected = false
    var isEnabled = true
    /// The mark drawn on the icon: a count of unviewed turns, a dot for
    /// unread history. Optional because most icons carry none.
    var badge: RailBadge?
    /// The tooltip, when it says more than the name and the key.
    var help: String?
    /// What VoiceOver reads of the mark, as the button's value. Optional
    /// because an icon without a mark has nothing to read.
    var badgeLabel: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(foreground)
                .railIcon(isSelected: isSelected, isHovering: isHovering && isEnabled)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        RailBadgeMark(badge: badge)
                    }
                }
                // The badge's ring cuts through the icon and its fill, and
                // no further.
                .compositingGroup()
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .iconButtonHelp(name, shortcut: shortcut, help: help)
        .accessibilityValue(Text(verbatim: badge == nil ? "" : badgeLabel ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(.quaternary) }
        return AnyShapeStyle(isSelected || isHovering ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
    }
}

/// A rail icon's mark, in the blue kept for unread and unviewed,
/// with a ring cut out of the icon under it, so the window's ground shows
/// through, translucent or not, and the mark stands off the icon. The
/// icon draws it in a compositing group, which is all the ring cuts. The
/// dot is the history row's unread dot, centered where a count's center
/// would be, so the mark stays in one place on the icon whichever it is.
struct RailBadgeMark: View {
    let badge: RailBadge

    var body: some View {
        let ring = LimpidLayout.Supervision.railBadgeRingWidth
        switch badge {
        case let .count(count):
            let inner = LimpidLayout.Supervision.railBadgeSize - 2 * ring
            Text(RailBadge.text(for: count))
                .font(.supervision(.badge, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(SupervisionTokens.onUnreadCount.color)
                .padding(.horizontal, LimpidLayout.Supervision.spaceXS)
                .frame(minWidth: inner, minHeight: inner)
                .background(Capsule().fill(SupervisionTokens.unreadCount.color))
                .padding(ring)
                .background(Capsule().fill(.black).blendMode(.destinationOut))
                .fixedSize()
                .offset(y: 1)
        case .dot:
            let dot = LimpidLayout.Supervision.notificationUnreadDotSize
            // How far the ringed dot's corner sits inside a ringed count's.
            let inset = (LimpidLayout.Supervision.railBadgeSize - dot) / 2 - ring
            Circle()
                .fill(SupervisionTokens.unread.color)
                .frame(width: dot, height: dot)
                .padding(ring)
                .background(Circle().fill(.black).blendMode(.destinationOut))
                .offset(x: -inset, y: 1 + inset)
        }
    }
}

extension View {
    /// A rail icon's frame: 18pt art in a 32pt square, filled while
    /// selected or hovered. Every rail button draws its icon through this.
    /// The fill is as see-through as the window's ground under the rail
    /// (`SurfaceGround`), so an open panel's button is not an opaque box.
    func railIcon(isSelected: Bool, isHovering: Bool) -> some View {
        font(.supervision(LimpidLayout.Supervision.railSymbolSize, weight: .regular))
            .frame(width: LimpidLayout.Supervision.railButtonSize, height: LimpidLayout.Supervision.railButtonSize)
            .background(SurfaceGround {
                RoundedRectangle(cornerRadius: LimpidLayout.Supervision.railButtonCornerRadius, style: .continuous)
                    .fill(isSelected ? SupervisionTokens.railSelection.color : isHovering ? SupervisionTokens.hover.color : .clear)
            })
            .contentShape(Rectangle())
    }
}

/// The rail's update icon, drawn in the accent color, opening the
/// update popover beside the rail.
private struct RailUpdateButton: View {
    let updater: SPUUpdater
    @Environment(UpdateStateModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @Environment(\.limpidAccent) private var accent
    @Environment(\.locale) private var locale
    @State private var isOpen = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            UpdateStatusGlyph(
                state: model.state,
                color: SupervisionTokens.accentIcon(settings.settings.appearance.accentColor)
            )
            .railIcon(isSelected: isOpen, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text(model.state.helpText))
        .accessibilityLabel(Text(model.state.helpText))
        .accessibilityValue(Text(verbatim: model.state.progressValueText(locale: locale)))
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            UpdatePopover(updater: updater) {
                isOpen = false
            }
            .environment(\.locale, locale)
            .limpidAccentPropagated(accent)
        }
    }
}
