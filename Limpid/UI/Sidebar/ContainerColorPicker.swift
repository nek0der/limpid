// ContainerColorPicker.swift
// Limpid — changing a project's palette color: the floating panel
// with its swatch grid, and the host that draws that panel.
//
// The panel is one of Limpid's floating panels (`FloatingPanel.swift`),
// drawn over a whole window like the pane rename field and the prompt cache
// panel: it shares their surface, its arrow points at the color dot it was
// opened from, and it may overlap the rows below. The project settings
// sheet opens it from its Color row.

import SwiftUI

/// The panel's body: a caption in the rename panel's style over the
/// palette as a grid of swatches, eight to a row, the current one in a ring.
/// Picking applies at once; there is nothing to confirm.
struct ContainerColorPicker: View {
    let current: Int?
    /// A palette slot, or nil for "Automatic": no color of the project's
    /// own, which draws in the accent (`LimpidColor.paletteColor`).
    let onSelect: (Int?) -> Void

    /// The swatch VoiceOver is on, moved to the current one when the panel
    /// appears; see the `onAppear` below.
    @AccessibilityFocusState private var focusedSwatch: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: LimpidLayout.containerColorPanelSpacing) {
            Text("Color")
                .font(LimpidFont.caption)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            grid
            automatic
        }
        .padding(LimpidLayout.floatingPanelPadding)
        .accessibilityElement(children: .contain)
        // The panel takes no keyboard focus (the keyboard stays with the
        // terminal, so typing there carries on), and a VoiceOver user would
        // otherwise have to hunt for it. Moved on the next pass, once the
        // swatches exist to receive it.
        .onAppear {
            DispatchQueue.main.async {
                focusedSwatch = current ?? -1
            }
        }
    }

    private var grid: some View {
        let palette = LimpidColor.projectPalette
        let columns = LimpidLayout.containerColorSwatchColumns
        let rows = stride(from: 0, to: palette.count, by: columns).map {
            Array($0..<min($0 + columns, palette.count))
        }
        return VStack(spacing: LimpidLayout.containerColorSwatchSpacing) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: LimpidLayout.containerColorSwatchSpacing) {
                    ForEach(rows[rowIndex], id: \.self) { index in
                        swatch(index)
                    }
                }
            }
        }
    }

    private func swatch(_ index: Int) -> some View {
        let isSelected = current == index
        return Button {
            onSelect(index)
        } label: {
            swatchFace(paletteIndex: index, isSelected: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(Self.name(of: index)))
        .accessibilityLabel(Text(Self.name(of: index)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityFocused($focusedSwatch, equals: index)
    }

    /// Draws a swatch in its slot: the fill the project's mark takes
    /// (`ProjectMarkRule`), so the swatch picked is the color the mark
    /// shows, in a ring while it is the project's. `nil` is Automatic's,
    /// the accent.
    private func swatchFace(paletteIndex: Int?, isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(SupervisionTokens.projectMarkFill(paletteIndex: paletteIndex))
                .frame(width: LimpidLayout.containerColorSwatchSize, height: LimpidLayout.containerColorSwatchSize)
            if isSelected {
                Circle()
                    .stroke(Color.primary.opacity(0.85), lineWidth: 2)
                    .frame(
                        width: LimpidLayout.containerColorSelectionRingSize,
                        height: LimpidLayout.containerColorSelectionRingSize
                    )
            }
        }
        .frame(width: LimpidLayout.containerColorSwatchSlot, height: LimpidLayout.containerColorSwatchSlot)
    }

    private static func name(of index: Int) -> LocalizedStringResource {
        LimpidColor.projectPaletteNames.indices.contains(index)
            ? LimpidColor.projectPaletteNames[index]
            : LocalizedStringResource("Color \(index + 1)")
    }

    /// Back to no color of the project's own, which a picked swatch had no
    /// way to undo: under the grid, a swatch in the accent and its name.
    private var automatic: some View {
        let isSelected = current == nil
        return Button {
            onSelect(nil)
        } label: {
            HStack(spacing: LimpidLayout.floatingPanelPadding / 2) {
                swatchFace(paletteIndex: nil, isSelected: isSelected)
                Text("Automatic", comment: "Project color picker: no color of the project's own")
                    .font(LimpidFont.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Use the accent color", comment: "Project color picker: tooltip of Automatic"))
        .accessibilityLabel(Text("Automatic", comment: "Project color picker: no color of the project's own"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityFocused($focusedSwatch, equals: -1)
    }
}

/// Hosts the open color picker over the window it is placed in, below the
/// color dot it was opened from, with the presentation in that window's
/// environment: the project settings sheet's Color row opens it. Picking
/// applies the color to the project and closes.
struct ContainerColorPanelHost: View {
    /// Whether a press on the color dot is left to the dot, a button that
    /// toggles the panel (the settings sheet), rather than closing it.
    var isAnchorPressLeftToAnchor = false

    @Environment(ContainerColorPresentation.self) private var presentation
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        FloatingPanelHost(
            request: presentation.request,
            width: LimpidLayout.containerColorPanelWidth,
            style: .arrowed,
            onPointerPressedOutside: { presentation.pointerPressedOutside() },
            onKey: { presentation.keyPressed(isEscape: $0.isEscape) },
            isAnchorPressLeftToAnchor: isAnchorPressLeftToAnchor,
            content: { request in
                // Read live, so the ring follows a color changed elsewhere
                // while the panel is open.
                ContainerColorPicker(current: session.project(request.projectID)?.paletteIndex) { index in
                    if let pick = presentation.pick(index) {
                        session.setProjectPaletteIndex(pick.projectID, to: pick.paletteIndex)
                    }
                }
            }
        )
    }
}
