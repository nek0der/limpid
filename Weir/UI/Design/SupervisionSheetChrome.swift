// SupervisionSheetChrome.swift
// Weir — the title line and the button row every supervision sheet shares.

import SwiftUI

/// A supervision sheet's title line: the title in `sheetTitleFontSize`
/// bold, what belongs beside it, and for a sheet that is only looked at,
/// the × that closes it. One view for every sheet, so the new worktree,
/// project settings, shortcut, and All Projects sheets cannot drift apart
/// in size or weight.
///
/// A sheet for looking things up closes with × and Esc (`closeKey`); a
/// sheet that takes input has no × and closes from its footer's buttons,
/// so there is one way out in one place.
struct SupervisionSheetHeader<Leading: View, Trailing: View>: View {
    let title: Text
    /// The ×'s action; `nil` for a sheet closed by its footer.
    var onClose: (() -> Void)?
    /// The ×'s tooltip, when it says more than "Close", such as its key.
    var closeHelp: LocalizedStringResource?
    /// The key that presses the ×. `nil` where something else already
    /// takes Esc (All Projects' key monitor), so the key is not taken
    /// twice.
    var closeKey: KeyboardShortcut?
    /// Whether the × is drawn as the keyboard's control, where a sheet
    /// moves Tab through its controls itself (All Projects).
    var isCloseFocused = false
    /// Right after the title, such as All Projects' counts.
    @ViewBuilder var leading: () -> Leading
    /// Ahead of the ×, at the end of the line, such as a filter.
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceM) {
            title
                .font(.supervision(WeirLayout.Supervision.sheetTitleFontSize, weight: .bold))
                .foregroundStyle(SupervisionTokens.text.color)
                .lineLimit(1)
                // Ahead of what sits beside it: in a narrow window, All
                // Projects' filter and counts give way before its name.
                .layoutPriority(3)
                .accessibilityAddTraits(.isHeader)
            leading()
            Spacer(minLength: WeirLayout.Supervision.spaceS)
            trailing()
            if let onClose {
                DismissGlyphButton(label: "Close", size: .large, help: closeHelp, action: onClose)
                    .keyboardShortcut(closeKey)
                    .supervisionFocusRing(isFocused: isCloseFocused, cornerRadius: DismissGlyphButton.largeCornerRadius)
                    // The control Return presses, said as the ring shows it.
                    .accessibilityAddTraits(isCloseFocused ? .isSelected : [])
            }
        }
    }
}

extension SupervisionSheetHeader where Leading == EmptyView, Trailing == EmptyView {
    /// A title alone, or a title and its ×.
    init(
        title: Text,
        onClose: (() -> Void)? = nil,
        closeHelp: LocalizedStringResource? = nil,
        closeKey: KeyboardShortcut? = nil
    ) {
        self.init(
            title: title,
            onClose: onClose,
            closeHelp: closeHelp,
            closeKey: closeKey,
            leading: { EmptyView() },
            trailing: { EmptyView() }
        )
    }
}

/// A supervision sheet's button row: what the sheet is doing, or a
/// secondary way elsewhere, at the start, and the sheet's own buttons at
/// the end, Cancel ahead of the primary, as a macOS dialog has them. The
/// buttons are the supervision styles, never the native ones the accent
/// tints (`SupervisionPrimaryButtonStyle`, `.supervisionSecondary`).
struct SupervisionSheetFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceS) {
            leading()
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension SupervisionSheetFooter where Leading == EmptyView {
    /// The buttons at the end, nothing at the start.
    init(@ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}
