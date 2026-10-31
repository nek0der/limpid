// CommitAndPRSection.swift
// Weir — "Commit & PR" at the foot of the changes panel: where the branch stands and the moves toward a pull request.

import AppKit
import SwiftUI

/// The foot of the changes panel. What it says and offers is
/// `CommitAndPRModel`'s; this lays it out and asks before cleaning up.
/// Its words and its other buttons stand above; its one primary move
/// (`CommitAndPRModel.footAction`) is in the panel's foot bar, on the line
/// the sidebar's scratch row and the decision bar stand on. With no move
/// there is no bar (`CommitAndPRFootBar`).
struct CommitAndPRSection: View {
    let state: AppState
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity
    /// Why "Clean Up Worktree…" stopped, while its alert shows.
    @State private var cleanUpBlocked: String?
    @State private var isCheckingCleanUp = false
    @State private var deletingWorktree: DeleteWorktreeTarget?
    @State private var forceDeleteWorktree: ForceDeleteWorktreeTarget?
    @State private var worktreeOperationError: DisplayText?
    @State private var footGate = CommitAndPRFootGate()

    var body: some View {
        let model = CommitAndPRActions.model(window: window, state: state)
        // The sidebar's ground, so the foot reads as apart from the turns
        // above it. At the panel's opacity, so with transparency on it is
        // not an opaque patch (laid over the panel, a little denser).
        let ground = SupervisionTokens.sidebar.color.opacity(surfaceOpacity)
        VStack(spacing: 0) {
            // Where the branch stands and the moves the foot bar does not
            // hold; then the words about the bar's own move, right above
            // it: why "Create PR" is off or what it will do, and the changes
            // no turn accounts for, which do not hold the PR back. Read in
            // that order by VoiceOver too. "Create PR" above the bar, while
            // "Show Current Diff" holds it, has its reason just under it.
            VStack(alignment: .leading, spacing: WeirLayout.Supervision.commitSectionSpacing) {
                Text("Commit & PR")
                    .font(.supervision(.caption, weight: .bold))
                    .tracking(WeirLayout.Supervision.commitHeadingTracking)
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .accessibilityAddTraits(.isHeader)
                facts(model)
                buttons(model)
                reason(model.create)
                if model.unviewedOutsideTurns > 0 {
                    outsideTurns(model.unviewedOutsideTurns)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WeirLayout.Supervision.commitSectionInsets)
            .background(ground)
            CommitAndPRFootBar(action: model.footAction, fill: ground, perform: performFootAction)
        }
        // A button that takes another's place under the pointer waits a
        // moment before it hears a press (`CommitAndPRFootGate`).
        .onChange(of: model.footAction?.kind, initial: true) { _, kind in
            footGate.noteShown(kind, at: SuspendingClock().now)
        }
        .alert(
            Text("Can’t Clean Up the Worktree"),
            isPresented: Binding(get: { cleanUpBlocked != nil }, set: {
                if !$0 {
                    cleanUpBlocked = nil
                }
            })
        ) {
            Button("OK") {}
        } message: {
            Text(verbatim: cleanUpBlocked ?? "")
        }
        .worktreeOperationAlerts(
            deletingWorktree: $deletingWorktree,
            forceDeleteWorktree: $forceDeleteWorktree,
            // This section closes no project; the title bar's menu does.
            removingProject: .constant(nil),
            worktreeOperationError: $worktreeOperationError
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Commit & PR"))
    }

    /// "PR #128 · Open · Checks passed (4/4) · 3 commits not in main · …":
    /// one muted line, wrapping as the panel narrows. With no fact to state,
    /// no line at all, so the section's spacing does not leave an empty
    /// gap under its heading.
    @ViewBuilder
    private func facts(_ model: CommitAndPRModel) -> some View {
        let request = model.pullRequest.map { [CommitAndPRText.pullRequest($0, locale: locale)] } ?? []
        let lines = model.lines.map { CommitAndPRText.line($0, locale: locale) }
        if request.isEmpty, lines.isEmpty {
            EmptyView()
        } else {
            Text(verbatim: AgentStatusText.joined(request + lines, locale: locale))
                .font(.supervision(.row))
                .foregroundStyle(SupervisionTokens.muted.color)
                .fixedSize(horizontal: false, vertical: true)
                // The same facts as a list, the checks' count in words.
                .accessibilityLabel(Text(verbatim: AgentStatusText.spokenList(
                    (model.pullRequest.map { [CommitAndPRText.spokenPullRequest($0, locale: locale)] } ?? [])
                        + lines.map { AgentStatusText.spoken($0, locale: locale) },
                    locale: locale
                )))
        }
    }

    /// The notice whose "Show Current Diff" the foot bar holds: it comes
    /// before every other move (`CommitAndPRModel.footAction`).
    private func outsideTurns(_ files: Int) -> some View {
        Text(verbatim: CommitAndPRText.outsideTurns(files, locale: locale))
            .font(.supervision(.meta))
            .foregroundStyle(SupervisionTokens.muted.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The foot bar's button, pressed: only once it has been there a moment.
    private func performFootAction(_ action: CommitAndPRModel.FootAction) {
        // At least the person's double-click interval, so the second press
        // of a slow double click is still taken for the button before.
        let settle = CommitAndPRFootGate.settle(doubleClickInterval: NSEvent.doubleClickInterval)
        guard footGate.accepts(action.kind, at: SuspendingClock().now, settle: settle) else { return }
        switch action {
        case .showCurrentDiff:
            CommitAndPRActions.showCurrentDiff(window: window, state: state)
        case .createPullRequest:
            CommitAndPRActions.createPullRequest(window: window, state: state)
        case let .openPullRequest(request):
            NSWorkspace.shared.open(request.url)
        case let .openExternalTool(tool):
            CommitAndPRActions.open(tool, window: window, state: state)
        }
    }

    /// The moves the foot bar does not hold.
    @ViewBuilder
    private func buttons(_ model: CommitAndPRModel) -> some View {
        let offersTool = model.offersExternalToolAboveFoot
        if model.offersOpenAboveFoot || model.offersCreateAboveFoot || offersTool || model.offersCleanUp {
            // Wraps rather than cuts a title when the panel is narrow.
            FlowLayout(spacing: WeirLayout.Supervision.commitSectionSpacing, lineSpacing: WeirLayout.Supervision.commitSectionSpacing) {
                if let request = model.pullRequest, model.offersOpenAboveFoot {
                    Button {
                        NSWorkspace.shared.open(request.url)
                    } label: {
                        Text("Open on \(request.forge.displayName)")
                    }
                }
                if let create = model.create, model.offersCreateAboveFoot {
                    Button("Create PR") {
                        CommitAndPRActions.createPullRequest(window: window, state: state)
                    }
                    .disabled(!create.isAvailable)
                    .accessibilityLabel(Text("Create PR"))
                    // The reason shows under the buttons, above the foot
                    // bar; VoiceOver reads it with the button it is about.
                    .accessibilityHint(Text(verbatim: blockerText(create)))
                }
                if let tool = model.externalTool, offersTool {
                    Button {
                        CommitAndPRActions.open(tool, window: window, state: state)
                    } label: {
                        Text("Open in \(tool.name)")
                    }
                    .accessibilityLabel(Text("Open in \(tool.name)"))
                }
                if model.offersCleanUp {
                    Button("Clean Up Worktree…") {
                        cleanUp()
                    }
                    .disabled(isCheckingCleanUp)
                    .accessibilityLabel(Text("Clean Up Worktree…"))
                }
            }
            .buttonStyle(.supervisionSecondary)
        }
    }

    /// The one reason "Create PR" cannot be pressed, or what pressing it
    /// will and will not do.
    @ViewBuilder
    private func reason(_ create: CommitAndPRModel.Create?) -> some View {
        switch create {
        case let .blocked(blocker):
            Text(verbatim: CommitAndPRText.blocker(blocker, locale: locale))
                .font(.supervision(.meta))
                .foregroundStyle(SupervisionTokens.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        case let .available(notes):
            ForEach(notes, id: \.self) { note in
                Text(verbatim: CommitAndPRText.note(note, locale: locale))
                    .font(.supervision(.meta))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case nil:
            EmptyView()
        }
    }

    private func blockerText(_ create: CommitAndPRModel.Create) -> String {
        CommitAndPRFootButton.blockerText(create, locale: locale)
    }

    private func cleanUp() {
        isCheckingCleanUp = true
        Task {
            defer { isCheckingCleanUp = false }
            switch await CommitAndPRActions.cleanUp(window: window, state: state, locale: locale) {
            case let .blocked(message):
                cleanUpBlocked = message
            case let .confirm(target):
                deletingWorktree = target
            case nil:
                break
            }
        }
    }
}

/// The changes panel's foot bar: its one move, trailing, as the review's
/// band holds its buttons, at the section's own side insets so the button's
/// edge lines up with the words above it. Only the bar's height and rule
/// are shared with the other columns; its insets belong to the panel.
///
/// Drawn only while there is a move to hold. The foot bars share one line
/// so that the rows in them, and their buttons, sit on one center line
/// across the window; an empty bar holds no row, and kept on that line it
/// would draw only a rule over 32pt of nothing under the section's words. Laid over the terminal
/// above a session's foot bar, the panel's bar is off that line anyway
/// (`ChangesPanelPlacement`), and the session's column already drops its
/// bar for a shell pane, where it has nothing to hold. So with no move the
/// section's ground runs to the panel's foot, and the bar comes in, with
/// the line, when a move does.
struct CommitAndPRFootBar: View {
    let action: CommitAndPRModel.FootAction?
    var fill: Color = .clear
    let perform: (CommitAndPRModel.FootAction) -> Void

    var body: some View {
        if let action {
            SupervisionFootBar(
                fill: fill,
                leadingInset: WeirLayout.Supervision.commitSectionInsets.leading,
                trailingInset: WeirLayout.Supervision.commitSectionInsets.trailing
            ) {
                CommitAndPRFootButton(action: action, perform: perform)
            }
        }
    }
}

/// The one button in the changes panel's foot bar
/// (`CommitAndPRModel.footAction`).
struct CommitAndPRFootButton: View {
    let action: CommitAndPRModel.FootAction
    let perform: (CommitAndPRModel.FootAction) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            button
                .buttonStyle(.supervisionSecondary)
        }
    }

    @ViewBuilder
    private var button: some View {
        switch action {
        case .showCurrentDiff:
            Button("Show Current Diff") {
                perform(.showCurrentDiff)
            }
            .accessibilityLabel(Text("Show Current Diff"))
        case let .createPullRequest(create):
            Button("Create PR") {
                perform(.createPullRequest(create))
            }
            .disabled(!create.isAvailable)
            .accessibilityLabel(Text("Create PR"))
            // The reason shows right above the bar; VoiceOver reads it with
            // the button it is about.
            .accessibilityHint(Text(verbatim: Self.blockerText(create, locale: locale)))
        case let .openPullRequest(request):
            Button {
                perform(.openPullRequest(request))
            } label: {
                Text("Open on \(request.forge.displayName)")
            }
        case let .openExternalTool(tool):
            Button {
                perform(.openExternalTool(tool))
            } label: {
                Text("Open in \(tool.name)")
            }
            .accessibilityLabel(Text("Open in \(tool.name)"))
        }
    }

    /// Why "Create PR" cannot be pressed, for VoiceOver's hint; empty while
    /// it can.
    static func blockerText(_ create: CommitAndPRModel.Create, locale: Locale) -> String {
        if case let .blocked(blocker) = create {
            CommitAndPRText.blocker(blocker, locale: locale)
        } else {
            ""
        }
    }
}
