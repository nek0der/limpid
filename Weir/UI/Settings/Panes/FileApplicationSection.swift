// FileApplicationSection.swift
// Weir — the Settings row that picks the app local files open in.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One preference serves Review and ⌘-clicked terminal paths, so it lives in
/// General rather than under either feature.
struct FileApplicationSection: View {
    @Environment(SettingsStore.self) private var store
    @State private var isApplicationSelectionInvalid = false
    /// The installed editors, found when the pane appears
    /// (`installedEditors`).
    @State private var installed: [FileApplicationCandidate] = []
    /// Each found app's icon at menu size, made once when it was found.
    @State private var icons: [String: NSImage] = [:]

    /// The menu's tag for "Other…", which opens the panel and is never the
    /// selection; a bundle identifier never contains a space.
    private static let otherTag = "other app"

    private var candidates: [FileApplicationCandidate] {
        FileApplicationCandidates.ordered(
            installed,
            chosen: store.settings.advanced.fileApplication,
            excluding: Bundle.main.bundleIdentifier
        )
    }

    var body: some View {
        Section {
            // A pop-up of the editors this Mac has, as the choice is one of
            // a few, with the open panel kept for any other app.
            Picker("App", selection: Binding<String?>(
                get: { store.settings.advanced.fileApplication?.bundleIdentifier },
                set: { choose($0) }
            )) {
                Text("Default Application").tag(String?.none)
                Divider()
                ForEach(candidates) { app in
                    Label {
                        Text(verbatim: app.name)
                    } icon: {
                        Image(nsImage: icon(for: app))
                    }
                    .tag(String?.some(app.bundleIdentifier))
                }
                Divider()
                Text("Other…").tag(String?.some(Self.otherTag))
            }
            .accessibilityLabel(Text("Open Files With"))
            .settingsSearchTarget(SettingsSearchCatalog.fileApplication.id)
            .task {
                await load()
            }
            if case .configuredApplicationMissing = FileOpener.application(
                for: store.settings.advanced.fileApplication
            ) {
                Label("Selected app unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(SupervisionTokens.waitingText.color)
                SettingsFootnote("Files will open in this app automatically when it becomes available again.")
                    .font(.caption)
            }
        } header: {
            Text("Open Files With")
        } footer: {
            SettingsFootnote(
                """
                Used when you ⌘-click a file path in the terminal and when you open a \
                file from Review. Visual Studio Code, Cursor, Xcode, Zed, and Sublime \
                Text open at the line.
                """
            )
        }
        .alert("The selected app can’t be used.", isPresented: $isApplicationSelectionInvalid) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose an app that has a bundle identifier.")
        }
    }

    /// What a menu item chooses: the default, an editor, or the panel.
    private func choose(_ tag: String?) {
        guard let tag else {
            store.settings.advanced.fileApplication = nil
            return
        }
        if tag == Self.otherTag {
            chooseApplication()
        } else if let app = candidates.first(where: { $0.bundleIdentifier == tag }) {
            // A chosen app that is gone keeps the name it was saved with.
            if app.url != nil {
                store.settings.advanced.fileApplication = app.application
            }
        }
    }

    /// The installed apps that open `FileApplicationCandidates.editedTypes`,
    /// as Launch Services lists them, each app once by its bundle
    /// identifier. The slow step, run off the main thread: Launch Services
    /// and reading every bundle can take a moment. Only values come back;
    /// the icons are made on main (`load`). The menu orders them later
    /// (`FileApplicationCandidates.ordered`).
    private nonisolated static func installedEditors() -> [FileApplicationCandidate] {
        var seen = Set<String>()
        return FileApplicationCandidates.editedTypes
            .flatMap { NSWorkspace.shared.urlsForApplications(toOpen: $0) }
            .compactMap { url in
                guard let application = FileOpener.application(fromBundleAt: url),
                      seen.insert(application.bundleIdentifier).inserted
                else { return nil }
                return FileApplicationCandidate(
                    bundleIdentifier: application.bundleIdentifier,
                    name: application.lastKnownDisplayName,
                    url: url
                )
            }
    }

    /// Finds the editors off the main thread, then takes each one's icon
    /// once, at menu size, and keeps it for every redraw. Merged into what
    /// is there, so an app chosen with "Other…" before the list arrived
    /// stays; dropped if the pane closed meanwhile.
    private func load() async {
        let found = await Task.detached(priority: .userInitiated) { Self.installedEditors() }.value
        guard !Task.isCancelled else { return }
        for candidate in found where !installed.contains(where: { $0.bundleIdentifier == candidate.bundleIdentifier }) {
            installed.append(candidate)
        }
        for candidate in found {
            if let url = candidate.url {
                cacheIcon(for: candidate.bundleIdentifier, at: url)
            }
        }
    }

    /// The app's icon at menu size, taken once per app. An icon from
    /// `icon(forFile:)` draws whichever of its sizes is asked for, so nothing
    /// is converted.
    private func cacheIcon(for bundleIdentifier: String, at url: URL) {
        guard icons[bundleIdentifier] == nil else { return }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        icons[bundleIdentifier] = image
    }

    /// The app's icon as found, or a generic app icon for one that is gone.
    private func icon(for app: FileApplicationCandidate) -> NSImage {
        icons[app.bundleIdentifier] ?? Self.genericIcon
    }

    private static let genericIcon: NSImage = {
        let image = NSWorkspace.shared.icon(for: .applicationBundle)
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

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
            // An app Launch Services did not list joins the menu with its icon.
            if !installed.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) {
                installed.append(FileApplicationCandidate(
                    bundleIdentifier: application.bundleIdentifier,
                    name: application.lastKnownDisplayName,
                    url: url
                ))
            }
            cacheIcon(for: application.bundleIdentifier, at: url)
            store.settings.advanced.fileApplication = application
        }
    }
}
