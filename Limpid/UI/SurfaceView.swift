// SurfaceView.swift
// Limpid — `NSView` host for one libghostty terminal surface; owns the
// surface lifetime, routes input/IME, and delegates drawing to Metal.

import AppKit
import GhosttyKit
import OSLog

private let log = Logger.limpid("surface.view")

/// `NSView` hosting one libghostty terminal surface.
///
/// Drawing is delegated entirely to libghostty (Metal-backed); we just
/// provide the layer-backed view, pipe events in, and own the
/// `ghostty_surface_t` lifetime.
final class SurfaceView: NSView {
    private weak var ghosttyApp: GhosttyApp?

    /// libghostty's surface handle. `nonisolated(unsafe)` because the C
    /// ABI dereferences it from render / event threads outside Swift's
    /// actor system; lifetime is bounded by `viewDidMoveToWindow` (init)
    /// → `deinit` (free), and the AppKit view itself is MainActor-only
    /// so Swift-side mutations stay confined to main.
    nonisolated(unsafe) var surface: ghostty_surface_t?

    /// One-shot flag flipped when `ghostty_surface_new` returns NULL.
    /// `PaneHostView` observes it via KVO-free re-evaluation (the host
    /// reads it during update) and renders an in-pane error card with
    /// a Retry button. A successful re-run of `createSurface` clears
    /// the flag.
    @objc dynamic var creationFailed: Bool = false

    /// IME composition buffer. Mirrors NSTextInputClient's marked text and
    /// is pushed to libghostty via ghostty_surface_preedit.
    var markedText: String = ""

    /// keyDown event currently being routed through the input context.
    /// doCommand uses this to forward the exact event to libghostty,
    /// since `NSApp.currentEvent` can be unreliable mid-dispatch.
    var activeKeyEvent: NSEvent?

    /// Buffer for `insertText:` calls that fire during a `keyDown` IME
    /// pass. When non-nil we're inside a key dispatch and IME committed
    /// text should accumulate here rather than be sent immediately —
    /// the same accumulation Ghostty's own macOS app (MIT) uses. When
    /// nil, `insertText:` is being called from somewhere else (voice
    /// input, accessibility) and we send the text straight through.
    var keyTextAccumulator: [String]?

    /// URL the mouse is currently hovering over (set by
    /// `GhosttyEventCoordinator` in response to `MOUSE_OVER_LINK`).
    var hoverUrl: String?

    /// Cursor shape requested by libghostty (e.g. pointing hand over
    /// a link). Updated by `GhosttyEventCoordinator` on
    /// `MOUSE_SHAPE` actions.
    var currentCursor: NSCursor = .iBeam

    /// Live SurfaceViews keyed by the raw pointer libghostty uses as
    /// `userdata`. The value side is a `WeakBox` so a deallocated view
    /// auto-drops to `nil` without us having to chase removal from
    /// every code path — `liveView(forUserdata:)` cleans the entry
    /// lazily on a nil hit. Pre-Phase-3 this was an
    /// `NSHashTable<SurfaceView>.weakObjects()` walked linearly on
    /// every C-callback dispatch (`O(n)` per call, with `n` running
    /// up to the count of every pane ever opened in the session); the
    /// dict makes the lookup `O(1)`.
    @MainActor private static var liveViewsByPointer: [UnsafeRawPointer: WeakBox] = [:]

    /// `weak` wrapper so a value-type dictionary can hold a weak class
    /// reference. Identical shape to the box `SurfaceRegistry` uses
    /// internally; lifted here so the surface-view lookup table can
    /// follow the same pattern.
    private final class WeakBox {
        weak var view: SurfaceView?
        init(_ view: SurfaceView) {
            self.view = view
        }
    }

    /// Recover a SurfaceView from a libghostty surface userdata
    /// pointer, validated against the live registry. Returns nil when
    /// the pointer no longer matches a live view: libghostty can fire
    /// a callback after the Swift view has deinited but before
    /// `ghostty_surface_free` returns (deinit hops to MainActor
    /// asynchronously), where a raw `takeUnretainedValue` would
    /// dereference freed memory. Must be called on MainActor — the
    /// registry isn't synchronised.
    ///
    /// O(1) average via the `liveViewsByPointer` dict. A nil
    /// `box.view` (the SurfaceView deallocated but the deinit task
    /// hasn't run yet) cleans the entry inline so a pointer reuse for
    /// a freshly-allocated SurfaceView doesn't read the stale slot.
    @MainActor
    static func liveView(forUserdata ptr: UnsafeMutableRawPointer) -> SurfaceView? {
        let key = UnsafeRawPointer(ptr)
        guard let box = liveViewsByPointer[key] else { return nil }
        if let view = box.view {
            return view
        }
        liveViewsByPointer.removeValue(forKey: key)
        return nil
    }

    /// Initial working directory for the first shell launched inside
    /// this surface. Set by `PaneHostView` from `Tab.workingDirectory`
    /// before `viewDidMoveToWindow` triggers `createSurface`.
    var initialWorkingDirectory: String?

    /// Owned C buffer fed into `ghostty_surface_new` so libghostty can
    /// copy from it internally. `nonisolated(unsafe)` because the
    /// nonisolated `deinit` hands the pointer to a MainActor `Task` to
    /// `free()` it. Mutation is confined to MainActor `createSurface()`
    /// (allocates via `strdup`, frees any prior buffer first) and the
    /// deinit Task (frees after libghostty no longer needs it), so
    /// there's no real concurrent access despite the unchecked
    /// declaration.
    private nonisolated(unsafe) var workingDirectoryCStr: UnsafeMutablePointer<CChar>?

    /// Path to a `.vt` file written by `ghostty_surface_write_scrollback`
    /// on a previous quit. When set, ghostty replays it before the
    /// shell starts so the visible state survives an app restart.
    var initialScrollbackPath: String?

    /// Owned C buffer with the same lifetime contract as
    /// `workingDirectoryCStr`: allocated by MainActor `createSurface()`,
    /// freed by the deinit's MainActor `Task`. `nonisolated(unsafe)`
    /// permits the deinit handoff; all mutation stays on main.
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
    /// `createSurface`.
    var extraEnvironment: [String: String] = [:]

    /// Owned C buffers backing `ghostty_env_var_s` array handed to
    /// `ghostty_surface_new`. Each `strdup`-style pointer is allocated
    /// by MainActor `createSurface()` and freed by the deinit's
    /// MainActor `Task` in the same order. `nonisolated(unsafe)` so
    /// the nonisolated deinit can read the arrays before posting the
    /// free Task; mutation is otherwise confined to main, so the
    /// unchecked-isolation cost is paid only at deinit handoff.
    nonisolated(unsafe) var envKeyBuffers: [UnsafeMutablePointer<CChar>] = []
    nonisolated(unsafe) var envValueBuffers: [UnsafeMutablePointer<CChar>] = []
    nonisolated(unsafe) var envVarsBuffer: UnsafeMutablePointer<ghostty_env_var_s>?

    /// Callback fired on `mouseDown` so the host can mark the pane as
    /// acknowledged (clears the unread dot). Set by `PaneHostView` —
    /// SurfaceView itself doesn't know its pane id or the WindowSession.
    var onUserAcknowledge: (() -> Void)?

    /// Callback fired when this pane gains keyboard focus (becomes first
    /// responder — on mount/restore, click, ⌘J, tab switch, arrow). Set
    /// by `PaneHostView`. The host uses it to track which pane currently
    /// holds attention focus so leaving a finished pane drops it from the
    /// Waiting list. Fired synchronously here (not deferred) so focus
    /// transitions are processed in order, never acking the pane we just
    /// arrived at.
    var onFocusEntry: (() -> Void)?

    /// Asked on mount: is this pane the tab's focused leaf? Set by
    /// `PaneHostView` to gate focus on concurrent (re)mounts; `nil` = always.
    var shouldFocusOnMount: (() -> Bool)?

    /// Context-menu plumbing back to `TabActions`. Set by
    /// `PaneHostView`; `SurfaceView` calls into the focused pane via
    /// these so we don't have to thread a `WindowSession` reference
    /// through AppKit. `onRequestFocus` MUST run before the others —
    /// they read `splitTree.focusedLeafID` and would otherwise target
    /// whichever pane was focused before the right-click.
    var onRequestFocus: (() -> Void)?
    var onRequestSplit: ((SplitDirection) -> Void)?
    var onRequestCloseActivePane: (() -> Void)?
    var onRequestBeginSearch: (() -> Void)?
    var onRequestMoveToNewTab: (() -> Void)?

    /// Lets the host gate the "Move Pane to New Tab" item by counting the
    /// owning tab's leaves — moving the lone pane in a 1-leaf tab is a
    /// no-op, so we hide the item entirely instead of leaving it
    /// disabled. Nil means "don't show".
    var canMoveToNewTab: (() -> Bool)?

    /// The pane this view represents. Set by `PaneHostView`; lets the
    /// AppKit drag-source path write a `pane:<UUID>` payload to the
    /// pasteboard without threading the id through every drag handler.
    /// Nil before mount (the registry assigns it on `register`).
    var paneID: UUID?

    /// Shared tab column drag-state. Set by `PaneHostView`. Used to announce
    /// `.pane` kind on drag start (so tab column drop targets gate their
    /// indicators) and to clear state via `end()` if AppKit's drag
    /// session ends without the SwiftUI drop delegate firing.
    var dragState: LimpidDragState?

    /// Closure returning the owning tab's id as a string (or "?" when
    /// the lookup fails). Threaded through `PaneHostView` so the
    /// pane-drag log line can name both pane and tab; `SurfaceView`
    /// itself has no `WindowSession` reference.
    var ownerTabIDForLogging: (() -> String)?

    /// Anchor for an in-progress ⌥⌘+drag. Captured on `mouseDown`; the
    /// drag session only opens once the cursor moves past
    /// `paneDragThreshold` so a stationary ⌥⌘-click neither hijacks
    /// libghostty's mouse press nor starts an empty drag.
    var paneDragAnchor: NSPoint?
    let paneDragThreshold: CGFloat = 4

    /// `true` between `beginPaneDrag` opening the AppKit dragging
    /// session and `draggingSession(_:endedAt:)` resetting it. Read by
    /// `mouseUp` to skip a libghostty release we never sent a matching
    /// press for (the ⌥⌘+mouseDown path was swallowed).
    var isAppKitPaneDragInProgress: Bool = false

    init(ghosttyApp: GhosttyApp) {
        self.ghosttyApp = ghosttyApp
        // CAMetalLayer rejects subsequent drawableSize updates when
        // the view is created at frame `.zero`: AppKit's renderer
        // latches the zero-sized backing on first attach and never
        // re-honors `drawableSize` after that. Initialize with a
        // small non-zero rect to avoid the latch.
        //
        // libghostty's renderer expects to set `self.layer` and
        // `wantsLayer` itself inside `ghostty_surface_new` (see ghostty's
        // `renderer/Metal.zig`). The ghostty macOS app gets away with
        // *not* pre-installing a layer because its SurfaceView lives at
        // the top of the SwiftUI representable boundary — `wantsLayer`
        // gets flipped while the view is still detached from its parent,
        // and reparent happens later. Limpid hosts the SurfaceView
        // inside an AppKit container, so by the time libghostty runs the
        // view is already addSubview'd into a layer-hosting hierarchy;
        // we install a `CAMetalLayer` up-front so the layer-backing
        // state is consistent when libghostty arrives — libghostty's own
        // `setProperty("layer", ...)` then swaps our placeholder for its
        // renderer-owned layer.
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        self.wantsLayer = true
        self.autoresizingMask = [.width, .height]
        // SwiftUI's NSViewRepresentable hosting doesn't call setFrameSize
        // during window drags. Subscribe to the view's own frame change
        // notification so we still see live resize events.
        self.postsFrameChangedNotifications = true
        self.postsBoundsChangedNotifications = true
        // No explicit `removeObserver` in deinit — the target-action
        // overloads of `addObserver(_:selector:name:object:)` hold the
        // target via a zeroing-weak reference, so the slot self-cleans
        // when this `SurfaceView` deallocates and the next matching
        // notification fires (per `NotificationCenter`'s documented
        // behavior). The asymmetry with the block-based observer
        // teardown is intentional: those carry strong captures that
        // ARC cannot clear on its own.
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
        // Register under the same pointer libghostty will pass as
        // `userdata` so `liveView(forUserdata:)` is an O(1) lookup.
        // Deinit removes the entry from the same MainActor task that
        // hands the handle to `ghostty_surface_free`.
        Self.liveViewsByPointer[UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())] =
            WeakBox(self)
        registerForDraggedTypes([.fileURL])
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
        // libghostty owns the layer; we only keep it informed of the live
        // pixel size and it resizes + redraws its own layer.
        pushSurfaceSize()
    }

    /// Push the current backing-pixel size + scale into libghostty.
    /// Used to live behind a 150ms debounce, which left the Metal
    /// layer running ahead of the cell grid during a divider drag —
    /// characters appeared stretched until the user paused. Ghostty's
    /// own macOS app (MIT) calls set_size on every layout pass with no
    /// debounce, relying on AppKit's natural ≤60Hz cap.
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

    // MARK: - Accessibility

    /// libghostty paints into the layer Metal-side and never publishes
    /// the visible buffer through `NSAccessibility`. The view itself
    /// is therefore invisible to VoiceOver — focus walks straight
    /// past, and a VO user can't even tell that there is a terminal
    /// here. Tag the view as a text-area role and label it "Terminal"
    /// so chrome traversal (sidebar / toolbar / pane navigation) at
    /// least lands on a discoverable element. Reading the buffer
    /// would need a separate `accessibilityValue` that snapshots the
    /// scrollback through libghostty's C API — defer that to a
    /// follow-up.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityLabel() -> String? {
        String(localized: "Terminal", comment: "VoiceOver label for the libghostty surface view")
    }

    // MARK: - Layer backing

    override func makeBackingLayer() -> CALayer {
        // Pre-install a CAMetalLayer so `wantsLayer = true` resolves to
        // a Metal-ready layer immediately, before libghostty swaps in its
        // own. Without this the view briefly hosts a generic `CALayer`,
        // and on Limpid's container-hosted path that intermediate state
        // races libghostty's `setProperty("layer", ...)` reparent.
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.displaySyncEnabled = true
        layer.wantsExtendedDynamicRangeContent = true
        return layer
    }

    // MARK: - `NSView` lifecycle

    /// AppKit notification observers re-armed every time the host
    /// window changes. `nonisolated(unsafe)` so the nonisolated `deinit`
    /// can hand them back to `NotificationCenter`; mutation is confined
    /// to MainActor `installWindowObservers` / `tearDownWindowObservers`,
    /// so there's no real concurrent access.
    private nonisolated(unsafe) var windowResizeObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var windowOcclusionObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var windowMiniaturizeObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var windowDeminiaturizeObserver: (any NSObjectProtocol)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tearDownWindowObservers()

        guard let window else { return }
        if surface == nil { createSurface() }
        // Focused leaf grabs the keyboard; others are marked unfocused so
        // they don't all render an active cursor. See `shouldFocusOnMount`.
        if shouldFocusOnMount?() ?? true {
            window.makeFirstResponder(self)
        } else if let surface { ghostty_surface_set_focus(surface, false) }
        installWindowObservers(on: window)
    }

    deinit {
        // `surface` is `nonisolated(unsafe)`, but the deinit may run on any
        // thread under Swift 6, so hop everything to MainActor to keep the
        // libghostty / NotificationCenter interactions safe.
        let s = surface
        let obs = windowResizeObserver
        let occObs = windowOcclusionObserver
        let miniObs = windowMiniaturizeObserver
        let deminiObs = windowDeminiaturizeObserver
        let wdBuf = workingDirectoryCStr
        let sbBuf = scrollbackPathCStr
        let envKeys = envKeyBuffers
        let envValues = envValueBuffers
        let envArray = envVarsBuffer
        // Capture `self`'s pointer while we still have a live reference
        // so the MainActor cleanup task can remove the live-view entry
        // even after the object's memory is freed. Reused as the dict
        // key in `liveViewsByPointer` (= what libghostty hands us as
        // `userdata`).
        let pointerKey = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        Task { @MainActor in
            // The allocator routinely reuses NSView pointers after
            // free, and a fresh `SurfaceView` allocated at the same
            // address will have already written its own `WeakBox`
            // into `liveViewsByPointer[pointerKey]`. An unconditional
            // remove would wipe THAT entry — every subsequent
            // libghostty callback for the new surface (`liveView(forUserdata:)`)
            // would then return nil and silently drop close /
            // clipboard / action requests. Only clear the slot if
            // its weak reference still points at a deallocated box
            // (matches the inline-cleanup case in `liveView`).
            if let box = SurfaceView.liveViewsByPointer[pointerKey], box.view == nil {
                SurfaceView.liveViewsByPointer.removeValue(forKey: pointerKey)
            }
            if let s { ghostty_surface_free(s) }
            if let obs { NotificationCenter.default.removeObserver(obs) }
            if let occObs { NotificationCenter.default.removeObserver(occObs) }
            if let miniObs { NotificationCenter.default.removeObserver(miniObs) }
            if let deminiObs { NotificationCenter.default.removeObserver(deminiObs) }
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
        pushSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
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
        //
        // We DO track attention focus here, though: gaining focus by
        // *any* means (tab switch included) acks the *arriving* pane's
        // finished turn — the row stays in WAITING but fades to viewed.
        // Unread is intentionally not cleared here (see the mouseDown
        // path); only the agent-state ack flows through `onFocusEntry`.
        onFocusEntry?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    // MARK: - Clipboard + keyboard pipeline

    // Moved to `SurfaceView+Keyboard.swift` (`paste:`, `copy:`,
    // `performKeyEquivalent`, `keyDown`, `keyUp`, `flagsChanged`,
    // `forward(_:action:…)`, `isNavigationOrFunctionKey`).
    // `NSTextInputClient` lives in `SurfaceView+TextInput.swift`;
    // static `NSEvent` → libghostty helpers in `SurfaceView+Input.swift`;
    // mouse handlers in `SurfaceView+Mouse.swift`.

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: fileOnlyOptions) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let surface,
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: fileOnlyOptions
              ) as? [URL],
              !urls.isEmpty
        else { return false }

        let paths = urls.map { shellEscape($0.path) }
        let joined = paths.joined(separator: " ")
        joined.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
        return true
    }

    private var fileOnlyOptions: [NSPasteboard.ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true]
    }

    /// Shell-escape a file path so spaces and special characters don't
    /// break the command line. Wraps in single quotes with internal
    /// single quotes escaped via the `'\''` idiom.
    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension SurfaceView {

    // MARK: - Surface creation

    /// Initialise the libghostty surface and bind it to this view.
    /// Idempotent in spirit — buffers from a prior `createSurface`
    /// (e.g. a re-mount where `ghostty_surface_new` returned NULL) are
    /// freed first. `PaneHostView` calls this from `updateNSView` as a
    /// fallback when the first `viewDidMoveToWindow` fired with a nil
    /// window and the early-return left `surface == nil`.
    func createSurface() {
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
            // Free any buffer from a prior createSurface (e.g. a re-mount
            // after `ghostty_surface_new` returned NULL) before overwriting it.
            if let prev = workingDirectoryCStr {
                free(prev)
                workingDirectoryCStr = nil
            }
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
            if let prev = scrollbackPathCStr {
                free(prev)
                scrollbackPathCStr = nil
            }
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
            // libghostty hands back NULL when allocation or its own
            // init fails. The pane otherwise stays mounted but
            // invisible — no shell, no cursor, no recovery — so the
            // user only notices that one Waiting-list row is gone.
            // Flip a one-shot flag the `PaneHostView` can read to
            // render an in-pane "Terminal failed to start" card with
            // a Retry button.
            log.fault("ghostty_surface_new returned NULL")
            creationFailed = true
            return
        }
        surface = s
        creationFailed = false

        // Push the initial size now that libghostty owns the layer.
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

// MARK: - Window observer lifecycle (energy)

extension SurfaceView {
    func tearDownWindowObservers() {
        let observers: [(any NSObjectProtocol)?] = [
            windowResizeObserver, windowOcclusionObserver,
            windowMiniaturizeObserver, windowDeminiaturizeObserver
        ]
        for obs in observers {
            obs.map { NotificationCenter.default.removeObserver($0) }
        }
        windowResizeObserver = nil
        windowOcclusionObserver = nil
        windowMiniaturizeObserver = nil
        windowDeminiaturizeObserver = nil
    }

    func installWindowObservers(on window: NSWindow) {
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pushSurfaceSize()
            }
        }

        windowOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let surface = self.surface else { return }
                let visible = self.window?.occlusionState.contains(.visible) ?? false
                ghostty_surface_set_occlusion(surface, visible)
            }
        }

        windowMiniaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let surface = self.surface else { return }
                ghostty_surface_set_occlusion(surface, false)
            }
        }

        windowDeminiaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let surface = self.surface else { return }
                ghostty_surface_set_occlusion(surface, true)
            }
        }
    }

    /// Tell libghostty whether this surface is currently visible on screen.
    /// When `false`, the renderer stops its CVDisplayLink and draw timer,
    /// cutting idle wakeups from ~120/s to near zero per hidden surface.
    func setOccluded(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, !occluded)
    }
}
