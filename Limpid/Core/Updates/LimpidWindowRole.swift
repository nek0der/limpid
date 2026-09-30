// LimpidWindowRole.swift
// Limpid — which of our windows an `NSWindow` is, as the updater reads it.

import AppKit

/// The SwiftUI `Window(id:)` scene id does not propagate to
/// `NSWindow.identifier`, so identifier-string filtering cannot tell the
/// main window from Settings. The UI tags each window through an associated
/// object instead (`LimpidWindowRoleMarker`),
/// and `LimpidUpdateDriver.hasInlineTarget` reads the tag here. Both
/// windows can show the inline update popover; a Sparkle alert window
/// carries neither tag.
enum LimpidWindowRole {
    case main
    case settings

    /// `objc_setAssociatedObject` needs a stable raw key. A static let keeps
    /// the address fixed for the process lifetime.
    fileprivate var associatedKey: UnsafeRawPointer {
        switch self {
        case .main: Self.mainKey
        case .settings: Self.settingsKey
        }
    }

    private nonisolated(unsafe) static let mainKey = makeKey()
    private nonisolated(unsafe) static let settingsKey = makeKey()

    private static func makeKey() -> UnsafeRawPointer {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        p.initialize(to: 0)
        return UnsafeRawPointer(p)
    }
}

extension NSWindow {
    func tagAsLimpid(_ role: LimpidWindowRole) {
        objc_setAssociatedObject(self, role.associatedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func isLimpid(_ role: LimpidWindowRole) -> Bool {
        (objc_getAssociatedObject(self, role.associatedKey) as? NSNumber)?.boolValue == true
    }

    /// `true` when the window hosts a Limpid main `ContentView`, not the
    /// Settings scene or a Sparkle alert window.
    var isLimpidMainWindow: Bool {
        isLimpid(.main)
    }

    /// `true` when the window hosts the `SettingsScene`, which also renders
    /// an inline `UpdatePopover` for the Update affordance on `GeneralPane`.
    var isLimpidSettingsWindow: Bool {
        isLimpid(.settings)
    }
}
