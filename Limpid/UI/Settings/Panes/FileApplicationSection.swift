// FileApplicationSection.swift
// Limpid — the Settings row that picks the app local files open in.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One preference serves Review and ⌘-clicked terminal paths, so it lives in
/// General rather than under either feature.
struct FileApplicationSection: View {
    @Environment(SettingsStore.self) private var store
    @State private var isApplicationSelectionInvalid = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Text(display: applicationName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Button("Choose App…") {
                    chooseApplication()
                }
                .accessibilityLabel(Text("Choose App for Opening Files"))
                if store.settings.advanced.fileApplication != nil {
                    Button("Restore Default") {
                        store.settings.advanced.fileApplication = nil
                    }
                    .accessibilityLabel(Text("Restore Default App for Opening Files"))
                }
            }
            .settingsControlRow()
            .settingsSearchTarget(SettingsSearchCatalog.fileApplication.id)
            if case .configuredApplicationMissing = FileOpener.application(
                for: store.settings.advanced.fileApplication
            ) {
                Label("Selected app unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Files will open in this app automatically when it becomes available again.")
                    .font(.caption)
            }
        } header: {
            Text("Open Files With")
        } footer: {
            Text(
                """
                Used when you ⌘-click a file path in the terminal and when you open a \
                file from Review. Visual Studio Code, Cursor, Xcode, Zed, and Sublime \
                Text open at the line.
                """
            )
        }
        .alert("The selected app cannot be used.", isPresented: $isApplicationSelectionInvalid) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose an application bundle that has a bundle identifier.")
        }
    }

    private var applicationName: DisplayText {
        FileOpener.application(for: store.settings.advanced.fileApplication).displayName
            .map { .verbatim($0) } ?? .localized("Default Application")
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        // AppKit localizes the open panel's own buttons and sidebar in the
        // language the process launched with, so our title and prompt do too: a
        // panel half in each language would read worse than one that waits
        // for the relaunch the menu bar also waits for.
        // swiftlint:disable launch_language_lookup
        panel.title = String(localized: "Choose App for Opening Files")
        panel.prompt = String(localized: "Choose")
        // swiftlint:enable launch_language_lookup
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let application = FileOpener.application(fromBundleAt: url) else {
                isApplicationSelectionInvalid = true
                return
            }
            store.settings.advanced.fileApplication = application
        }
    }
}
