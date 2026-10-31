// PaneHeaderMetrics.swift
// Weir — the pane header's sizes that rules outside the view
// depend on.

import CoreGraphics

/// The header's geometry as far as Core needs it. The split floor counts the
/// header's height and narrowest width, and the rename rule asks whether a
/// header is wide enough to edit its name in place, so these numbers cannot
/// live only in `WeirLayout`, which Core does not read.
/// `WeirLayout` takes its header values from here; the rest of the
/// header's look (fonts, the rename panel) stays there.
enum PaneHeaderMetrics {
    /// The height of the decision bar under the pane (`decisionBarHeight`), so
    /// the two lines around a terminal read as a pair. The terminal gives up
    /// exactly this much, since the header sits above it rather than over it.
    static let height: CGFloat = 32

    /// Leading and trailing inset of the header's content, smaller than the
    /// tab row's inset, as a pane may be narrow and its marks sit closer.
    static let horizontalPadding: CGFloat = 6

    /// Gap between the header's items, and the least the spacer before its
    /// trailing items may shrink to.
    static let itemSpacing: CGFloat = 4

    /// Slots for the kind's mark, the "⋯" menu, and the agent state mark. The
    /// kind's mark is an agent's badge or a shell's prompt, as wide as
    /// `agentBadgeWidth`; the state mark's slot is the tab row's trailing
    /// slot, which `AgentStateMark` draws itself into. Tests pin both.
    static let kindMarkSlot: CGFloat = 18
    static let menuSlot: CGFloat = 18
    static let markSlot: CGFloat = 16

    /// Square slot for the symbol of the warning that the agent runs without
    /// asking, the size of the state mark's beside it.
    static let warningSlot: CGFloat = markSlot

    /// Room the rename field needs to be usable in place: about a dozen
    /// characters of the name.
    static let inlineRenameFieldMinimumWidth: CGFloat = 100

    /// Width of the header's narrowest form, the kind's mark and the menu,
    /// which it keeps at every width. The spacer between them sits between
    /// two gaps of its own because `HStack` spacing applies around a
    /// `Spacer` like any other child.
    static let minimumWidth: CGFloat = horizontalPadding * 2
        + kindMarkSlot
        + itemSpacing // kind's mark to spacer
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
        + itemSpacing // kind's mark to field
        + inlineRenameFieldMinimumWidth
        + itemSpacing // state mark's gap
        + markSlot

    /// The same, counting the prompt cache clock while the header draws one,
    /// the warning's symbol while the agent runs without asking, and the
    /// unzoom button while the pane is zoomed: each sits in the row beside
    /// the field, in a slot of its own, and would otherwise take its width
    /// out of the field. The split floor reads `minimumWidth`, not this, so
    /// none changes how narrow a pane may get.
    static func inlineRenameMinimumWidth(showsPromptCacheClock: Bool, showsWarning: Bool, isZoomed: Bool) -> CGFloat {
        inlineRenameMinimumWidth
            + (showsPromptCacheClock ? itemSpacing + markSlot : 0)
            + (showsWarning ? itemSpacing + warningSlot : 0)
            + (isZoomed ? itemSpacing + menuSlot : 0)
    }
}
