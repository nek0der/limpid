// ContainerSettingsSheet.swift
// Limpid — a project's settings sheet: name, color, root, worktree
// placement, the agents it routes, setup commands, the files to copy into
// new worktrees, test commands, and hidden
// worktrees. The supervision sheets' title and footer around a grouped Form.
// Auto-saves on every change — the only button is "Done".

import AppKit
import SwiftUI

struct ContainerSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceSession.self) private var session

    /// The project the sheet edits.
    let projectID: UUID
    /// The sheet's height, from the window it is shown over
    /// (`height(forWindowHeight:)`): a sheet taller than its window puts
    /// Done out of reach.
    let height: CGFloat

    @State private var nameDraft: String = ""
    /// The Setup Commands as a newline-separated string (one command
    /// per line). A step's `timeout` / `cwd` are set by hand in
    /// `state.json`; the sheet names them under the editor and keeps them
    /// with their line (`SetupCommandsDraft`).
    @State private var bootstrapDraft: String = ""
    /// The steps as the sheet opened, to say which lines an edit took
    /// their timeout or cwd from (`SetupCommandsDraft.droppedDetailCount`).
    @State private var openedBootstrap: [BootstrapItem] = []
    /// The test commands as the list the sheet edits; see `CheckCommandsDraft`.
    @State private var checksDraft = CheckCommandsDraft(commands: nil, defaults: AgentProviderRegistry.checkDefaults)
    /// The files to copy into new worktrees as the list the sheet edits;
    /// see `IgnoredFilesDraft`.
    @State private var filesDraft = IgnoredFilesDraft(patterns: nil)
    /// The Color row's picker. The sheet is a window of its own, where the
    /// main window's floating panels cannot draw, so it holds and draws its
    /// own: the same panel, hanging from the row's color dot.
    @State private var colorPanel = ContainerColorPresentation()
    /// The color dot's frame in global coordinates, which here are the
    /// sheet window's.
    @State private var colorDotFrame: CGRect = .zero
    /// This sheet's window: the folder panel for a custom placement hangs
    /// from it, and Done reads it to wait out text still being composed.
    @State private var hostWindow = HostWindowReference()

    /// `nil` once the project is closed from elsewhere while the sheet is
    /// up: the sheet then edits nothing until it is dismissed.
    private var project: Project? {
        session.project(projectID)
    }

    private var hiddenWorktrees: [Worktree] {
        project?.worktrees.filter(\.isHidden) ?? []
    }

    /// A hidden worktree by the name its row went by (`RowName`), which a
    /// name the person gave it keeps while it is hidden.
    private func hiddenRowName(_ worktree: Worktree) -> String {
        session.rowName(of: .worktree(projectID: projectID, worktreeID: worktree.id))?.text ?? worktree.label
    }

    /// The preferred height while the window has room, less a margin above
    /// and below the sheet as the window shrinks, down to the least. Before
    /// the first geometry pass the window's height is 0, and the sheet
    /// takes the preferred height rather than collapsing.
    static func height(forWindowHeight windowHeight: CGFloat) -> CGFloat {
        let metrics = LimpidLayout.Supervision.self
        guard windowHeight > 0 else { return metrics.projectSettingsSheetPreferredHeight }
        return max(
            metrics.projectSettingsSheetMinHeight,
            min(metrics.projectSettingsSheetPreferredHeight, windowHeight - metrics.sheetWindowMargin)
        )
    }

    /// Whether an input method is composing in `window`'s focused field:
    /// ⌘⏎ then belongs to the text being typed, as in the new worktree
    /// sheet (`NewSessionKey`), and does not close the sheet.
    static func isComposing(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? any NSTextInputClient)?.hasMarkedText() ?? false
    }

    /// The supervision sheets' shape: the title, the form that
    /// scrolls, and Done at the bottom right. Not a `NavigationStack`'s
    /// toolbar: a macOS sheet has no title bar, so a `.principal` title is
    /// never drawn.
    var body: some View {
        let metrics = LimpidLayout.Supervision.self
        VStack(spacing: 0) {
            SupervisionSheetHeader(title: Text(ProjectSettingsText.title(project: project?.name)))
                .padding(EdgeInsets(
                    top: metrics.sheetInsets.top,
                    leading: metrics.sheetInsets.leading,
                    bottom: 0,
                    trailing: metrics.sheetInsets.trailing
                ))
            form
            Divider()
            SupervisionSheetFooter {
                // Return breaks a line in the commands' editors, so Done
                // takes ⌘⏎, as the new worktree sheet's Create does.
                Button("Done") {
                    guard !Self.isComposing(in: hostWindow.window) else { return }
                    dismiss()
                }
                .buttonStyle(SupervisionPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .help(Text("Done (⌘⏎)", comment: "Project settings sheet: tooltip of Done"))
            }
            .padding(EdgeInsets(
                top: metrics.spaceM,
                leading: metrics.sheetInsets.leading,
                bottom: metrics.spaceM,
                trailing: metrics.sheetInsets.trailing
            ))
        }
        .frame(width: metrics.sheetWidth, height: height)
        .background(HostWindowReader(reference: hostWindow))
        // Every change is saved as it is made, so Esc is Done too.
        // The commands' editors take Esc first and pass it on (`onCancel`).
        .onExitCommand { dismiss() }
        .overlay {
            // The dot toggles the panel itself, so a press on it is left to
            // the dot rather than closing the panel as a click outside.
            ContainerColorPanelHost(isAnchorPressLeftToAnchor: true)
                .environment(colorPanel)
        }
        .onAppear(perform: loadDrafts)
    }

    private var form: some View {
        Form {
            generalSection
            worktreesSection
            RoutedAgentsSection(
                claudeEnabled: project?.routeClaudeWorktrees ?? true,
                codexEnabled: project?.routeCodexWorktrees ?? true,
                onClaudeChange: applyRouteClaudeToggle,
                onCodexChange: applyRouteCodexToggle
            )
            bootstrapSection
            filesSection
            checksSection
            if !hiddenWorktrees.isEmpty {
                hiddenSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // The headings as written, in title case, never a style's capitals.
        .textCase(nil)
        // The window hands the accent down as `.tint`, which on macOS 26
        // also colors pop-up values and bordered buttons. As in the
        // Settings window (`SettingsForm`), the form drops it and the
        // switches put it back (`RoutedAgentsSection`).
        .tint(nil as Color?)
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            HStack {
                Text("Name")
                Spacer()
                TextField("", text: $nameDraft)
                    // The row's label is a Text beside the field, which
                    // VoiceOver does not take as the field's name.
                    .accessibilityLabel(Text("Name"))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 260)
                    .onSubmit { commitName() }
                    .onDisappear { commitName() }
            }
            HStack {
                Text("Color")
                Spacer()
                Button {
                    if colorPanel.request == nil {
                        colorPanel.open(projectID: projectID, anchor: colorDotFrame)
                    } else {
                        colorPanel.close()
                    }
                } label: {
                    Circle()
                        .fill(LimpidColor.paletteColor(project?.paletteIndex))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Change Color"))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    colorDotFrame = frame
                    colorPanel.updateAnchor(projectID: projectID, anchor: frame)
                }
            }
            if let project {
                PathRow(label: "Root", url: project.rootURL)
            }
        }
    }

    // MARK: - Worktrees

    private var worktreesSection: some View {
        Section {
            // The new worktree sheet's menu: the placements, the
            // chosen folder among them, and "Choose a Folder…" to pick one.
            LabeledContent(ProjectSettingsText.placement) {
                Menu {
                    WorktreePlacementMenuItems(
                        project: project,
                        onChoose: applyPlacement,
                        onChooseFolder: chooseCustomParent
                    )
                } label: {
                    Text(display: WorktreePlacementActions.shortTitle(of: project?.worktreePlacement ?? .siblingPrefixed))
                }
                .fixedSize()
                .accessibilityLabel(Text(ProjectSettingsText.placement))
            }
            // Not made yet, so never "Not Found"; Finder shows the folder
            // it will go in.
            PathRow(label: "Preview", url: placementPreviewURL, isExpectedToExist: false)
        } header: {
            Text("Worktrees")
        } footer: {
            Text(
                """
                Used for new worktrees created from this project. \
                Applies to future creations only — existing worktrees stay where they are.
                """
            )
        }
    }

    /// Preview of the path a new worktree would land at, using a
    /// placeholder branch leaf so the user can sanity-check the
    /// strategy without filling the Create sheet first.
    private var placementPreviewURL: URL? {
        project?.resolvedWorktreeURL(branchLeaf: "<branch>")
    }

    // MARK: - Routed agents

    /// Per-agent opt-out section for the PreToolUse hooks that
    /// intercept agent-initiated `git worktree add` invocations. One
    /// `Toggle` per supported CLI — adding a new agent is a new row.
    ///
    /// Extracted to a nested `View` because the parent sheet's Form
    /// section list otherwise blows past Swift's IRGen capacity at
    /// `Onone` (`llvm::report_fatal_error` in `Explosion::setArgs`).
    private struct RoutedAgentsSection: View {
        let claudeEnabled: Bool
        let codexEnabled: Bool
        // The setters land via SwiftUI `Binding`, which expects an
        // `@isolated(any) @Sendable` closure. Annotating these properties
        // with `@MainActor` (or `@MainActor @Sendable`) currently trips a
        // Swift 6 IRGen crash on this file, so `body` wraps them in closure
        // literals instead: those inherit the view's main-actor isolation,
        // which is what makes handing them to `Binding` race-free.
        let onClaudeChange: (Bool) -> Void
        let onCodexChange: (Bool) -> Void

        private static func label(for kind: AgentKind) -> LocalizedStringResource {
            let name = AgentProviderRegistry.displayName(for: kind)
            return LocalizedStringResource("\(name) CLI", comment: "Toggle label; the agent's name")
        }

        var body: some View {
            Section {
                // Each agent names itself through the registry, so the only
                // translated part is the word around the name. The rows are
                // the Settings window's switch rows, so the switches are the
                // mini ones System Settings uses in a form and keep the
                // accent the form drops as `.tint`.
                SettingsToggle(
                    Text(Self.label(for: .claude)),
                    isOn: Binding(get: { claudeEnabled }, set: { onClaudeChange($0) })
                )
                SettingsToggle(
                    Text(Self.label(for: .codex)),
                    isOn: Binding(get: { codexEnabled }, set: { onCodexChange($0) })
                )
            } header: {
                Text(ProjectSettingsText.agentWorktrees)
            } footer: {
                Text(
                    """
                    When an agent listed here runs `git worktree add`, \
                    Limpid intercepts it and applies this project’s \
                    placement and setup commands. Off lets the agent use \
                    its own default location.
                    """
                )
            }
        }
    }

    // MARK: - Bootstrap

    /// One shell command per line. Runs sequentially inside every
    /// newly-created worktree — both the sidebar's "New Worktree" flow
    /// and Claude's `git worktree add` (intercepted by
    /// `limpid-pretool-worktree-hook`) re-enter the same code path so
    /// the user can rely on identical setup regardless of trigger.
    ///
    /// Uses `PlainTextEditor` (instead of SwiftUI's `TextEditor`)
    /// because the default `NSTextView` rewrites `"` → `“`/`”`, `--`
    /// → `—`, etc. — silent substitutions that downstream `sh -c`
    /// can't parse.
    private var bootstrapSection: some View {
        Section {
            // Saved from the editor's own edits only, so opening the sheet writes nothing.
            PlainTextEditor(
                text: Binding(get: { bootstrapDraft }, set: { bootstrapDraft = $0
                    commitBootstrap()
                }),
                onCancel: { dismiss() }
            )
            .frame(minHeight: 90)
            .accessibilityLabel(Text(ProjectSettingsText.setupCommands))
            // What state.json adds to a line, which the text cannot show.
            ForEach(SetupCommandsDraft.details(of: project?.bootstrap ?? []), id: \.line) { detail in
                Text(SetupCommandsDraft.description(of: detail))
                    .font(LimpidFont.caption)
                    .foregroundStyle(SettingsFootnote.style.color)
            }
            let dropped = SetupCommandsDraft.droppedDetailCount(before: openedBootstrap, after: project?.bootstrap ?? [])
            if dropped > 0 {
                Label {
                    Text("\(dropped) lines lost the timeout or folder set in state.json.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SupervisionTokens.waitingText.color)
                }
                .font(LimpidFont.caption)
            }
        } header: {
            Text(ProjectSettingsText.setupCommands)
        } footer: {
            Text(
                """
                One shell command per line, run in order inside the new \
                worktree right after it is created. Leave it empty to run nothing. \
                A line given a timeout or a folder in state.json keeps them while you edit it.
                """
            )
        }
    }

    /// The files Git ignores that each new worktree gets a copy of,
    /// a list as the test commands are: paths and patterns, with no order.
    private var filesSection: some View {
        Section {
            IgnoredFilesList(draft: editedFiles, root: project?.rootURL)
        } header: {
            Text(ProjectSettingsText.filesToCopy)
        } footer: {
            Text(ProjectSettingsText.filesToCopyFooter)
        }
    }

    /// The commands whose last run in a turn shows with the turn.
    /// Shown as the list in force, the defaults included, so adding or
    /// removing one is an edit of what the person sees. A list, not a text
    /// area as Setup is: these are patterns with no order, where Setup's
    /// lines are steps run one after another.
    private var checksSection: some View {
        Section {
            TestCommandsList(draft: editedChecks)
        } header: {
            Text(ProjectSettingsText.checkCommands)
        } footer: {
            Text(
                """
                A trailing * matches the rest of a word. The last of these an agent runs \
                in a turn shows with the turn. ✓ only means it exited with 0, not that \
                the change is right. Remove every command to show no tests.
                """
            )
        }
    }

    // MARK: - Hidden Worktrees

    private var hiddenSection: some View {
        Section {
            ForEach(hiddenWorktrees) { wt in
                HStack {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(hiddenRowName(wt))
                    Spacer()
                    Button("Show") {
                        session.unhideWorktree(projectID: projectID, worktreeID: wt.id)
                    }
                    .buttonStyle(.borderless)
                    // Each row's button by its worktree, so VoiceOver's list
                    // of buttons tells them apart.
                    .accessibilityLabel(Text(
                        "Show \(hiddenRowName(wt))",
                        comment: "Project settings, VoiceOver: shows one hidden worktree again"
                    ))
                }
            }
            if hiddenWorktrees.count > 1 {
                Button("Show All") {
                    session.unhideAllWorktrees(projectID: projectID)
                }
            }
        } header: {
            Text("Hidden Worktrees (\(hiddenWorktrees.count))")
        }
    }

    // MARK: - Persistence helpers

    private func loadDrafts() {
        if let project {
            nameDraft = project.name
            bootstrapDraft = SetupCommandsDraft.text(for: project.bootstrap)
            openedBootstrap = project.bootstrap
            checksDraft = CheckCommandsDraft(
                commands: project.checkCommands,
                defaults: AgentProviderRegistry.checkDefaults
            )
            filesDraft = IgnoredFilesDraft(patterns: project.ignoredFilesToCopy)
        }
    }

    /// The files list as the person edits it: each edit saves what it
    /// changed (`IgnoredFilesDraft.save`), so opening the sheet writes
    /// nothing.
    private var editedFiles: Binding<IgnoredFilesDraft> {
        Binding(
            get: { filesDraft },
            set: { edited in
                let previous = filesDraft
                filesDraft = edited
                if case let .patterns(patterns) = IgnoredFilesDraft.save(from: previous, to: edited) {
                    session.setProjectIgnoredFilesToCopy(projectID, to: patterns)
                }
            }
        )
    }

    /// The draft as steps, keeping what state.json adds to a line
    /// (`SetupCommandsDraft.items`), pushed through `WorkspaceSession`.
    private func commitBootstrap() {
        guard let project else { return }
        session.setProjectBootstrap(projectID, to: SetupCommandsDraft.items(
            from: bootstrapDraft,
            previous: project.bootstrap,
            normalizing: CommandLineText.sanitizeSmartPunctuation
        ))
    }

    /// The list as the person edits it: each edit saves what it changed
    /// (`CheckCommandsDraft.save`). Loading the sheet sets the draft
    /// directly, past this, so opening it writes nothing.
    private var editedChecks: Binding<CheckCommandsDraft> {
        Binding(
            get: { checksDraft },
            set: { edited in
                let previous = checksDraft
                checksDraft = edited
                if case let .commands(commands) = CheckCommandsDraft.save(
                    from: previous,
                    to: edited,
                    normalizing: CommandLineText.sanitizeSmartPunctuation
                ) {
                    session.setProjectCheckCommands(projectID, to: commands)
                }
            }
        )
    }

    private func applyRouteClaudeToggle(_ enabled: Bool) {
        session.setProjectRouteClaudeWorktrees(projectID, to: enabled)
    }

    private func applyRouteCodexToggle(_ enabled: Bool) {
        session.setProjectRouteCodexWorktrees(projectID, to: enabled)
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project?.name else { return }
        session.renameProject(projectID, to: trimmed)
    }

    // MARK: - Worktree placement mutations

    /// The custom item only lists while its folder is the placement, so
    /// choosing it keeps that folder (`WorktreePlacementActions.apply`).
    private func applyPlacement(_ choice: WorktreePlacementActions.Choice) {
        guard let project else { return }
        WorktreePlacementActions.apply(
            choice,
            customParent: WorktreePlacementActions.customParent(of: project.worktreePlacement),
            to: projectID,
            in: session,
            attachedTo: hostWindow.window
        )
    }

    /// Asks for the folder new worktrees go in, starting at the one in use;
    /// the panel hangs from this sheet.
    private func chooseCustomParent() {
        WorktreePlacementActions.chooseCustomParent(
            startingAt: project.map { WorktreePlacementActions.customParent(of: $0.worktreePlacement) } ?? "",
            for: projectID,
            in: session,
            attachedTo: hostWindow.window
        )
    }
}
