// NeedsAttentionRowView.swift
// Limpid — one Needs Attention row, as the title bar's list and the menu bar both draw it.

import SwiftUI

/// This is a row: the session's name and how long the item has waited, and under
/// them where the item is and its fact. Its button (Answer…)
/// stands beside the row rather than in it, so the row's fill marks only
/// what opening the row goes to; VoiceOver reaches the button there, as
/// its own element. The menu bar lays what it acts on in place under the
/// row, outside the fill for the same reason.
struct NeedsAttentionRowView: View {
    let row: NeedsAttentionListModel.Row
    let now: Date
    let isSelected: Bool
    let isActionSelected: Bool
    /// What opening the row does, for VoiceOver: the list goes to the pane
    /// in its own window; the menu bar says it goes there in Limpid.
    var openHint = Self.listOpenHint
    /// Opens the row, chosen as it was.
    let onOpen: (NeedsAttentionListOpening) -> Void
    let onAction: () -> Void
    /// The pointer came over the row (`true`) or left it, for a list whose
    /// pointer selects the row it is over; `nil` where the row only tints
    /// itself under the pointer.
    var onHover: ((Bool) -> Void)?
    @Environment(\.locale) private var locale
    @Environment(\.popoverSurface.ground) private var ground
    @Environment(\.popoverSurface.rowHighlight) private var highlight
    @Environment(\.popoverSurface.ink) private var ink
    @State private var isHovering = false

    static let listOpenHint = LocalizedStringResource(
        "Goes to this pane",
        comment: "Needs Attention list row accessibility hint"
    )

    var body: some View {
        HStack(spacing: LimpidLayout.Supervision.spaceSnug) {
            rowFace
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.supervisionSecondary(size: .compact))
                    // The keyboard's place on the button, shown like a
                    // focused control, since the list holds the focus.
                    .supervisionFocusRing(
                        isFocused: isActionSelected,
                        cornerRadius: LimpidLayout.Supervision.buttonCornerRadius
                    )
                    // The control Return presses, said as the ring shows it.
                    .accessibilityAddTraits(isActionSelected ? .isSelected : [])
            }
        }
    }

    private var rowFace: some View {
        HStack(alignment: .top, spacing: LimpidLayout.Supervision.popoverRowColumnSpacing) {
            // On the system menu's lit row the fill is the system's
            // accent, which an unread ring in the accent would vanish
            // into; it turns the color of the row's words, as they do.
            StateGlyph(kind: glyph, inkOnAccentFill: selectedText)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: LimpidLayout.Supervision.popoverRowLineSpacing) {
                HStack(spacing: LimpidLayout.Supervision.spaceSnug) {
                    Text(verbatim: row.title)
                        .font(.supervision(.label, weight: .semibold))
                        .foregroundStyle(selectedText ?? ink.text)
                        .lineLimit(1)
                        .supervisionTruncation(.name)
                    Spacer(minLength: LimpidLayout.Supervision.spaceSnug)
                    Text(display: waitLabel)
                        .font(.supervision(.meta))
                        .monospacedDigit()
                        .foregroundStyle(selectedText ?? ink.muted)
                        .fixedSize()
                }
                Text(detail)
                    .font(.supervision(.meta))
                    .lineLimit(1)
                    // The place leads; a command or a file at the end stays
                    // with it ("alpha · Write: /Users/…/notes.txt").
                    .supervisionTruncation(row.factTruncation)
                    .accessibilityLabel(row.spokenDetail.isEmpty ? Text(detail) : Text(verbatim: row.spokenDetail))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(rowInsets)
        .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill))
        // The edge is the material's way of showing the selected row; the
        // system menu's fill needs none, so it draws none.
        .popoverSelectionEdge(
            isSelected: isSelected && !highlight.pointerSelects,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .onClick { onOpen(.click(holdsCommand: $0)) }
        .onHover { isHovering in
            self.isHovering = isHovering
            onHover?(isHovering)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text(openHint))
        .accessibilityAction { onOpen(.click(holdsCommand: false)) }
        // What ⌘-click does, which VoiceOver cannot do with a key held.
        .accessibilityActions {
            if row.opensInNewWindow {
                Button { onOpen(.newWindowAction) } label: { Text(NewWindowText.actionName) }
            }
        }
        .modifier(NewWindowHelp(isShown: row.opensInNewWindow))
    }

    /// The one color every word takes on the selected row where the fill
    /// asks for it (the system menu's); `nil` keeps each word its own.
    private var selectedText: Color? {
        isSelected ? highlight.selectedText : nil
    }

    /// The row's fill: under the system menu's highlight, the accent while
    /// the row is selected and nothing otherwise, since the pointer selects
    /// the row rather than tinting it; on the ground's, its selection and
    /// hover fills.
    private var fill: Color {
        if highlight.pointerSelects {
            return isSelected ? (highlight.selection ?? .clear) : .clear
        }
        return isSelected ? ground.selection.color : isHovering ? ground.hover.color : .clear
    }

    /// The system menu's rows are drawn in its rhythm; Limpid's
    /// lists in the popovers'.
    private var rowInsets: EdgeInsets {
        highlight.pointerSelects ? LimpidLayout.Supervision.menuBarRowInsets : LimpidLayout.Supervision.popoverRowInsets
    }

    private var cornerRadius: CGFloat {
        highlight.pointerSelects
            ? LimpidLayout.Supervision.menuBarRowCornerRadius
            : LimpidLayout.Supervision.needsAttentionRowCornerRadius
    }

    /// The place in the quiet color, the fact in the color of its state:
    /// amber for what waits on the person and red for a stop, as on the
    /// sidebar's rows, so the two lists read alike. On the system menu's
    /// fill both are white, as a menu turns every word of its lit row.
    private var detail: AttributedString {
        var lead = AttributedString(row.placeLead)
        lead.foregroundColor = selectedText ?? ink.muted
        var fact = AttributedString(row.fact)
        fact.foregroundColor = selectedText ?? factColor
        return lead + fact
    }

    /// How long the item has waited: "just now" under a minute, then a compact
    /// duration in the window's language ("4m", "4分").
    private var waitLabel: DisplayText {
        let elapsed = max(0, now.timeIntervalSince(row.arrivedAt))
        if elapsed < 60 {
            return .localized("just now")
        }
        return .verbatim(Duration.seconds(elapsed).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 1).locale(locale)
        ))
    }

    private var glyph: StateGlyph.Kind {
        switch row.state {
        case .approval: .needsApproval
        case .question: .needsAnswer
        case .response: .needsResponse
        case .signIn: .needsSignIn
        case .stopped: .stopped
        case .unread: .unread
        }
    }

    private var factColor: Color {
        switch row.state {
        case .approval, .question, .response, .signIn: SupervisionTokens.waitingText.color
        case .stopped: SupervisionTokens.stoppedText.color
        case .unread: ink.muted
        }
    }

    private var actionTitle: LocalizedStringKey? {
        switch row.action {
        case .answer: "Answer…"
        case nil: nil
        }
    }
}

extension KeyEquivalent {
    /// ⇧Tab, which AppKit delivers as a character of its own (U+0019)
    /// rather than as Tab with Shift held.
    static let backTab = KeyEquivalent("\u{19}")
}

extension KeyPress {
    /// ⇧Tab, however it arrives: as its own character, or as Tab with
    /// Shift held.
    var isBackTab: Bool {
        key == .backTab || modifiers.contains(.shift)
    }
}
