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

    /// Optional inherited config provided when a libghostty NEW_SPLIT
    /// builds the surface — carries the origin pane's cwd, command,
    /// font etc. so the split lands in the parent's environment.
    private var inheritedConfig: ghostty_surface_config_s?

    /// Initial working directory for the first shell launched inside
    /// this surface. Set by `PaneHostView` from `Tab.workingDirectory`
    /// before `viewDidMoveToWindow` triggers `createSurface`. Ignored
    /// when `inheritedConfig` is set (the parent split's cwd wins).
    /// Owned C buffer kept alive for ghostty's internal copy.
    var initialWorkingDirectory: String?
    private nonisolated(unsafe) var workingDirectoryCStr: UnsafeMutablePointer<CChar>?

    /// Path to a `.vt` file written by `ghostty_surface_write_scrollback`
    /// on a previous quit. When set on a fresh top-level surface, ghostty
    /// replays it before the shell starts so the visible state survives
    /// an app restart. Splits ignore this — they inherit the parent's
    /// running terminal state instead.
    var initialScrollbackPath: String?
    private nonisolated(unsafe) var scrollbackPathCStr: UnsafeMutablePointer<CChar>?

    /// Shell command sent into the surface a short delay after libghostty
    /// hands us a live surface. The delay lets the shell print its
    /// prompt first so the typed command lands on a clean line. See
    /// `Tab.initialCommands` for the model-level documentation.
    var initialCommand: String?

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

    convenience init(ghosttyApp: GhosttyApp, inheritedFrom config: ghostty_surface_config_s) {
        self.init(ghosttyApp: ghosttyApp)
        self.inheritedConfig = config
    }

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
        scheduleSurfaceSizePush()
    }

    private var pendingSurfaceResize: DispatchWorkItem?

    private func scheduleSurfaceSizePush() {
        pendingSurfaceResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pushSurfaceSize()
        }
        pendingSurfaceResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
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

    private func pushSurfaceSize() {
        guard let surface, let window else { return }
        let backing = convertToBacking(bounds).size
        guard backing.width > 0, backing.height > 0 else { return }
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
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
                self?.scheduleSurfaceSizePush()
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
        Task { @MainActor in
            if let s { ghostty_surface_free(s) }
            if let obs { NotificationCenter.default.removeObserver(obs) }
            if let wdBuf { free(wdBuf) }
            if let sbBuf { free(sbBuf) }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerOnly()
        scheduleSurfaceSizePush()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayerOnly()
        scheduleSurfaceSizePush()
    }

    /// Mutation-driven sync path: the SwiftUI host (`PaneHostView`)
    /// passes the measured size via `GeometryReader` so we can push a
    /// fresh content size to libghostty without waiting on AppKit's
    /// frame-change cascade. The notification-driven channels still
    /// fire too — `pushSurfaceSize` is debounced so duplicates collapse.
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
        scheduleSurfaceSizePush()
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

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags

        // Fast path for control-modified terminal input (Ctrl+C, Ctrl+D, …).
        // These are terminal control input, not text composition: bypass
        // AppKit's text interpretation and route directly through libghostty,
        // exactly how cmux does it (see cmux: GhosttyTerminalView.keyDown).
        if flags.contains(.control),
           !flags.contains(.command),
           !flags.contains(.option),
           !hasMarkedText(),
           let surface
        {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = Self.translateMods(flags)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = 0
            if let unshifted = event.characters(byApplyingModifiers: []),
               let scalar = unshifted.unicodeScalars.first
            {
                keyEvent.unshifted_codepoint = scalar.value
            }
            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            let handled: Bool
            if text.isEmpty {
                keyEvent.text = nil
                handled = ghostty_surface_key(surface, keyEvent)
            } else {
                handled = text.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
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

        if !accumulated.isEmpty {
            // IME committed text via insertText: — forward each chunk as a
            // key event so libghostty's encoder runs normally.
            for text in accumulated {
                forward(event, action: GHOSTTY_ACTION_PRESS, overrideText: text)
            }
        } else if !consumed {
            // Plain key (no IME consumption, no commit) — forward as-is.
            forward(event, action: GHOSTTY_ACTION_PRESS)
        }
        // else: IME consumed but emitted no text (e.g. dead-key composing,
        // or cancelOperation: which `doCommand:` already re-forwarded).
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

        var key = ghostty_input_key_s()
        key.action = (event.type == .keyDown && event.isARepeat) ? GHOSTTY_ACTION_REPEAT : action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.translateMods(event.modifierFlags)
        key.consumed_mods = Self.translateMods(
            event.modifierFlags.subtracting([.control, .command])
        )
        key.unshifted_codepoint = 0
        if let unshifted = event.characters(byApplyingModifiers: []),
           let scalar = unshifted.unicodeScalars.first
        {
            key.unshifted_codepoint = scalar.value
        }
        key.composing = false

        // Pick text source: explicit override (IME accumulator), otherwise
        // event.characters unless suppressed.
        let textSource: String? = if let overrideText { overrideText } else if suppressText { nil } else { event.characters }

        var handled = false
        if let chars = textSource, !chars.isEmpty {
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

    private static func translateMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
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

        // Start from libghostty's inherited config when this surface
        // descends from a split (so cwd / command / font carry over),
        // otherwise build a fresh top-level window config.
        var config: ghostty_surface_config_s
        if let inherited = inheritedConfig {
            config = inherited
        } else {
            config = ghostty_surface_config_new()
            config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        }
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = viewPtr
        config.userdata = viewPtr
        config.scale_factor = scale

        // For fresh top-level surfaces (no inherited config), point
        // ghostty at the tab's stored cwd so the shell starts in the
        // project / worktree directory instead of $HOME. The C string
        // must outlive `ghostty_surface_new`; we stash it on self and
        // free it in deinit.
        if inheritedConfig == nil, let wd = initialWorkingDirectory, !wd.isEmpty {
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

        // Scrollback replay — only on fresh top-level surfaces. Splits
        // inherit a live terminal state so a replay would corrupt it.
        // The C string must outlive `ghostty_surface_new`.
        if inheritedConfig == nil,
           let path = initialScrollbackPath,
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
