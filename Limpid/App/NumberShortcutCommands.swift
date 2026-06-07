// NumberShortcutCommands.swift
// Limpid — ⌘1…⌘9 (Nth tab in the active container) and ⌘⌃1…⌘⌃9
// (Nth top-level container) menu entries. Each entry is written
// out by hand instead of being generated with `ForEach` because
// SwiftUI's `CommandGroup` result builder snapshots the first
// iteration's `keyboardShortcut` and silently drops the updates
// from later iterations of an otherwise-identical Button — a
// `ForEach(1...9)` loop ends up registering ⌘1 only and leaves
// ⌘2…⌘9 unbound.

import SwiftUI

struct NumberShortcutCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .windowList) {
            goToTabButton(number: 1)
            goToTabButton(number: 2)
            goToTabButton(number: 3)
            goToTabButton(number: 4)
            goToTabButton(number: 5)
            goToTabButton(number: 6)
            goToTabButton(number: 7)
            goToTabButton(number: 8)
            goToTabButton(number: 9)
            goToSectionButton(number: 1)
            goToSectionButton(number: 2)
            goToSectionButton(number: 3)
            goToSectionButton(number: 4)
            goToSectionButton(number: 5)
            goToSectionButton(number: 6)
            goToSectionButton(number: 7)
            goToSectionButton(number: 8)
            goToSectionButton(number: 9)
        }
    }

    private func goToTabButton(number: Int) -> some View {
        Button {
            NavActions.activateTabInActiveContainer(at: number - 1, in: state.session)
        } label: {
            Label("Go to Tab \(number)", systemImage: "\(number).square")
        }
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
    }

    private func goToSectionButton(number: Int) -> some View {
        Button {
            NavActions.activateContainer(at: number - 1, in: state.session)
        } label: {
            Label("Go to Section \(number)", systemImage: "\(number).circle")
        }
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [.command, .control])
    }
}
