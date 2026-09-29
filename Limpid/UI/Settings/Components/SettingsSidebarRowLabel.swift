// SettingsSidebarRowLabel.swift
// Limpid — a section row in the Settings sidebar. System Settings
// draws every section as a 20pt tile, so all icons read as the same
// size. We keep monochrome glyphs but fit each one into the same box:
// SF Symbols differ a lot in natural size ("textformat" is wide and
// short, "gearshape" is square), and `Label` renders them at their
// natural size, which made the column look uneven and oversized.

import SwiftUI

struct SettingsSidebarRowLabel: View {
    let section: SettingsSection

    /// The slot every glyph is centered in, matching the tile width
    /// System Settings reserves before the title.
    static let iconSlot: CGFloat = 20
    /// The box the glyph is scaled to fit inside the slot.
    static let glyphSize: CGFloat = 15
    /// Gap between the slot and the title. It lands the title at the same
    /// offset from the cell's leading edge as System Settings (measured
    /// 36.5pt).
    static let titleSpacing: CGFloat = 10

    var body: some View {
        HStack(spacing: Self.titleSpacing) {
            Image(systemName: section.icon)
                .resizable()
                .scaledToFit()
                .frame(width: Self.glyphSize, height: Self.glyphSize)
                .frame(width: Self.iconSlot, height: Self.iconSlot)
                .accessibilityHidden(true)
            Text(section.title)
        }
    }
}
