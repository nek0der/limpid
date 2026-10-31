// WeirLayout+Sheets.swift
// Weir — the measures of the supervision window's sheets, palette, history, and menu bar item.

import SwiftUI

/// The sheets and popovers of `WeirLayout.Supervision`, kept apart so the
/// main file stays one screen of surfaces and bars.
extension WeirLayout.Supervision {

    // MARK: Sheets

    /// The width of the sheets the supervision window presents as a
    /// dialog (project settings), and of the keyboard shortcuts panel over
    /// the window: 520pt inside the insets.
    static let sheetWidth: CGFloat = 560
    /// The new worktree sheet's width, wider than the other sheets': its
    /// form puts a column of labels beside a segmented choice whose
    /// segments share the controls' column equally, so its widest words, in
    /// English or Japanese, beside the widest label ("Open After
    /// Creating"), set what the sheet needs. Measured against those words
    /// by `NewSessionSheetLayoutTests`.
    static let newSessionSheetWidth: CGFloat = 640
    /// A failed setup step's log in the worktree's launch bar, scrolled
    /// within this height once it is longer (`SessionLaunchBar`).
    static let launchLogMaxHeight: CGFloat = 140
    /// The empty window's column of projects and its open button
    /// (`EmptyWindowView`).
    static let emptyWindowColumnWidth: CGFloat = 360
    /// The approval card's tool input: its well's inset around the lines
    /// (top and bottom together), and the most it grows before it scrolls.
    static let approvalDetailsVerticalInsets: CGFloat = 12
    static let approvalDetailsMaxHeight: CGFloat = 180
    /// The project settings sheet's height, before the window's: its form
    /// scrolls inside, so the sheet is the preferred height while the
    /// window has room and shrinks with it down to the least, where the
    /// title, a section, and Done still show
    /// (`ContainerSettingsSheet.height(forWindowHeight:)`).
    static let projectSettingsSheetPreferredHeight: CGFloat = 600
    static let projectSettingsSheetMinHeight: CGFloat = 360
    /// What a sheet sized from its window leaves of the window's height,
    /// above and below it together.
    static let sheetWindowMargin: CGFloat = 48

    // MARK: New session sheet

    /// Every sheet's inset from its edges, and between its blocks.
    static let sheetInsets = EdgeInsets(top: spaceXL, leading: spaceXL, bottom: spaceXL, trailing: spaceXL)
    static let sheetSpacing = spaceL
    static let newSessionSheetInsets = sheetInsets
    static let newSessionSheetSpacing = sheetSpacing
    /// Between the labels' column and the controls' column.
    static let newSessionColumnSpacing = spaceM
    /// Between two rows of the form.
    static let newSessionRowSpacing = spaceM
    /// Inside a row: a control and the muted line under it, a menu and the
    /// path beside it.
    static let newSessionInlineSpacing = spaceXS + spaceHairline

    /// A sheet's text field and menu face on one line: a little taller than
    /// the regular-size pop-up, as a field that takes typing is.
    static let sheetFieldHeight: CGFloat = 28
    static let sheetFieldInsets = EdgeInsets(
        top: spaceXS + spaceHairline,
        leading: spaceS,
        bottom: spaceXS + spaceHairline,
        trailing: spaceS
    )
    static let sheetFieldCornerRadius: CGFloat = 7
    /// What the sheet's fields fade to while git makes the worktree, and
    /// the agent menu's face for an agent that is not found.
    static let sheetFieldDisabledOpacity: Double = 0.55

    static let sheetTitleFontSize = WeirFont.Supervision.Size.title
    static let sheetLabelFontSize = WeirFont.Supervision.Size.row

    // MARK: Segmented picker

    /// `SupervisionSegmentedPicker`: a little shorter than the sheet's
    /// 28pt field and close to a regular button, so it sits beside both
    /// as a sibling rather than the large native control it replaces.
    static let segmentedHeight: CGFloat = 26
    /// The track around the pill.
    static let segmentedInset = spaceHairline
    static let segmentedHorizontalPadding = spaceM
    static let segmentedFontSize = WeirFont.Supervision.Size.body
    static let segmentedCornerRadius: CGFloat = 7
    /// The track's corner less its inset, so the pill's curve runs
    /// parallel to the track's.
    static let segmentedPillCornerRadius = segmentedCornerRadius - segmentedInset
    /// A segment's dot after its words (Unread while anything is unread):
    /// a list's bullet, a step apart from the words.
    static let segmentedDotSize = WeirFont.Supervision.Size.bullet.rawValue
    static let segmentedDotSpacing = spaceXS

    // MARK: Command palette

    /// The title bar's field, which the dropdown hangs under: as wide as
    /// the range allows while the bar's sides keep their ideal widths, and
    /// the first to give way when they do not
    /// (`SupervisionWindowWidths.titleBar`). At the floor the placeholder
    /// is cut and the field's key still shows.
    static let paletteFieldWidthRange: ClosedRange<CGFloat> = 150...340
    static let paletteFieldCornerRadius: CGFloat = 7
    static let paletteFieldSymbolSize = WeirFont.Supervision.Size.label
    /// Wider than the field it hangs under, so a row's name, detail,
    /// and keys share one line.
    static let paletteDropdownWidth: CGFloat = 560
    /// Between the field's lower edge and the dropdown hung under it.
    static let paletteDropdownGap = spaceSnug
    static let paletteDropdownMaxHeight: CGFloat = 440
    static let paletteDropdownPadding = popoverInset
    static let paletteRowInsets = popoverRowInsets
    /// The heading, the rows, and the prefixes' foot all start 16pt in:
    /// the surface's 8pt padding and their own 8pt.
    static func paletteHeadingInsets(isFirst: Bool) -> EdgeInsets {
        headingInsets(isFirst: isFirst)
    }

    static let paletteFootInsets = EdgeInsets(top: spaceS, leading: spaceS, bottom: spaceXS, trailing: spaceS)
    static let paletteFootSpacing = spaceL

    // MARK: Keycaps

    /// A key combination in one cap: 1pt edges, 2pt along the bottom.
    static let keycapCornerRadius: CGFloat = 4
    static let keycapHorizontalPadding = spaceSnug
    static let keycapHeight: CGFloat = 17

    // MARK: Panel search field

    /// The search field of a panel over the window (`PanelSearchField`):
    /// as tall as a sheet's field, between the 23pt All Projects' filter
    /// had and the 31pt the shortcuts search had, so a field that takes
    /// typing looks the same in a sheet and in either panel.
    static let panelSearchFieldHeight = sheetFieldHeight
    static let panelSearchFieldHorizontalInset = spaceS
    static let panelSearchFieldCornerRadius = sheetFieldCornerRadius

    /// Returns how far the field's text and placeholder are lowered in
    /// `locale`'s script. The field centers the font's line, and Japanese
    /// glyphs, which have no descenders, stand in its upper part: we measured
    /// them 1.25pt above the field's middle. Latin's capitals sit in the
    /// middle as they are.
    static func panelSearchTextDrop(for locale: Locale) -> CGFloat {
        locale.language.languageCode == .japanese ? 1 : 0
    }

    /// This is the height of the review rail's file filter
    /// (`SearchFieldFace.rail`), shorter than a panel's field for its
    /// caption-sized words over the file list.
    static let railSearchFieldHeight: CGFloat = 24

    // MARK: Notification history

    /// Wide enough that what a row is about and the time share the first line,
    /// and a source's heading keeps its place and its note.
    static let notificationHistoryWidth: CGFloat = 400
    static let notificationHistoryPadding = popoverInset
    static let notificationRowInsets = popoverRowInsets
    static let notificationRowCornerRadius: CGFloat = 8
    /// Between a source's heading and the edge of its group.
    static let notificationHeadingGroupGap = spaceXS
    /// Between a source's group edge and the fills of the rows inside it,
    /// so a hovered or selected row never covers the edge.
    static let notificationGroupInset = spaceHairline
    static let notificationGroupCornerRadius = notificationRowCornerRadius + notificationGroupInset
    /// Where the rule between a group's rows starts: at the words' column,
    /// as the rows' glyphs need no rule between them.
    static let notificationGroupRuleLeading = notificationGroupInset + notificationRowInsets.leading
        + notificationGlyphColumnWidth + notificationColumnSpacing
    /// Between what a row is about and what came of it.
    static let notificationLineSpacing = spaceHairline
    /// The first line's height, which the glyph centers on.
    static let notificationSourceLineHeight: CGFloat = 16
    /// A source's heading, over its rows.
    static let notificationSourceHeadingHeight: CGFloat = 22
    /// A source's fold ("4 more"): the whole line, as tall as a one-line
    /// row, takes the click.
    static let notificationFoldHeight: CGFloat = 26
    /// Above every source's heading but a day's first.
    static let notificationSourceSpacing = spaceSnug
    /// The glyph's column, wide enough for the shell's prompt badge.
    static let notificationGlyphColumnWidth: CGFloat = 18
    static let notificationColumnSpacing = popoverRowColumnSpacing
    static func notificationDayInsets(isFirst: Bool) -> EdgeInsets {
        headingInsets(isFirst: isFirst)
    }

    static let notificationUnreadDotSize: CGFloat = 7
    /// The heading's line, as tall as its ⋯.
    static let notificationHeadingHeight: CGFloat = 24
    /// Inside the panel's own padding: the heading, its words in line with
    /// the rows' and ⋯ a step in from the edge; the filters, their edge in
    /// line with the rows' fills, so the words in both line up.
    static let notificationHeadingInsets = EdgeInsets(
        top: spaceXS,
        leading: popoverWordsInset - popoverInset,
        bottom: spaceM,
        trailing: popoverControlInset - popoverInset
    )
    static let notificationFilterRowInsets = EdgeInsets(top: 0, leading: 0, bottom: spaceXS, trailing: 0)
    /// Inside the notice's fill.
    static let notificationNoticeInsets = EdgeInsets(top: spaceS, leading: spaceS, bottom: spaceS, trailing: spaceS)

    // MARK: Menu bar item

    /// The most the rows take before they scroll; the window is as tall as
    /// what it shows below that, the heading and one line when empty.
    static let menuBarListMaxHeight: CGFloat = 480
    /// The menu's rhythm is the system menu's, measured on macOS 26:
    /// a row's fill turns its corner concentric with the window's, its
    /// radius the window's less the list's inset (the system menu's 12pt
    /// window and 5pt inset give its rows 7pt), and its words stand 14pt
    /// in. Our window is the one MenuBarExtra draws, 16pt, so the list
    /// stands 6pt in on every side, the bottom included, and a row's
    /// corner is 10pt. The rows touch, as a menu's do.
    static let menuBarWindowCornerRadius: CGFloat = 16
    static let menuBarListInset: CGFloat = 6
    static let menuBarRowCornerRadius = menuBarWindowCornerRadius - menuBarListInset
    static let menuBarRowInsets = EdgeInsets(top: spaceXS + 1, leading: spaceS, bottom: spaceXS + 1, trailing: spaceS)
    static let menuBarRowSpacing: CGFloat = 0
    /// Where the menu's words start outside a row (the heading, the empty
    /// line, a notice): in line with the rows' words.
    static let menuBarWordsInset = menuBarListInset + menuBarRowInsets.leading
    /// What a row lays under it (the command, a note, its buttons): in line
    /// with the row's words, past its state glyph, and a step above the
    /// next row.
    static let menuBarInPlaceInsets = EdgeInsets(
        top: 0,
        leading: menuBarRowInsets.leading + stateGlyphSize + popoverRowColumnSpacing,
        bottom: spaceS,
        trailing: menuBarRowInsets.trailing
    )
    /// The image the menu bar is handed: as high as its 18pt item, and
    /// wider than high for the badge at the mark's corner.
    static let menuBarLampImageSize = CGSize(width: 22, height: 18)
    static let menuBarCommandInsets = EdgeInsets(top: spaceXS, leading: spaceS, bottom: spaceXS, trailing: spaceS)
    static let menuBarCommandCornerRadius = smallControlCornerRadius
}
