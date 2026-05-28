// SurfaceView.swift
// Limpid — `NSView` host for one libghostty terminal surface; owns the
// surface lifetime, routes input/IME, and delegates drawing to Metal.

import AppKit
import GhosttyKit
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "surface.view")

/// `NSView` hosting one libghostty terminal surface.
///
/// Drawing is delegated entirely to libghostty (Metal-backed); we just
/// provide the layer-backed view, pipe events in, and own the
/// `ghostty_surface_t` lifetime.
final class SurfaceView: NSView {
    private weak var ghosttyApp: GhosttyApp?
    nonisolated(unsafe) var surface: ghostty_surface_t?

    /// IME composition buffer. Mirrors NSTextInputClient's marked text and
    /// is pushed to libghostty via ghostty_surface_preedit.
    private var markedText: String = ""

    /// keyDown event currently being routed through the input context.
    /// doCommand uses this to forward the exact event to libghostty,
    /// since `NSApp.currentEvent` can be unreliable mid-dispatch.
    private var activeKeyEvent: NSEvent?

    /// Buffer for `insertText:` calls that fire during a `keyDown` IME
    /// pass. When non-nil we're inside a key dispatch and IME committed
    /// text should accumulate here rather than be sent immediately —
    /// matches cmux's pattern. When nil, `insertText:` is being called
    /// from somewhere else (voice input, accessibility) and we send the
    /// text straight through.
    private var keyTextAccumulator: [String]?

    /// Last bounds + backing scale we already pushed to the layer.
    /// `syncLayerOnly` short-circuits when these match the current
    /// values so a window drag doesn't fan out into a CATransaction
    /// per 60 Hz tick on every resize-observer leg.
    private var lastSyncedBounds: NSRect = .zero
    private var lastSyncedScale: CGFloat = 0

    /// Recover a SurfaceView from a libghostty surface userdata pointer.
    /// libghostty hands back whatever pointer we stored in
    /// `surface_config.userdata` (we set it to `Unmanaged.passUnretained(self)`).
    ///
    /// Direct `takeUnretainedValue` is UAF-prone when libghostty fires a
    /// callback after the Swift view has deinited but before
    /// `ghostty_surface_free` has actually returned (deinit hops to
    /// MainActor asynchronously). Callers should prefer
    /// `liveView(forUserdata:)` which validates against the weak
    /// `liveViews` set first.
    static func from(userdata: UnsafeMutableRawPointer) -> SurfaceView {
        Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Live SurfaceViews keyed weakly so a deallocated view auto-drops
    /// out. Lets late libghostty callbacks check whether a userdata
    /// pointer still corresponds to a real Swift object before
    /// dereferencing into freed memory.
    @MainActor private static let liveViews = NSHashTable<SurfaceView>.weakObjects()

    /// Validated counterpart to `from(userdata:)`: returns nil when the
    /// pointer no longer matches any live view. Must be called on
    /// MainActor — the registry isn't synchronised.
    @MainActor
    static func liveView(forUserdata ptr: UnsafeMutableRawPointer) -> SurfaceView? {
        for case let view as SurfaceView in liveViews.allObjects
            where Unmanaged.passUnretained(view).toOpaque() == ptr
        {
            return view
        }
        return nil
    }

    /// Initial working directory for the first shell launched inside
    /// this surface. Set by `PaneHostView` from `Tab.workingDirectory`
    /// before `viewDidMoveToWindow` triggers `createSurface`.
    /// Owned C buffer kept alive for ghostty's internal copy.
    var initialWorkingDirectory: String?
    private nonisolated(unsafe) var workingDirectoryCStr: UnsafeMutablePointer<CChar>?

    /// Path to a `.vt` file written by `ghostty_surface_write_scrollback`
    /// on a previous quit. When set, ghostty replays it before the
    /// shell starts so the visible state survives an app restart.
    var initialScrollbackPath: String?
    private nonisolated(unsafe) var scrollbackPathCStr: UnsafeMutablePointer<CChar>?

    /// Shell command sent into the surface a short delay after libghostty
    /// hands us a live surface. The delay lets the shell print its
    /// prompt first so the typed command lands on a clean line. See
    /// `Tab.initialCommands` for the model-level documentation.
    var initialCommand: String?

    /// Extra environment variables merged into the pty environment when
    /// libghostty spawns the shell. Pre-existing entries with the same
    /// key are overridden (PATH-prepending is the caller's job). Set by
    /// `PaneHostView` before `viewDidMoveToWindow` triggers
    /// `createSurface`. C buffers are kept alive for ghostty's internal
    /// copy and freed in deinit alongside the cwd/scrollback buffers.
    var extraEnvironment: [String: String] = [:]
    nonisolated(unsafe) var envKeyBuffers: [UnsafeMutablePointer<CChar>] = []
    nonisolated(unsafe) var envValueBuffers: [UnsafeMutablePointer<CChar>] = []
    nonisolated(unsafe) var envVarsBuffer: UnsafeMutablePointer<ghostty_env_var_s>?

    /// Latest title libghostty reported for *this* surface (regardless
    /// of whether the surface is the focused leaf of its tab). The
    /// coordinator records it on every SET_TITLE so switching focus
    /// between split panes restores the right title immediately,
    /// without waiting for the newly-focused shell to re-emit OSC 0.
    var paneTitle: String?

    /// Callback fired on `mouseDown` so the host can mark the pane as
    /// acknowledged (clears the unread dot). Set by `PaneHostView` —
    /// SurfaceView itself doesn't know its pane id or the WindowSession.
    var onUserAcknowledge: (() -> Void)?

    init(ghosttyApp: GhosttyApp) {
        self.ghosttyApp = ghosttyApp
        // CAMetalLayer rejects subsequent drawableSize updates when the
        // view is created at frame .zero (see maplibre-native#67).
        // Initialize with a small non-zero rect to avoid that latch.
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        self.wantsLayer = true
        self.autoresizingMask = [.width, .height]
        // SwiftUI's NSViewRepresentable hosting doesn't call setFrameSize
        // during window drags. Subscribe to the view's own frame change
        // notification so we still see live resize events.
        self.postsFrameChangedNotifications = true
        self.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: self
        )
        Self.liveViews.add(self)
    }

    /// Dump the current scrollback state to `path` via libghostty's new
    /// public API. Used at quit time so the snapshot can be replayed on
    /// the next launch. Returns true on success.
    @discardableResult
    func writeScrollback(to path: String) -> Bool {
        guard let surface else { return false }
        return path.withCString { ptr in
            ghostty_surface_write_scrollback(surface, ptr)
        }
    }

    @objc private func frameDidChange(_ note: Notification) {
        syncLayerOnly()
        pushSurfaceSize()
    }

    private func syncLayerOnly() {
        guard let window else { return }
        // Cheap short-circuit: nothing has changed. We're called from
        // six different paths (frame, bounds, window resize, setFrameSize,
        // backing-property change, surface-create) and during a window
        // drag they all fire at 60 Hz with the same values. The
        // CATransaction below is not free — the early-out drops the
        // resize hot path to a single comparison per tick.
        let scale = window.backingScaleFactor
        let currentBounds = bounds
        if lastSyncedBounds == currentBounds, lastSyncedScale == scale { return }
        lastSyncedBounds = currentBounds
        lastSyncedScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer {
            layer.contentsScale = scale
            layer.frame = currentBounds
        }
        if let metalLayer = layer as? CAMetalLayer {
            let backing = convertToBacking(currentBounds).size
            if backing.width > 0, backing.height > 0 {
                metalLayer.drawableSize = backing
            }
        }
        CATransaction.commit()
    }

    /// Push the current backing-pixel size + scale into libghostty.
    /// Used to live behind a 150 ms debounce, which left the Metal
    /// layer running ahead of the cell grid during a divider drag —
    /// characters appeared stretched until the user paused. Both
    /// ghostty's own macOS app and cmux call set_size on every layout
    /// pass with no debounce, relying on AppKit's natural ≤60 Hz cap.
    /// Idempotent guards below avoid duplicate calls when the size or
    /// scale hasn't actually changed since the last push.
    private var lastPushedSize: (width: UInt32, height: UInt32)?
    private var lastPushedScale: Double?

    private func pushSurfaceSize() {
        guard let surface, let window else { return }
        let backing = convertToBacking(bounds).size
        guard backing.width > 0, backing.height > 0 else { return }
        let scale = Double(window.backingScaleFactor)
        if scale != lastPushedScale {
            ghostty_surface_set_content_scale(surface, scale, scale)
            lastPushedScale = scale
        }
        let width = UInt32(backing.width)
        let height = UInt32(backing.height)
        if lastPushedSize?.width != width || lastPushedSize?.height != height {
            ghostty_surface_set_size(surface, width, height)
            lastPushedSize = (width, height)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layer backing

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.displaySyncEnabled = true
        layer.wantsExtendedDynamicRangeContent = true
        return layer
    }

    // MARK: - `NSView` lifecycle

    private nonisolated(unsafe) var windowResizeObserver: (any NSObjectProtocol)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Drop any previous observer (view may move between windows).
        if let obs = windowResizeObserver {
            NotificationCenter.default.removeObserver(obs)
            windowResizeObserver = nil
        }

        guard let window else { return }
        if surface == nil { createSurface() }
        window.makeFirstResponder(self)

        // SwiftUI's WindowGroup hosting doesn't always propagate frame
        // changes down to `NSViewRepresentable`'s `NSView` (we verified
        // via logs: setFrameSize never fires during a window drag). Observe
        // the window directly and push the size ourselves.
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // The notification arrives on .main but the closure is
            // declared @Sendable / nonisolated, so we have to hop into
            // MainActor explicitly before touching SurfaceView state.
            MainActor.assumeIsolated {
                self?.syncLayerOnly()
                self?.pushSurfaceSize()
            }
        }
    }

    deinit {
        // `surface` is `nonisolated(unsafe)`, but the deinit may run on any
        // thread under Swift 6, so hop everything to MainActor to keep the
        // libghostty / NotificationCenter interactions safe.
        let s = surface
        let obs = windowResizeObserver
        let wdBuf = workingDirectoryCStr
        let sbBuf = scrollbackPathCStr
        let envKeys = envKeyBuffers
        let envValues = envValueBuffers
        let envArray = envVarsBuffer
        Task { @MainActor in
            if let s { ghostty_surface_free(s) }
            if let obs { NotificationCenter.default.removeObserver(obs) }
            if let wdBuf { free(wdBuf) }
            if let sbBuf { free(sbBuf) }
            for buf in envKeys {
                free(buf)
            }
            for buf in envValues {
                free(buf)
            }
            if let envArray { envArray.deallocate() }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerOnly()
        pushSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerOnly()
        pushSurfaceSize()
    }

    /// Mutation-driven sync path: the SwiftUI host (`PaneHostView`)
    /// passes the measured size via `GeometryReader` so we can push a
    /// fresh content size to libghostty without waiting on AppKit's
    /// frame-change cascade. The notification-driven channels still
    /// fire too — `pushSurfaceSize` skips duplicates via its cached
    /// last-push size.
    func applyExpectedSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // Only re-push if the new size differs from what AppKit
        // already reflects — avoids redundant ghostty_surface_set_size
        // calls during static layout.
        if abs(bounds.width - size.width) < 0.5,
           abs(bounds.height - size.height) < 0.5
        {
            return
        }
        pushSurfaceSize()
    }

    // MARK: - First responder / keyboard

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        // Don't clear unread here — AppKit auto-focuses the pane on tab
        // switch which would wipe the ring before the user has had a
        // chance to see it. We clear in `mouseDown` instead so the user
        // has to actively click into the pane to acknowledge.
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    // MARK: - Clipboard (responder-chain selectors)

    /// `paste:` / `copy:` are the macOS-standard responder-chain
    /// selectors AppKit dispatches when the user picks Edit > Paste /
    /// Edit > Copy or presses ⌘V / ⌘C. By implementing them on
    /// `SurfaceView`, the keystroke automatically reaches the
    /// **focused** pane (the first responder), instead of being
    /// claimed by whichever surface NSWindow's `performKeyEquivalent`
    /// traversal happens to visit first. Pre-#57 libghostty supplied
    /// `super+c=copy_to_clipboard` / `super+v=paste_from_clipboard`
    /// from its built-in macOS defaults; #57 added `keybind = clear`
    /// which wiped those, and re-adding them as ordinary keybind
    /// lines reintroduces the wrong-pane bug because libghostty's
    /// binding table is per-surface but the trigger is identical
    /// across all of them. Routing through the responder chain
    /// solves both problems: focused-pane routing falls out of
    /// AppKit's existing dispatch, and Edit menu clicks work for
    /// free.
    ///
    /// We forward to libghostty via `ghostty_surface_binding_action`
    /// (the same path `SessionActions.endSearch/searchNext/...` uses)
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

        // libghostty keybind fast-path. Lets the binding fire before
        // the menu bar / IME chain swallows it (notably JIS Kotoeri
        // grabbing ⌘⇧- in `interpretKeyEvents`). We redispatch via
        // `keyDown` rather than calling `ghostty_surface_key`
        // directly — calling it from `performKeyEquivalent` looks
        // like it works but the action callback never fires.
        // Same pattern as Ghostty's macOS app.
        if event.type == .keyDown,
           let surface,
           Self.eventHitsKeybind(event: event, surface: surface)
        {
            self.keyDown(with: event)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags

        // Fast path for control-modified terminal input (Ctrl+C,
        // Ctrl+D, …). These are terminal control input, not text
        // composition: bypass AppKit's text interpretation and route
        // directly through libghostty. Mirrors cmux's pattern. Gated
        // on `!hasMarkedText()` so an active IME composition can
        // still own Ctrl-keys it cares about (e.g. cancel).
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
            if handled { return }
            // Otherwise fall through and let IME try.
        }

        if isNavigationOrFunctionKey(event) {
            // For ESC (keyCode 53) keep `text=event.characters` so libghostty
            // can write the bare ESC byte. For other navigation/function keys
            // suppress text so the keyCode → escape-sequence translation
            // isn't double-encoded.
            forward(event, action: GHOSTTY_ACTION_PRESS, suppressText: event.keyCode != 53)
            return
        }

        // IME path. Accumulate any text the input context commits during
        // this dispatch so we can forward it as a single key event to
        // libghostty (cmux pattern). `activeKeyEvent` lets `doCommand:`
        // re-forward the underlying key (Calyx pattern) when IME consumes
        // the keystroke as an editor command instead.
        activeKeyEvent = event
        defer { activeKeyEvent = nil }
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let consumed = inputContext?.handleEvent(event) ?? false
        let accumulated = keyTextAccumulator ?? []
        // Treat ⌘ / ⌃ / ⌥ as "this is a keybind, not text composition".
        // Kotoeri returns `consumed = true` for Shift+⌘ combos without
        // emitting committed text, so a pure `!consumed` gate would
        // drop legitimate keybinds — we forward those anyway when a
        // modifier is held. Plain (non-modifier) keystrokes that the
        // IME consumes — including synthetic / accessibility events
        // whose `characters` is a bare `\r` after every prompt — stay
        // dropped, which is what fixes the double-prompt bug.
        let hasKeybindModifiers = !event.modifierFlags
            .isDisjoint(with: [.command, .control, .option])

        if !accumulated.isEmpty {
            // IME committed text via insertText: — forward each chunk
            // as a key event so libghostty's encoder runs normally.
            for text in accumulated {
                forward(event, action: GHOSTTY_ACTION_PRESS, overrideText: text)
            }
        } else if !hasMarkedText(), !consumed || hasKeybindModifiers {
            forward(event, action: GHOSTTY_ACTION_PRESS)
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

    override func keyUp(with event: NSEvent) {
        forward(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        forward(event, action: GHOSTTY_ACTION_PRESS)
    }

    @discardableResult
    private func forward(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        suppressText: Bool = false,
        overrideText: String? = nil
    ) -> Bool {
        guard let surface else { return false }
        let consumedMods = Self.translateMods(
            event.modifierFlags.subtracting([.control, .command])
        )
        var key = Self.makeKeyEvent(from: event, action: action, consumedMods: consumedMods)
        // Text source: explicit override (IME accumulator) wins;
        // otherwise re-encode with only text-shaping mods so JIS
        // Shift+⌘+- surfaces as "=" (see `bindingText` for why).
        let textSource: String? = if let overrideText {
            overrideText
        } else if suppressText {
            nil
        } else {
            Self.bindingText(from: event)
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

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    override func mouseDown(with event: NSEvent) {
        // A click inside the pane is the user acknowledging it — clear
        // any pending unread ring/dot now. This is the trigger instead
        // of `becomeFirstResponder` because tab switches re-focus the
        // pane automatically and would otherwise dismiss the ring
        // before the user has even looked.
        onUserAcknowledge?()
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePos(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        // Convert wheel delta to ghostty's "lines" convention.
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas { scrollMods |= 1 << 0 }
        switch event.momentumPhase {
        case .began: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue) << 1
        case .stationary: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue) << 1
        case .changed: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1
        case .ended: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue) << 1
        case .cancelled: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue) << 1
        case .mayBegin: scrollMods |= Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue) << 1
        default: break
        }
        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            scrollMods
        )
    }

    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.translateMods(event.modifierFlags))
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Pass POINTS (not pixels): libghostty handles the content-scale
        // conversion internally. AppKit's origin is bottom-left, libghostty
        // expects top-left.
        let x = Double(p.x)
        let y = Double(bounds.height - p.y)
        ghostty_surface_mouse_pos(surface, x, y, Self.translateMods(event.modifierFlags))
    }

    fileprivate func pushPreedit() {
        guard let surface else { return }
        markedText.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr)))
        }
    }
}

// MARK: - NSTextInputClient

extension SurfaceView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let str: String
        switch string {
        case let s as NSAttributedString: str = s.string
        case let s as String: str = s
        default: return
        }
        markedText = str
        pushPreedit()
    }

    func unmarkText() {
        if !markedText.isEmpty {
            markedText = ""
            pushPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Composition is done; clear preedit before committing the text.
        unmarkText()
        let chars: String
        switch string {
        case let s as NSAttributedString: chars = s.string
        case let s as String: chars = s
        default: return
        }
        guard !chars.isEmpty else { return }

        // If we're inside a keyDown dispatch, accumulate so the caller can
        // forward the committed text as a normal key event (lets libghostty's
        // encoder run on it). Otherwise the call came from outside the key
        // pipeline (voice input, accessibility) — send as paste.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        guard let surface else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Place the IME candidate window near the view origin. Proper caret
        // tracking lives in a later phase (query libghostty for the cursor
        // rectangle).
        guard let window else { return .zero }
        let viewRect = NSRect(origin: .zero, size: .zero)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    override func doCommand(by selector: Selector) {
        // IME consumed the keyDown and dispatched an editor selector
        // (insertNewline:, deleteBackward:, …). Forward the exact event
        // we're routing (captured in keyDown) so the terminal still
        // sees the key while IME is active.
        if let event = activeKeyEvent ?? NSApp.currentEvent, event.type == .keyDown {
            forward(event, action: GHOSTTY_ACTION_PRESS)
        }
    }

    // MARK: - Surface creation

    private func createSurface() {
        guard let app = ghosttyApp else {
            log.fault("createSurface called with no GhosttyApp")
            return
        }

        let scale = window?.backingScaleFactor ?? 1.0
        let viewPtr = Unmanaged.passUnretained(self).toOpaque()

        var config = ghostty_surface_config_new()
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = viewPtr
        config.userdata = viewPtr
        config.scale_factor = scale

        // Point ghostty at the tab's stored cwd so the shell starts in
        // the project / worktree directory instead of $HOME. The C
        // string must outlive `ghostty_surface_new`; we stash it on
        // self and free it in deinit.
        if let wd = initialWorkingDirectory, !wd.isEmpty {
            // `strdup` returns NULL on OOM; handing that NULL to
            // libghostty would crash inside the C side. Skip the cwd
            // override and let the shell fall back to $HOME.
            if let buf = strdup(wd) {
                workingDirectoryCStr = buf
                config.working_directory = UnsafePointer(buf)
            } else {
                log.error("strdup(working_directory) returned NULL — falling back to $HOME")
            }
        }

        // Scrollback replay. The C string must outlive
        // `ghostty_surface_new`.
        if let path = initialScrollbackPath,
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path)
        {
            if let buf = strdup(path) {
                scrollbackPathCStr = buf
                config.initial_scrollback_path = UnsafePointer(buf)
                // The path embeds the pane UUID under the user's
                // Application Support dir — `.private` so the
                // unified log doesn't reveal session structure.
                log.notice("scrollback replay scheduled: path=\(path, privacy: .private)")
            } else {
                log.error("strdup(scrollback path) returned NULL — skipping replay")
            }
        }

        applyExtraEnvironment(into: &config)

        guard let s = ghostty_surface_new(app.handle, &config) else {
            log.fault("ghostty_surface_new returned NULL")
            return
        }
        surface = s

        // Initial sync — visual layer + immediate surface size.
        syncLayerOnly()
        pushSurfaceSize()
        log.notice("surface created (\(Int(self.bounds.width), privacy: .public)x\(Int(self.bounds.height), privacy: .public))")

        scheduleInitialCommandIfNeeded()
    }

    /// Type the `initialCommand` into the surface ~600ms after creation,
    /// then simulate a Return keypress to execute it. The delay gives
    /// the shell time to print its prompt; sending earlier risks the
    /// command landing inside the prompt-rendering output.
    ///
    /// Why two API calls instead of `command + "\n"` via
    /// `ghostty_surface_text` alone: libghostty documents that API as
    /// "treated like a paste" — under bracketed paste mode (default in
    /// modern zsh) a trailing `\n` is buffered as a literal newline in
    /// the edit buffer, not as Enter-to-execute. We deliver the body
    /// as paste-text and the submit via a synthesized Return key event
    /// so the shell actually runs the command.
    private func scheduleInitialCommandIfNeeded() {
        guard let command = initialCommand, !command.isEmpty else { return }
        let body = command.hasSuffix("\n") ? String(command.dropLast()) : command
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, let surface = self.surface else { return }
            body.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
            }
            self.sendReturnKey(to: surface)
        }
    }

    /// Synthesize a Return keypress (press + release) on `surface`.
    /// Used by `scheduleInitialCommandIfNeeded` to submit pasted text
    /// without depending on shell paste-mode quirks.
    private func sendReturnKey(to surface: ghostty_surface_t) {
        // macOS virtual keycode for Return is 36 (`kVK_Return`).
        let returnKeyCode: UInt32 = 36
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var key = ghostty_input_key_s()
            key.action = action
            key.keycode = returnKeyCode
            key.mods = ghostty_input_mods_e(0)
            key.consumed_mods = ghostty_input_mods_e(0)
            key.unshifted_codepoint = 0x0D
            key.composing = false
            if action == GHOSTTY_ACTION_PRESS {
                "\r".withCString { ptr in
                    key.text = ptr
                    _ = ghostty_surface_key(surface, key)
                }
            } else {
                key.text = nil
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

}
