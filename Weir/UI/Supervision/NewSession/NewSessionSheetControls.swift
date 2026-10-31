// NewSessionSheetControls.swift
// Weir — the new worktree sheet's parts: menu faces, a checkbox with its line, problem text, the failure box, fields, Return and ⌘⏎.

import AppKit
import SwiftUI
import WeirDomain

/// A menu's face as the sheet's fields are drawn: on the window's color,
/// edged in `line`, as tall as a field, the chevron at its end, faded as a
/// field is while it takes no choice. The window's own bordered button would
/// cut a face to its title's width, and the base's runs the column's width.
struct NewSessionMenuFace<Content: View>: View {
    let fillsWidth: Bool
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.sheetFieldCornerRadius, style: .continuous)
        HStack(spacing: WeirLayout.Supervision.spaceS - WeirLayout.Supervision.spaceHairline) {
            content
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.supervision(.disclosure, weight: .semibold))
                .foregroundStyle(SupervisionTokens.muted.color)
                .accessibilityHidden(true)
        }
        .font(.supervision(.body))
        .foregroundStyle(SupervisionTokens.text.color)
        .padding(.horizontal, WeirLayout.Supervision.spaceS)
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: WeirLayout.Supervision.sheetFieldHeight, alignment: .leading)
        .background(shape.fill(SupervisionTokens.window.color))
        .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
        .contentShape(shape)
        .opacity(isEnabled ? 1 : WeirLayout.Supervision.sheetFieldDisabledOpacity)
    }
}

/// A checkbox of the sheet and the muted line under it, which says what
/// it acts on: the files it copies, the commands it runs. The line is the
/// box's VoiceOver hint too, so it is not read twice. It wraps onto the
/// two lines a status line has rather than cut a sentence short, the
/// branches it names shortened first (`NewSessionModel.shownName`).
struct NewSessionCheckbox<Detail: View>: View {
    let title: LocalizedStringResource
    @Binding var isOn: Bool
    let hint: Text?
    /// Whether the box takes a choice; the line under it stays live, for a
    /// way on such as opening Project Settings.
    var isToggleEnabled = true
    @ViewBuilder let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: WeirLayout.Supervision.newSessionInlineSpacing) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(.supervision(.label))
                    // The explicit color would otherwise keep a box that takes
                    // no choice looking as live as the others.
                    .foregroundStyle(isToggleEnabled ? SupervisionTokens.text.color : SupervisionTokens.muted.color)
            }
            .toggleStyle(.checkbox)
            .disabled(!isToggleEnabled)
            .modifier(OptionalAccessibilityHint(hint: hint))
            detail
                .font(.supervision(.meta))
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(NewSessionStatusLine.lineCount)
                .fixedSize(horizontal: false, vertical: true)
                // Indented to the box's title.
                .padding(.leading, WeirLayout.Supervision.spaceXL)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// A line under one of the sheet's controls: what Create will do, or what
/// stops it, as tall as what it says. The branches the runs mark are drawn
/// in the code face, as the fields above draw them. The sentence
/// wraps onto a second line
/// rather than lose its words; a branch too long for that is cut in its
/// middle (`SupervisionTruncation.middle`), where a branch is least read,
/// so the cut falls in the name and never in the sentence around it. The
/// whole sentence is the tooltip.
struct NewSessionStatusLine: View {
    let runs: [NewSessionModel.LineRun]
    let color: Color
    /// At most `lineCount`; `nil`, for a test, lets it take every line it
    /// needs, to tell whether the two hold it.
    var lineLimit: Int? = Self.lineCount

    /// The most lines a line under a control takes.
    nonisolated static let lineCount = 2
    /// The muted line under a control.
    static let font = Font.supervision(.meta)
    /// A branch inside that line.
    static let codeFont = Font.supervisionCode(beside: .meta)

    /// The room of `lines` blank lines, drawn as a line is (attributed
    /// text, whose lines stand a point taller than a plain string's at the
    /// same font), so a line measured against it, or kept from shrinking
    /// below it, is the height it says.
    static func reservedSpace(lines: Int = lineCount) -> some View {
        Text(AttributedString(Array(repeating: " ", count: lines).joined(separator: "\n")))
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .accessibilityHidden(true)
    }

    var body: some View {
        let line = runs.reduce(into: AttributedString()) { line, run in
            // The code face is monospaced, so characters measure the width.
            var piece = AttributedString(run.isCode ? NewSessionModel.shownName(run.text) : run.text)
            if run.isCode {
                piece.font = Self.codeFont
            }
            line += piece
        }
        Text(line)
            .font(Self.font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(NewSessionStatusTooltip(text: runs.map(\.text).joined()))
    }
}

/// A hint only when there is one.
private struct OptionalAccessibilityHint: ViewModifier {
    let hint: Text?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

/// A tooltip only when there is one: an empty `.help` would take the
/// pointer from the whole sentence's tooltip around it.
struct NewSessionStatusTooltip: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(Text(verbatim: text))
        } else {
            content
        }
    }
}

/// What the line under the branch says of a problem that stops Create, in
/// `locale`'s language; `nil` for one said nowhere.
enum NewSessionProblemText {
    static func text(_ problem: NewSessionModel.Problem, model: NewSessionModel, locale: Locale) -> String? {
        // The name and the folder are cut in their middle, before the line
        // wraps, so a long one never pushes the sentence past its lines.
        let branch = NewSessionModel.shownName(model.checkoutBranch)
        let resource: LocalizedStringResource? = switch problem {
        case .branchNameInvalid:
            "“\(branch)” can’t be a branch name."
        case .branchExists:
            LocalizedStringResource(
                "“\(branch)” is already a branch. Choose Existing Branch to check it out.",
                comment: "New worktree sheet: a local branch has the typed name"
            )
        case .branchCheckedOut:
            LocalizedStringResource(
                // Short: it shares the one line under the branch.
                "“\(branch)” is checked out in another worktree.",
                comment: "New worktree sheet: the local branch named is checked out in the project's folder or another worktree"
            )
        case .noBranchChosen:
            // The empty menu says it; Create is off.
            nil
        case let .folderExists(url):
            "A folder already exists at \(folder(url))."
        case .noBase:
            LocalizedStringResource(
                "No base branch was found.",
                comment: "New worktree sheet: no default branch and no current branch"
            )
        case let .pullRequestsUnavailable(availability):
            pullRequestsUnavailable(availability)
        case .noPullRequestChosen:
            // The empty field says it; Create is off.
            nil
        case let .pullRequestElsewhere(repository):
            LocalizedStringResource(
                "This link is to a pull request of \(repository), not of this project’s remote.",
                comment: "New worktree sheet: the pasted link names another repository; the argument is it, as host/owner/repo"
            )
        case let .pullRequestNotFound(number):
            LocalizedStringResource(
                "Couldn’t find PR #\(number).",
                comment: "New worktree sheet: the forge has no pull request of the number typed"
            )
        case let .pullRequestLookupFailed(number, said) where said.isEmpty:
            LocalizedStringResource(
                "Couldn’t read PR #\(number). Try again in a moment.",
                comment: "New worktree sheet: gh or glab did not answer about the pull request"
            )
        case let .pullRequestLookupFailed(number, said):
            LocalizedStringResource(
                "Couldn’t read PR #\(number): \(said)",
                comment: "New worktree sheet: gh or glab failed to read the pull request; the number, then the CLI's own words"
            )
        }
        return resource?.resolved(in: locale)
    }

    /// The folder a problem names, cut in its middle past twice a branch's
    /// room: a path is read in the line's own face, narrower than code.
    private static func folder(_ url: URL) -> String {
        SupervisionTruncation.middle(PathFormatting.abbreviateHome(url.path), limit: NewSessionModel.longestShownName * 2)
    }

    /// Why no worktree can be made from a pull request here: the source's
    /// tooltip, and the line under the branch when the segment was chosen
    /// before the answer came. `nil` while it is still being asked.
    static func pullRequestsUnavailable(_ availability: PullRequestAvailability) -> LocalizedStringResource? {
        switch availability {
        case .checking, .available:
            nil
        case .noForge:
            LocalizedStringResource(
                "Weir found no remote of this project that gh or glab can read pull requests from.",
                comment: "New worktree sheet: why the Pull Request source is off; no remote on a host gh or glab serves"
            )
        case let .toolMissing(forge):
            LocalizedStringResource(
                "Install \(forge.executableName) to create worktrees from pull requests.",
                comment: "New worktree sheet: why the Pull Request source is off; the argument is gh or glab"
            )
        case let .notSignedIn(forge):
            LocalizedStringResource(
                "\(forge.executableName) isn’t signed in, so Weir can’t read pull requests.",
                comment: "New worktree sheet: why the Pull Request source is off; the argument is gh or glab"
            )
        }
    }
}

/// What git said when it could not add the worktree, selectable, in a box
/// that scrolls past a few lines.
struct NewSessionFailureBox: View {
    let failure: DisplayText

    var body: some View {
        ScrollView {
            Text(display: failure)
                .font(.supervision(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 96)
        .padding(WeirLayout.Supervision.spaceS)
        .background(RoundedRectangle(cornerRadius: WeirLayout.Supervision.smallControlCornerRadius)
            .fill(SupervisionTokens.stoppedFill.color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(
            "Couldn’t create the worktree",
            comment: "New worktree sheet, VoiceOver: git failed to add the worktree"
        ))
        .accessibilityValue(Text(display: failure))
    }
}

/// A text field of the sheet, drawn as the supervision window's other
/// fields are: plain, on the window's color, edged in `line`, a little
/// taller than a pop-up on one line, with the accent's ring while it has
/// the keyboard. The bordered system field keeps its small height whatever
/// control size it is given. A click anywhere in the box puts the keys in
/// the field, as a bordered field's does.
struct NewSessionSheetField: ViewModifier {
    let isFocused: Bool
    let focus: () -> Void
    /// The whole sheet's `.disabled` while the worktree is made: the
    /// field's own `.disabled` would sit inside this box, where the box
    /// cannot read it, but the sheet's reaches here.
    @Environment(\.isEnabled) private var takesText

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: WeirLayout.Supervision.sheetFieldCornerRadius, style: .continuous)
        content
            .textFieldStyle(.plain)
            .padding(WeirLayout.Supervision.sheetFieldInsets)
            .frame(maxWidth: .infinity, minHeight: WeirLayout.Supervision.sheetFieldHeight, alignment: .leading)
            // The tap is the box's, behind the field, so a click on the text
            // still places the caret where it lands.
            .background(shape.fill(SupervisionTokens.window.color).onTapGesture {
                if takesText {
                    focus()
                }
            })
            .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1).allowsHitTesting(false))
            .opacity(takesText ? 1 : WeirLayout.Supervision.sheetFieldDisabledOpacity)
            .supervisionFocusRing(
                isFocused: isFocused && takesText,
                cornerRadius: WeirLayout.Supervision.sheetFieldCornerRadius
            )
    }
}

/// The sheet's Return and ⌘⏎ (`NewSessionKey`), taken before the field
/// editor sees them: a plain Return submits the field and selects its
/// whole text, so the next key would replace the branch's name. For this
/// sheet's window only: a panel hung from the sheet, or any other window,
/// keeps its own keys.
struct NewSessionKeyMonitor: View {
    let onCreate: () -> Void

    var body: some View {
        WindowKeyDownMonitor(handle: handle)
    }

    /// Whether the sheet took `event`.
    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        let action = NewSessionKey.action(
            isReturn: event.namedKey == .return,
            modifiers: KeyModifiers(event.modifierFlags),
            hasMarkedText: window.isComposingText
        )
        switch action {
        case .create:
            onCreate()
            return true
        case .swallow:
            return true
        case .pass:
            return false
        }
    }
}
