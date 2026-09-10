// SurfaceView+Keyboard.swift
// Limpid — `NSResponder` keyboard + clipboard pipeline. Split out of
// `SurfaceView.swift` to keep the main file focused on layer / view
// lifecycle. Covers the four entry points AppKit walks for a
// keystroke (`performKeyEquivalent`, `keyDown`, `keyUp`,
// `flagsChanged`), the IME-coordinated `forward(_:action:…)` helper
// that re-encodes the event for libghostty, `commitText(_:)` for
// text an input method committed, and the responder-chain
// clipboard selectors (`paste:`, `copy:`).
//
// The companion `SurfaceView+Input.swift` holds the static
// `NSEvent` → `ghostty_input_key_s` helpers
// (`translateMods` / `makeKeyEvent` / `bindingText` /
// `eventHitsKeybind`) used below; `SurfaceView+TextInput.swift` holds
// the `NSTextInputClient` IME conformance.

import AppKit
import GhosttyKit

extension SurfaceView {

    // MARK: - Clipboard (responder-chain selectors)

    /// `paste:` / `copy:` are the macOS-standard responder-chain
    /// selectors AppKit dispatches when the user picks Edit > Paste /
    /// Edit > Copy or presses ⌘V / ⌘C. By implementing them on
    /// `SurfaceView`, the keystroke automatically reaches the
    /// **focused** pane (the first responder), instead of being
    /// claimed by whichever surface NSWindow's `performKeyEquivalent`
    /// traversal happens to visit first. Pre-ghostty#57 libghostty supplied
    /// `super+c=copy_to_clipboard` / `super+v=paste_from_clipboard`
    /// from its built-in macOS defaults; ghostty#57 added `keybind = clear`
    /// which wiped those, and re-adding them as ordinary keybind
    /// lines reintroduces the wrong-pane bug because libghostty's
    /// binding table is per-surface but the trigger is identical
    /// across all of them. Routing through the responder chain
    /// solves both problems: focused-pane routing falls out of
    /// AppKit's existing dispatch, and Edit menu clicks work for
    /// free.
    ///
    /// We forward to libghostty via `ghostty_surface_binding_action`
    /// (the same path `SearchActions.endSearch/searchNext/...` uses)
    /// so libghostty's clipboard plumbing — including its prompt for
    /// suspicious paste content — still runs.
    @objc func paste(_ sender: Any?) {
        guard let surface else { return }
        let action = "paste_from_clipboard"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        let action = "copy_to_clipboard"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: - Responder entry points

    /// Route ⌘Q to `NSApplication.terminate(_:)` so the standard
    /// termination chain (including `applicationWillTerminate`) runs.
    ///
    /// Without this override, libghostty's surface key pipeline
    /// consumes the keystroke before AppKit gets a chance to ask the
    /// main menu, so the SwiftUI-auto-generated Quit shortcut never
    /// fires. The save handler in `LimpidApp` (registered for
    /// `willTerminateNotification`) is therefore skipped on every
    /// ⌘Q quit — silent data loss. Sending the event straight to
    /// `terminate` reproduces what a mouse click on "Quit Limpid"
    /// already does correctly.
    ///
    /// Companion fix in `Info.plist`: `NSSupportsSuddenTermination`
    /// and `NSSupportsAutomaticTermination` are now `false` so macOS
    /// actually fires `applicationWillTerminate` instead of
    /// short-circuiting to `_exit`. Companion fix in
    /// `GhosttyConfigBridge`: `keybind = super+q=unbind` so
    /// libghostty's own `.quit` action can't race the terminate path.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "q"
        {
            NSApp.terminate(nil)
            return true
        }

        // Focus guard: only the focused surface intercepts libghostty
        // keybinds. `NSWindow.performKeyEquivalent` traverses every
        // subview, so without this check the first SurfaceView the
        // traversal visits would claim the event regardless of which
        // pane the user is actually working in — ⌘+ would resize the
        // wrong split, etc. Routing through the responder chain
        // (firstResponder === self) re-aligns the fast-path with
        // focus, the same property the new `paste:` / `copy:`
        // selectors get for free from AppKit's built-in dispatch.
        guard self.window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }

        // libghostty keybind fast-path. Beats the IME chain (notably
        // JIS Kotoeri grabbing ⌘⇧- in `interpretKeyEvents`). We
        // redispatch via `keyDown` because calling `ghostty_surface_key`
        // straight from `performKeyEquivalent` never fires the action
        // callback. Same shape as Ghostty's macOS app.
        //
        // When the event matches a binding we probe the main menu
        // first so menu-owned shortcuts (⌘J, ⌘⇧R, …) respect their
        // current enabled state — disabled items fall through to
        // libghostty's `=ignore` and drop silently instead of leaking
        // the literal character. Mirrors `Ghostty.MenuShortcutManager`.
        if event.type == .keyDown,
           let surface,
           Self.eventHitsKeybind(event: event, surface: surface)
        {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }
            self.keyDown(with: event)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.consumeAsynchronousCompositionEnter(
            keyCode: event.keyCode,
            timestamp: event.timestamp,
            interval: &asynchronousCompositionInterval
        ) {
            return
        }
        let flags = event.modifierFlags

        // Fast path for control-modified terminal input (Ctrl+C,
        // Ctrl+D, …). These are terminal control input, not text
        // composition: bypass AppKit's text interpretation and route
        // directly through libghostty. Gated on `!hasMarkedText()` so
        // an active IME composition can still own Ctrl-keys it cares
        // about (e.g. cancel).
        if flags.contains(.control),
           !flags.contains(.command),
           !flags.contains(.option),
           !hasMarkedText(),
           let surface
        {
            var key = Self.makeKeyEvent(
                from: event,
                action: GHOSTTY_ACTION_PRESS,
                consumedMods: GHOSTTY_MODS_NONE
            )
            // libghostty encodes the actual control byte itself
            // (Ctrl+C → 0x03), so we hand it the unshifted character
            // and let its encoder do the work.
            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            let handled = text.withCString { ptr in
                key.text = text.isEmpty ? nil : ptr
                return ghostty_surface_key(surface, key)
            }
            if handled {
                return
            }
            // Otherwise fall through and let IME try.
        }

        // While composing, arrows / ESC / tab belong to the IME (candidate
        // navigation, cancel, select), not the terminal. Same `!hasMarkedText()`
        // gate as the control fast-path above.
        if !hasMarkedText(), isNavigationOrFunctionKey(event) {
            // For ESC (keyCode 53) keep `text=event.characters` so libghostty
            // can write the bare ESC byte. For other navigation/function keys
            // suppress text so the keyCode → escape-sequence translation
            // isn't double-encoded.
            forward(event, action: GHOSTTY_ACTION_PRESS, suppressText: event.keyCode != 53)
            return
        }

        // IME path. Accumulate any text the input context commits during
        // this dispatch so we can forward it as a single key event to
        // libghostty — the same accumulation Ghostty's own macOS app
        // (MIT) uses. `activeKeyEvent` lets `doCommand:` re-forward the
        // underlying key when IME consumes the keystroke as an editor
        // command instead.
        activeKeyEvent = event
        defer { activeKeyEvent = nil }
        let translationEvent = surface.map {
            Self.translationEvent(from: event, surface: $0)
        } ?? event
        activeTranslationKeyEvent = translationEvent
        defer { activeTranslationKeyEvent = nil }
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let wasComposing = hasMarkedText()
        let consumed = inputContext?.handleEvent(translationEvent) ?? false
        let accumulated = keyTextAccumulator ?? []
        // Treat ⌘ / ⌃ / ⌥ as "this is a keybind, not text composition".
        // Kotoeri returns `consumed = true` for ⇧⌘ combos without
        // emitting committed text, so a pure `!consumed` gate would
        // drop legitimate keybinds — we forward those anyway when a
        // modifier is held. Plain (non-modifier) keystrokes that the
        // IME consumes — including synthetic / accessibility events
        // whose `characters` is a bare `\r` after every prompt — stay
        // dropped, which is what fixes the double-prompt bug.
        let hasKeybindModifiers = !event.modifierFlags
            .isDisjoint(with: [.command, .control, .option])

        if !accumulated.isEmpty {
            if wasComposing {
                // IME committed composed text. forward() would match
                // keybinds like shift+enter=text:\n on the underlying
                // key event and discard the composed text, so we commit
                // it without a physical key instead.
                for text in accumulated where !Self.isSuppressibleControlInput(text) {
                    commitText(text)
                }
            } else {
                // Regular (non-IME) text — forward as a key event
                // so libghostty's encoder runs normally.
                for text in accumulated {
                    forward(
                        event,
                        action: GHOSTTY_ACTION_PRESS,
                        overrideText: text,
                        translationEvent: translationEvent
                    )
                }
            }
        } else if !hasMarkedText(), !consumed || hasKeybindModifiers {
            forward(
                event,
                action: GHOSTTY_ACTION_PRESS,
                translationEvent: translationEvent
            )
        }
        // else: preedit active — the keystroke belongs to the IME.
    }

    /// Returns true for keys that the input context tends to swallow as
    /// editor selectors but that should go straight to the terminal.
    private func isNavigationOrFunctionKey(_ event: NSEvent) -> Bool {
        // macOS virtual keycodes for the keys we want to bypass.
        let bypassKeyCodes: Set<UInt16> = [
            123, 124, 125, 126, // arrows: left, right, down, up
            115, 116, 117, 119, 121, // home, page up, fwd-delete, end, page down
            53, // escape
            48, // tab
            96, 97, 98, 99, 100, 101, // F-keys
            109, 103, 111, 105, 107,
            113, 106, 64, 79, 80
        ]
        return bypassKeyCodes.contains(event.keyCode)
    }

    /// We compare occurrence times because Dictation can commit asynchronously
    /// before AppKit dispatches the Enter that ended composition. An Enter
    /// pressed after the commit (including after microphone-key termination)
    /// must still reach the terminal, regardless of how soon it follows.
    static func consumeAsynchronousCompositionEnter(
        keyCode: UInt16,
        timestamp: TimeInterval,
        interval: inout ClosedRange<TimeInterval>?
    ) -> Bool {
        // macOS virtual keycodes for the keys that commit a composition.
        let commitKeyCodes: Set<UInt16> = [
            36, // return
            76 // keypad enter
        ]
        defer { interval = nil }
        guard let interval else { return false }
        return commitKeyCodes.contains(keyCode) && interval.contains(timestamp)
    }

    override func keyUp(with event: NSEvent) {
        forward(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        // Bare modifier presses during IME composition clear the
        // preedit visually (ghostty#4634). Suppress them.
        if hasMarkedText() {
            return
        }
        // Keep the pane-drag cursor in sync on every modifier change so
        // ⌥⌘ press/release flips the cursor without waiting for a
        // mouse move.
        updatePaneDragCursor(event)
        forward(event, action: GHOSTTY_ACTION_PRESS)
    }

    @discardableResult
    func forward(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        suppressText: Bool = false,
        overrideText: String? = nil,
        translationEvent suppliedTranslationEvent: NSEvent? = nil
    ) -> Bool {
        guard let surface else { return false }
        let translationEvent = suppliedTranslationEvent
            ?? (event.type == .keyDown
                ? Self.translationEvent(from: event, surface: surface)
                : event)
        let consumedMods = Self.translateMods(
            translationEvent.modifierFlags.subtracting([.control, .command])
        )
        var key = Self.makeKeyEvent(from: event, action: action, consumedMods: consumedMods)
        // Text source: explicit override (IME accumulator) wins;
        // otherwise re-encode with only text-shaping mods so JIS
        // ⇧⌘+- surfaces as "=" (see `bindingText` for why).
        let textSource: String? = if let overrideText {
            overrideText
        } else if suppressText {
            nil
        } else {
            Self.bindingText(from: translationEvent)
        }
        // Only attach `key.text` when the candidate text is printable
        // (first byte ≥ 0x20). Control characters (`\r`, `\n`, `\t`,
        // ctrl-modified keys) are encoded by libghostty itself from
        // the keycode + mods — passing them through `key.text`
        // overrides that encoder and breaks `ctrl+enter`. It also
        // lets synthetic / accessibility keyDown events whose
        // `characters` is a bare `\r` write a literal carriage
        // return into the pty after every command, triggering zsh's
        // `accept-line` on an empty buffer and drawing a second
        // prompt.
        var handled = false
        if let chars = textSource,
           !chars.isEmpty,
           let firstByte = chars.utf8.first,
           firstByte >= 0x20
        {
            chars.withCString { ptr in
                key.text = ptr
                handled = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            handled = ghostty_surface_key(surface, key)
        }
        return handled
    }

    /// Commits text an input method produced — IME confirmation,
    /// Dictation, the character viewer — as typed input.
    ///
    /// `ghostty_surface_text` is libghostty's paste entry point, so it
    /// brackets the text whenever the program has bracketed paste on,
    /// and the program then applies paste handling to a dictated word.
    /// A key event avoids that, but a real one carries the physical key
    /// that ended the composition and libghostty matches keybinds
    /// before encoding — `shift+enter` is bound to `text:\n`, so the
    /// committed text would be dropped for the binding's action.
    ///
    /// We therefore send a key event with no key: `keycode` is a value
    /// the macOS keycode table doesn't map, which libghostty resolves
    /// to `unidentified`, and no modifiers are set. Nothing can match a
    /// binding, and the encoder — finding no table entry and no
    /// modifiers to apply — writes `text` to the pty verbatim. A
    /// keycode of `0` would resolve to `KeyA` on macOS and could
    /// collide with a bare-letter keybind.
    ///
    /// Verbatim also covers control characters, so callers screen them
    /// with `isSuppressibleControlInput(_:)`.
    @discardableResult
    func commitText(_ text: String) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32.max
        key.unshifted_codepoint = 0
        key.composing = false
        return text.withCString { ptr in
            key.text = ptr
            return ghostty_surface_key(surface, key)
        }
    }

    /// A lone control character is never text the terminal should
    /// receive: `commitText` writes it to the pty as-is, and a bare
    /// `\r` fires zsh's `accept-line` on an empty buffer — the double
    /// prompt `forward()` already screens out.
    static func isSuppressibleControlInput(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard let first = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex
        else { return false }
        return first.value < 0x20
    }
}
