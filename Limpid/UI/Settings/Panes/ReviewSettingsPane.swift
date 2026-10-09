// ReviewSettingsPane.swift
// Limpid — Settings for Review's jump behavior and agent handoff instructions.

import SwiftUI

struct ReviewSettingsPane: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Review", section: .review) {
            Section {
                SettingsToggle(
                    "Open the turn's changes when jumping to a finished agent",
                    isOn: $store.settings.jumpOpensTurnReview
                )
                .settingsSearchTarget(SettingsSearchCatalog.jumpOpensTurnReview.id)
            } header: {
                Text("Finished Agents")
            }

            Section {
                TextField(
                    "",
                    text: $store.settings.advanced.reviewInstructions,
                    prompt: Text(ReviewPromptBuilder.defaultInstructions),
                    axis: .vertical
                )
                .lineLimit(6...16)
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Review instructions"))
                .settingsSearchTarget(SettingsSearchCatalog.reviewInstructions.id)
            } header: {
                // A small button keeps the header's height close to a
                // plain text header; the negative padding absorbs the
                // remaining 4pt so the spacing above and below the header
                // matches the other sections (30pt and 10pt).
                HStack {
                    Text("Review Instructions")
                    Spacer(minLength: 8)
                    Button("Restore Default") {
                        store.settings.advanced.reviewInstructions = ""
                    }
                    .controlSize(.small)
                    .disabled(store.settings.advanced.reviewInstructions.isEmpty)
                    .accessibilityLabel(Text("Restore Default Review Instructions"))
                }
                .padding(.vertical, -2)
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
        }
    }
}
