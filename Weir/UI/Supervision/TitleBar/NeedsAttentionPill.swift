// NeedsAttentionPill.swift
// Weir — the title bar's "Needs Attention n", which opens the list.

import SwiftUI

/// The attention count across every project, always in sight. It
/// opens the Needs Attention list; ⌘J moves to the next item without it.
struct NeedsAttentionPill: View {
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(SettingsStore.self) private var settings
    @Environment(\.locale) private var locale

    var body: some View {
        let model = NeedsAttentionPillModel(attentionQueue.queue.counts())
        TitleBarMenuButton(menu: .needsAttention) { isHighlighted in
            NeedsAttentionPillLabel(model: model, isHighlighted: isHighlighted)
        }
        .help(Text(verbatim: model.tooltip(
            listShortcut: settings.settings.keyboard.shortcut(for: .showNeedsAttention)?.displayString,
            nextShortcut: settings.settings.keyboard.shortcut(for: .nextAttention)?.displayString,
            locale: locale
        )))
        .accessibilityLabel(Text(model.label))
        .accessibilityValue(Text(verbatim: AgentStatusText.spokenList(
            AttentionSummaryText.breakdown(model.counts, locale: locale),
            locale: locale
        )))
    }
}

/// A bordered button: a tray, "Needs Attention", and the count in a pill
/// of its own. The pill carries the state: a soft amber
/// chip while something blocks on the person, a soft blue one for unread
/// turns only, unfilled at zero, where the whole button turns quiet. Where the title
/// bar leaves it too little room (`SupervisionWindowWidths.titleBar`), the
/// words go and the tray and the count stay; the button's VoiceOver label
/// and tooltip still name it.
private struct NeedsAttentionPillLabel: View {
    let model: NeedsAttentionPillModel
    let isHighlighted: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            button(isWordShown: true)
            button(isWordShown: false)
        }
    }

    private func button(isWordShown: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.attentionButtonCornerRadius, style: .continuous)
        let isEmpty = model.style == .empty
        return HStack(spacing: WeirLayout.Supervision.titleBarLabelSpacing) {
            Image(systemName: "tray")
                .font(.supervision(.icon))
            if isWordShown {
                Text("Needs Attention")
                    .font(.supervision(.label, weight: isEmpty ? .medium : .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            countPill
        }
        .foregroundStyle(isEmpty ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
        .padding(.vertical, WeirLayout.Supervision.spaceXS)
        .padding(.horizontal, WeirLayout.Supervision.spaceS)
        // As see-through as the title bar's ground (`SurfaceGround`), so
        // with the background opacity under 100% it is not an opaque box.
        .background(SurfaceGround {
            shape.fill(isHighlighted ? SupervisionTokens.hover.color : SupervisionTokens.window.color)
        })
        .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
        .contentShape(shape)
    }

    private var countPill: some View {
        let style = NeedsAttentionCountStyle.of(model.style)
        return Text(model.count, format: .number)
            .font(.supervision(.meta, weight: model.style == .empty ? .medium : .semibold))
            .monospacedDigit()
            .foregroundStyle(style.label.color)
            .padding(.horizontal, WeirLayout.Supervision.spaceSnug)
            .frame(minWidth: WeirLayout.Supervision.attentionCountMinSize, minHeight: WeirLayout.Supervision.attentionCountMinSize)
            .background(Capsule().fill(style.fill?.color ?? .clear))
            .overlay {
                if let edge = style.edge {
                    Capsule().strokeBorder(edge.color, lineWidth: 1)
                }
            }
    }
}

/// The count's colors by style: a soft chip of the state's
/// family, as the decision bar's tag is (`DecisionBarTagStyle`), with its
/// figures in the family's text tone at 4.5:1 and a 1pt ring in the
/// state's own color. The fill is opaque and keeps its strength while the
/// button's ground turns to `hover`, so the figures keep their ratio there.
/// At zero the count has no fill and no ring: the whole button is quiet
/// (the strong amber disc with dark figures read as a dark
/// block on the title bar).
struct NeedsAttentionCountStyle: Equatable {
    /// `nil` at zero.
    let fill: ThemedColor?
    let label: ThemedColor
    /// `nil` at zero.
    let edge: ThemedColor?

    static func of(_ style: NeedsAttentionPillModel.Style) -> Self {
        switch style {
        case .blocking:
            Self(fill: SupervisionTokens.waitingFill, label: SupervisionTokens.waitingText, edge: SupervisionTokens.waiting)
        // The count's blue edge says unread only, on the blue's
        // soft fill as the amber has its own. The unread state glyph is
        // drawn in the accent instead (`StateGlyph`).
        case .unreadOnly:
            Self(fill: SupervisionTokens.unreadFill, label: SupervisionTokens.unreadText, edge: SupervisionTokens.unread)
        case .empty:
            Self(fill: nil, label: SupervisionTokens.muted, edge: nil)
        }
    }
}
