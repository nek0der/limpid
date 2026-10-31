// SessionHeaderView.swift
// Weir — the session header: the state glyph, the name, and the chips that fit beside it.

import AppKit
import SwiftUI

/// The 36pt line above the pane strip. The chips never cut the name:
/// those that do not fit go to the header's tooltip, Git chips first, and
/// only then is the name cut short.
struct SessionHeaderView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(PRStatusStore.self) private var prStatusStore
    @Environment(GitFactsStore.self) private var gitFacts
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    /// Unbounded until the header is laid out, so no chip is hidden for
    /// the first frame.
    @State private var width: CGFloat = .greatestFiniteMagnitude

    /// Text measured with AppKit can come out a point or so narrower than
    /// SwiftUI draws it; without the slack a chip that "just fits" would
    /// cut the name it must never cut.
    private static let measuringSlack: CGFloat = 2
    private static let nameFont = NSFont.systemFont(
        ofSize: WeirLayout.Supervision.sessionHeaderNameFontSize.rawValue,
        weight: .bold
    )

    var body: some View {
        let container = window.selection.activeContainerID
        let info = prStatusStore.info(for: container)
        let facts = gitFacts.facts(for: container)
        if let row = SessionSidebarModel(
            activeIn: session,
            window: window.id,
            queue: attentionQueue.queue,
            runtimes: attention.allRuntimes,
            approvals: approvals.ledger,
            pullRequest: info,
            gitFacts: facts,
            locale: locale
        ).rows.first {
            let model = SessionHeaderModel(
                row: row,
                pullRequestNumber: info?.number,
                pullRequestState: info?.state,
                gitFacts: facts,
                locale: locale
            )
            header(
                model,
                // On the request's chip, whatever the session's state.
                pullRequestMark: row.fact.pullRequest == nil ? nil : PRMarkPresentation.supervisionStyle(for: info),
                pullRequest: info.map { (container: container, info: $0) }
            )
        }
    }

    private func header(
        _ model: SessionHeaderModel,
        pullRequestMark: PRMarkPresentation?,
        pullRequest: (container: ContainerID, info: PRInfo)?
    ) -> some View {
        let layout = WeirLayout.Supervision.self
        let cacheMark = session.activeTab(in: window.id).flatMap { tab in
            attention.promptCacheMark(in: tab).map { (tab: tab, mark: $0) }
        }
        let chips = chipTexts(model, cacheMark: cacheMark?.mark)
        let shown = Set(HeaderChipOverflow.shown(
            chips: chips.map {
                HeaderChipOverflow.Chip(
                    kind: $0.kind,
                    width: SupervisionChip.width(of: $0.text, hasIcon: $0.hasIcon)
                        + ($0.source == .pullRequest && pullRequestMark != nil ? PullRequestChip.markWidth : 0)
                )
            },
            fixedWidth: HeaderChipOverflow.fixedWidth(
                nameWidth: Self.textWidth(model.name, font: Self.nameFont),
                glyphWidth: layout.stateGlyphSize,
                horizontalPadding: layout.sessionHeaderHorizontalInset,
                spacing: layout.sessionHeaderSpacing,
                slack: Self.measuringSlack
            ),
            available: width,
            spacing: layout.sessionHeaderChipSpacing,
            leadingSpacing: layout.sessionHeaderSpacing
        ))
        let hidden = chips.indices.filter { !shown.contains($0) }.map { chips[$0].text }
        // On the glyph and the name rather than the whole header: the PR
        // chip opens its card, and a tooltip over it would open beside the
        // card over the same spot.
        let tooltip = Text(verbatim: AgentStatusText.joined([model.name] + hidden, locale: locale))
        return HStack(spacing: layout.sessionHeaderSpacing) {
            SessionStateGlyph(glyph: model.glyph)
                .frame(width: layout.stateGlyphSize, height: layout.stateGlyphSize)
                .help(tooltip)
            Text(verbatim: model.name)
                .font(Font(Self.nameFont))
                .lineLimit(1)
                .supervisionTruncation(model.nameTruncation)
                .help(tooltip)
                .accessibilityAddTraits(.isHeader)
            if !shown.isEmpty {
                HStack(spacing: layout.sessionHeaderChipSpacing) {
                    ForEach(chips.indices.filter(shown.contains), id: \.self) { index in
                        chipView(chips[index], cacheMark: cacheMark, pullRequest: pullRequest, pullRequestMark: pullRequestMark)
                            .fixedSize()
                    }
                }
            }
        }
        // Leading, not a trailing spacer, which the stack would also set
        // apart by its spacing and so take from the name.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, layout.sessionHeaderHorizontalInset)
        .frame(height: layout.sessionHeaderHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
    }

    /// The exception chips, then the Git ones.
    private func chipTexts(_ model: SessionHeaderModel, cacheMark: PromptCacheMark?) -> [HeaderChipText] {
        let cache = cacheMark.map { [HeaderChipText(source: .promptCache, text: $0.chipTitle.resolved(in: locale))] } ?? []
        let git = model.gitChips.map { chip in
            HeaderChipText(source: chip.kind == .pullRequest ? .pullRequest : .git, text: chip.text)
        }
        return cache + git
    }

    @ViewBuilder
    private func chipView(
        _ chip: HeaderChipText,
        cacheMark: (tab: Tab, mark: PromptCacheMark)?,
        pullRequest: (container: ContainerID, info: PRInfo)?,
        pullRequestMark: PRMarkPresentation?
    ) -> some View {
        switch chip.source {
        case .promptCache:
            if let cacheMark {
                // The selected tab's clock place: in this window the header
                // holds the clock the tab list would.
                PromptCacheMarkView(mark: cacheMark.mark, place: .tabRow(tabID: cacheMark.tab.id), style: .chip)
            }
        case .pullRequest:
            if let pullRequest {
                PullRequestChip(text: chip.text, container: pullRequest.container, info: pullRequest.info, mark: pullRequestMark)
            } else {
                SupervisionChip(text: Text(verbatim: chip.text))
            }
        case .git:
            SupervisionChip(text: Text(verbatim: chip.text))
        }
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The pull request's chip, after the request's mark: the header's
/// place for what is attached to the session, as the sidebar row's is
/// beside its badge. Its card opens as the sidebar row's does, on the
/// pointer resting on the mark or the chip, and on the keyboard reaching
/// the chip. The card
/// is the header's own (`PRHoverSource.Place.sessionHeader`), so the
/// sidebar row of the same branch neither moves it nor closes it.
private struct PullRequestChip: View {
    let text: String
    let container: ContainerID
    let info: PRInfo
    let mark: PRMarkPresentation?
    @Environment(PRHoverPresentation.self) private var presentation
    @FocusState private var isFocused: Bool
    /// The chip's frame, which the card hangs beside when the keyboard
    /// opens it.
    @State private var frame: CGRect = .zero

    /// The keyboard's hold on the card, apart from the pointer's
    /// (`prHoverCard(_:place:)`).
    private var focusSource: PRHoverSource {
        PRHoverSource(container: container, place: .sessionHeaderFocus)
    }

    /// What the mark adds to the chip's width, for the header's overflow
    /// (`HeaderChipOverflow`).
    static let markWidth = WeirLayout.Supervision.agentBadgeHeight + WeirLayout.Supervision.spaceSnug

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceSnug) {
            if let mark {
                SessionPRMark(style: mark)
            }
            chip
        }
        // The mark and the chip are one place: the card opens from either
        // and hangs beside the chip's end.
        .prHoverCard((container: container, info: info), place: .sessionHeader)
    }

    private var chip: some View {
        SupervisionChip(text: Text(verbatim: text))
            // Reached by the keyboard only: a click must leave the
            // terminal's keyboard where it was.
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused($isFocused)
            .supervisionFocusRing(
                isFocused: isFocused,
                cornerRadius: WeirLayout.Supervision.chipCornerRadius
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onChange(of: isFocused) { _, isFocused in
                if isFocused {
                    presentation.rowEntered(rowID: focusSource, info: info, anchor: frame, delay: .zero)
                } else {
                    presentation.rowExited(rowID: focusSource)
                }
            }
            .onDisappear { presentation.rowDisappeared(rowID: focusSource) }
    }
}

/// One chip in display order: the exception chips, then the Git ones.
private struct HeaderChipText {
    enum Source {
        case promptCache
        case pullRequest
        case git
    }

    let source: Source
    let text: String

    var kind: HeaderChipOverflow.Kind {
        switch source {
        case .pullRequest, .git: .git
        case .promptCache: .exception
        }
    }

    /// The clock carries a symbol before its words.
    var hasIcon: Bool {
        source == .promptCache
    }
}
