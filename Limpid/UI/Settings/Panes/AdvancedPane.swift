// AdvancedPane.swift
// Limpid — Settings → Advanced. Layer the user's
// `~/.config/ghostty/config` beneath Limpid Settings, plus the
// destructive "Restore All Defaults" escape hatch. The 4-layer
// config model + forced-overrides story lives in `LimpidSettings.swift`;
// the footer below just summarises it.

import AppKit
import SwiftUI

struct AdvancedPane: View {
    @Environment(SettingsStore.self) private var store
    @State private var confirmReset: Bool = false

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Advanced") {
            Section {
                HStack {
                    Button("Reveal settings.json in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.settingsFileURL])
                    }
                    Button("Open in Default Editor") {
                        NSWorkspace.shared.open(store.settingsFileURL)
                    }
                }
            } header: {
                Text("settings.json")
            } footer: {
                Text(
                    """
                    Edit `settings.json` directly. Limpid watches the file and reloads on save. \
                    A typo is recoverable — the malformed copy is renamed to settings.json.bak-decode-failed-<ts> \
                    on the next launch and defaults are loaded.
                    """
                )
            }

            Section {
                Toggle(
                    "Use Ghostty config file",
                    isOn: Binding(
                        get: { store.settings.advanced.ghosttyConfig == .on },
                        set: { store.settings.advanced.ghosttyConfig = $0 ? .on : .off }
                    )
                )
                if store.settings.advanced.ghosttyConfig.isOn,
                   !store.ghosttyConfigDiagnostics.isEmpty
                {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Ghostty config errors",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                        ForEach(Array(store.ghosttyConfigDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(diagnostic)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            } header: {
                Text("Ghostty Config")
            } footer: {
                Text(
                    """
                    Loads settings from ~/.config/ghostty/config. Key bindings are not applied because \
                    Limpid manages its own shortcuts. Limpid also takes priority for some safety and display \
                    settings. Restart Limpid after editing the file.
                    """
                )
            }

            // Sits under Ghostty Config because both are "Limpid talks
            // to something outside itself" switches. Off by default:
            // it shells out to a CLI the user may not have, so it has
            // to be asked for rather than discovered by surprise.
            Section {
                Toggle(
                    "Show PR status in sidebar",
                    isOn: $store.settings.advanced.showPRStatusInSidebar
                )
                Toggle(
                    "Mark only rows needing attention",
                    isOn: $store.settings.advanced.showPRStatusOnlyWhenAttention
                )
                .disabled(!store.settings.advanced.showPRStatusInSidebar)
            } header: {
                Text("Integrations")
            } footer: {
                Text(
                    """
                    Marks a sidebar row whose branch has a pull request, and shows the title \
                    and CI summary on hover. Requires `gh` (GitHub) or `glab` (GitLab), \
                    signed in to the remote's host. \
                    Refreshes on focus, every \(PRStatusSyncer.refreshIntervalMinutes) minutes \
                    otherwise, and faster while checks are running.

                    Restricting the mark to rows with a failing check leaves fewer of them \
                    on screen; the hover card reports every request either way.
                    """
                )
            }

            // Its own section rather than a third line under
            // Integrations: the cost is the pane's scrollback, which
            // needs saying, and saying it next to the pull-request
            // footer would bury it.
            Section {
                Toggle(
                    "Run agents in tmux",
                    isOn: $store.settings.advanced.hostsAgentsInTmux
                )
            } header: {
                Text("tmux")
            } footer: {
                Text(
                    """
                    Starts each agent in a tmux session of its own. The agent keeps running \
                    when Limpid quits, including the relaunch after an update, and the pane \
                    reconnects to the same session on the next launch. Requires tmux.

                    Applies to panes opened after the change. The pane's scrollback stays in \
                    tmux rather than Limpid. A command that prints and exits, such as \
                    `claude --version`, runs outside it.
                    """
                )
            }

            // Only the instructions, not the whole prompt: the comment blocks
            // below them carry escaping and diff markers the agent depends on,
            // and a template that could break those would be a way to send
            // feedback about code that does not exist.
            Section {
                // A prompt rather than a placeholder drawn over a `TextEditor`:
                // the overlay had to guess the editor's own text insets, which
                // put the default text a few points off the caret and let it
                // run past the right edge. A field's prompt sits exactly where
                // its text will.
                TextField(
                    "",
                    text: $store.settings.advanced.reviewInstructions,
                    prompt: Text(verbatim: ReviewPromptBuilder.defaultInstructions),
                    axis: .vertical
                )
                .lineLimit(6...16)
                .textFieldStyle(.plain)
                // Without this the form keeps a label column for the empty
                // label and trailing-aligns the field beside it, which pushed
                // every line of the instructions against the right margin.
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                // A form puts a field's content against its trailing edge,
                // which for one line of a setting is right and for a block of
                // prose is not: it ran the instructions up the right margin.
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Review instructions"))
            } header: {
                HStack {
                    Text("Review")
                    Spacer(minLength: 8)
                    // Emptying the field is what restores the default, so the
                    // button says that rather than "clear" — the field is
                    // never empty on screen, it falls back to the text behind
                    // it, and a reader who cleared it by hand would not know
                    // that is what they had done.
                    Button("Restore Default") {
                        store.settings.advanced.reviewInstructions = ""
                    }
                    .disabled(store.settings.advanced.reviewInstructions.isEmpty)
                }
            } footer: {
                Text(
                    """
                    Review writes this above the comments it hands to an agent. Leave \
                    it empty for the text shown here, which follows the app's language.

                    The worktree and the comment count are written above this text, \
                    and the comments themselves below it; none of that can be edited \
                    here. Rules that belong to \
                    the project rather than to this handoff — how to run the tests, \
                    whether to commit — go in the agent's own project instructions.

                    Review pastes into the pane below it, so Limpid keeps Ghostty's \
                    paste protection on for every pane: a multi-line paste into a \
                    program that did not ask for bracketed paste is confirmed first. \
                    This overrides that one setting in your own Ghostty config.
                    """
                )
            }

            // Lives at the bottom of the last pane on purpose — this
            // is the kind of switch a user only reaches for when
            // something is wrong, and putting it next to the daily
            // controls would invite mis-clicks.
            Section {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Text("Restore All Defaults")
                }
            } footer: {
                Text(
                    """
                    Resets every Limpid preference to its factory default. \
                    The app language and your settings.json on disk are both rewritten.
                    """
                )
            }
        }
        .alert("Restore all settings to defaults?", isPresented: $confirmReset) {
            Button("Restore Defaults", role: .destructive) {
                store.settings = .default
                store.appLanguage = .system
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}
