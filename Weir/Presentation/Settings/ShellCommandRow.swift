// ShellCommandRow.swift
// Weir — what the Settings row of the shell command says and offers.

import Foundation

/// A plain value so that which action each state offers can be tested without
/// a view.
struct ShellCommandRow: Equatable {
    enum Action: Hashable {
        case install
        case repair
        case uninstall
        case showInFinder

        var title: LocalizedStringResource {
            switch self {
            case .install: "Install"
            case .repair: "Repair"
            case .uninstall: "Uninstall"
            case .showInFinder: "Show in Finder"
            }
        }

        var accessibilityLabel: LocalizedStringResource {
            switch self {
            case .install: "Install shell command"
            case .repair: "Repair shell command"
            case .uninstall: "Uninstall shell command"
            case .showInFinder: "Show the existing file in Finder"
            }
        }
    }

    let statusText: DisplayText
    let actions: [Action]

    /// `isAppOnReadOnlyVolume` takes away what would link here, since such a
    /// link breaks once the volume goes; removing a link stays possible.
    init(status: ShellCommandStatus, path: String, isAppOnReadOnlyVolume: Bool) {
        switch status {
        case .notInstalled:
            statusText = isAppOnReadOnlyVolume
                ? .localized("Move Weir to Applications to install the shell command.")
                : .localized("Not installed")
            actions = isAppOnReadOnlyVolume ? [] : [.install]
        case .installed:
            statusText = .localized("Installed at \(path)")
            actions = [.uninstall]
        case .staleLink:
            statusText = .localized("The link at \(path) doesn’t lead to this copy of Weir.")
            actions = isAppOnReadOnlyVolume ? [.uninstall] : [.repair, .uninstall]
        case .occupied:
            statusText = .localized("Another file is already at \(path). Weir leaves it as it is.")
            actions = [.showInFinder]
        }
    }
}
