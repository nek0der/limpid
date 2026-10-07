// PaneHeaderMetrics.swift
// Limpid — the split pane header's sizes that rules outside the view
// depend on.

import CoreGraphics

/// The header's geometry as far as Core needs it. The split floor counts the
/// header's height and narrowest width, and the rename rule asks whether a
/// header is wide enough to edit its name in place, so these numbers cannot
/// live only in `LimpidLayout`, which Core does not read.
/// `LimpidLayout` takes its header values from here; the rest of the
/// header's look (fonts, the rename panel) stays there.
enum PaneHeaderMetrics {
    /// One line of name text with room around it. The terminal gives up
    /// exactly this much, since the header sits above it rather than over it.
    static let height: CGFloat = 24

    /// Leading and trailing inset of the header's content. The glyph slot
    /// already carries air on both sides of the glyph, so this is smaller
    /// than the tab row's inset.
    static let horizontalPadding: CGFloat = 6

    /// Gap between the header's items, and the least the spacer before its
    /// trailing items may shrink to.
    static let itemSpacing: CGFloat = 4

    /// Square slots for the kind glyph, the "⋯" menu, and the agent state
    /// mark. The mark's slot is the tab row's trailing slot, which
    /// `AgentStateMark` draws itself into; a test pins the two together.
    static let glyphSlot: CGFloat = 16
    static let menuSlot: CGFloat = 18
    static let markSlot: CGFloat = 16

    /// Room the rename field needs to be usable in place: about a dozen
    /// characters of the name.
    static let inlineRenameFieldMinimumWidth: CGFloat = 100

    /// Width of the header's narrowest form, the kind glyph and the menu,
    /// which it keeps at every width. The spacer between them sits between
    /// two gaps of its own because `HStack` spacing applies around a
    /// `Spacer` like any other child.
    static let minimumWidth: CGFloat = horizontalPadding * 2
        + glyphSlot
        + itemSpacing // glyph to spacer
        + itemSpacing // spacer's minimum length
        + itemSpacing // spacer to menu
        + menuSlot

    /// Header width at which the name is edited in place: the narrowest
    /// form, the field with its gap, and the state mark with its gap, which
    /// an agent pane keeps while renaming. Narrower headers open the
    /// floating rename panel instead.
    static let inlineRenameMinimumWidth: CGFloat = minimumWidth
        + itemSpacing // glyph to field
        + inlineRenameFieldMinimumWidth
        + itemSpacing // state mark's gap
        + markSlot
}
