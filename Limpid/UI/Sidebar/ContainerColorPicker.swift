// ContainerColorPicker.swift
// Limpid — popover content for changing a Group / Project palette
// color. Surfaced from a tappable dot in `ContainerRow` and from the
// row's right-click context menu. Single horizontal row of swatches;
// current selection wears a primary-colored ring.

import SwiftUI

struct ContainerColorPicker: View {
    let current: Int?
    let onSelect: (Int) -> Void

    private static let columns = 8

    var body: some View {
        let palette = LimpidColor.projectPalette
        let rows = stride(from: 0, to: palette.count, by: Self.columns).map {
            Array($0..<min($0 + Self.columns, palette.count))
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Color")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { rowIdx in
                    HStack(spacing: 6) {
                        ForEach(rows[rowIdx], id: \.self) { idx in
                            swatch(idx)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func swatch(_ idx: Int) -> some View {
        let isSelected = (current ?? -1) == idx
        Button {
            onSelect(idx)
        } label: {
            ZStack {
                Circle()
                    .fill(LimpidColor.projectPalette[idx])
                    .frame(width: 20, height: 20)
                if isSelected {
                    Circle()
                        .stroke(Color.primary.opacity(0.85), lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Color \(idx + 1)")
    }
}
