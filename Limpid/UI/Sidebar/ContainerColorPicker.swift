// ContainerColorPicker.swift
// Limpid — changing a Group / Project palette color: the floating panel
// with its swatch grid, and the host that draws that panel.
//
// The panel is one of Limpid's floating panels (`FloatingPanel.swift`),
// drawn over a whole window like the pane rename field and the prompt cache
// panel: it shares their surface, its arrow points at the color dot it was
// opened from, and it may overlap the rows below. A sidebar row opens it
// from "Change Color"; the settings sheet from its Color row.

import SwiftUI

/// The panel's body: a caption in the rename panel's style over the
/// palette as a grid of swatches, eight to a row, the current one in a ring.
/// Picking applies at once; there is nothing to confirm.
struct ContainerColorPicker: View {
    let current: Int?
    let onSelect: (Int) -> Void

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
        }
        .padding(LimpidLayout.floatingPanelPadding)
        .accessibilityElement(children: .contain)
        // The panel takes no keyboard focus (the keyboard stays with the
        // terminal, so typing there carries on), and a VoiceOver user would
        // otherwise have to hunt for it. Moved on the next pass, once the
        // swatches exist to receive it.
        .onAppear {
            DispatchQueue.main.async {
                focusedSwatch = current ?? 0
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
            ZStack {
                Circle()
                    .fill(LimpidColor.projectPalette[index])
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Color \(index + 1)")
        .accessibilityLabel(Text("Color \(index + 1)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityFocused($focusedSwatch, equals: index)
    }
}

/// Hosts the open color picker over the window it is placed in, below the
/// color dot it was opened from: the main window's sidebar rows, or the
/// container settings sheet's Color row, each with its own presentation in
/// the environment. Picking applies the color to the container and closes.
struct ContainerColorPanelHost: View {
    /// Whether a press on the color dot is left to the dot, a button that
    /// toggles the panel (the settings sheet), rather than closing it.
    var isAnchorPressLeftToAnchor = false

    @Environment(ContainerColorPresentation.self) private var presentation
    @Environment(WindowSession.self) private var session

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
                ContainerColorPicker(current: session.paletteIndex(of: request.container)) { index in
                    if let pick = presentation.pick(index) {
                        session.setPaletteIndex(pick.paletteIndex, for: pick.container)
                    }
                }
            }
        )
    }
}
