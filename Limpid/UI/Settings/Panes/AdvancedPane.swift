// AdvancedPane.swift
// Limpid — Direct settings-file access and the global reset escape hatch.

import AppKit
import SwiftUI

struct AdvancedPane: View {
    @Environment(SettingsStore.self) private var store
    @Environment(\.turnRecordsRemoved) private var turnRecordsRemoved
    @State private var isResetConfirmationPresented = false
    /// A narrower turn history waiting for the person to confirm what it
    /// deletes; nil while the rows show what is saved.
    @State private var pendingRetention: TurnRetentionSettings?
    /// What the sweep says `pendingRetention` deletes.
    @State private var pendingRemoval = PendingRemoval.counting

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Advanced", section: .advanced) {
            Section {
                SettingsButtonRow {
                    Button("Show settings.json in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.settingsFileURL])
                    }
                    .accessibilityLabel(Text("Show settings.json in Finder"))
                    Button("Open in Default Editor") {
                        NSWorkspace.shared.open(store.settingsFileURL)
                    }
                    .accessibilityLabel(Text("Open settings.json in Default Editor"))
                }
                .settingsSearchTarget(SettingsSearchCatalog.settingsFile.id)
            } header: {
                Text("settings.json")
            } footer: {
                SettingsFootnote(
                    """
                    Edit `settings.json` directly. Limpid watches the file and reloads on save. \
                    A typo is recoverable — the malformed copy is renamed to settings.json.bak-decode-failed-<ts> \
                    on the next launch and defaults are loaded.
                    """
                )
            }

            Section {
                SettingsNumberRow(
                    title: "Keep turns for",
                    value: Binding(integer: retentionBinding(\.days)),
                    range: Double(TurnRetentionSettings.dayRange.lowerBound)...Double(TurnRetentionSettings.dayRange.upperBound),
                    unit: "days",
                    // Through the same binding, so a default that deletes
                    // records asks first as typing it would.
                    defaultValue: Double(TurnRetentionSettings().days)
                )
                .settingsSearchTarget(SettingsSearchCatalog.turnRetentionDays.id)
                SettingsNumberRow(
                    title: "Turns per conversation",
                    value: Binding(integer: retentionBinding(\.turns)),
                    range: Double(TurnRetentionSettings.turnRange.lowerBound)...Double(TurnRetentionSettings.turnRange.upperBound),
                    step: 10,
                    unit: "turns",
                    defaultValue: Double(TurnRetentionSettings().turns)
                )
                .settingsSearchTarget(SettingsSearchCatalog.turnRetentionTurns.id)
                if let pending = pendingRetention {
                    retentionConfirmation(pending)
                }
            } header: {
                Text("Turn History")
            } footer: {
                SettingsFootnote(
                    """
                    How long the records of your agents’ turns are kept, and how many of the latest turns \
                    each conversation keeps. The days spare the unread turns of open conversations; the count \
                    applies to every turn. Making either smaller asks first when it would delete records, \
                    and deleted records can’t be recovered.
                    """
                )
            }
            .task(id: pendingRetention) { await countPendingRetention() }

            Section {
                SettingsButtonRow {
                    Button(role: .destructive) {
                        isResetConfirmationPresented = true
                    } label: {
                        Text("Restore Default Settings")
                    }
                }
                .settingsSearchTarget(SettingsSearchCatalog.restoreAllDefaults.id)
            } header: {
                Text("Reset")
            } footer: {
                SettingsFootnote(
                    """
                    Restores every Limpid setting to its default. \
                    The app language and your settings.json on disk are both rewritten.
                    """
                )
            }
        }
        .alert("Restore all settings to defaults?", isPresented: $isResetConfirmationPresented) {
            Button("Restore Defaults", role: .destructive) {
                store.settings = .default
                store.appLanguage = .system
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
    }

    /// One of the turn history's two numbers as the rows edit it: the
    /// change waiting for confirmation while there is one, else the saved
    /// value. A change that keeps fewer turns waits under the rows while the
    /// sweep counts what it deletes (`countPendingRetention`); any other is
    /// saved as it is made.
    private func retentionBinding(_ field: WritableKeyPath<TurnRetentionSettings, Int>) -> Binding<Int> {
        Binding(
            get: { (pendingRetention ?? store.settings.advanced.turnRetention)[keyPath: field] },
            set: { value in
                let saved = store.settings.advanced.turnRetention
                var proposed = pendingRetention ?? saved
                proposed[keyPath: field] = value
                if TurnRetentionCut.isDecrease(from: saved, to: proposed) {
                    pendingRetention = proposed
                    pendingRemoval = .counting
                } else {
                    pendingRetention = nil
                    store.settings.advanced.turnRetention = proposed
                }
            }
        )
    }

    /// Asks the sweep what the waiting change deletes, off the main actor,
    /// and saves it at once when that is nothing (`TurnRetentionCut`). An
    /// answer for a change since replaced is dropped: the task for the new
    /// one is already counting.
    private func countPendingRetention() async {
        guard let pending = pendingRetention else { return }
        let removed: Int? = if let turnRecordsRemoved {
            await turnRecordsRemoved(pending.limits)
        } else {
            0
        }
        guard !Task.isCancelled, pendingRetention == pending else { return }
        guard let removed else {
            pendingRemoval = .unknown
            return
        }
        let saved = store.settings.advanced.turnRetention
        if TurnRetentionCut.needsConfirmation(from: saved, to: pending, removing: removed) {
            pendingRemoval = .removes(removed)
        } else {
            pendingRetention = nil
            store.settings.advanced.turnRetention = pending
        }
    }

    /// What a narrower turn history would delete, said before it is saved:
    /// a sweep that runs on it cannot be undone. When the count could
    /// not be made, it still asks, without a number.
    @ViewBuilder
    private func retentionConfirmation(_ pending: TurnRetentionSettings) -> some View {
        if let message = pendingRemoval.message {
            HStack(spacing: 8) {
                Label {
                    message
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SupervisionTokens.waitingText.color)
                }
                Spacer(minLength: 8)
                Button("Cancel") {
                    pendingRetention = nil
                }
                Button("Delete Records", role: .destructive) {
                    store.settings.advanced.turnRetention = pending
                    pendingRetention = nil
                }
            }
            .settingsControlRow()
            .accessibilityElement(children: .contain)
        }
    }
}

/// What the sweep says a waiting turn history deletes.
private enum PendingRemoval: Equatable {
    /// Being counted: nothing is said yet.
    case counting
    case removes(Int)
    /// The rules could not count them.
    case unknown

    var message: Text? {
        switch self {
        case .counting: nil
        case let .removes(count): Text("Up to \(count) turn records will be deleted. This can’t be undone.")
        case .unknown: Text("This can’t be undone.")
        }
    }
}
