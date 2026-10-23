// NewSessionSheet.swift
// Limpid — the new worktree sheet: the branch, its base and fetch, the files, the setup, what opens, the folder.

import AppKit
import SwiftUI

/// The new worktree sheet: a form of two columns, the labels
/// right-aligned and muted in the leading one and the controls beside them,
/// each control the rest of the row. It only makes a worktree: the
/// branch (new, existing, or a pull request's), its base, whether to fetch
/// first, copy the files Git ignores, and run the setup, what opens once it
/// is made (an agent, a shell, or nothing), and the folder. What arrives after it
/// opens never changes its height (`form`). "Create" (⌘⏎) makes the
/// worktree while the sheet waits, so a failure of git is answered here;
/// the copy, the setup, and what opens then go on in the worktree's row
/// (`SessionLaunchStore`).
struct NewSessionSheet: View {
    let request: NewSessionSheetRequest
    @Environment(WorkspaceSession.self) private var session
    @Environment(SessionLaunchStore.self) private var launches
    /// The window the sheet was opened in, whose selection the new
    /// worktree lands in. Handed to the sheet by the window, which
    /// presents it.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    /// Holds what the sheet remembers (`newSession`).
    @Environment(SettingsStore.self) private var settingsStore
    @State private var model: NewSessionModel?
    @State private var isCreating = false
    @State private var failure: DisplayText?
    /// The fetch the sheet started, which Create waits for.
    @State private var fetchTask: Task<Void, Never>?
    /// Whether that fetch still runs, whatever the box says now.
    @State private var isFetchRunning = false
    /// Create pressed while the fetch runs: nothing is made yet.
    @State private var isWaitingForFetch = false
    /// Whether the open pull requests were asked for: once a sheet.
    @State private var hasListedPullRequests = false
    /// The forge side of a pull request's worktree, shared with the
    /// pull request marks; `nil` in a demo run, which offers none.
    @Environment(\.prStatusSyncer) private var prStatusSyncer
    /// Create, waiting for the fetch or making the worktree; Cancel drops
    /// it while it waits.
    @State private var createTask: Task<Void, Never>?
    /// The sheet's own window, which the folder panel hangs from.
    @State private var hostWindow = HostWindowReference()
    @FocusState private var isBranchFocused: Bool

    /// `model` is the form already loaded, for a test that measures the
    /// sheet without a repository to load it from; the window passes
    /// none, and the sheet loads its own (`load`).
    init(request: NewSessionSheetRequest, model: NewSessionModel? = nil) {
        self.request = request
        _model = State(initialValue: model)
    }

    private var project: Project? {
        session.project(request.projectID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LimpidLayout.Supervision.newSessionSheetSpacing) {
            // Each block is bounded to the sheet's width: a block wider
            // than the sheet would widen the whole stack, which the sheet's
            // fixed width then centers, cutting every block on both sides.
            Group {
                SupervisionSheetHeader(title: Text(WorktreeText.sheetTitle(project: project?.name ?? "")))
                if let model = Binding($model) {
                    form(model)
                        // Waiting for the fetch, the fields stay as Create
                        // was pressed with them.
                        .disabled(isWaitingForFetch)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
                footer
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        // While git works, the fields are what it was given.
        .disabled(isCreating)
        .padding(LimpidLayout.Supervision.newSessionSheetInsets)
        .frame(width: LimpidLayout.Supervision.newSessionSheetWidth)
        // Nothing in the sheet is animated by a transaction: rows change at
        // once, so the sheet's height changes in one step. The segments'
        // pills slide on their own clock (`SupervisionSegmentedPicker`).
        .transaction { $0.animation = nil }
        .background(NewSessionKeyMonitor(onCreate: startCreating))
        .background(HostWindowReader(reference: hostWindow))
        .task { await load() }
        // Closed while git works, the worktree would still be made and
        // its failure seen by no one.
        .interactiveDismissDisabled(isCreating)
        .onChange(of: model?.needsFetch) { _, needsFetch in
            if needsFetch == true {
                startFetch()
            }
        }
        .task(id: pullRequestLookupKey) { await lookUpPullRequest() }
        .task(id: isListingPullRequests) { await listPullRequests() }
        .onChange(of: project) { _, project in
            // The placement changes from the folder's menu, the setup and
            // the files in the project's settings in another window. Not
            // while creating: the new worktree changes the project too, and
            // the name would turn to the next free one as the sheet closes.
            if let project, !isCreating {
                model?.setProject(project)
            }
        }
    }

    // MARK: - Form

    private func form(_ bound: Binding<NewSessionModel>) -> some View {
        let model = bound.wrappedValue
        let metrics = LimpidLayout.Supervision.self
        // The sheet's height never changes on its own: macOS 26 keeps a
        // sheet centered on its window, so a taller sheet moves up, the
        // control the pointer is over with it. What comes in after it
        // opens (the carry's count, the fetch's answer, a pull request's)
        // lands in room kept for it. A line keeps no room for what it does
        // not say, though:
        // an empty line read as a gap between the rows. So a line the
        // person's own typing or choice brings or lengthens may change the
        // height, and git's failure makes the sheet taller.
        //
        // Rows rather than a `Grid`: a grid splits its width equally
        // between its columns before it sizes them, so the labels' column
        // took what its words needed and the controls' column only its
        // half, leaving the rest of the sheet empty and cutting the
        // segments' words; the rows it had measured at that narrower width
        // kept their wrapped heights as gaps once laid out. A row gives
        // its control all that its label leaves (`formRow`).
        return VStack(alignment: .leading, spacing: metrics.newSessionRowSpacing) {
            formRow(Self.sourceLabel) {
                sourcePicker(bound)
            }
            formRow(model.source == .pullRequest ? Self.pullRequestLabel : Self.branchLabel, alignment: .top) {
                VStack(alignment: .leading, spacing: metrics.newSessionInlineSpacing) {
                    switch model.source {
                    case .newBranch: branchField(bound)
                    case .existingBranch: existingBranchMenu(bound)
                    case .pullRequest: pullRequestField(bound)
                    }
                    branchStatusLine(model)
                }
            }
            formRow(Self.baseLabel, alignment: .top) {
                VStack(alignment: .leading, spacing: metrics.newSessionInlineSpacing) {
                    baseMenu(bound)
                    baseStatusLine(model)
                }
            }
            formRow(nil, alignment: .top) {
                checkboxes(bound)
            }
            formRow(Self.openLabel) {
                NewSessionOpenMenu(
                    title: Self.openLabel,
                    choice: binding(bound, \.open, set: { $0.open = $1 }),
                    agents: model.openMenuAgents
                )
            }
            formRow(Self.folderLabel) {
                folderCell(model)
            }
            if let failure {
                formRow(nil, alignment: .top) {
                    NewSessionFailureBox(failure: failure)
                }
            }
        }
    }

    /// One row of the form: `title` in the labels' column, then `content`
    /// across the rest of the row. Every row's label cell holds every label
    /// the form has, unseen, so the column is as wide as the widest label in
    /// every row, whatever the row shows, and the controls never move
    /// sideways. A row whose control carries a line under it aligns at the
    /// top, the label as tall as the control so it sits level with it; the
    /// others center the label on the control.
    private func formRow(
        _ title: LocalizedStringResource?,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: alignment, spacing: LimpidLayout.Supervision.newSessionColumnSpacing) {
            ZStack(alignment: .trailing) {
                ForEach(Self.rowLabels.indices, id: \.self) { index in
                    rowLabel(Self.rowLabels[index])
                }
                .hidden()
                .accessibilityHidden(true)
                if let title {
                    rowLabel(title, height: alignment == .top ? LimpidLayout.Supervision.sheetFieldHeight : nil)
                }
            }
            content()
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let sourceLabel = LocalizedStringResource(
        "Start From",
        comment: "New worktree sheet: label of where the branch comes from, a new one or an existing one"
    )
    private static let branchLabel = LocalizedStringResource("Branch Name")
    private static let pullRequestLabel = LocalizedStringResource(
        "Pull Request",
        comment: "New worktree sheet: the source's segment that checks out a pull request's branch, and the label of its number's row"
    )
    private static let baseLabel = LocalizedStringResource(
        "Base Branch",
        comment: "New worktree sheet: label of the branch the new one starts from"
    )
    private static let openLabel = LocalizedStringResource(
        "Open After Creating",
        comment: "New worktree sheet: label of what opens in the worktree once it is made"
    )
    private static let folderLabel = LocalizedStringResource(
        "Placement",
        comment: "New worktree sheet: label of where the worktree's folder goes"
    )
    /// Every label of the leading column, which sets its width.
    static let rowLabels = [sourceLabel, branchLabel, pullRequestLabel, baseLabel, openLabel, folderLabel]

    /// A label of the leading column: muted, at the sheet's label size.
    /// `height` is the control's beside it, for a row aligned at the top.
    private func rowLabel(_ title: LocalizedStringResource, height: CGFloat? = nil) -> some View {
        Text(title)
            .font(.supervision(LimpidLayout.Supervision.sheetLabelFontSize))
            .foregroundStyle(SupervisionTokens.muted.color)
            .lineLimit(1)
            .fixedSize()
            .frame(height: height)
    }
}

/// The form's rows, the footer, and what the sheet does, apart from the
/// layout above so each part reads on its own.
extension NewSessionSheet {

    // MARK: - Source and branch

    private func sourcePicker(_ bound: Binding<NewSessionModel>) -> some View {
        let model = bound.wrappedValue
        // Off where no CLI can read a request, the reason its tooltip and
        // its VoiceOver value.
        let unavailable = NewSessionProblemText.pullRequestsUnavailable(model.context.pullRequests).map { Text($0) }
        return SupervisionSegmentedPicker(
            Text(Self.sourceLabel),
            selection: binding(bound, \.source, set: { $0.source = $1 }),
            options: NewSessionModel.Source.allCases.map { source in
                source == .pullRequest
                    ? .init(
                        source,
                        Self.sourceTitle(source),
                        help: unavailable,
                        accessibilityValue: unavailable,
                        isEnabled: model.canChoosePullRequest
                    )
                    : .init(source, Self.sourceTitle(source))
            }
        )
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    /// A source's segment: its words, which the layout test measures
    /// against the segment's share of the row.
    static func sourceTitle(_ source: NewSessionModel.Source) -> Text {
        switch source {
        case .newBranch:
            Text("New Branch", comment: "New worktree sheet: the worktree gets a new branch")
        case .existingBranch:
            Text("Existing Branch", comment: "New worktree sheet: the worktree checks out a local branch")
        case .pullRequest:
            // The row's own label: the segment and the row it brings say
            // the same words.
            Text(pullRequestLabel)
        }
    }

    /// The pull request's number, typed (`12`, `#12`, a link) or picked from
    /// the open ones beside it; it is looked up as it is typed.
    private func pullRequestField(_ bound: Binding<NewSessionModel>) -> some View {
        let model = bound.wrappedValue
        return HStack(spacing: LimpidLayout.Supervision.newSessionInlineSpacing) {
            TextField(
                text: binding(bound, \.pullRequestText, set: { $0.setPullRequestText($1) }),
                prompt: Text(verbatim: "#123").foregroundStyle(SupervisionTokens.muted.color)
            ) {
                Text("Pull request number", comment: "New worktree sheet, VoiceOver: the pull request number's field")
            }
            .labelsHidden()
            .font(.supervisionCode(beside: .label))
            .focused($isBranchFocused)
            .modifier(NewSessionSheetField(isFocused: isBranchFocused) { isBranchFocused = true })
            Menu {
                if model.openPullRequests.isEmpty {
                    Text("No Open Pull Requests", comment: "New worktree sheet: the menu of open pull requests, with none")
                }
                ForEach(model.openPullRequests, id: \.number) { head in
                    Button {
                        bound.wrappedValue.choosePullRequest(head)
                    } label: {
                        Text(verbatim: "#\(head.number)  \(head.title)")
                    }
                }
            } label: {
                NewSessionMenuFace(fillsWidth: false) {
                    Image(systemName: "list.bullet")
                        .accessibilityHidden(true)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!model.canChoosePullRequest)
            .help(Text(Self.openPullRequestsTitle))
            .accessibilityLabel(Text(Self.openPullRequestsTitle))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private static let openPullRequestsTitle = LocalizedStringResource(
        "Open Pull Requests",
        comment: "New worktree sheet: tooltip and VoiceOver label of the menu that lists the open pull requests to pick from"
    )

    /// The new branch's name. Empty, it takes the suggested name, which
    /// the placeholder shows.
    private func branchField(_ bound: Binding<NewSessionModel>) -> some View {
        let model = bound.wrappedValue
        return TextField(
            text: binding(bound, \.branchName, set: { $0.setBranchName($1) }),
            prompt: Text(verbatim: model.suggestedBranchName)
                .foregroundStyle(SupervisionTokens.muted.color)
        ) {
            Text("Branch Name", comment: "New worktree sheet, VoiceOver: the branch's field")
        }
        .labelsHidden()
        .font(.supervisionCode(beside: .label))
        .focused($isBranchFocused)
        .modifier(NewSessionSheetField(isFocused: isBranchFocused) { isBranchFocused = true })
    }

    /// The local branches a worktree can check out, one chosen.
    private func existingBranchMenu(_ bound: Binding<NewSessionModel>) -> some View {
        let model = bound.wrappedValue
        return Menu {
            ForEach(model.existingBranches, id: \.self) { branch in
                Toggle(isOn: Binding(
                    get: { bound.wrappedValue.existingBranch == branch },
                    set: { _ in bound.wrappedValue.existingBranch = branch }
                )) {
                    Text(verbatim: branch)
                }
            }
        } label: {
            NewSessionMenuFace(fillsWidth: true) {
                Text(verbatim: model.existingBranch ?? "—")
                    .font(.supervisionCode(beside: .label))
                    .lineLimit(1)
                    .supervisionTruncation(.branch)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .disabled(model.existingBranches.isEmpty)
        .accessibilityLabel(Text(Self.existingBranchesTitle))
        .accessibilityValue(Text(verbatim: model.existingBranch ?? ""))
    }

    private static let existingBranchesTitle = LocalizedStringResource(
        "Existing Branches",
        comment: "New worktree sheet: tooltip and VoiceOver label of the branch field's list of local branches"
    )

    /// The line under the branch (`NewSessionModel.branchLine`), as tall as
    /// what it says and never less than one line: it says something from
    /// the moment the sheet opens, and a second line it keeps empty for a
    /// longer sentence read as a gap under the first. It changes height
    /// only as the person types or chooses; a pull request's number, whose
    /// answer comes later, keeps both lines from the moment it is typed
    /// (`awaitsPullRequestAnswer`). Red only for what stops Create; else
    /// what Create will do, muted, the branches it names in the code face.
    private func branchStatusLine(_ model: NewSessionModel) -> some View {
        let lines = model.awaitsPullRequestAnswer ? NewSessionStatusLine.lineCount : 1
        return ZStack(alignment: .topLeading) {
            NewSessionStatusLine.reservedSpace(lines: lines)
            switch model.branchLine {
            case let .problem(problem):
                if let text = NewSessionProblemText.text(problem, model: model, locale: locale) {
                    statusText([.plain(text)], color: SupervisionTokens.stoppedText.color)
                }
            case let .outcome(outcome):
                statusText(NewSessionModel.resultRuns(outcome, locale: locale), color: SupervisionTokens.muted.color)
            case let .lookingUp(number):
                statusText([.plain(LocalizedStringResource(
                    "Looking up PR #\(number)…",
                    comment: "New worktree sheet: gh or glab is reading the pull request typed"
                ).resolved(in: locale))], color: SupervisionTokens.muted.color)
            case .empty:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(NewSessionStatusLine.font)
    }

    /// The line under the base, only while it says something: most bases
    /// are local, and a fetch says nothing of them, so room kept for it
    /// read as a gap. It comes and goes with the person's own choice (the
    /// fetch's box, the base, the source), at once like every row
    /// (`.transaction` in `body`), so nothing moves under Reduce Motion
    /// either. While it is there it keeps the room of the longest form the
    /// fetch's answer can give it (`NewSessionModel.baseLineForms`), which
    /// comes on its own after the sheet opens. A pull request's line,
    /// whose words come with the request, has its two lines from the
    /// moment its number is typed (`awaitsPullRequestAnswer`).
    @ViewBuilder
    private func baseStatusLine(_ model: NewSessionModel) -> some View {
        if model.baseLine != nil || model.awaitsPullRequestAnswer {
            let isWarning = model.source == .pullRequest
                ? model.foundPullRequest.map { $0.state != .open } ?? false
                : model.fetchState == .failed
            ZStack(alignment: .topLeading) {
                if model.awaitsPullRequestAnswer {
                    NewSessionStatusLine.reservedSpace()
                }
                ForEach(model.baseLineForms(locale: locale), id: \.self) { form in
                    baseLineText(form, isWarning: isWarning)
                        .hidden()
                        .accessibilityHidden(true)
                }
                if let line = model.baseLine {
                    baseLineText(NewSessionModel.baseLineText(line, locale: locale), isWarning: isWarning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(NewSessionStatusLine.font)
        }
    }

    /// `text` under the base, in muted words after an amber caution mark
    /// when it warns.
    @ViewBuilder
    private func baseLineText(_ text: String, isWarning: Bool) -> some View {
        if isWarning {
            Label {
                statusText([.plain(text)], color: SupervisionTokens.muted.color)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(SupervisionTokens.waiting.color)
                    .accessibilityHidden(true)
            }
        } else {
            statusText([.plain(text)], color: SupervisionTokens.muted.color)
        }
    }

    private func statusText(_ runs: [NewSessionModel.LineRun], color: Color) -> some View {
        NewSessionStatusLine(runs: runs, color: color)
    }

    // MARK: - Base

    /// The bases offered, the one in use checked: with the fetch on, the
    /// remote's branch first (`origin/main`). An existing branch has its
    /// own history, so the menu takes no choice for one.
    private func baseMenu(_ bound: Binding<NewSessionModel>) -> some View {
        let model = bound.wrappedValue
        return Menu {
            ForEach(model.bases, id: \.self) { base in
                Toggle(isOn: Binding(
                    get: { bound.wrappedValue.base == base },
                    set: { _ in bound.wrappedValue.baseName = base.name }
                )) {
                    baseLabel(base)
                }
            }
        } label: {
            NewSessionMenuFace(fillsWidth: true) {
                Text(verbatim: baseFace(model))
                    .font(.supervisionCode(beside: .label))
                    .lineLimit(1)
                    .supervisionTruncation(.branch)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .disabled(model.source != .newBranch || model.bases.isEmpty)
        .accessibilityLabel(Text(Self.baseLabel))
        .accessibilityValue(model.source == .pullRequest ? Text(verbatim: baseFace(model)) : model.base
            .map(baseLabel) ?? Text(verbatim: ""))
    }

    /// The base menu's face: the base in use, or for a pull request the
    /// branch it comes from, which is its history.
    private func baseFace(_ model: NewSessionModel) -> String {
        if model.source == .pullRequest {
            return model.pullRequestHeadName ?? "—"
        }
        return model.base?.name ?? "—"
    }

    /// A base as the menu lists it: the current worktree's branch says so.
    private func baseLabel(_ base: NewSessionModel.Base) -> Text {
        base.isCurrentWorktree
            ? Text(
                "\(base.name) (Current Worktree)",
                comment: "New worktree sheet: a base, the branch of the worktree the window shows; the argument is the branch"
            )
            : Text(verbatim: base.name)
    }

    // MARK: - Checkboxes

    /// Fetch first, copy the files Git ignores, run the setup: each with
    /// what it acts on under it. One with nothing to act on is off and
    /// says where to set it.
    private func checkboxes(_ bound: Binding<NewSessionModel>) -> some View {
        let model = bound.wrappedValue
        return VStack(alignment: .leading, spacing: LimpidLayout.Supervision.spaceS) {
            NewSessionCheckbox(
                title: LocalizedStringResource(
                    "Fetch before creating (git fetch)",
                    comment: "New worktree sheet: fetch the base's remote before making the worktree"
                ),
                isOn: Binding(
                    get: { bound.wrappedValue.fetches && bound.wrappedValue.context.fetchRemote != nil },
                    set: { bound.wrappedValue.fetches = $0 }
                ),
                hint: Text(LocalizedStringResource(
                    "Creates the worktree from the latest state of the remote branch, not from an older local copy.",
                    comment: "New worktree sheet, VoiceOver: hint of the fetch checkbox"
                )),
                isToggleEnabled: model.context.fetchRemote != nil
            ) {
                EmptyView()
            }
            NewSessionCheckbox(
                title: LocalizedStringResource(
                    "Copy ignored files from the project folder",
                    comment: "New worktree sheet: copy the files Git ignores that Project Settings names into the new worktree"
                ),
                isOn: Binding(
                    get: { bound.wrappedValue.copiesFiles && bound.wrappedValue.canCopyFiles },
                    set: { bound.wrappedValue.copiesFiles = $0 }
                ),
                // The window's locale joins the paths (「、」 in Japanese).
                hint: model.canCopyFiles ? Text(model.filesToCopy, format: .list(type: .and, width: .narrow)) : nil,
                isToggleEnabled: model.canCopyFiles
            ) {
                if model.canCopyFiles {
                    // A list, not a sentence: past two lines its end goes,
                    // and the tooltip has it whole.
                    Text(verbatim: model.filesToCopy.joined(separator: "  "))
                        .font(.supervisionCode(beside: .meta))
                        .lineLimit(NewSessionStatusLine.lineCount)
                        .truncationMode(.tail)
                        .help(Text(verbatim: model.filesToCopy.joined(separator: "\n")))
                } else {
                    Button {
                        openProjectSettings()
                    } label: {
                        Text(LocalizedStringResource(
                            "Choose files to copy in Project Settings…",
                            comment: "New worktree sheet: under the copy checkbox when the project names no files; opens Project Settings"
                        ))
                        .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            carryCheckbox(bound)
            NewSessionCheckbox(
                title: LocalizedStringResource(
                    "Run setup commands",
                    comment: "New worktree sheet: run the project's setup commands in the new worktree"
                ),
                isOn: Binding(
                    get: { bound.wrappedValue.runsSetup && bound.wrappedValue.canRunSetup },
                    set: { bound.wrappedValue.runsSetup = $0 }
                ),
                hint: model.canRunSetup ? Text(verbatim: model.setupCommands.joined(separator: "; ")) : nil,
                isToggleEnabled: model.canRunSetup
            ) {
                // No line at all without commands: an empty one would
                // still stand a line tall under the box.
                if model.canRunSetup {
                    Text(verbatim: model.setupCommands.joined(separator: " · "))
                        .font(.supervisionCode(beside: .meta))
                        .lineLimit(NewSessionStatusLine.lineCount)
                        .truncationMode(.tail)
                        .help(Text(verbatim: model.setupCommands.joined(separator: "\n")))
                }
            }
        }
    }

    /// Carry the shown worktree's uncommitted changes: named by its
    /// branch, with how many files and that a failure leaves it as it was
    /// under it. Off, and saying why, when the window shows no row of this
    /// project or the row has nothing to carry.
    private func carryCheckbox(_ bound: Binding<NewSessionModel>) -> some View {
        let model = bound.wrappedValue
        let source = model.context.carrySource
        let title = if let source {
            LocalizedStringResource(
                "Move uncommitted changes from \(NewSessionModel.shownName(source.name))",
                comment: "New worktree sheet: move the shown worktree's uncommitted changes into the new one; the argument is its branch"
            )
        } else {
            LocalizedStringResource(
                "Move uncommitted changes",
                comment: "New worktree sheet: the carry's checkbox while the window shows no worktree of this project"
            )
        }
        return NewSessionCheckbox(
            title: title,
            isOn: Binding(
                get: { bound.wrappedValue.carriesChanges && bound.wrappedValue.canCarryChanges },
                set: { bound.wrappedValue.carriesChanges = $0 }
            ),
            hint: source.map { source in
                Text(LocalizedStringResource(
                    "Moves staged and unstaged changes and untracked files into the new worktree, and removes them from \(source.name).",
                    comment: "New worktree sheet, VoiceOver: hint of the carry's checkbox; the argument is the shown worktree's branch"
                ))
            },
            isToggleEnabled: model.canCarryChanges
        ) {
            // The count comes after the sheet opens, and lengthens the line:
            // it stands over every form it can take, unseen, so it is as tall
            // as the longest from the start and the sheet never grows.
            ZStack(alignment: .topLeading) {
                ForEach(model.carryLineForms(locale: locale), id: \.self) { form in
                    Text(verbatim: form)
                        .hidden()
                        .accessibilityHidden(true)
                }
                Text(verbatim: model.carryLine(locale: locale))
            }
        }
    }

    /// Project Settings, where the files to copy are named: the sheet
    /// closes first, as one sheet stands over a window at a time.
    private func openProjectSettings() {
        dismiss()
        window.commands.send(.openProjectSettings(nil))
    }

    // MARK: - Folder

    /// Where the worktree goes: the placement's menu, named by the
    /// placement in use, which changes the project's setting as its
    /// settings do; then the path it gives, muted and monospaced, cut in
    /// its middle, where a path is least read. The menu comes first, so the
    /// path takes what is left of the line.
    private func folderCell(_ model: NewSessionModel) -> some View {
        HStack(spacing: LimpidLayout.Supervision.newSessionInlineSpacing + LimpidLayout.Supervision.spaceHairline) {
            placementMenu
            Text(verbatim: model.destination.map { PathFormatting.abbreviateHome($0.path) } ?? "")
                .font(.supervisionCode(beside: .body))
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
                .supervisionTruncation(.path)
                .textSelection(.enabled)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    /// The placements as Project Settings lists them too
    /// (`WorktreePlacementMenuItems`); the folder panel hangs from this sheet.
    private var placementMenu: some View {
        Menu {
            WorktreePlacementMenuItems(project: project, onChoose: choosePlacement, onChooseFolder: chooseFolder)
        } label: {
            NewSessionMenuFace(fillsWidth: false) {
                Text(display: placementShortTitle)
                    .lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(Self.placementTitle))
        .accessibilityLabel(Text(Self.placementTitle))
        .accessibilityValue(Text(display: placementShortTitle))
    }

    /// The menu's face: the placement in use, short.
    private var placementShortTitle: DisplayText {
        WorktreePlacementActions.shortTitle(of: project?.worktreePlacement ?? .siblingPrefixed)
    }

    private static let placementTitle = LocalizedStringResource(
        "Worktree Placement",
        comment: "New worktree sheet: tooltip and VoiceOver label of the folder's placement menu"
    )

    /// Changes the project's placement; the destination follows through
    /// `onChange(of: project)`. The custom item only lists while its folder
    /// is the placement, so choosing it keeps that folder.
    private func choosePlacement(_ choice: WorktreePlacementActions.Choice) {
        guard let project else { return }
        WorktreePlacementActions.apply(
            choice,
            customParent: WorktreePlacementActions.customParent(of: project.worktreePlacement),
            to: project.id,
            in: session,
            attachedTo: hostWindow.window
        )
    }

    /// Asks for the folder new worktrees go in, starting at the one in use.
    private func chooseFolder() {
        guard let project else { return }
        WorktreePlacementActions.chooseCustomParent(
            startingAt: WorktreePlacementActions.customParent(of: project.worktreePlacement),
            for: project.id,
            in: session,
            attachedTo: hostWindow.window
        )
    }

    // MARK: - Footer

    /// ⌥⌘N's note at the start, muted, as a note rather than a button's
    /// key: what git is doing takes its place while the sheet waits. Both
    /// buttons at the end, Cancel first, as a macOS dialog has them.
    private var footer: some View {
        SupervisionSheetFooter {
            if isCreating || isWaitingForFetch {
                ProgressView()
                    .controlSize(.small)
                Group {
                    if isWaitingForFetch {
                        Text(LocalizedStringResource(
                            "Fetching…",
                            comment: "New worktree sheet: while git fetches the base's remote, under the base and in the footer"
                        ))
                    } else {
                        Text("Creating the worktree…", comment: "New worktree sheet: git is adding the worktree")
                    }
                }
                .font(.supervision(.caption))
                .foregroundStyle(SupervisionTokens.muted.color)
            } else if !window.newWorktreeSheet.introducesInstantKey,
                      let shortcut = settingsStore.settings.keyboard.shortcut(for: .newWorktreeNow)
            {
                // Left out while the note above the sheet introduces the
                // same keys: said once, at the top, where it is read first.
                Text(LocalizedStringResource(
                    "\(shortcut.displayString) creates a worktree without showing this sheet.",
                    comment: "New worktree sheet: the note at the footer's start; the argument is the shortcut, as in ⌥⌘N"
                ))
                .font(.supervision(.caption))
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
            }
        } trailing: {
            Button("Cancel", role: .cancel) { cancel() }
                .buttonStyle(.supervisionSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
            Button(action: startCreating) {
                Text("Create", comment: "New worktree sheet: makes the worktree")
            }
            // Taken first by `NewSessionKeyMonitor`, with Return; named
            // here so the button says its key to VoiceOver and in its
            // tooltip.
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(SupervisionPrimaryButtonStyle())
            .disabled(isCreating || isWaitingForFetch || model?.plan == nil)
            .help(Text("Create (⌘⏎)", comment: "New worktree sheet: tooltip of Create"))
        }
    }

    /// A field of the model. An edit leaves git's last failure where it is:
    /// the box going would shrink the sheet, which macOS keeps centered, and
    /// move what was just clicked from under the pointer. The next "Create"
    /// clears it as it tries again (`create`).
    private func binding<Value>(
        _ model: Binding<NewSessionModel>,
        _ path: KeyPath<NewSessionModel, Value>,
        set: @escaping (inout NewSessionModel, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { model.wrappedValue[keyPath: path] },
            set: { value in
                set(&model.wrappedValue, value)
            }
        )
    }

    // MARK: - Actions

    private var stores: NewSessionStores {
        var stores = NewSessionStores(session: session, launches: launches, settingsStore: settingsStore)
        stores.pullRequests = prStatusSyncer?.pullRequests
        return stores
    }

    private func load() async {
        failure = request.failure
        guard model == nil, let loaded = await NewSessionActions.load(request, window: window, stores: stores) else { return }
        // A second load that finished first keeps its form.
        guard model == nil else { return }
        model = loaded
        startFetch()
        // Asked after the form is up: `glab` answers over the network.
        let stores = stores
        Task {
            let availability = await NewSessionActions.pullRequestAvailability(for: loaded, stores: stores)
            model?.setPullRequestAvailability(availability)
        }
        Task {
            let count = await NewSessionActions.countCarryChanges(for: loaded, stores: stores)
            model?.setCarryCount(count)
        }
        // The form is new in this update: the keys go to the branch's
        // field once its text view is in the window.
        KeyboardHandoff.afterResponderSettles {
            isBranchFocused = true
        }
    }

    /// Fetches the base's remote as the sheet opens, or as the base comes
    /// to need it (the fetch turned on, the default base chosen again), so
    /// how far the local branch is behind is said before Create. A fetch
    /// still running is never started twice: Git's own run cannot be
    /// stopped, and two in one repository clash on its locks. Turned off
    /// and on again, the sheet waits for the one that runs.
    private func startFetch() {
        guard let current = model, current.needsFetch, current.fetchState == .none else { return }
        model?.fetchState = .fetching
        guard !isFetchRunning else { return }
        isFetchRunning = true
        let stores = stores
        fetchTask = Task {
            let state = await NewSessionActions.fetch(for: current, stores: stores)
            isFetchRunning = false
            guard model?.fetchState == .fetching else { return }
            // The base was changed to a local one meanwhile: the result is
            // still the remote's, kept for when it is chosen again. With the
            // fetch turned off, nothing is fetching any more.
            model?.fetchState = model?.fetches == true ? state : .none
        }
    }

    /// The number to look up while the field names one not looked up yet,
    /// from a pull request source a CLI can read; else `nil`, which looks
    /// up nothing.
    private var pullRequestLookupKey: Int? {
        guard let model, model.source == .pullRequest, case .available = model.context.pullRequests,
              model.pullRequestLinkElsewhere == nil, case let .lookingUp(number) = model.pullRequest
        else { return nil }
        return number
    }

    /// Looks up the number the field names, once typing pauses: each key
    /// would otherwise start a CLI. A later number cancels this one, and an
    /// answer for a number no longer typed is dropped by the model.
    private func lookUpPullRequest() async {
        guard let number = pullRequestLookupKey, let current = model else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled,
              let lookup = await NewSessionActions.lookUpPullRequest(number, for: current, stores: stores) else { return }
        model?.setPullRequestLookup(lookup, for: number)
    }

    /// Whether a pull request source a CLI can read is chosen, which lists
    /// the open requests once.
    private var isListingPullRequests: Bool {
        guard let model, model.source == .pullRequest, case .available = model.context.pullRequests else { return false }
        return true
    }

    /// The open requests, once a sheet; asked again only when the person
    /// left the source before they came.
    private func listPullRequests() async {
        guard isListingPullRequests, !hasListedPullRequests, let current = model else { return }
        let heads = await NewSessionActions.openPullRequests(for: current, stores: stores)
        guard !Task.isCancelled else { return }
        model?.openPullRequests = heads
        hasListedPullRequests = true
    }

    /// "Create", from the button, ⌘⏎, or Return. Set before the task
    /// starts, so a second key finds it. A fetch still running is waited
    /// for, and the worktree starts from what it brings; meanwhile nothing
    /// is made, so Cancel still closes the sheet.
    private func startCreating() {
        guard !isCreating, !isWaitingForFetch, model?.plan != nil else { return }
        startFetch()
        // A fetch that runs still is waited for whatever the source is now:
        // a pull request's head is fetched from the same repository, and two
        // fetches in one repository clash on its locks.
        guard model?.isFetching == true || isFetchRunning else {
            isCreating = true
            createTask = Task { await create() }
            return
        }
        isWaitingForFetch = true
        createTask = Task {
            await fetchTask?.value
            isWaitingForFetch = false
            guard !Task.isCancelled, model?.plan != nil else { return }
            isCreating = true
            await create()
        }
    }

    /// Cancel: closes the sheet, and drops a Create still waiting for the
    /// fetch, which has made nothing yet.
    private func cancel() {
        if isWaitingForFetch {
            createTask?.cancel()
        }
        dismiss()
    }

    private func create() async {
        guard let model else {
            isCreating = false
            return
        }
        failure = nil
        switch await NewSessionActions.create(model, request: request, window: window, stores: stores) {
        case .created:
            // `isCreating` stays on through the dismiss: the new worktree's
            // folder now exists, and the check would flash "already exists".
            dismiss()
        case .notReady:
            isCreating = false
        case let .failed(message, madeBranch):
            isCreating = false
            failure = message
            if let madeBranch {
                self.model?.useMadeBranch(madeBranch)
            }
        }
    }
}
