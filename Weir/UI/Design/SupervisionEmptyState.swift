// SupervisionEmptyState.swift
// Weir — what a list, a panel, or a popover shows while it has nothing to show: a symbol, a message, and a description.

import SwiftUI

/// Every empty state, in one layout: the surface keeps its own
/// heading, and under it, centered, a symbol, the message, and the
/// description when there is one; then the surface's own action, if it
/// offers one. A panel or a sidebar (`.regular`) centers the block in the
/// room it has, a little above the middle; a popover or a menu
/// (`.compact`) draws it smaller, from the top, since it sizes itself to
/// what it holds, with more room under the words than over the symbol.
/// A message or a description that wraps is set in lines of even length
/// (`BalancedLines`). A list's box in a form
/// (`.inline`) draws the message alone, in the one row the list keeps, as
/// an empty table's placeholder does in System Settings.
///
/// We draw it ourselves rather than with `ContentUnavailableView`: on macOS
/// that view sets its label in the system's large title style and fills
/// whatever it is given, with no smaller form for a popover, and its colors
/// are the system's labels rather than the ink of the surface it stands on
/// (`PopoverInk`), which over the menu bar's glass is not the panels' gray.
///
/// The message is quiet, as an empty list is: muted, a step under the
/// heading's weight, so the heading still says what the surface is. With
/// Increase Contrast it takes the text color, as the symbol does. The sizes
/// follow Dynamic Type from the type steps they start at, as the empty
/// session area's hints do and nothing else in the window does: the words here are all the surface says, and
/// a person who asked for larger text needs them most. Nothing moves, so
/// there is no motion to reduce. VoiceOver reads the message, then the
/// description, as one element, and not the symbol, which only repeats
/// the surface's own; an action stays an element of its own.
struct SupervisionEmptyState<Actions: View>: View {
    enum Size: Equatable, Sendable {
        /// A panel, a sidebar, or a surface with nothing else on it.
        case regular
        /// A popover or a menu.
        case compact
        /// A list's box in a form: the message alone, centered in the row
        /// the list keeps, so removing the last row does not change the
        /// box's height.
        case inline
    }

    let state: EmptyState
    let size: Size
    let actions: Actions

    @Environment(\.popoverSurface.ink) private var ink
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.locale) private var locale

    @ScaledMetric private var symbolSize: CGFloat
    @ScaledMetric private var messageSize: CGFloat
    @ScaledMetric private var descriptionSize: CGFloat

    private typealias Layout = WeirLayout.Supervision

    init(_ state: EmptyState, size: Size, @ViewBuilder actions: () -> Actions) {
        self.state = state
        self.size = size
        self.actions = actions()
        let metrics = Metrics(size)
        _symbolSize = ScaledMetric(wrappedValue: metrics.symbol.rawValue, relativeTo: .title)
        _messageSize = ScaledMetric(wrappedValue: metrics.message.rawValue, relativeTo: .body)
        _descriptionSize = ScaledMetric(wrappedValue: metrics.description.rawValue, relativeTo: .callout)
    }

    var body: some View {
        let metrics = Metrics(size)
        VStack(spacing: metrics.actionGap) {
            words(metrics)
                .frame(maxWidth: metrics.maxWidth)
            actions
        }
        .padding(metrics.insets)
        .frame(
            maxWidth: .infinity,
            maxHeight: size == .regular ? .infinity : nil,
            alignment: size == .compact ? .top : .center
        )
    }

    private func words(_ metrics: Metrics) -> some View {
        VStack(spacing: metrics.descriptionGap) {
            if size != .inline {
                Image(systemName: state.symbol)
                    .font(.system(size: symbolSize, weight: .regular))
                    .foregroundStyle(isContrastIncreased ? ink.text : ink.muted)
                    .padding(.bottom, metrics.symbolGap - metrics.descriptionGap)
            }
            if size == .inline {
                // One row, whatever the width: the list's height must not
                // change as its last row goes.
                message.lineLimit(1)
            } else {
                // Lines of even length, so no word or two is left alone
                // under a full line (`BalancedLines`), broken in Japanese
                // only between phrases (`PhraseBreaks`).
                BalancedLines { message }
                if let description = state.description(locale: locale) {
                    BalancedLines {
                        Text(verbatim: PhraseBreaks.joined(description, locale: locale))
                            .font(.system(size: descriptionSize))
                            .foregroundStyle(isContrastIncreased ? ink.text : ink.muted)
                    }
                }
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: state.spoken(locale: locale)))
    }

    private var message: some View {
        Text(verbatim: PhraseBreaks.joined(state.message(locale: locale), locale: locale))
            .font(.system(size: messageSize, weight: size == .inline ? .regular : .medium))
            .foregroundStyle(isContrastIncreased ? ink.text : ink.muted)
    }

    private var isContrastIncreased: Bool {
        contrast == .increased
    }

    /// Each size's steps, from the window's type and spacing tokens.
    struct Metrics: Equatable {
        let symbol: WeirFont.Supervision.Size
        let message: WeirFont.Supervision.Size
        let description: WeirFont.Supervision.Size
        /// From the symbol to the message.
        let symbolGap: CGFloat
        /// From the message to the description.
        let descriptionGap: CGFloat
        /// From the words to the action.
        let actionGap: CGFloat
        /// The most the words take across, so a wide panel still sets
        /// them in short lines under the symbol.
        let maxWidth: CGFloat
        let insets: EdgeInsets

        init(_ size: Size) {
            switch size {
            case .regular:
                symbol = .symbolHero
                message = .label
                description = .meta
                symbolGap = Layout.spaceS
                descriptionGap = Layout.spaceXS
                actionGap = Layout.spaceM
                maxWidth = Layout.emptyStateMaxWidth
                // 16pt more under the block than over it, and 32pt in all
                // as at the middle, so a centered block sits 8pt above the
                // middle, where the eye takes the middle to be: under a
                // heading, a block at the true middle looks low, the more
                // so over a rounded bottom edge.
                insets = EdgeInsets(
                    top: Layout.spaceS,
                    leading: Layout.spaceXL,
                    bottom: Layout.spaceXL + Layout.spaceXS,
                    trailing: Layout.spaceXL
                )
            case .compact:
                symbol = .display
                message = .row
                description = .caption
                symbolGap = Layout.spaceSnug
                descriptionGap = Layout.spaceHairline
                actionGap = Layout.spaceS
                maxWidth = Layout.emptyStateMaxWidth
                // The popover puts no padding of its own around what it
                // holds (`FloatingPanelHost`), so the room under the words
                // is this inset alone. Over the symbol, the line above's own
                // bottom spacing (about a step, with a heading's room for
                // its control) and `spaceXS` make about 15pt. Under the
                // words, the popover's corner curves in, and the same 15pt
                // there reads as less; clear of the corner by a step, the
                // room under the words looks at least as large as the room
                // over the symbol.
                insets = EdgeInsets(
                    top: Layout.spaceXS,
                    leading: Layout.spaceL,
                    bottom: WeirLayout.floatingPanelCornerRadius + Layout.spaceXS,
                    trailing: Layout.spaceL
                )
            case .inline:
                // Only the message is drawn; the list sets the row's height.
                symbol = .display
                message = .label
                description = .caption
                symbolGap = 0
                descriptionGap = 0
                actionGap = 0
                maxWidth = .infinity
                insets = EdgeInsets(top: 0, leading: Layout.spaceS, bottom: 0, trailing: Layout.spaceS)
            }
        }
    }
}

extension SupervisionEmptyState where Actions == EmptyView {
    init(_ state: EmptyState, size: Size) {
        self.init(state, size: size) { EmptyView() }
    }
}

extension EmptyState {
    /// The SF Symbol over the message: the one the surface's own heading,
    /// rail button, or tab already shows where it has one, so the empty
    /// state reads as that surface's; a magnifying glass for a search
    /// that found nothing, as the system's own empty searches show.
    var symbol: String {
        switch self {
        // The folder Open Folder… turns into a project.
        case .noProjects: "folder"
        case .noWorktreeSelected, .noOpenWorktrees: ContainerSymbol.worktree
        case .nothingNeedsAttention: "tray"
        case .noNotifications, .noAgentNotifications, .noCommandNotifications, .noUnreadNotifications: "bell"
        case .noTurns: "plus.forwardslash.minus"
        case .notGitRepository, .changesUnavailable: "exclamationmark.triangle"
        case .noChangesInScope, .incompleteRecord: ReviewPresentation.symbol
        case .noComments: "text.bubble"
        case .noMatchingWorktrees, .noMatchingFiles, .noResults, .noMatchingShortcuts, .noSettingsFound: "magnifyingglass"
        case .noTestCommands, .noTabs, .noOpenTab: "terminal"
        case .noFilesToCopy: "doc.on.doc"
        case .scratchElsewhere: "macwindow.on.rectangle"
        }
    }
}
