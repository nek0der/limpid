// SessionHeaderModel.swift
// Weir — the session header: the state glyph, the name, and the chips beside it.

import Foundation
import WeirDomain

/// The 36pt line above the pane strip: the session's state glyph, its
/// name, then its exception chips and its Git chips, the pull request's
/// with the request's mark before it. Every session shows it, one shell
/// tab included, so the name and the Git facts stay in one place and the
/// area keeps its shape from one session to the next.
struct SessionHeaderModel: Equatable {
    /// What a Git chip states, which the view reads to know the chip that
    /// opens a card rather than its words.
    enum GitChipKind: Equatable {
        /// The pull request's chip, which opens the request's card.
        case pullRequest
        case fact(GitFactsText.ChipKind)
    }

    /// A Git fact beside the name ("PR #128"). Exception chips (the prompt
    /// cache) are controls, drawn by the view from the pane they speak for.
    struct GitChip: Identifiable, Equatable {
        let kind: GitChipKind
        let text: String

        var id: String {
            switch kind {
            case .pullRequest: "pullRequest"
            case let .fact(kind): kind.rawValue
            }
        }
    }

    let glyph: SessionRowFact.Glyph
    let name: String
    /// Where `name` is cut, as the session's row cuts it
    /// (`SessionSidebarModel.Row.nameTruncation`).
    let nameTruncation: SupervisionTruncation
    let gitChips: [GitChip]

    /// `gitFacts` adds "+3 commits" and "2 files uncommitted" after the pull
    /// request's chip, the commits only while the request is not
    /// merged (`GitFactsText.chips`).
    init(
        row: SessionSidebarModel.Row,
        pullRequestNumber: Int?,
        pullRequestState: PRState? = nil,
        gitFacts: GitFacts? = nil,
        locale: Locale
    ) {
        glyph = row.fact.glyph
        name = row.name
        nameTruncation = row.nameTruncation
        let pullRequest = pullRequestNumber.map { number in
            [GitChip(
                kind: .pullRequest,
                text: LocalizedStringResource("PR #\(number)", comment: "Worktree header chip: the branch's pull request")
                    .resolved(in: locale)
            )]
        } ?? []
        gitChips = pullRequest + GitFactsText.chips(gitFacts, isPullRequestMerged: pullRequestState == .merged, locale: locale).map {
            GitChip(kind: .fact($0.kind), text: $0.text)
        }
    }
}

/// Which chips fit beside the session name. The name is never cut
/// for a chip: when the header is too narrow, Git chips go to its tooltip
/// first, from the last, then exception chips, and only then is the name
/// cut short.
enum HeaderChipOverflow {
    enum Kind: Equatable {
        case exception
        case git
    }

    struct Chip: Equatable {
        let kind: Kind
        let width: CGFloat
    }

    /// Everything on the header's line but its chips: the padding on both
    /// sides, the glyph, the spacing after it, the name at its full width,
    /// and `slack` for text that draws a little wider than it measured.
    /// Each chip adds its own spacing in `shown`.
    static func fixedWidth(
        nameWidth: CGFloat,
        glyphWidth: CGFloat,
        horizontalPadding: CGFloat,
        spacing: CGFloat,
        slack: CGFloat
    ) -> CGFloat {
        2 * horizontalPadding + glyphWidth + spacing + nameWidth + slack
    }

    /// The indices of `chips` (in display order) that stay in the header.
    /// `fixedWidth` is everything else on the line: the glyph, the name at
    /// its full width, and the padding. Chips are `spacing` apart, and the
    /// first is `leadingSpacing` from the name (`spacing` when `nil`).
    static func shown(
        chips: [Chip],
        fixedWidth: CGFloat,
        available: CGFloat,
        spacing: CGFloat,
        leadingSpacing: CGFloat? = nil
    ) -> [Int] {
        var shown = Array(chips.indices)
        func width() -> CGFloat {
            shown.enumerated().reduce(fixedWidth) { total, entry in
                total + (entry.offset == 0 ? leadingSpacing ?? spacing : spacing) + chips[entry.element].width
            }
        }
        for kind in [Kind.git, .exception] {
            while width() > available, let last = shown.lastIndex(where: { chips[$0].kind == kind }) {
                shown.remove(at: last)
            }
        }
        return shown
    }
}
