// SupervisionSharedParts.swift
// Weir — small parts several supervision surfaces draw alike: a menu trigger, a dropdown row's ground, a key hint.

import SwiftUI

/// The face of a bordered pop-up's trigger (`PopUpMenuButton`'s label): what
/// it shows now, then a chevron, in a thin edge. The changes panel's
/// conversation filter and the review's scope menu use it, so both read as
/// the same kind of control, and both fade alike while off.
struct BorderedMenuTriggerLabel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.isEnabled) private var isEnabled

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.menuTriggerCornerRadius, style: .continuous)
        HStack(spacing: Layout.spaceSnug) {
            content()
            Image(systemName: "chevron.down")
                .font(.supervision(.disclosure, weight: .semibold))
                .foregroundStyle(SupervisionTokens.muted.color)
        }
        .padding(.horizontal, Layout.menuTriggerHorizontalPadding)
        .frame(height: Layout.menuTriggerHeight)
        .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
        .contentShape(shape)
        // Its words draw their own colors, which disabling leaves as they
        // are; it fades as the window's bordered buttons do.
        .opacity(isEnabled ? 1 : SupervisionTokens.disabledOpacity)
    }
}

extension View {
    /// The ground of a dropdown's or a short list's row: the surface's
    /// selection fill and edge on the chosen row, its hover fill under the
    /// pointer, as the attention list's rows have them. One rule, so a row
    /// under the pointer never reads as the chosen one in one list and not
    /// in the next. A list whose rows keep their own corner (the command
    /// palette's are circular) passes its style, so sharing the rule leaves
    /// each row's outline as it was.
    func dropdownRowBackground(
        isSelected: Bool,
        isHovering: Bool,
        cornerRadius: CGFloat = WeirLayout.Supervision.dropdownRowCornerRadius,
        cornerStyle: RoundedCornerStyle = .continuous
    ) -> some View {
        modifier(DropdownRowBackground(
            isSelected: isSelected,
            isHovering: isHovering,
            cornerRadius: cornerRadius,
            cornerStyle: cornerStyle
        ))
    }
}

private struct DropdownRowBackground: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool
    let cornerRadius: CGFloat
    let cornerStyle: RoundedCornerStyle
    @Environment(\.popoverSurface.ground) private var ground

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
        content
            .background(shape.fill(DropdownRowFill.fill(isSelected: isSelected, isHovering: isHovering, on: ground)?.color ?? .clear))
            .popoverSelectionEdge(isSelected: isSelected, in: shape)
    }
}

/// Which of the ground's fills a dropdown row takes (`dropdownRowBackground`):
/// the selection's when chosen, the hover's under the pointer, none
/// otherwise.
enum DropdownRowFill {
    static func fill(isSelected: Bool, isHovering: Bool, on ground: PopoverGround) -> RowFill? {
        if isSelected {
            return ground.selection
        }
        return isHovering ? ground.hover : nil
    }
}

/// A primary button's title with "⌘⏎" beside it while `showsHint`: the
/// decision bar's and the review's send buttons say their key there until
/// the person has used it a few times (`PrimaryKeyHint`). The key is drawn
/// for the eye only; the button's help and VoiceOver name it.
struct PrimaryKeyHintLabel: View {
    let title: Text
    let showsHint: Bool

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceSnug) {
            title
            if showsHint {
                Text(verbatim: "⌘⏎")
                    .font(.supervision(.detail, weight: .medium))
                    .opacity(SupervisionTokens.keyHintOpacity)
                    .accessibilityHidden(true)
            }
        }
    }
}
