// SparkleUpdater.swift
// Limpid — Sparkle integration: owns the `SPUUpdater` and exposes its
// state to SwiftUI so the Check for Updates menu item stays in sync.

import Sparkle
import SwiftUI

/// View model that surfaces Sparkle's `canCheckForUpdates` flag as a
/// `@Published` property so SwiftUI views can disable the menu item
/// while the updater is busy.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// SwiftUI button suitable for placement in `CommandGroup(after: .appInfo)`.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
