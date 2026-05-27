// SurfaceView+Input.swift
// Limpid — static helpers for translating `NSEvent` into the
// `ghostty_input_key_s` struct libghostty expects. Lives outside
// `SurfaceView.swift` purely to keep that file's line count under
// the SwiftLint cap; logically these belong to the surface view.

import AppKit
import GhosttyKit

extension SurfaceView {

    /// `NSEvent.modifierFlags` → libghostty's `ghostty_input_mods_e`.
    /// We only forward the four primary modifiers plus caps lock —
    /// everything else (function key, numeric pad, etc.) is dropped
    /// because libghostty's keybind matcher doesn't look at them.
    static func translateMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// Build a `ghostty_input_key_s` from an NSEvent. Shared scaffold
    /// for the three call sites that hand events to libghostty
    /// (`performKeyEquivalent` fast-path, ctrl-only keyDown bypass,
    /// `forward`). Text is set separately because each site has its
    /// own opinion about shift-folding.
    @MainActor
    static func makeKeyEvent(
        from event: NSEvent,
        action: ghostty_input_action_e,
        consumedMods: ghostty_input_mods_e
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = (event.type == .keyDown && event.isARepeat) ? GHOSTTY_ACTION_REPEAT : action
        key.keycode = UInt32(event.keyCode)
        key.mods = translateMods(event.modifierFlags)
        key.consumed_mods = consumedMods
        key.composing = false
        if let unshifted = event.characters(byApplyingModifiers: []),
           let scalar = unshifted.unicodeScalars.first
        {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    /// Keystroke re-encoded with shift/option only — strips
    /// command/control so JIS ⌘⇧- produces "=" instead of bare "-".
    /// libghostty's utf8 binding match relies on this; same trick
    /// Ghostty's macOS app uses for its translation event.
    static func bindingText(from event: NSEvent) -> String {
        let textMods = event.modifierFlags.subtracting([.command, .control])
        return event.characters(byApplyingModifiers: textMods)
            ?? event.charactersIgnoringModifiers
            ?? ""
    }

    /// Does libghostty have a binding that would unconditionally
    /// fire on this event? Returns `false` for `performable`
    /// bindings — those need libghostty's live surface-state check,
    /// so we let them follow the normal keyDown path instead of
    /// short-circuiting here.
    @MainActor
    static func eventHitsKeybind(
        event: NSEvent,
        surface: ghostty_surface_t
    ) -> Bool {
        var key = makeKeyEvent(
            from: event,
            action: GHOSTTY_ACTION_PRESS,
            consumedMods: GHOSTTY_MODS_NONE
        )
        let text = bindingText(from: event)
        return text.withCString { ptr in
            key.text = text.isEmpty ? nil : ptr
            var flags = ghostty_binding_flags_e(0)
            guard ghostty_surface_key_is_binding(surface, key, &flags) else {
                return false
            }
            let isPerformable = (flags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0
            return !isPerformable
        }
    }
}
