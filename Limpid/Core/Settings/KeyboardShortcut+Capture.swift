// KeyboardShortcut+Capture.swift
// Limpid — the AppKit-touching half of the shortcut model. Pulling
// `NSEvent` translation into its own file lets the core
// `KeyboardShortcut.swift` stay free of `import AppKit`, which in
// turn keeps the model unit tests honest about not depending on
// AppKit (and lets the same types compile on a headless test host
// without dragging in the AppKit runtime).

import AppKit
import Carbon.HIToolbox

extension StoredShortcut {

    /// Capture a `StoredShortcut` from a `keyDown` event. Returns
    /// `nil` if the event has no usable key (modifier-only press,
    /// dead key, etc.).
    @MainActor
    static func capture(from event: NSEvent) -> StoredShortcut? {
        let modifiers = modifiersFromNSEvent(event.modifierFlags)
        guard let key = ghosttyKey(from: event) else { return nil }
        return StoredShortcut(key: key, modifiers: modifiers)
    }

    /// Translate AppKit's `NSEvent.modifierFlags` to our stable
    /// `ShortcutModifiers` bitset. Anything outside the four primary
    /// modifiers (caps lock, function key, …) is dropped — we never
    /// bind to those.
    private static func modifiersFromNSEvent(
        _ flags: NSEvent.ModifierFlags
    ) -> ShortcutModifiers {
        var set: ShortcutModifiers = []
        if flags.contains(.command) { set.insert(.command) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.control) { set.insert(.control) }
        return set
    }

    /// Carbon keyCodes → named-key strings for keys that don't have
    /// a useful character (arrows, function keys, return, escape…).
    /// Punctuation and digits intentionally aren't in this table —
    /// they're captured as their unshifted character via
    /// `charactersIgnoringModifiers`, which gives us the user's
    /// layout-specific literal (`=` on US's keyCode 24, `^` on JIS's
    /// same physical key) without us having to know the layout.
    private static let keyCodeNames: [UInt16: String] = [
        36: "return", 76: "return", // return, keypad enter
        48: "tab", 49: "space", 51: "backspace", 53: "escape",
        117: "delete", 115: "home", 119: "end",
        116: "page_up", 121: "page_down",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4",
        96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12"
    ]

    /// `NSEvent.keyCode` → stored key string. Named keys come from
    /// the table above; everything else translates the hardware
    /// keyCode through the active layout with **all** modifiers
    /// stripped. `charactersIgnoringModifiers` would otherwise still
    /// honor Shift, so a `⇧]` press would capture as `}` and the
    /// stored binding could never match the literal `]` libghostty
    /// expects in its keybind line.
    @MainActor
    private static func ghosttyKey(from event: NSEvent) -> String? {
        if let named = keyCodeNames[event.keyCode] { return named }
        if let translated = translateKeyCodeIgnoringShift(event.keyCode), !translated.isEmpty {
            return translated.lowercased()
        }
        // Last-ditch fallback: better to round-trip the shifted glyph
        // than to refuse the capture entirely.
        guard let raw = event.charactersIgnoringModifiers?.lowercased(),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    /// Translate `keyCode` through the active input source with zero
    /// modifiers. Uses Carbon's `UCKeyTranslate` because it's the only
    /// AppKit-side API that exposes the "no modifiers" mapping. The
    /// non-shifted character is what we store: `keyCode = 30` on a US
    /// layout returns `"]"` regardless of whether the live event held
    /// Shift, so the user's `⇧]` capture round-trips through
    /// libghostty's keybind file as `shift+]=…` instead of `}`.
    @MainActor
    private static func translateKeyCodeIgnoringShift(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { rawBuffer -> String? in
            guard let layoutBytes = rawBuffer.baseAddress else { return nil }
            let keyLayoutPtr = layoutBytes.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var actualStringLength = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                keyLayoutPtr,
                keyCode,
                UInt16(kUCKeyActionDown),
                0, // modifierKeyState — zero strips Shift, Option, …
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &actualStringLength,
                &chars
            )
            guard status == noErr, actualStringLength > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: actualStringLength)
        }
    }
}
