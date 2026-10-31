// PanelSearchField.swift
// Weir — the search field of a panel over the whole window, and the face it shares with the project menu and the review rail.

import SwiftUI

/// The one search field of the panels over the window (All Projects, the
/// keyboard shortcuts panel), so the two cannot drift apart in height,
/// type, or edge. `hover`'s fill in a `line` edge, as tall as a
/// sheet's field (`panelSearchFieldHeight`), with the accent's ring while
/// it has the keyboard. The native search field Settings uses is not this:
/// it draws the system's own face, not the window's tokens.
struct PanelSearchField: View {
    @Binding var text: String
    /// The placeholder, which is also what VoiceOver names the field.
    let prompt: Text
    var isFocused: FocusState<Bool>.Binding
    /// Whether the ring shows while the field has the keyboard. False while
    /// a panel that moves Tab through its controls itself draws the ring on
    /// another of them (`KeyboardShortcutPanelKeys`, `AllProjectsSelection`).
    var showsRing = true

    @Environment(\.locale) private var locale

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        TextField("", text: $text, prompt: prompt.foregroundStyle(SupervisionTokens.muted.color))
            .textFieldStyle(.plain)
            .font(.supervision(.body))
            .foregroundStyle(SupervisionTokens.text.color)
            // The text is drawn lower, not laid out lower, so the field keeps
            // its height.
            .offset(y: Layout.panelSearchTextDrop(for: locale))
            .focused(isFocused)
            .searchFieldFace(.panel, showsRing: isFocused.wrappedValue && showsRing)
            .accessibilityLabel(prompt)
    }
}

/// This is how a search field looks around its line: its fill, its edge, its
/// corner, and how much room it takes. It is only the face: what the field holds,
/// where focus goes, and what its keys do stay with each field, since the
/// panels', the project menu's, and the review rail's fields differ there
/// (Return and ⌘Return, a clear button, arrows into a list).
struct SearchFieldFace {
    /// This is how the face takes its room around the line.
    enum Size {
        /// The face has a height of its own, with this much room on either side.
        case height(CGFloat, horizontalInset: CGFloat)
        /// The face is the line's own height with these insets around it.
        case insets(EdgeInsets)
    }

    let fill: Color
    /// This is a one-point edge inside the shape, for a field whose fill
    /// alone would not stand off what it is on.
    var edge: Color?
    let cornerRadius: CGFloat
    var cornerStyle: RoundedCornerStyle = .continuous
    let size: Size

    private typealias Layout = WeirLayout.Supervision

    /// This is the face of the panels over the window (All Projects, the
    /// keyboard shortcuts panel): `hover`'s fill in a `line` edge, as tall as
    /// a sheet's field. It takes a height of its own rather than one made of
    /// insets around the line, so a field beside a title and one on a line of
    /// its own stand alike.
    static let panel = SearchFieldFace(
        fill: SupervisionTokens.hover.color,
        edge: SupervisionTokens.line.color,
        cornerRadius: Layout.panelSearchFieldCornerRadius,
        size: .height(Layout.panelSearchFieldHeight, horizontalInset: Layout.panelSearchFieldHorizontalInset)
    )

    /// This is a dropdown's search (the project menu), sunk into the
    /// dropdown's `well` so it reads as a field on the popover's own surface.
    static func dropdown(well: Color) -> Self {
        SearchFieldFace(
            fill: well,
            cornerRadius: Layout.dropdownSearchCornerRadius,
            size: .insets(Layout.dropdownSearchInsets)
        )
    }

    /// This is the review rail's file filter: a short field in the rail's
    /// row hover, small enough to sit over the file list.
    static let rail = SearchFieldFace(
        fill: WeirColor.rowHoverFill,
        cornerRadius: Layout.smallControlCornerRadius,
        cornerStyle: .circular,
        size: .height(Layout.railSearchFieldHeight, horizontalInset: Layout.spaceS)
    )
}

extension View {
    /// Draws the field's face around this content: `face`'s room, fill, and
    /// edge, and the accent's ring while `showsRing`, which the caller works
    /// out from its own focus.
    func searchFieldFace(_ face: SearchFieldFace, showsRing: Bool = false) -> some View {
        modifier(SearchFieldFaceModifier(face: face, showsRing: showsRing))
    }
}

private struct SearchFieldFaceModifier: ViewModifier {
    let face: SearchFieldFace
    let showsRing: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: face.cornerRadius, style: face.cornerStyle)
        sized(content)
            .background(shape.fill(face.fill))
            .overlay {
                if let edge = face.edge {
                    shape.strokeBorder(edge, lineWidth: 1)
                }
            }
            .supervisionFocusRing(isFocused: showsRing, cornerRadius: face.cornerRadius)
    }

    @ViewBuilder
    private func sized(_ content: Content) -> some View {
        switch face.size {
        case let .height(height, horizontalInset):
            content
                .padding(.horizontal, horizontalInset)
                .frame(height: height)
        case let .insets(insets):
            content.padding(insets)
        }
    }
}
