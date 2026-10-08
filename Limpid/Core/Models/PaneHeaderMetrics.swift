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

    /// Width of the narrowest form of a zoomed pane's header: it keeps the
    /// unzoom button, in a slot the size of the menu's, beside the menu.
    /// Only a zoomed pane has the button, and a zoomed pane is as wide as
    /// the window's terminal area, so the split floor stays `minimumWidth`.
    static let zoomedMinimumWidth: CGFloat = minimumWidth
        + itemSpacing // unzoom button's gap
        + menuSlot // the unzoom button

    /// Width of the form that keeps the prompt cache clock after the name and
    /// the state mark have gone: the narrowest form and the clock with its
    /// gap. The split floor stays `minimumWidth`; a pane narrower than this
    /// drops the clock rather than growing for it.
    static let clockFormWidth: CGFloat = minimumWidth
        + itemSpacing // clock's gap
        + markSlot // the clock, in the state mark's slot size

    /// Header width at which the name is edited in place: the narrowest
    /// form, the field with its gap, and the state mark with its gap, which
    /// an agent pane keeps while renaming. Narrower headers open the
    /// floating rename panel instead.
    static let inlineRenameMinimumWidth: CGFloat = minimumWidth
        + itemSpacing // glyph to field
        + inlineRenameFieldMinimumWidth
        + itemSpacing // state mark's gap
        + markSlot

    /// The same, counting the prompt cache clock while the header draws one
    /// and the unzoom button while the pane is zoomed: each sits in the row
    /// beside the field, in a slot of its own, and would otherwise take its
    /// width out of the field. The split floor reads `minimumWidth`, not
    /// this, so neither changes how narrow a pane may get.
    static func inlineRenameMinimumWidth(showsPromptCacheClock: Bool, isZoomed: Bool) -> CGFloat {
        inlineRenameMinimumWidth
            + (showsPromptCacheClock ? itemSpacing + markSlot : 0)
            + (isZoomed ? itemSpacing + menuSlot : 0)
    }
}
