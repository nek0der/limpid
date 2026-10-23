// StatusBandModel.swift
// Limpid — what the window's bottom band says about the pane in use.

import Foundation

/// The 26pt band along the window's bottom: where the pane in use is,
/// as project › worktree › pane, and what runs in it: the agent, the folder,
/// the terminal's size, and its encoding. It only shows; nothing on it is
/// pressed.
struct StatusBandModel: Equatable {
    struct Input: Equatable {
        /// `nil` for a scratch tab, which no project holds.
        var projectName: String?
        /// The branch of the checkout; `nil` for scratch, or a project with
        /// no branch.
        var checkoutName: String?
        /// `nil` while the window shows no tab.
        var paneName: String?
        /// The pane runs a shell the person has not named. Its name is then
        /// its folder's, which is most often the project's own, and the
        /// path would read "alpha › main › alpha": the crumb says
        /// "Shell" instead. A pane the person named keeps that name.
        var isUnnamedShell = false
        /// `nil` for a pane with no agent.
        var agentName: String?
        /// Home abbreviated (`~/…`); `nil` until the pane's directory is
        /// known, or when it is the pane's name already (the header's rule).
        var folder: String?
        /// `nil` while the terminal has no grid yet (off screen, starting).
        var gridSize: TerminalGridSize?
        /// The folder a scratch tab works in, home abbreviated: it stands
        /// in the path where a project's branch would.
        var scratchFolder: String?
        /// The project's folder, home abbreviated, for a window that shows
        /// no tab: the only fact there is to state.
        var projectFolder: String?
        /// The review tab is in front: the band speaks of it, not of the
        /// pane behind it.
        var isReviewShown = false
    }

    /// One step of the path.
    struct Crumb: Equatable {
        let text: String
        /// A branch or a folder, which the band draws in the code face:
        /// a name Git or the file system gave, not a word of ours.
        let isCode: Bool
    }

    /// One fact on the band's right.
    struct Detail: Equatable {
        let text: String
        /// A folder, the one fact that gives up its middle when the band is
        /// too narrow; the others are short and keep their whole.
        let isFolder: Bool
    }

    /// libghostty reads and writes UTF-8 only, so the band states it rather
    /// than leaving it to be guessed.
    static let encoding = "UTF-8"
    /// Between two steps of the path.
    static let crumbSeparator = " › "

    /// "limpid › main › Claude". Read from the right: the view shortens it
    /// from the left (`SupervisionTruncation.breadcrumb`), so the pane
    /// stays in sight.
    let path: String
    /// `path`'s steps, in order, for the view to draw each in its face.
    let crumbs: [Crumb]
    /// "Claude Code", "~/limpid", "120×40", "UTF-8": set side by side.
    let details: [Detail]
    /// What VoiceOver reads for the band, the size in words.
    let spokenLabel: String

    init(_ input: Input, locale: Locale) {
        let place = input.projectName ?? LocalizedStringResource("Scratch").resolved(in: locale)
        let review = LocalizedStringResource("Review").resolved(in: locale)
        let pane: String? = if input.paneName == nil {
            nil
        } else if input.isReviewShown {
            review
        } else if input.isUnnamedShell {
            LocalizedStringResource("Shell").resolved(in: locale)
        } else {
            input.paneName
        }
        // A scratch shell named by its folder would say the folder twice,
        // so a crumb that repeats the one before it is dropped.
        let candidates = [
            Crumb(text: place, isCode: false),
            (input.checkoutName ?? input.scratchFolder).map { Crumb(text: $0, isCode: true) },
            pane.map { Crumb(text: $0, isCode: false) }
        ]
        crumbs = candidates
            .compactMap(\.self)
            .reduce(into: [Crumb]()) { parts, part in
                if parts.last?.text != part.text {
                    parts.append(part)
                }
            }
        let pathParts = crumbs.map(\.text)
        path = pathParts.joined(separator: Self.crumbSeparator)
        let grid = input.gridSize.map { "\($0.columns)×\($0.rows)" }
        let spokenGrid = input.gridSize.map { size in
            LocalizedStringResource(
                "\(size.columns) columns, \(size.rows) rows",
                comment: "Status band, VoiceOver: the terminal's size; arguments: columns, rows"
            ).resolved(in: locale)
        }
        let spokenDetails: [String]
        if input.paneName == nil {
            // No pane: only where the project lives. The encoding is a
            // pane's, so it is not stated.
            details = input.projectFolder.map { [Detail(text: $0, isFolder: true)] } ?? []
            spokenDetails = details.map(\.text)
        } else if input.isReviewShown {
            // The review has no agent, folder, or grid of its own to state.
            details = [Detail(text: review, isFolder: false)]
            spokenDetails = []
        } else {
            details = [
                input.agentName.map { Detail(text: $0, isFolder: false) },
                input.folder.map { Detail(text: $0, isFolder: true) },
                grid.map { Detail(text: $0, isFolder: false) },
                Detail(text: Self.encoding, isFolder: false)
            ].compactMap(\.self)
            spokenDetails = [input.agentName, input.folder, spokenGrid, Self.encoding].compactMap(\.self)
        }
        spokenLabel = AgentStatusText.spokenList(pathParts + spokenDetails, locale: locale)
    }
}
