// ReviewSettingsPane.swift
// Limpid — Settings for Review file handling and agent handoff instructions.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReviewSettingsPane: View {
    @Environment(SettingsStore.self) private var store
    @State private var isApplicationSelectionInvalid = false

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Review", section: .review) {
            Section {
                HStack(spacing: 10) {
                    Text(reviewFileApplicationName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Button("Choose App…") {
                        chooseReviewFileApplication()
                    }
                    .accessibilityLabel(Text("Choose Review App"))
                    if store.settings.advanced.reviewFileApplication != nil {
                        Button("Restore Default") {
                            store.settings.advanced.reviewFileApplication = nil
                        }
                        .accessibilityLabel(Text("Restore Default Review App"))
                    }
                }
                .settingsSearchTarget(SettingsSearchCatalog.reviewFileApplication.id)
                if case .configuredApplicationMissing = ReviewFileAction.application(
                    for: store.settings.advanced.reviewFileApplication
                ) {
                    Label("Selected app unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Review files will open in this app automatically when it becomes available again.")
                        .font(.caption)
                }
            } header: {
                Text("Review Files")
            }

            Section {
                TextField(
                    "",
                    text: $store.settings.advanced.reviewInstructions,
                    prompt: Text(verbatim: ReviewPromptBuilder.defaultInstructions),
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
                HStack {
                    Text("Review Instructions")
                    Spacer(minLength: 8)
                    Button("Restore Default") {
                        store.settings.advanced.reviewInstructions = ""
                    }
                    .disabled(store.settings.advanced.reviewInstructions.isEmpty)
                    .accessibilityLabel(Text("Restore Default Review Instructions"))
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
        }
        .alert("The selected app cannot be used.", isPresented: $isApplicationSelectionInvalid) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose an application bundle that has a bundle identifier.")
        }
    }

    private var reviewFileApplicationName: String {
        ReviewFileAction.application(for: store.settings.advanced.reviewFileApplication).displayName
            ?? String(localized: "Default Application")
    }

    private func chooseReviewFileApplication() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Review App")
        panel.prompt = String(localized: "Choose")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let application = ReviewFileAction.application(fromBundleAt: url) else {
                isApplicationSelectionInvalid = true
                return
            }
            store.settings.advanced.reviewFileApplication = application
        }
    }
}
