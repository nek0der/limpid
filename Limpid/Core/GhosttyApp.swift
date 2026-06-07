// GhosttyApp.swift
// Limpid — owns the libghostty `ghostty_app_t` handle and the runtime
// callbacks that bridge libghostty into the Limpid app.

import AppKit
import Foundation
import GhosttyKit
import OSLog

private let log = Logger.limpid("ghostty.app")

/// Owns the libghostty `ghostty_app_t` handle and the underlying configuration.
///
/// All access happens on the main actor. The app is freed in `deinit`.
@MainActor
final class GhosttyApp {
    nonisolated(unsafe) let handle: ghostty_app_t

    private nonisolated(unsafe) let config: ghostty_config_t

    init(settings: LimpidSettings = .default) throws {
        // Initialize global ghostty state (argv) once per process.
        _ = GhosttyApp.bootstrap

        let cfg = ghostty_config_new()
        guard let cfg else { throw Error.configInitFailed }

        // Layer 2 (Opt-in): user's ~/.config/ghostty/config. Off by
        // default — Limpid Settings is the single source of truth in
        // the common case. Advanced users can flip the toggle to
        // bring their keybinds + shell-integration prefs along.
        if settings.advanced.ghosttyConfig.isOn {
            ghostty_config_load_default_files(cfg)
        }

        // Layer 3 + 4: Limpid settings serialized via
        // `GhosttyConfigBridge`, with forced overrides appended
        // last so the Liquid Glass toolbar stays intact regardless
        // of what user config tried to set.
        let resourcesDir = GhosttyApp.resolveResourcesDir()
        if let path = GhosttyConfigBridge.writeConfigFile(
            settings: settings,
            resourcesDir: resourcesDir,
            appearance: GhosttyApp.currentAppearance(preference: settings.appearance.colorScheme)
        ) {
            path.withCString { ghostty_config_load_file(cfg, $0) }
        }

        ghostty_config_finalize(cfg)

        // Build runtime config with callbacks. `userdata` carries an
        // unretained pointer back to this `GhosttyApp` instance so the
        // wakeup callback can call `ghostty_app_tick(handle)` — without
        // that, libghostty's internal event queue never drains and any
        // surface created after the queue saturates stalls in startup.
        let selfPointer = Unmanaged.passUnretained(GhosttyApp.placeholder).toOpaque()
        var runtime = ghostty_runtime_config_s(
            userdata: selfPointer,
            supports_selection_clipboard: false,
            wakeup_cb: GhosttyApp.wakeupCallback,
            action_cb: GhosttyApp.actionCallback,
            read_clipboard_cb: GhosttyApp.readClipboardCallback,
            confirm_read_clipboard_cb: GhosttyApp.confirmReadClipboardCallback,
            write_clipboard_cb: GhosttyApp.writeClipboardCallback,
            close_surface_cb: GhosttyApp.closeSurfaceCallback
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            ghostty_config_free(cfg)
            throw Error.appInitFailed
        }

        self.handle = app
        self.config = cfg

        // Register *this* instance for future wakeup callbacks. We pass
        // a placeholder pointer at runtime-config build time because
        // `self` isn't fully initialized yet, then swap it in after
        // `ghostty_app_new` succeeds via the shared box. The
        // precondition catches the day we start opening a second
        // window with its own GhosttyApp — the C callbacks all key
        // off this single box, so two live instances would silently
        // route every wakeup to one of them.
        precondition(GhosttyApp.placeholder.target == nil, "GhosttyApp must be a singleton; second instance detected")
        GhosttyApp.placeholder.target = self

        log.notice("ghostty app created")
    }

    /// Shared mutable box used to thread the live `GhosttyApp` reference
    /// through libghostty's C runtime callbacks. Updated once per process
    /// (we only ever create one `GhosttyApp`).
    @MainActor
    final class WeakBox {
        weak var target: GhosttyApp?
    }

    static let placeholder = WeakBox()

    nonisolated deinit {
        ghostty_app_free(handle)
        ghostty_config_free(config)
    }

    // MARK: - Resources dir

    /// Locate ghostty's `share/ghostty` directory. Order:
    ///   1. App bundle Resources (release builds copy it in).
    ///   2. `LIMPID_GHOSTTY_RESOURCES` env override (sole dev escape
    ///      hatch — the older list of `~/<x>/limpid/...` guesses was
    ///      removed to keep maintainer-specific paths out of shipped
    ///      `strings`).
    ///   3. Walk-up from the executable to find
    ///      `vendor/ghostty/zig-out/share/ghostty` (works for dev
    ///      builds running out of DerivedData).
    ///   4. nil — ghostty falls back to its built-in defaults (no
    ///      title hooks, no terminfo).
    static func resolveResourcesDir() -> String? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourcePath {
            let candidate = (bundled as NSString).appendingPathComponent("ghostty")
            if fm.fileExists(atPath: (candidate as NSString).appendingPathComponent("shell-integration")) {
                return candidate
            }
        }
        // Dev build via Xcode DerivedData: the bundle lives miles away
        // from the source tree, so the bundle-relative walk-up below
        // misses the repo. `LIMPID_GHOSTTY_RESOURCES` is the supported
        // dev escape hatch — we deliberately don't enumerate
        // `~/<something>/limpid` paths because every candidate gets
        // baked into the shipped binary's `strings` output, leaking
        // the maintainer's local directory layout.
        if let envOverride = ProcessInfo.processInfo.environment["LIMPID_GHOSTTY_RESOURCES"],
           fm.fileExists(atPath: (envOverride as NSString).appendingPathComponent("shell-integration"))
        {
            return envOverride
        }
        // Walk up from the executable to find the repo root (dev build).
        let exec = Bundle.main.bundleURL
        var cursor = exec
        for _ in 0..<8 {
            cursor = cursor.deletingLastPathComponent()
            let dev = cursor
                .appendingPathComponent("vendor/ghostty/zig-out/share/ghostty", isDirectory: true)
            if fm.fileExists(atPath: dev.appendingPathComponent("shell-integration").path) {
                return dev.path
            }
        }
        return nil
    }

    /// Resolve the appearance libghostty should render under, given
    /// the user's `ColorSchemePreference`. `.light` / `.dark` win
    /// directly; `.system` reads `AppleInterfaceStyle` from
    /// `NSGlobalDomain` rather than `NSApp.effectiveAppearance` so
    /// this is safe to call from `GhosttyApp.init` before
    /// NSApplication has finished its appearance graph.
    static func currentAppearance(
        preference: ColorSchemePreference
    ) -> GhosttyConfigBridge.Appearance {
        switch preference {
        case .light: .light
        case .dark: .dark
        case .system:
            UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
        }
    }

    // MARK: - One-time global bootstrap

    /// Call `ghostty_init(argc, argv)` exactly once per process before any
    /// other libghostty API. libghostty stashes argv globally and sets up
    /// its allocator + state. Using a lazy `static let` guarantees a
    /// single execution even across concurrent first-touchers.
    private static let bootstrap: Void = {
        // libghostty resolves its resources dir during `ghostty_init`:
        // first from `$GHOSTTY_RESOURCES_DIR`, otherwise by walking up
        // from the executable looking for a `terminfo/.../xterm-ghostty`
        // sentinel. Our bundle ships the shell-integration scripts under
        // `Resources/ghostty` but no `terminfo`, so the walk-up never
        // matches and libghostty disables shell integration entirely
        // ("no resources dir set") — which kills OSC 7 cwd reporting,
        // prompt marks, and title updates. Export the path explicitly
        // before init so the env branch resolves it without needing the
        // terminfo sentinel. Note the `resources-dir` *config* key does
        // NOT feed this path (it only resolves bundled themes); the two
        // are independent in libghostty.
        if getenv("GHOSTTY_RESOURCES_DIR") == nil,
           let dir = GhosttyApp.resolveResourcesDir()
        {
            setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
        }
        let args = CommandLine.unsafeArgv
        let rc = ghostty_init(UInt(CommandLine.argc), args)
        if rc != 0 {
            log.fault("ghostty_init returned \(rc, privacy: .public)")
        }
    }()

    // MARK: - Runtime callbacks

    /// Wake up the run loop. libghostty calls this from a worker thread
    /// when its internal event queue has work pending. Hop to the main
    /// actor and drain the queue with `ghostty_app_tick`. Without this,
    /// surface initialization piles up and shells never reach their
    /// first prompt.
    private static let wakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
        guard let userdata else { return }
        nonisolated(unsafe) let ud = userdata
        DispatchQueue.main.async {
            let box = Unmanaged<WeakBox>.fromOpaque(ud).takeUnretainedValue()
            if let app = box.target {
                ghostty_app_tick(app.handle)
            }
        }
    }

    /// libghostty asks for an action (split, tab, fullscreen, etc.).
    /// libghostty fires this callback from the same thread that drains
    /// the app's event loop — which we drive from MainActor via
    /// `ghostty_app_tick`. `MainActor.assumeIsolated` therefore *asserts*
    /// (it would trap if libghostty ever called from a worker), not
    /// "hops"; the synchronous path is required because the callback
    /// returns `Bool` to libghostty to signal whether the action was
    /// handled.
    private static let actionCallback: ghostty_runtime_action_cb = { app, target, action in
        guard let app else { return false }
        nonisolated(unsafe) let safeApp = app
        let safeTarget = target
        let safeAction = action
        return MainActor.assumeIsolated {
            GhosttyActionRouter.handle(app: safeApp, target: safeTarget, action: safeAction)
        }
    }

    /// libghostty wants to read the clipboard. `userdata` here is the
    /// *surface's* userdata (see ghostty source apprt/embedded.zig:
    /// `self.app.opts.read_clipboard(self.userdata, ...)`), which we set
    /// to the SurfaceView pointer.
    ///
    /// libghostty allows us to complete the request asynchronously via
    /// `ghostty_surface_complete_clipboard_request`, so we hop to
    /// MainActor before touching `NSPasteboard` (which is main-thread-
    /// only) and before dereferencing the userdata pointer (the Swift
    /// view may have deinited between this fire and the hop).
    private static let readClipboardCallback: ghostty_runtime_read_clipboard_cb = { userdata, _, state in
        guard let userdata else { return false }
        nonisolated(unsafe) let ud = userdata
        nonisolated(unsafe) let st = state
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let view = SurfaceView.liveView(forUserdata: ud),
                      let surface = view.surface
                else { return }
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                text.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, st, false)
                }
            }
        }
        return true
    }

    /// libghostty asks to confirm a clipboard request — fires when
    /// `clipboard-read = ask` (the libghostty default for OSC 52
    /// reads) or for paste-protection triggers. Hands the request to
    /// `ClipboardConfirmationCoordinator` so the user decides via a
    /// sheet; without that any escape sequence the shell receives
    /// could silently read or overwrite the system clipboard. Same
    /// MainActor hop + liveness check as `readClipboardCallback` to
    /// avoid touching a freed `SurfaceView`.
    private static let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = { userdata, str, state, request in
        guard let userdata, let str else { return }
        nonisolated(unsafe) let ud = userdata
        nonisolated(unsafe) let st = state
        let rawRequest = request
        // Materialize the C string into an owned Swift `String` here,
        // synchronously inside the callback frame, NOT after the main
        // hop. libghostty calls us from inside its own
        // `completeClipboardRequest`, which is itself nested in our
        // `readClipboardCallback`'s `text.withCString { ptr in ... }`
        // closure (`GhosttyApp.swift:256`). The pointer `str` aliases
        // that `ptr` and only stays valid while the outer `withCString`
        // is on the stack. Deferring the `String(cString:)` into the
        // `DispatchQueue.main.async` block read freed heap — paste
        // protection (the whole reason this callback exists) fires the
        // path on every user paste. Mirrors the sibling
        // `writeClipboardCallback`, which already copies up front.
        let contents = String(cString: str)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let view = SurfaceView.liveView(forUserdata: ud),
                      let surface = view.surface
                else { return }
                guard let coordinator = ClipboardConfirmationCoordinator.shared,
                      let kind = ClipboardConfirmationKind(rawRequest)
                else {
                    // Coordinator not wired up (should not happen
                    // after AppState init) or an unknown request type
                    // arrived from a newer libghostty. Deny rather
                    // than allow — fail closed.
                    ghostty_surface_complete_clipboard_request(surface, "", st, false)
                    return
                }
                coordinator.enqueue(
                    kind: kind,
                    contents: contents,
                    view: view,
                    state: st
                )
            }
        }
    }

    /// libghostty wants to write to the clipboard. Take the first
    /// text/plain entry (or fall back to the first entry). Materialize
    /// the text on whatever thread the callback fired on (C strings
    /// don't need an actor), then hop to MainActor before touching
    /// `NSPasteboard`, which is main-thread-only per AppKit. Same
    /// MainActor-hop pattern as `readClipboardCallback` /
    /// `confirmReadClipboardCallback`.
    ///
    /// `confirm == true` signals `clipboard-write = ask` policy: we
    /// must NOT write to the pasteboard directly. Route through the
    /// confirmation coordinator and only commit on Allow. Falling back
    /// to the unconditional write would defeat the user's policy and
    /// let any OSC 52 sequence land bytes in the system pasteboard.
    /// `confirm == false` is the historical "trust" path — write
    /// straight to `NSPasteboard`.
    private static let writeClipboardCallback: ghostty_runtime_write_clipboard_cb = { userdata, _, contents, count, confirm in
        guard let contents, count > 0 else { return }
        var text: String?
        for i in 0..<count {
            let entry = contents[i]
            if let mime = entry.mime, String(cString: mime) == "text/plain",
               let data = entry.data
            {
                text = String(cString: data)
                break
            }
        }
        if text == nil, let data = contents[0].data {
            text = String(cString: data)
        }
        guard let text else { return }
        if !confirm {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSPasteboard.general.declareTypes([.string], owner: nil)
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            return
        }
        // confirm == true — enqueue against the coordinator. libghostty
        // does not allocate a request-state for the write path (only
        // confirm_read_clipboard_cb does), so we pass `state: nil` and
        // the coordinator's allow() path writes to NSPasteboard
        // directly instead of completing a C-side request.
        guard let userdata else { return }
        nonisolated(unsafe) let ud = userdata
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let view = SurfaceView.liveView(forUserdata: ud) else { return }
                ClipboardConfirmationCoordinator.shared?.enqueue(
                    kind: .osc52Write,
                    contents: text,
                    view: view,
                    state: nil
                )
            }
        }
    }

    /// libghostty wants to close a surface — typically because the
    /// child shell process exited. `userdata` is the *surface's*
    /// userdata (an unretained pointer to `SurfaceView`), and
    /// `processAlive` distinguishes shell exits from forced closes.
    /// Hop to MainActor and broadcast so `GhosttyEventCoordinator`
    /// can remove the pane from the SplitTree.
    private static let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { userdata, processAlive in
        guard let userdata else { return }
        nonisolated(unsafe) let ud = userdata
        let alive = processAlive
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // The SurfaceView may have deinited between this
                // callback firing on libghostty's thread and the hop
                // landing on MainActor. `liveView(forUserdata:)`
                // returns nil when the weak entry is gone, so we
                // dereference into freed memory exactly never.
                guard let view = SurfaceView.liveView(forUserdata: ud) else { return }
                GhosttyActionRouter.emit(.closeSurface(view, processAlive: alive))
            }
        }
    }

    // MARK: - Errors

    enum Error: Swift.Error {
        case configInitFailed
        case appInitFailed
    }
}
