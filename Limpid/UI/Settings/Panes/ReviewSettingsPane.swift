// ReviewSettingsPane.swift
// Limpid — Settings → Review: jumping to unread turns, the handoff instructions, and the external diff command.

import SwiftUI

struct ReviewSettingsPane: View {
    @Environment(SettingsStore.self) private var store
    /// The text the instructions editor shows: the reader's own, or the
    /// default in the app's language (`ReviewInstructionsDraft`).
    @State private var instructionsDraft = ""

    var body: some View {
        @Bindable var store = store
        form
            .onAppear(perform: loadInstructions)
            // A default follows the language; the reader's own text stays.
            .onChange(of: store.appLocale) { _, _ in
                if store.settings.advanced.reviewInstructions.isEmpty {
                    loadInstructions()
                }
            }
            // Edited in settings.json or restored with every default.
            .onChange(of: store.settings.advanced.reviewInstructions) { _, saved in
                let shown = ReviewInstructionsDraft.saved(text: instructionsDraft, defaults: ReviewInstructionsDraft.defaults)
                if shown != saved {
                    loadInstructions()
                }
            }
    }

    private func loadInstructions() {
        instructionsDraft = ReviewInstructionsDraft.text(
            saved: store.settings.advanced.reviewInstructions,
            locale: store.appLocale
        )
    }

    private var form: some View {
        @Bindable var store = store
        return SettingsForm(title: "Review", section: .review) {
            Section {
                SettingsToggle(
                    "Open Review when jumping to an unread turn",
                    isOn: $store.settings.jumpOpensTurnReview
                )
                .settingsSearchTarget(SettingsSearchCatalog.jumpOpensTurnReview.id)
            } header: {
                Text("Unread Turns")
            }

            Section {
                // The text in effect, so adding a line to the default is an
                // edit of what is shown; Return breaks a line, as in the
                // project's setup commands.
                // Saved from the reader's typing only: filling the editor on
                // appear sets the draft past this binding, so opening the
                // pane never rewrites what is stored.
                PlainTextEditor(text: Binding(
                    get: { instructionsDraft },
                    set: { text in
                        instructionsDraft = text
                        store.settings.advanced.reviewInstructions = ReviewInstructionsDraft.saved(
                            text: text,
                            defaults: ReviewInstructionsDraft.defaults
                        )
                    }
                ), wrapsLines: true)
                    .frame(minHeight: 120)
                    .accessibilityLabel(Text("Review instructions"))
                    .settingsSearchTarget(SettingsSearchCatalog.reviewInstructions.id)
                HStack(spacing: 8) {
                    if store.settings.advanced.reviewInstructions.isEmpty {
                        SettingsFootnote("Default text, in the app’s language")
                    } else {
                        SettingsFootnote("Edited")
                    }
                    Spacer(minLength: 8)
                    if !store.settings.advanced.reviewInstructions.isEmpty {
                        RestoreDefaultButton(accessibilityLabel: "Restore Default Review Instructions") {
                            store.settings.advanced.reviewInstructions = ""
                            loadInstructions()
                        }
                    }
                }
                .settingsControlRow()
            } header: {
                Text("Review Instructions")
            } footer: {
                SettingsFootnote(
                    """
                    Review writes this above the comments it hands to an agent. The default \
                    text follows the app’s language until you change it.

                    The worktree and the comment count are written above this text, \
                    and the comments themselves below it; none of that can be edited \
                    here. Rules that belong to \
                    the project rather than to this handoff — how to run the tests, \
                    whether to commit — go in the agent’s own project instructions.

                    Review pastes into the pane below it, so Limpid keeps Ghostty’s \
                    paste protection on for every pane: a multi-line paste into a \
                    program that didn’t ask for bracketed paste is confirmed first. \
                    This overrides that one setting in your own Ghostty config.
                    """
                )
            }

            // Free text, naming no tool in the app itself.
            Section {
                TextField(
                    "Command",
                    text: Binding(
                        get: { store.settings.review.externalDiffCommand },
                        // The command goes to a shell, which cannot run the
                        // curly quotes a field may type.
                        set: { store.settings.review.externalDiffCommand = CommandLineText.sanitizeSmartPunctuation($0) }
                    ),
                    prompt: Text("e.g. git difftool")
                )
                // The whole row, read from its start as a command is, under
                // the section's heading that names it: as a value beside
                // "Command" the form set it against the trailing edge.
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .font(.supervision(.row, design: .monospaced))
                .accessibilityLabel(Text("External diff tool command"))
                .settingsSearchTarget(SettingsSearchCatalog.externalDiffCommand.id)
                if let tool = CommitAndPRModel.externalTool(store.settings.review.externalDiffCommand) {
                    // What the command turns into where it is used, so the
                    // reader sees the button before going to look for it.
                    LabeledContent("Button in the changes panel") {
                        Text("Open in \(tool.name)")
                            .padding(.horizontal, LimpidLayout.Supervision.spaceS)
                            .padding(.vertical, LimpidLayout.Supervision.spaceHairline)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color(nsColor: .separatorColor))
                            }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("External Diff Tool")
            } footer: {
                SettingsFootnote(
                    """
                    A command run in a new tab of the worktree to look at its changes. Commit & PR \
                    in the changes panel shows a button that runs it. Leave it empty to show no button.
                    """
                )
            }
        }
    }
}
