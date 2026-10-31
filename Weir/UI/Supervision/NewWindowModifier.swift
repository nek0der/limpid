// NewWindowModifier.swift
// Weir — whether the click that chose a row held ⌘, which opens it in a new window.

import AppKit
import SwiftUI

/// ⌘-click on a row of another project opens it in a new window.
/// A row that can take a gesture tells the two clicks apart itself
/// (`View.onClick(perform:)`). A `Button`, which says only that it was
/// pressed, by the keyboard and VoiceOver as well as by a click, reads ⌘
/// from the click AppKit is handling (`isCommandClick`).
@MainActor
enum NewWindowModifier {
    /// Whether the `Button` action being run is a ⌘-click: the event AppKit
    /// is handling is a click with ⌘ held. `NSApp.currentEvent` is the last
    /// event taken from the queue, and stays after it is handled, so only a
    /// click counts: a press from the keyboard or VoiceOver, or an action
    /// run later, is never read as one, whatever was held before. Nor are
    /// the keys held now, which are not the click's.
    static var isCommandClick: Bool {
        guard let event = NSApp.currentEvent else { return false }
        return isCommandClick(type: event.type, modifierFlags: event.modifierFlags)
    }

    /// Whether an event of `type` with `modifierFlags` is a ⌘-click: a press
    /// or release of the primary button with ⌘ alone (`isCommandOnly`).
    nonisolated static func isCommandClick(type: NSEvent.EventType, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard type == .leftMouseDown || type == .leftMouseUp else { return false }
        return isCommandOnly(modifierFlags)
    }

    /// Whether `modifierFlags` hold ⌘ alone of the keys that change a click
    /// (`chord`): what makes a click a ⌘-click at every row, so ⇧⌘ or ⌥⌘
    /// opens a row where it is wherever it is clicked.
    nonisolated static func isCommandOnly(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.chord == .command
    }
}

extension View {
    /// A click on the view, told whether it was a ⌘-click: SwiftUI's
    /// own tap with ⌘ first, then the plain tap, so the click is read as it
    /// happens rather than from an event AppKit has kept. SwiftUI's ⌘ tap
    /// also takes ⇧⌘ and ⌥⌘, so the keys held as it ends say whether ⌘ was
    /// alone (`NewWindowModifier.isCommandOnly`), as a `Button` row reads
    /// it (`NewWindowModifier.isCommandClick`).
    func onClick(perform action: @escaping (_ holdsCommand: Bool) -> Void) -> some View {
        gesture(
            TapGesture().modifiers(.command).onEnded { action(NewWindowModifier.isCommandOnly(NSEvent.modifierFlags)) }
                .exclusively(before: TapGesture().onEnded { action(false) })
        )
    }
}

/// The tooltip of a row ⌘-click opens in a new window, only on
/// such a row: an empty `.help` still installs a tooltip.
struct NewWindowHelp: ViewModifier {
    let isShown: Bool
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        if isShown {
            content.help(Text(verbatim: NewWindowText.clickHelp(locale: locale)))
        } else {
            content
        }
    }
}
