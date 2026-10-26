// LimpidLayout.swift
// Limpid — layout constants gathered in one place so the various
// hard-coded sizes scattered across views become discoverable and
// movable in lockstep. Sits alongside `LimpidColor / LimpidFont /
// LimpidMotion` to round out the design-token set.

import CoreGraphics
import Foundation

enum LimpidLayout {

    // MARK: - Traffic lights

    /// Leading x of the close button. AppKit's own default is 9, which
    /// reads tight against a flush sidebar: the sidebar's rows start their
    /// glyphs at `Supervision.surfaceHeadingInset`, so a button at 9 sits
    /// closer to the window edge than anything below it.
    static let trafficLightOriginX: CGFloat = 18

    /// Gap between the origins of two neighboring traffic lights, and
    /// the size AppKit draws each one at — both measured on macOS 26
    /// (buttons at x = 9 / 32 / 55, 14pt square). We move the row but
    /// keep its rhythm; the previous 20pt spacing packed the buttons
    /// tighter than the system does.
    static let trafficLightSpacing: CGFloat = 23
    static let trafficLightButtonSize: CGFloat = 14

    /// Width the traffic-light row occupies from the window's leading
    /// edge. We use it to leave room in the main area's top strip when
    /// the sidebar is hidden. Derived rather than typed in so it cannot
    /// drift away from the placement above.
    static var trafficLightWidth: CGFloat {
        trafficLightOriginX + 2 * trafficLightSpacing + trafficLightButtonSize
    }

    /// Height of the Settings window's top strip, which its traffic lights
    /// center on, so its list opens where the main window's would. The main
    /// window's title bar has its own (`Supervision.titleBarHeight`).
    static let topStripHeight: CGFloat = 52

    // MARK: - Main window

    /// Smallest main-window content height we support. The width's
    /// floor is derived from the supervision layout
    /// (`Supervision.windowMinWidth`).
    static let mainWindowMinHeight: CGFloat = 400

    /// Height of the content box a grouped `Form` row has on macOS 26. A
    /// 24pt pop-up overhangs it by 3pt on each side and stays centered.
    /// Custom rows
    /// (`View.settingsControlRow(controlHeight:)`) reproduce that with a
    /// negative vertical padding. `LabeledContent` cannot be used for
    /// them because it sizes the row from its label and bottom-aligns
    /// taller content.
    static let settingsRowContentHeight: CGFloat = 18
    /// Width of the shortcut recorder pill in Settings, shared by every
    /// recorder row so the pills line up.
    static let settingsRecorderWidth: CGFloat = 170
    /// Height of the shortcut recorder pill in Settings: body text plus
    /// 2pt each side.
    static let settingsRecorderPillHeight: CGFloat = 20
    /// The recorder pill's inset from its text, and its corners.
    static let settingsRecorderPillHorizontalPadding: CGFloat = 8
    static let settingsRecorderPillCornerRadius: CGFloat = 5
    /// Slot for a row's accessory (the recorder pill's menu and reset, a
    /// value row's ↺), placed before the control so the control's trailing
    /// edge lines up with the form's other controls.
    static let settingsRecorderAccessoryWidth: CGFloat = 18
    /// Slider rows: a fixed slider frame and readout slot keep the track
    /// edges aligned across rows whose labels differ in width. The width
    /// leaves the longest label ("Unfocused pane opacity" in Japanese) on one
    /// line at the form's 542pt inner width with some room to spare (it
    /// wraps at 220). A slider lays out 16pt tall, which is the control
    /// height `settingsControlRow` pads up from.
    static let settingsSliderWidth: CGFloat = 180
    /// How far a row that only acts under the switch above it is indented
    /// (Background opacity under Translucent window), as System Settings
    /// indents a setting that depends on another.
    static let settingsChildRowIndent: CGFloat = 20
    static let settingsSliderValueWidth: CGFloat = 56
    static let settingsSliderControlHeight: CGFloat = 16
    /// Rows that hold only text (the version row) are shorter than
    /// control rows; this pads them up to the same height.
    static let settingsTextRowControlHeight: CGFloat = 16

    /// The narrowest the review surface may be: what the band at its foot
    /// needs in its narrowest fit (`ReviewTabBandRow.Fit.narrowest`).
    /// Measured with the bar's insets at the band's widest (no pane to
    /// insert into, 12 comments, "Mark as Viewed"), that is 374pt in
    /// English and 342pt in Japanese; the fit before it, with its tag and
    /// counts, takes up to 523pt (`SupervisionFootBarTests`). The window's
    /// minimum (`Supervision.windowMinWidth`) and the sidebar's drawn width
    /// (`SupervisionWindowWidths.sidebarDrawnWidth`) keep the session's
    /// column at least this wide. Narrower than this, the band cuts the
    /// destination's name rather than push Close out of the column.
    static let reviewMinWidth: CGFloat = 400

    /// Height of a title bar control (the palette field, its buttons).
    static let titleBarControlHeight: CGFloat = 28

    /// Corner radius of the transient hover highlight.
    static let titleBarHoverCorner: CGFloat = 7

    // MARK: - Agent marks

    /// The square an agent state mark (`AgentStateMark`, `.headerStatus`) or
    /// a prompt cache clock is drawn in, so the two stand at one size
    /// wherever they sit beside each other.
    static let stateMarkSlot: CGFloat = 16

    /// The stopped glyph on a pane's failure card (a process that exited
    /// with an error, a terminal that could not start): larger than a
    /// row's, since it heads a card of its own.
    static let paneFailureGlyphSize: CGFloat = 22

    // MARK: - Pull-request hover card

    /// Drawn size of the check-status glyph inside the hover card,
    /// picked to sit with the `.callout` text beside it. Fixed, like
    /// every size here, so it does not track the `.callout` under
    /// Dynamic Type.
    static let prCardGlyphSize: CGFloat = 14

    // MARK: - Pane surface

    /// Radius of the banner a pane shows when its process exits. The
    /// pane itself is square and flush: it is the content, and a
    /// terminal's character grid — a full-width tmux status row most
    /// visibly — should not be clipped by a corner or held off the
    /// column edge. The banner is a card floating over that content,
    /// so it still rounds.
    static let paneBannerCornerRadius: CGFloat = 10

    /// The split pane header's geometry. Core's rules count it too, so the
    /// values live in `PaneHeaderMetrics`; these names keep the views
    /// reading from one place with the rest of the layout.
    static let paneHeaderHeight = PaneHeaderMetrics.height
    static let paneHeaderHorizontalPadding = PaneHeaderMetrics.horizontalPadding
    static let paneHeaderItemSpacing = PaneHeaderMetrics.itemSpacing
    static let paneHeaderGlyphSlot = PaneHeaderMetrics.glyphSlot
    static let paneHeaderMenuSlot = PaneHeaderMetrics.menuSlot

    /// The header's type, sized to fit one line in `paneHeaderHeight`: the
    /// kind glyph, the pane's name, and the directory beside it, which is a
    /// step smaller so the name leads. The "⋯" menu glyph matches the
    /// directory.
    static let paneHeaderGlyphFontSize = LimpidFont.Supervision.Size.micro
    static let paneHeaderNameFontSize = LimpidFont.Supervision.Size.meta
    static let paneHeaderDetailFontSize = LimpidFont.Supervision.Size.caption
    static let paneHeaderMenuFontSize = LimpidFont.Supervision.Size.caption

    /// The gap between a "⋯" button and the top of the menu it opens,
    /// which is about where AppKit's own pull-down menus sit.
    static let popUpMenuGap = Supervision.spaceXS

    /// The width a header form needs for its name, or for its directory, to
    /// count as fitting. A few characters are enough to tell panes apart;
    /// past that the text truncates into whatever the row gives it, and a
    /// row that cannot spare even this drops the text instead.
    static let paneHeaderNameFittingWidth: CGFloat = 32
    static let paneHeaderDetailFittingWidth: CGFloat = 40

    /// How far the pointer moves with the button down before a press turns
    /// into a pane drag, from the header and from the terminal's ⌥⌘ drag
    /// alike. Small enough to feel immediate, large enough that a click
    /// with a slight wobble stays a click.
    static let paneDragThreshold: CGFloat = 4

    /// Panels that float below what opened them — the pane rename field,
    /// the prompt cache panel and the container color picker — share the
    /// command palette's corner radius, and keep this far from the window's
    /// edges.
    static let floatingPanelCornerRadius: CGFloat = 16
    static let floatingPanelWindowMargin = Supervision.spaceS
    /// The inset of a floating panel's content: the rename field's and the
    /// color picker's. The prompt cache panel keeps its own, a little wider
    /// for its sentences and full-width buttons.
    static let floatingPanelPadding = Supervision.spaceM

    /// The arrow some floating panels carry on the edge facing what opened
    /// them (the prompt cache panel, the color picker): a square of this
    /// side turned 45 degrees, half of it showing past the edge.
    static let floatingPanelArrowSize: CGFloat = 14
    /// How far the arrow's tip stands past the panel's edge, and how wide
    /// its base is either side of its center: half the square's diagonal.
    static let floatingPanelArrowHeight: CGFloat = floatingPanelArrowSize / 2.squareRoot()
    /// The least distance from the arrow's center to either corner, so its
    /// base stays clear of the rounding.
    static let floatingPanelArrowInset: CGFloat = floatingPanelCornerRadius + floatingPanelArrowHeight + 4
    /// Gap between an arrowed panel's edge and what it points at: room for
    /// the arrow, with a little air between its tip and the anchor.
    static let floatingPanelArrowAnchorGap: CGFloat = floatingPanelArrowHeight + 3

    /// The container color picker: sixteen swatches eight to a row, which
    /// keeps the grid two rows short beside a sidebar row and every swatch a
    /// comfortable click; a ring around the current one; under a caption on
    /// the floating panel surface. The panel's width follows from the grid,
    /// so placement can know it before the panel is measured.
    static let containerColorSwatchSize: CGFloat = 20
    static let containerColorSelectionRingSize: CGFloat = 24
    static let containerColorSwatchSlot: CGFloat = 26
    static let containerColorSwatchSpacing = Supervision.spaceSnug
    static let containerColorSwatchColumns = 8
    /// Between the caption and the grid.
    static let containerColorPanelSpacing = Supervision.spaceS
    static let containerColorGridWidth: CGFloat = .init(containerColorSwatchColumns) * containerColorSwatchSlot
        + CGFloat(containerColorSwatchColumns - 1) * containerColorSwatchSpacing
    static let containerColorPanelWidth: CGFloat = containerColorGridWidth + floatingPanelPadding * 2

    /// The floating rename panel a header narrower than
    /// `PaneHeaderMetrics.inlineRenameMinimumWidth` opens instead of editing in
    /// place: wide enough for a name of a few words, on the command
    /// palette's surface, with the field drawn like a text field so it
    /// reads as one at a glance.
    static let paneRenamePanelWidth: CGFloat = 240
    static let paneRenamePanelSpacing = Supervision.spaceSnug
    static let paneRenameFieldCornerRadius = Supervision.smallControlCornerRadius
    static let paneRenameFieldVerticalPadding = Supervision.spaceXS
    /// Inside the field's box, to its first glyph on either side: the
    /// field's first glyph stands on its label's leading edge
    /// (`InlineRenameField`), so the box's inset is all there is.
    static let paneRenameFieldHorizontalPadding = Supervision.spaceHairline
    static let paneRenameFieldFontSize = LimpidFont.Supervision.Size.label
    /// Gap between the header and the panel.
    static let paneRenamePanelAnchorGap = Supervision.spaceXS
    /// The well an inline rename's field stands in (`InlineRenameField`):
    /// how far it reaches above and below the label's line, so the
    /// selection, which is the line's height, sits inside it, and how
    /// round its corners are, a field's corner at that height.
    static let inlineRenameWellVerticalOutset: CGFloat = 1
    static let inlineRenameWellCornerRadius: CGFloat = 4

    /// The prompt cache clock in a pane header, sized to sit in the same
    /// slot as the state mark beside it (`AgentStateMark.Placement.headerStatus`).
    static let promptCacheClockFontSize = LimpidFont.Supervision.Size.row

    /// The panel a prompt cache clock opens, after the design: wide enough
    /// for its longest Japanese sentence on one line, a title a step above
    /// its two sentences, and buttons at the sentences' size.
    static let promptCachePanelWidth: CGFloat = 300
    static let promptCachePanelPadding = Supervision.spaceM
    /// Between the text block and the buttons.
    static let promptCachePanelSectionSpacing = Supervision.spaceM
    /// Between the title row and the two sentences.
    static let promptCachePanelTitleSpacing = Supervision.spaceS
    static let promptCachePanelTitleGlyphSpacing = Supervision.spaceSnug
    /// The title's clock glyph is drawn in a slot this wide, so the pane
    /// line under the title can start exactly where the title's text does.
    static let promptCachePanelTitleGlyphWidth: CGFloat = 13
    static let promptCachePanelLineSpacing = Supervision.spaceHairline
    static let promptCachePanelButtonSpacing = Supervision.spaceSnug
    static let promptCachePanelTitleFontSize = LimpidFont.Supervision.Size.label
    static let promptCachePanelTextFontSize = LimpidFont.Supervision.Size.caption
    /// Between the title row and the line naming the pane.
    static let promptCachePanelPaneLineSpacing = Supervision.spaceHairline
    /// The pane line's size, a half step under the panel's sentences, as
    /// the design has it.
    static let promptCachePanelPaneLineFontSize = LimpidFont.Supervision.Size.detail
    static let promptCacheButtonCornerRadius: CGFloat = 7
    static let promptCacheButtonHorizontalPadding = Supervision.spaceM
    /// The two command buttons sit a point taller than the plain one, whose
    /// missing border would otherwise make it read as the larger. Off the
    /// scale by that point on purpose: rounded to a step, the bordered
    /// buttons would either match the plain one or lose height, and with
    /// it some of what they can be pressed on.
    static let promptCacheButtonVerticalPadding = Supervision.spaceXS + 1
    static let promptCachePlainButtonVerticalPadding = Supervision.spaceXS

    // MARK: - Sidebar

    /// Default width of an invisible resize handle.
    static let resizeHandleWidth: CGFloat = 6

    /// Width of the transparent resize handles between main-window columns.
    /// Rows remain selectable outside this band.
    static let columnResizeHandleWidth: CGFloat = 12

    /// The supervision window's measures. Kept together so the window
    /// and the tests read one set.
    enum Supervision {

        // MARK: Spacing

        /// The supervision UI's one spacing scale, seven steps: 2, 4, 6, 8,
        /// 12, 16, 20. Every popover, sheet, and panel of the window takes
        /// its insets, gaps, and paddings from these steps, directly or
        /// through the roles below (`popoverInset`, `popoverRowInsets`…),
        /// so no surface is spaced on numbers of its own. A gap that would
        /// fall between steps (a tag's 5pt, a label's 7pt, a band's 14pt)
        /// takes the step beside it. `spaceHairline` is only for the gap
        /// between two rows' fills, so they read as one list, and between
        /// a row's own lines. `spaceSnug` is the gap between the window's
        /// surfaces (`surfaceGap`), and between a label and its mark.
        static let spaceHairline: CGFloat = 2
        static let spaceXS: CGFloat = 4
        static let spaceSnug: CGFloat = 6
        static let spaceS: CGFloat = 8
        static let spaceM: CGFloat = 12
        static let spaceL: CGFloat = 16
        static let spaceXL: CGFloat = 20

        /// A popover's or menu's edge to its rows' fills: half the surface's
        /// 16pt corner, so a row's 8pt corner turns with it.
        static let popoverInset = spaceS
        /// How far a focus ring stands outside what it rings
        /// (`supervisionFocusRing`).
        static let focusRingOutset = keyboardRingWidth + 1
        /// A popover's edge to a field: the field's focus ring, which stands
        /// `focusRingOutset` outside it, sits `spaceM` in, so the ring reads
        /// as inside the surface rather than against its edge.
        static let popoverFieldInset = spaceM + focusRingOutset
        /// Between two rows of a popover's list.
        static let popoverRowSpacing = spaceHairline
        /// Between two rows of two lines or more (the Needs Attention list,
        /// the notification history, the menu bar item): a step more than a
        /// menu's rows, as each is read one by one rather than run down.
        static let popoverTwoLineRowSpacing = spaceXS
        /// Between a row's glyph and its words, and between the row's lines.
        static let popoverRowColumnSpacing = spaceS
        static let popoverRowLineSpacing = spaceHairline
        /// Where a popover's words start when they are not in a row (a
        /// heading, a note): in line with the rows' words, the popover's
        /// inset and the row's own.
        static let popoverWordsInset = popoverInset + spaceS
        /// A popover's edge to a control on its heading's line (Next
        /// Action, Clear All).
        static let popoverControlInset = spaceM
        /// The most an empty state's words take across
        /// (`SupervisionEmptyState`): short lines under its symbol, in a
        /// wide panel as in a narrow one.
        static let emptyStateMaxWidth: CGFloat = 280
        /// Where a drag would land (`SupervisionDropMark`), on a pane, a tab
        /// or a sidebar row alike: thinner than the keyboard's ring, which
        /// says where the keys go, so a target reads as a place to drop
        /// rather than a second focus. 1.5pt is three pixels on a Retina
        /// display, as the attention frame's is, so it stays crisp there.
        static let dropTargetRingWidth: CGFloat = 1.5
        /// How far a pane's mark stands in from every line around the pane:
        /// the surface's border on an outer edge, the seam on an inner one
        /// (`SurfaceFrameFit.inset(by:)`). None: the ring runs along the
        /// pane's own edges, so it outlines the pane that takes the drop.
        /// Standing 4pt in, it read as a box drawn inside the pane rather
        /// than the pane itself.
        static let dropTargetPaneInset: CGFloat = 0
        /// A sidebar row or a tab while it is dragged: faint in its place.
        static let draggedItemOpacity: Double = 0.4

        static let titleBarHeight: CGFloat = 48
        /// The tool window bars on both edges; icons are 32pt with 18pt art.
        static let railWidth: CGFloat = 40
        static let railButtonSize: CGFloat = 32
        static let railSymbolSize = LimpidFont.Supervision.Size.display
        static let sidebarDefaultWidth = SessionLayoutDefaults.supervisionSidebarWidth
        static let sidebarWidthRange: ClosedRange<CGFloat> = 220...400
        /// The narrowest main window: both margins, both rails
        /// with their gaps, the sidebar at its narrowest, and the session
        /// at the review's minimum, so every surface keeps its own floor.
        /// 730pt with today's numbers.
        static let windowMinWidth = SupervisionWindowWidths.windowMinWidth(
            surfaceGap: surfaceGap,
            railWidth: railWidth,
            sidebarMinWidth: sidebarWidthRange.lowerBound,
            sessionMinWidth: LimpidLayout.reviewMinWidth
        )

        static let changesPanelDefaultWidth: CGFloat = 360
        static let changesPanelWidthRange: ClosedRange<CGFloat> = 300...520
        /// The first line of each surface (the sidebar's "Projects", the
        /// session header, the changes panel's "Changes"), its heading and
        /// buttons centered in it. One height for the three, so their
        /// center lines run across the window on one line, 18pt under the
        /// body's top, where the rails' first icons are centered too
        /// (`railTopInset`).
        static let surfaceHeadingLineHeight: CGFloat = 36
        /// Where a surface's heading line starts and ends: in line with the
        /// glyphs of the sidebar's rows under it (the list's inset and the
        /// row's own), and the review's top edge in the session column.
        static let surfaceHeadingInset = sidebarListInset + sessionRowHorizontalInset
        /// A glyph button's room either side of its glyph, inside its hover
        /// fill (`SupervisionIconButtonStyle`).
        static let iconButtonHorizontalPadding = spaceS
        /// Where a heading line's glyph button ends (the sidebar's ＋, the
        /// changes panel's ×): its glyph, not its hover fill, stands a
        /// heading's inset in from the surface's edge, as the heading's
        /// words do at the other end.
        static let surfaceHeadingButtonTrailingInset = surfaceHeadingInset - iconButtonHorizontalPadding
        /// A surface's heading, and the session header's name, which names
        /// what the whole column shows and so reads a step larger.
        static let surfaceHeadingFontSize = LimpidFont.Supervision.Size.label
        static let sessionHeaderNameFontSize = LimpidFont.Supervision.Size.heading
        static let sessionHeaderHeight = surfaceHeadingLineHeight
        static let paneStripHeight: CGFloat = 30
        /// The review tab's label: long enough for "T7 · {prompt}",
        /// and no longer, so a long scope never takes the strip from the
        /// terminal tabs. Short of room, it is cut as theirs are
        /// (`PaneStripTabWidths`).
        static let reviewTabTitleMaxWidth: CGFloat = 260
        /// The review band's destination menu, its chevron included, where
        /// the band is short of room (`ReviewTabBandRow.Fit.compact` and
        /// narrower): room for "Claude Code 2" whole; a longer name with
        /// what runs there is cut in its middle.
        static let reviewDestinationMaxWidth: CGFloat = 120
        /// A file's header in the review tab's stacked diff, and the bar
        /// over it that sizes up the range, so the two read alike.
        static let reviewFileHeaderHeight: CGFloat = 30
        /// The review tab's top edge: its first line, the scope menu
        /// and what stands beside it with 8pt above and below; the inset at
        /// its sides; and the gaps along it.
        static let reviewTabTopRowHeight: CGFloat = 40
        static let reviewTabTopInset = surfaceHeadingInset
        static let reviewTabTopSpacing = spaceM
        /// Between "Review Scope" and its dropdown, which it names.
        static let reviewTabScopeLabelSpacing = spaceS
        /// The "T8 finished" box's corners.
        static let reviewFollowingCornerRadius: CGFloat = 8
        /// A file's mark in the stacked diff ("New", "Changed Outside
        /// Turns"): a small neutral tag.
        static let reviewFileMarkCornerRadius: CGFloat = 4
        static let reviewFileMarkHorizontalPadding = spaceSnug
        /// The row at the foot of each of the window's three columns: the
        /// scratch row in the sidebar, the decision bar or the review's band
        /// in the session, and the changes panel's primary action. One
        /// height, with the rule drawn inside it (`SupervisionFootBar`), so
        /// the three rules sit on one line across the window and the
        /// buttons in them on one center line.
        static let footBarHeight: CGFloat = 32
        /// The rule along a foot bar's top, inside its height.
        static let footBarRuleWidth: CGFloat = 1
        /// The center column's foot bar insets (the decision bar and what
        /// stands in its place), and the default. The sidebar's foot bar
        /// keeps its list's 8/8 (`SidebarFootBar`), and the changes panel's
        /// its section's 16/16 (`CommitAndPRFootBar`). A step less at the
        /// trailing end, where a button's own padding stands inside its
        /// edge, so the review's band keeps a fit at the review's least
        /// width.
        static let footBarLeadingInset = spaceM
        static let footBarTrailingInset = spaceS
        /// Always there in an agent's pane, so the terminal never changes
        /// its rows when the bar's content changes. The foot bar's height,
        /// so it lines up with the sidebar's and the changes panel's.
        static let decisionBarHeight = footBarHeight
        static let statusBarHeight: CGFloat = 26
        /// The independent surfaces (sidebar, terminal, changes panel) and
        /// the darker gap between them.
        static let surfaceCornerRadius: CGFloat = 10
        static let surfaceGap = spaceSnug
        /// The `line` edge each surface draws inside its corners.
        static let surfaceBorderWidth: CGFloat = 1
        /// The amber or red frame inside a pane whose agent waits on the
        /// person or stopped (`PaneAttentionFrame`). 2pt read heavier
        /// than the state it marks; at 1.5pt (3px on a Retina display) it
        /// still stands out from the surface's 1pt `line` edge beside it
        /// at a glance, and the state is also said in words and a glyph
        /// (the decision bar, the tab's dot, the row), not by the frame's
        /// color alone. Its own value, so the rings that share 2pt
        /// (`keyboardRingWidth`) keep theirs.
        static let paneAttentionFrameWidth: CGFloat = 1.5
        static let stateGlyphSize: CGFloat = 15
        /// The state glyph where it rides on something else, a tab's
        /// badge, and where it stands for a whole group (a folded project
        /// header). The smallest size the
        /// glyph is drawn at, so its "!" and "?" are checked at it.
        static let stateGlyphCompactSize: CGFloat = 11
        /// The commands a workspace with no tab lists in its terminal's
        /// place (`EmptySessionHints`): at most this wide, so a name stays
        /// near its keys.
        static let emptySessionHintsWidth: CGFloat = 280

        // MARK: Session header

        /// Either side of the header's line (a surface heading's), and
        /// between its glyph, its name, and its chips; the chips sit closer
        /// to one another.
        static let sessionHeaderHorizontalInset = surfaceHeadingInset
        static let sessionHeaderSpacing = spaceS
        static let sessionHeaderChipSpacing = spaceSnug

        // MARK: Pane strip

        /// Between the strip's tabs, and from its edges.
        static let paneStripSpacing = spaceHairline
        static let paneStripInset = spaceM
        /// The rule under the strip, which the selected tab opens onto the
        /// terminal below it.
        static let paneStripRuleWidth: CGFloat = 1
        /// A strip tab: a folder tab, its top corners rounded.
        static let paneStripTabCornerRadius: CGFloat = 7
        static let paneStripTabHorizontalPadding = spaceM
        /// After the tab's ×: the padding less the room the ×'s hit area
        /// keeps beside its glyph, so the glyph stands as far from the edge
        /// as the badge on the other side.
        static let paneStripTabTrailingInset = spaceS
        /// Between a tab's badge, its title, and its marks.
        static let paneStripTabSpacing = spaceSnug
        /// A title longer than this is cut, so one tab never crowds out the
        /// rest.
        static let paneStripTitleMaxWidth: CGFloat = 190
        /// The least of a title a tab keeps when the strip is short of room
        /// (`PaneStripTabWidths`): about six letters and the ellipsis, so a
        /// cut title still tells its tab from the next. Past it the strip
        /// scrolls rather than cut further.
        static let paneStripTitleMinWidth: CGFloat = 56
        /// The fade at an end of the strip past which tabs continue
        /// (`PaneStripOverflow`): wide enough to read as a tab going on
        /// under the edge, narrow enough to leave the cut tab's title.
        static let paneStripEdgeFadeWidth: CGFloat = 24
        static let paneStripAddButtonWidth: CGFloat = 28
        /// A tab's marks: the dot for output since it was last shown, and
        /// the boxed words (tmux, exit 1).
        static let tabUnreadDotSize: CGFloat = 7
        /// A tab's state, laid on its badge's bottom trailing corner:
        /// the state glyph at this size, set off from the badge by a ring
        /// cut out of it, and standing this far past the badge's corner.
        static let tabStateMarkSize: CGFloat = stateGlyphCompactSize
        static let tabStateMarkRing: CGFloat = 2
        static let tabStateMarkOutset: CGFloat = 3
        /// How far above the title's baseline an item of the "+" menu
        /// centers its badge: about half the cap height of its 12.5pt
        /// title, so the badge centers on the title's line rather than on
        /// the item, whose caption would pull it down.
        static let addTabMenuBadgeRaise: CGFloat = 4
        static let tabMarkCornerRadius: CGFloat = 4
        static let tmuxMarkHeight: CGFloat = 14
        static let tmuxMarkHorizontalPadding = spaceXS

        // MARK: Decision bar

        static let decisionBarSpacing = spaceS
        static let decisionBarButtonSpacing = spaceXS
        /// The tag before the bar's words, and the count after it.
        static let decisionBarTagHeight: CGFloat = 18
        static let decisionBarTagHorizontalPadding = spaceS
        static let decisionBarCountHorizontalPadding = spaceSnug
        /// The ⋯'s square: as wide as a borderless menu button around its
        /// glyph, the press area the SwiftUI menu it replaced had.
        static let decisionBarMoreWidth: CGFloat = 22
        /// The least the sentence keeps beside where to answer, so it is
        /// never cut to its ellipsis alone; below it, where to answer takes
        /// its short form. In a pane too narrow even for that, it shrinks to
        /// half the words' width (`DecisionBarWordsLayout`).
        static let decisionBarTextMinWidth: CGFloat = 80

        // MARK: Approval card

        static let approvalCardSpacing = spaceS
        static let approvalCommandCornerRadius: CGFloat = 7
        /// The command's box scrolls past this, so a long one never pushes
        /// the buttons off the card.
        static let approvalCommandMaxHeight: CGFloat = 160

        // MARK: Toast

        /// The toast's inverted box, and how far above the decision bar it
        /// floats.
        static let toastCornerRadius: CGFloat = 9
        static let toastSpacing = spaceS
        static let toastGap = spaceSnug

        // MARK: Title bar

        /// Leading x of the title bar's first control: past the traffic
        /// lights with 14pt of air, wider than the gap between the bar's own
        /// controls so the lights stand apart from them, or in their place
        /// while full screen takes them away.
        static func titleBarLeadingInset(areTrafficLightsHidden: Bool) -> CGFloat {
            areTrafficLightsHidden ? LimpidLayout.trafficLightOriginX : LimpidLayout.trafficLightWidth + 14
        }

        /// Between the title bar's controls, and from the last one to the
        /// window's trailing edge (the window's 6pt and the bar's own 6pt).
        static let titleBarSpacing = spaceSnug
        static let titleBarTrailingInset = spaceM
        /// Between a dropdown control's mark, its text, and its chevron.
        static let titleBarLabelSpacing = spaceSnug
        /// Back and forward before the palette field: glyph buttons
        /// (`SupervisionIconButtonStyle`) as tall as the field and as wide,
        /// so each is a square the pointer finds as easily as the field.
        static let titleBarHistoryButtonSize = LimpidLayout.titleBarControlHeight
        /// Between back and forward, closer than the bar's parts are, so
        /// the two read as one pair, as a browser's do.
        static let titleBarHistoryButtonSpacing = spaceHairline
        static let projectAvatarSize: CGFloat = 20
        static let projectAvatarCornerRadius: CGFloat = 5
        /// The dot beside the project's name for another project's items.
        static let otherProjectsDotSize: CGFloat = 7
        static let worktreeSymbolSize = LimpidFont.Supervision.Size.icon
        /// The Needs Attention control: a bordered button whose count sits
        /// in a badge at least this wide and tall.
        static let attentionButtonCornerRadius: CGFloat = 7
        static let attentionCountMinSize: CGFloat = 20
        static let needsAttentionListWidth: CGFloat = 380
        /// The list's heading: its line, as tall as its Next Action button,
        /// with this above and below it.
        static let needsAttentionHeadingTopInset = spaceM
        static let needsAttentionHeadingBottomInset = spaceXS
        /// The supervision button styles' corners (primary, secondary,
        /// destructive), which a focus ring around one of them follows.
        static let buttonCornerRadius: CGFloat = 6
        /// The primary button's height, and the regular secondary one's
        /// beside it, so a bar that holds both lines them up.
        static let buttonHeight: CGFloat = 22
        /// `SupervisionSecondaryButtonStyle`'s heights.
        static let secondaryButtonHeight = buttonHeight
        static let secondaryButtonCompactHeight: CGFloat = 20
        static let secondaryButtonMiniHeight: CGFloat = 18
        static let needsAttentionRowCornerRadius: CGFloat = 8
        static let needsAttentionRowSpacing = popoverTwoLineRowSpacing

        // MARK: Sidebar

        static let sidebarHeadingButtonHeight: CGFloat = 22
        /// The list's inset from the surface's sides and bottom, and a row's
        /// own inset inside its fill.
        static let sidebarListInset = spaceS
        static let sessionRowHorizontalInset = spaceS
        static let sessionRowHeight: CGFloat = 44
        /// The line a sidebar section folds into ("Other Worktrees 52"):
        /// one line of meta text, lower than a two-line row, so the folded
        /// lists read as below the rows rather than among them.
        static let sidebarFoldRowHeight: CGFloat = 26
        /// A project's header (`[mark] name ─── count ▽`): one line, taller
        /// than a fold line, so each project reads as starting there.
        static let sidebarProjectHeaderHeight: CGFloat = 28
        /// Above each header but the first: the clear space that, with the
        /// header's rule, marks where one project ends and the next begins.
        static let sidebarProjectGap = spaceSnug
        /// The header's project mark, a step under the title bar's.
        static let sidebarProjectAvatarSize: CGFloat = 17
        /// What waits inside a folded header, drawn at the glyph's smallest.
        static let sidebarHeaderMarkSize = stateGlyphCompactSize
        /// The line a dragged header would land on.
        static let sidebarDropLineHeight: CGFloat = 2
        static let sessionRowSpacing = spaceHairline
        static let sessionRowCornerRadius: CGFloat = 7
        /// Between the glyph, the text, and the fixed column; and between
        /// a row's two lines.
        static let sessionRowColumnSpacing = spaceS
        static let sessionRowLineSpacing = spaceHairline
        /// The column the time and the agent badge share, so every row cuts
        /// its name and its fact at the same place.
        static let sessionRowTrailingColumnWidth: CGFloat = 32
        /// The scratch row's fill, centered in the sidebar's foot bar with
        /// 3pt above and below it.
        static let scratchRowHeight: CGFloat = 26
        /// A row the arrow keys are on.
        static let keyboardRingWidth: CGFloat = 2
        /// An agent's badge: two letters on its color, or the shell's
        /// outline. 16pt tall on a row, 18pt on its own (the scratch row and
        /// a card).
        static let agentBadgeWidth: CGFloat = 18
        static let agentBadgeHeight: CGFloat = 16
        static let agentBadgeLargeHeight: CGFloat = 18
        static let agentBadgeCornerRadius: CGFloat = 5
        /// The edge inside an agent's badge (`SupervisionTokens.claudeEdge`,
        /// `codexEdge`): drawn on the side where a brand fill stands under
        /// 3:1 off the surfaces it sits on.
        static let agentBadgeEdgeWidth: CGFloat = 1
        /// A failing check's ✕ and a running check's dot on a pull
        /// request's mark: their disc, the ring of the surface around it,
        /// and how far a corner badge hangs out.
        static let checksBadgeSize: CGFloat = 9
        static let checksBadgeRingWidth: CGFloat = 1.5
        static let checksBadgeOffset: CGFloat = 3
        /// Passing checks' green check: a box a little larger than the
        /// discs, since a line with no disc reads smaller, and a line
        /// thin enough that it stays lighter than either disc.
        static let checksPassedSize: CGFloat = 10
        static let checksPassedLineWidth: CGFloat = 1.6

        // MARK: Chips

        /// A bordered word or count: a project's counts, a card's Git facts.
        static let chipHorizontalPadding = spaceSnug
        static let chipHeight: CGFloat = 18
        static let chipCornerRadius: CGFloat = 5

        // MARK: Title bar dropdowns

        /// The project ▾ and the worktree ▾, one width: they open side by
        /// side from one title bar, and the worktree's paths need the room.
        static let titleBarDropdownWidth: CGFloat = 440
        /// Below its control, the dropdown nearly touches it.
        static let titleBarDropdownGap = spaceHairline
        /// The pane strip's "+" menu keeps its own air below the tab strip.
        static let addTabMenuGap = spaceSnug
        static let addTabMenuItemCornerRadius = smallControlCornerRadius
        /// Open Tabs: wide enough for a tab's title and its line beside the
        /// badge, and narrower than the title bar's dropdowns, which hold
        /// paths.
        static let openTabsListWidth: CGFloat = 360
        /// The Open Tabs button's square, inside the strip's height with
        /// room above and below, as Chrome's tab search button sits.
        static let openTabsButtonSize: CGFloat = 24
        /// The corners of the window's small bordered parts: a menu's
        /// trigger, a segment row, a command's well, a field drawn in a
        /// panel, a row of a short list.
        static let smallControlCornerRadius: CGFloat = 6
        static let dropdownPadding = popoverInset
        static let dropdownRowCornerRadius: CGFloat = 8
        static let dropdownRowSpacing = spaceS
        /// The column a check mark takes, on every row, so the names line up.
        static let dropdownCheckColumnWidth: CGFloat = 14
        static let dropdownIconColumnWidth: CGFloat = 16
        /// A two-line row's first line, which its check, icon, and glyph
        /// center on.
        static let dropdownRowLineHeight: CGFloat = 17
        static let dropdownFootItemCornerRadius: CGFloat = 7
        static let dropdownSearchCornerRadius: CGFloat = 8
        static let dropdownProjectAvatarSize: CGFloat = 22
        static let dropdownProjectAvatarCornerRadius: CGFloat = 6

        // MARK: All projects

        static let allProjectsMaxWidth: CGFloat = 1080
        /// The corner of a panel over the whole window (All Projects, the
        /// keyboard shortcuts panel; `overlayPanelSurface`): the popovers'
        /// and the palette's, as for every surface that floats over the
        /// window.
        static let overlayPanelCornerRadius = LimpidLayout.floatingPanelCornerRadius
        static let allProjectsSpacing = spaceM
        /// Above a section's heading after the cards of the one before.
        static let allProjectsSectionGap = spaceL
        static let allProjectsFilterWidth: CGFloat = 260
        static let allProjectsFilterMinWidth: CGFloat = 140
        /// The least height of the room All Projects' empty state centers
        /// its words in: the words and an even margin around them, so they
        /// neither sit tight under the header nor float in a tall sheet.
        static let allProjectsEmptyMinHeight: CGFloat = 180
        static let allProjectsCardCornerRadius: CGFloat = 10
        static let allProjectsCardSpacing = spaceS
        /// The narrowest a card is drawn: below it, a row holds a card
        /// fewer (`AllProjectsSelection.columns`), so the title and the
        /// chips keep their room.
        static let allProjectsCardMinWidth: CGFloat = 260
        static let allProjectsPlaceDotSize: CGFloat = 8
        static let allProjectsTailCornerRadius: CGFloat = 6

        // MARK: Rails

        static let railButtonCornerRadius: CGFloat = 8
        /// The rails run the body's height, as the surfaces beside them do.
        /// Their first icon is centered on the surfaces' heading line, and
        /// their last on the foot bars', so each end of a rail lines up
        /// with what stands across the window from it.
        static let railTopInset = (surfaceHeadingLineHeight - railButtonSize) / 2
        static let railBottomInset = (footBarHeight - railButtonSize) / 2
        /// Between a rail's icons, and the least room between its top group
        /// and its bottom one.
        static let railButtonSpacing = spaceXS
        static let railGroupMinimumGap = spaceL
        /// A count on a rail icon, ringed in the window's ground so it
        /// stands off the icon under it.
        static let railBadgeSize: CGFloat = 15
        static let railBadgeRingWidth: CGFloat = 2

        // MARK: Status band

        /// From the window's edges: the window's own margin, as wide as
        /// the gap between its surfaces, then a snug step of the band's
        /// own, so the band's words start just inside where the surfaces
        /// above it begin. Two snug steps make 12, a step of the scale,
        /// where a snug step and a small one (6 + 8) would make an
        /// off-scale 14.
        static let statusBandInset = surfaceGap + spaceSnug
        /// Between the facts on the band's right: one step, as wide as the
        /// inset, so the facts read as apart as the band is from the edge.
        static let statusBandSpacing = spaceM

        // MARK: Changes panel

        /// The rule between the turns and Commit & PR. The one over the
        /// panel's primary action is the foot bar's own
        /// (`footBarRuleWidth`); the head has none, as no surface's heading
        /// line does.
        static let changesPanelRuleWidth: CGFloat = 1
        /// Between the head's lines: the title, the conversation filter,
        /// the totals.
        static let changesHeadSpacing = spaceXS
        /// Between the totals' lines, one fact to a line, as a turn's two
        /// lines sit.
        static let changesTotalsLineSpacing = spaceHairline
        /// Around the turns, and between their cards.
        static let changesListInset = spaceM
        static let turnCardSpacing = spaceS
        static let turnCardCornerRadius: CGFloat = 9
        /// The column "T7" takes, so every prompt starts at the same x: wide
        /// enough for "T1000" in the number's face (`turnNumberFont`), so a
        /// long conversation's numbers still line up. And the gap after it.
        static let turnNumberColumnWidth: CGFloat = 34
        /// The same column in a worktree of several conversations, where
        /// the conversation's badge and number ("Cl #12") stand under the
        /// turn's number: the 18pt badge, a hairline, and three caption
        /// figures.
        static let turnLabelColumnWidth: CGFloat = 44
        /// A row's first column: the badge's where the row carries its
        /// conversation, else the number's. The one source of where the
        /// prompt starts, which the moves under it start at too
        /// (`turnActionInsets(hasConversation:)`).
        static func turnFirstColumnWidth(hasConversation: Bool) -> CGFloat {
            hasConversation ? turnLabelColumnWidth : turnNumberColumnWidth
        }

        static let turnColumnSpacing = spaceS
        static let turnLineSpacing = spaceHairline
        /// Between the moves under a turn ("Mark as Viewed up to Here",
        /// the restore), and between their lines when they wrap.
        static let turnActionSpacing = spaceM
        static let turnActionLineSpacing = spaceXS
        /// The blue rule on an unviewed turn's leading edge, and the
        /// ring on the turns the review tab shows.
        static let turnUnviewedRuleWidth: CGFloat = 3
        static let turnOpenRingWidth: CGFloat = 1.5
        /// A turn a restore took back has a dashed edge: the card steps back
        /// while its words keep text's contrast.
        static let restoredTurnBorderDash: [CGFloat] = [3, 3]
        /// The changes panel's conversation filter and the review's scope
        /// menu, whose labels carry an 18pt badge.
        static let menuTriggerHeight: CGFloat = 24
        static let menuTriggerHorizontalPadding = spaceS
        static let menuTriggerCornerRadius = smallControlCornerRadius
        /// Around the viewed line, inside the turns' inset.
        static let viewedLineInset = spaceHairline
        /// Between the parts of the line's row (rule, words, rule, Unmark
        /// as Viewed), and the least each rule keeps, so the line still
        /// reads as a line at the panel's narrowest.
        static let viewedLineWordSpacing = spaceS
        static let viewedLineRuleMinWidth: CGFloat = 8
        /// The restore record's box at the top of the panel.
        static let restoreRecordCornerRadius: CGFloat = 8
        static let restoreRecordSpacing = spaceXS
        /// Commit & PR's heading is spaced out a little, as small capitals
        /// are, so it reads as a heading at 11pt.
        static let commitSectionSpacing = spaceS
        static let commitHeadingTracking: CGFloat = 0.66
    }
}
