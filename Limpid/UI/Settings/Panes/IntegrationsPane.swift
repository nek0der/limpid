// IntegrationsPane.swift
// Limpid — Settings for external configuration and command-line integrations.

import SwiftUI

struct IntegrationsPane: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Integrations", section: .integrations) {
            Section {
                Toggle(
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

            Section {
                Toggle(
                    "Show PR status in sidebar",
                    isOn: $store.settings.advanced.showPRStatusInSidebar
                )
                .settingsSearchTarget(SettingsSearchCatalog.showPRStatus.id)
                Toggle(
                    "Mark only rows needing attention",
                    isOn: $store.settings.advanced.showPRStatusOnlyWhenAttention
                )
                .disabled(!store.settings.advanced.showPRStatusInSidebar)
                .settingsSearchTarget(SettingsSearchCatalog.showPRStatusOnlyWhenAttention.id)
            } header: {
                Text("Pull Requests")
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

            Section {
                Toggle(
                    "Run agents in tmux",
                    isOn: $store.settings.advanced.hostsAgentsInTmux
                )
                .settingsSearchTarget(SettingsSearchCatalog.hostsAgentsInTmux.id)
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
        }
    }
}
