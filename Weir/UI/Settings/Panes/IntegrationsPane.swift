// IntegrationsPane.swift
// Weir — Settings for external configuration and command-line integrations.

import AppKit
import SwiftUI

struct IntegrationsPane: View {
    @Environment(SettingsStore.self) private var store

    @Environment(\.reloadGhosttyConfig) private var reloadGhosttyConfig
    /// The Ghostty config file libghostty reads last, which wins where they
    /// overlap; nil when there is none. Looked up when the pane shows and
    /// when its window comes forward (`refresh`), never while drawing.
    @State private var configFile: URL?
    /// Whether that file was saved after libghostty last read it.
    @State private var isConfigUnread = false
    /// Whether a tmux is installed where agents look for one.
    @State private var isTmuxFound = true

    /// The file facts the pane shows, read once rather than on every redraw.
    private func refresh() {
        let file = GhosttyUserConfig.fileToEdit()
        configFile = file
        isConfigUnread = file.map(Self.isUnread) ?? false
        isTmuxFound = TmuxClientProbe.locateTmux() != nil
    }

    /// Whether `file` changed after libghostty last read the user config.
    private static func isUnread(_ file: URL) -> Bool {
        guard let readAt = GhosttyConfigBridge.userConfigReadAt else { return false }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified.map { $0 > readAt } ?? false
    }

    var body: some View {
        form
            .task(id: store.settings.advanced.ghosttyConfig.isOn) {
                refresh()
                // Turning the setting on reloads the config after the
                // settings sync's debounce; look again once it has read
                // the file, so the note compares with that read.
                try? await Task.sleep(for: PersistenceTiming.interactive * 2)
                guard !Task.isCancelled else { return }
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                refresh()
            }
    }

    private var form: some View {
        @Bindable var store = store
        return SettingsForm(title: "Integrations", section: .integrations) {
            Section {
                SettingsToggle(
                    "Use Ghostty config file",
                    isOn: Binding(
                        get: { store.settings.advanced.ghosttyConfig == .on },
                        set: { store.settings.advanced.ghosttyConfig = $0 ? .on : .off }
                    )
                )
                .settingsSearchTarget(SettingsSearchCatalog.ghosttyConfig.id)
                if store.settings.advanced.ghosttyConfig.isOn,
                   !store.ghosttyConfigDiagnostics.isEmpty
                {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Ghostty config errors",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(SupervisionTokens.stoppedText.color)
                        ForEach(Array(store.ghosttyConfigDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(diagnostic)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                // Editing the file is the work this setting asks for, so the
                // file is one click away, as settings.json is in Advanced.
                if let file = configFile {
                    SettingsButtonRow {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                        .accessibilityLabel(Text("Show Ghostty config file in Finder"))
                        Button("Open File") {
                            NSWorkspace.shared.open(file)
                        }
                        .accessibilityLabel(Text("Open Ghostty config file"))
                    }
                    if store.settings.advanced.ghosttyConfig.isOn, isConfigUnread, let reloadGhosttyConfig {
                        HStack(spacing: 12) {
                            SettingsFootnote("The file changed since Weir last read it.")
                            Spacer(minLength: 12)
                            Button("Reload") {
                                reloadGhosttyConfig()
                                refresh()
                            }
                            .help(Text("Reads the Ghostty config file again."))
                        }
                        .settingsControlRow()
                    }
                }
            } header: {
                Text("Ghostty Config")
            } footer: {
                SettingsFootnote(
                    """
                    Loads settings from ~/.config/ghostty/config. Key bindings aren’t applied because \
                    Weir manages its own shortcuts. Weir also takes priority for some safety and display \
                    settings. After editing the file, choose Reload; some settings reach only new terminals.
                    """
                )
            }

            Section {
                SettingsToggle(
                    "Run agents in tmux",
                    isOn: $store.settings.advanced.hostsAgentsInTmux
                )
                .settingsSearchTarget(SettingsSearchCatalog.hostsAgentsInTmux.id)
                // On but with nothing to run: say so, since the agents then
                // run without tmux and stop when Weir quits, the one thing
                // the switch was turned on to avoid.
                if store.settings.advanced.hostsAgentsInTmux, !isTmuxFound {
                    Label {
                        Text("tmux wasn’t found. Agents run without tmux until it is installed, and stop when Weir quits.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(SupervisionTokens.waitingText.color)
                    }
                    .font(.caption)
                }
            } header: {
                Text("tmux")
            } footer: {
                SettingsFootnote(
                    """
                    Starts each agent in a tmux session of its own. The agent keeps running \
                    when Weir quits, including the relaunch after an update, and the pane \
                    reconnects to the same session on the next launch. Requires tmux.

                    Applies to panes opened after the change. The pane’s scrollback stays in \
                    tmux rather than Weir. A command that prints and exits, such as \
                    `claude --version`, runs outside it.
                    """
                )
            }
        }
    }
}
