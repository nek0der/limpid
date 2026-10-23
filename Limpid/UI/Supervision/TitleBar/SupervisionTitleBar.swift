// SupervisionTitleBar.swift
// Limpid — the supervision window's 48pt title bar: place, history, palette, attention.

import SwiftUI

/// The title bar: on the left, where this window is (project ▾ and
/// worktree ▾); in the middle, back and forward and the command palette
/// field, as a browser sets them before its address field; on the right,
/// only what must stay in sight (Needs Attention n). Nothing here appears
/// and disappears with the work, so the bar's layout never moves. The
/// dropdowns hang from it through `TitleBarMenuHost`.
struct SupervisionTitleBar: View {
    @Environment(ProjectWindowState.self) private var window

    var body: some View {
        // Back, forward, and the field stand on the bar's center whatever
        // the project's name, so they do not shift as the place changes
        // (`SupervisionWindowWidths.titleBar`).
        SupervisionTitleBarLayout(metrics: .init(
            leadingInset: LimpidLayout.Supervision.titleBarLeadingInset(
                areTrafficLightsHidden: window.selection.areTrafficLightsHidden
            ),
            trailingInset: LimpidLayout.Supervision.titleBarTrailingInset,
            spacing: LimpidLayout.Supervision.titleBarSpacing,
            fieldRange: LimpidLayout.Supervision.paletteFieldWidthRange
        )) {
            TitleBarPlaceLayout(spacing: LimpidLayout.Supervision.titleBarSpacing) {
                ProjectMenuButton()
                WorktreeMenuButton()
            }
            TitleBarHistoryButtons()
            ToolbarPaletteField()
            NeedsAttentionPill()
        }
        .frame(height: LimpidLayout.Supervision.titleBarHeight)
        .frame(maxWidth: .infinity)
    }
}

/// Lays out the place controls (project ▾, worktree ▾) in a row, each at
/// its ideal width while the row has room for both, and sharing the room
/// fairly when it has not (`SupervisionWindowWidths.placeControlWidths`).
///
/// Not an `HStack`: that offers each control an equal share of the row
/// before it knows what the others need, and a control whose name is a
/// `Text` takes the share and cuts its name to it, even though the row was
/// offered room for both names whole. Which control that happens to
/// depends on the names' widths — the project's name was cut to "al…"
/// when the main checkout was detached, because its worktree ▾ then named
/// the folder in a wider monospaced face than the branch it named before.
struct TitleBarPlaceLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        // The controls are of a fixed height (`TitleBarMenuLabel`), so the
        // row is as tall as the tallest whatever is proposed: a `.zero`
        // or `.infinity` proposal would otherwise come back as itself.
        let height = ideals.map(\.height).max() ?? 0
        let idealWidth = ideals.map(\.width).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: min(proposal.width ?? idealWidth, idealWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let widths = SupervisionWindowWidths.placeControlWidths(
            ideals: subviews.map { $0.sizeThatFits(.unspecified).width },
            spacing: spacing,
            width: bounds.width
        )
        HorizontalLayoutPlacement.place(subviews, widths: widths, in: bounds, spacing: spacing)
    }
}

/// Lays out the title bar's four parts (the place controls, back and
/// forward, the palette field, Needs Attention) across the bar's whole
/// width, insets included, so the center group of back, forward, and the
/// field stands on the bar's center. The widths come from
/// `SupervisionWindowWidths.titleBar`; this only measures the sides and
/// the buttons and places what it is given, each part centered on the
/// bar's height.
struct SupervisionTitleBarLayout: Layout {
    let metrics: SupervisionWindowWidths.TitleBarMetrics

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        // The bar's parts are of fixed heights, so the bar is as tall as
        // the tallest whatever is proposed; `.frame(height:)` above sets
        // the height it is drawn at.
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        guard let width = proposal.width else {
            let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            let gaps = metrics.spacing * CGFloat(max(subviews.count - 1, 0))
            return CGSize(width: metrics.leadingInset + ideal + gaps + metrics.trailingInset, height: height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        // The bar always builds exactly these four parts, in this order
        // (`SupervisionTitleBar.body`); anything else is a mistake there.
        assert(subviews.count == 4, "The title bar lays out its place controls, back and forward, the field, and Needs Attention")
        guard subviews.count == 4 else { return }
        let leading = subviews[0]
        let history = subviews[1]
        let field = subviews[2]
        let trailing = subviews[3]
        let historyWidth = history.sizeThatFits(.unspecified).width
        let widths = SupervisionWindowWidths.titleBar(
            width: bounds.width,
            leadingIdeal: leading.sizeThatFits(.unspecified).width,
            historyWidth: historyWidth,
            trailingIdeal: trailing.sizeThatFits(.unspecified).width,
            metrics: metrics
        )
        let historyGap = historyWidth > 0 ? metrics.spacing : 0
        let groupMinX = bounds.midX - (historyWidth + historyGap + widths.field) / 2
        leading.place(
            at: CGPoint(x: bounds.minX + metrics.leadingInset, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: widths.leading, height: bounds.height)
        )
        history.place(
            at: CGPoint(x: groupMinX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: historyWidth, height: bounds.height)
        )
        field.place(
            at: CGPoint(x: groupMinX + historyWidth + historyGap, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: widths.field, height: bounds.height)
        )
        trailing.place(
            at: CGPoint(x: bounds.maxX - metrics.trailingInset, y: bounds.midY),
            anchor: .trailing,
            proposal: ProposedViewSize(width: widths.trailing, height: bounds.height)
        )
    }
}

/// A title bar control that opens one of the window's dropdowns. It reports
/// where it is, which the dropdown hangs from, and shows itself pressed
/// while its dropdown is open.
struct TitleBarMenuButton<Label: View>: View {
    let menu: TitleBarMenuRequest.Menu
    /// Builds the label; true while hovered or while the dropdown is open.
    @ViewBuilder let label: (_ isHighlighted: Bool) -> Label
    @Environment(ProjectWindowState.self) private var window
    @State private var frame: CGRect = .zero
    @State private var isHovering = false

    var body: some View {
        Button {
            window.toggleTitleBarMenu(menu, anchor: frame)
        } label: {
            label(isHovering || window.titleBarMenu?.menu == menu)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newFrame in
            frame = newFrame
            // ⌃⌘J opens the list from the keyboard, hung from here too.
            if menu == .needsAttention {
                window.needsAttentionAnchor = newFrame
            }
        }
    }
}

/// The look of a dropdown control: a mark, its text, anything that goes
/// with the text, a chevron, and the hover fill the title bar's controls
/// share.
struct TitleBarMenuLabel<Leading: View, Trailing: View>: View {
    /// How the control's text reads.
    enum TextStyle {
        /// The project's name: the bar's title.
        case title
        /// A branch name, set in the monospaced face branches have
        /// everywhere else.
        case branch
        /// A word standing in for a name the control has none of.
        case placeholder
    }

    let title: String
    let isHighlighted: Bool
    var textStyle = TextStyle.placeholder
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: LimpidLayout.Supervision.titleBarLabelSpacing) {
            leading
            Text(verbatim: title)
                .font(font)
                .foregroundStyle(textStyle == .placeholder ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                .lineLimit(1)
                .supervisionTruncation(textStyle == .branch ? .branch : .name)
            trailing
            Image(systemName: "chevron.down")
                .font(.supervision(.glyph, weight: .semibold))
                .foregroundStyle(SupervisionTokens.muted.color)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, LimpidLayout.Supervision.spaceS)
        .frame(height: LimpidLayout.titleBarControlHeight)
        // As see-through as the title bar's ground (`SurfaceGround`), so
        // the control whose menu is open is not an opaque box.
        .background(SurfaceGround {
            RoundedRectangle(cornerRadius: LimpidLayout.titleBarHoverCorner, style: .continuous)
                .fill(isHighlighted ? SupervisionTokens.hover.color : .clear)
        })
        .contentShape(Rectangle())
    }

    private var font: Font {
        switch textStyle {
        case .title: .supervision(.label, weight: .semibold)
        case .branch: .supervisionCode(beside: .label, weight: .medium)
        case .placeholder: .supervision(.label)
        }
    }
}

extension TitleBarMenuLabel where Trailing == EmptyView {
    init(title: String, isHighlighted: Bool, textStyle: TextStyle = .placeholder, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, isHighlighted: isHighlighted, textStyle: textStyle, leading: leading, trailing: { EmptyView() })
    }
}

/// One plain item at the bottom of a title bar dropdown: its words, and
/// its shortcut on the right when it has one. No icon, so the items read
/// as commands under the list rather than more of its rows.
struct DropdownItem: View {
    let title: LocalizedStringKey
    /// The key that does the same, as the menu shows it ("⌘O").
    let shortcut: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.popoverSurface.ground) private var ground
    @State private var isHovering = false

    init(_ title: LocalizedStringKey, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: LimpidLayout.Supervision.spaceS) {
                Text(title)
                    .font(.supervision(.label))
                    .foregroundStyle(SupervisionTokens.text.color)
                Spacer(minLength: LimpidLayout.Supervision.spaceS)
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(.supervision(.meta))
                        .foregroundStyle(SupervisionTokens.muted.color)
                }
            }
            .padding(LimpidLayout.Supervision.dropdownFootItemInsets)
            .background(
                // The dropdown's ground decides the fill, as for its rows:
                // the opaque gray all but vanishes on the material.
                RoundedRectangle(cornerRadius: LimpidLayout.Supervision.dropdownFootItemCornerRadius, style: .continuous)
                    .fill(isHovering && isEnabled ? ground.hover.color : .clear)
            )
            .opacity(isEnabled ? 1 : SupervisionTokens.disabledOpacity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A title bar dropdown's heading over its list ("Projects").
struct DropdownHeading: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(.supervision(.meta))
            .foregroundStyle(SupervisionTokens.muted.color)
            .lineLimit(1)
            .padding(LimpidLayout.Supervision.dropdownHeadingInsets)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The rule between a dropdown's list and the items under it.
struct DropdownSeparator: View {
    var body: some View {
        Rectangle()
            .fill(SupervisionTokens.line.color)
            .frame(height: 1)
            .padding(.vertical, LimpidLayout.Supervision.spaceXS)
            .accessibilityHidden(true)
    }
}

/// The check a dropdown row carries when it is what the window shows, in
/// a column every row keeps, so the names line up whichever row is checked.
/// The row's selected trait says the same to VoiceOver.
struct DropdownCheckMark: View {
    let isChecked: Bool
    let color: Color

    var body: some View {
        Image(systemName: "checkmark")
            .font(.supervision(.caption, weight: .bold))
            .foregroundStyle(color)
            .opacity(isChecked ? 1 : 0)
            .frame(width: LimpidLayout.Supervision.dropdownCheckColumnWidth)
            .accessibilityHidden(true)
    }
}
