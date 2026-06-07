// GhosttyActionRouter.swift
// Limpid — translates libghostty action callbacks into a typed
// `GhosttyEvent` and forwards it to the installed sink (usually
// `GhosttyEventCoordinator.dispatch`).
//
// The pre-F2 design went through NotificationCenter:
//   C cb → Router posts Notification → Coordinator observes
// Only one observer ever existed, so the NC indirection just cost
// type safety (userInfo was `[String: Any]`) and forced
// `@unchecked Sendable` wrappers around `Notification`. The new
// direct-call design keeps the same C→Swift hop without the bus.

import AppKit
import Foundation
import GhosttyKit
import OSLog

private let log = Logger.limpid("ghostty.router")

/// Type-safe event emitted by the libghostty action layer. Mirrors the
/// `GHOSTTY_ACTION_*` tags Limpid actually handles.
enum GhosttyEvent {
    case setTitle(SurfaceView, title: String)
    case setPwd(SurfaceView, pwd: String)
    case gotoTab(rawIndex: Int32)
    case childExited(SurfaceView, exitCode: UInt32, atMs: UInt64)
    case desktopNotification(SurfaceView, title: String, body: String)
    case ringBell(SurfaceView)
    case commandFinished(SurfaceView, exitCode: Int, durationNs: UInt64)
    /// libghostty asks the apprt to dismiss the search overlay.
    /// Fires in response to Limpid driving `end_search` via
    /// `ghostty_surface_binding_action` (no libghostty keybind owns
    /// it anymore — `SearchActions.endSearch` is the only trigger).
    case endSearch(SurfaceView)
    /// Updated total-matches counter for the current search.
    case searchTotal(SurfaceView, total: Int?)
    /// Updated currently-selected match index (0-based).
    case searchSelected(SurfaceView, selected: Int?)
    /// Fired from `GhosttyApp.closeSurfaceCallback` (not the action
    /// callback). Lives in the same enum so all libghostty-driven
    /// session mutations flow through a single dispatch point.
    case closeSurface(SurfaceView, processAlive: Bool)
    /// libghostty detected a link under the mouse cursor (or nil when
    /// the cursor left the link region).
    case mouseOverLink(SurfaceView, url: String?)
    /// libghostty asks us to open a URL (⌘-click on a detected link
    /// or OSC 8 hyperlink).
    case openUrl(url: String)
    /// libghostty wants the cursor shape changed (e.g. pointing hand
    /// over a link).
    case mouseShape(SurfaceView, shape: ghostty_action_mouse_shape_e)
}

@MainActor
enum GhosttyActionRouter {
    /// Sink installed by `AppState` immediately after constructing the
    /// coordinator. `nil` during a brief window at boot before the
    /// first surface is created — anything that arrives during that
    /// window is dropped with a log.
    static var sink: ((GhosttyEvent) -> Void)?

    /// Entry point invoked from the C action callback. Returns `true`
    /// when the action was recognized and dispatched.
    static func handle(
        app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        log.debug("action tag=\(action.tag.rawValue, privacy: .public)")
        guard let event = decode(target: target, action: action) else { return false }
        emit(event)
        return true
    }

    /// Convenience used by `GhosttyApp.closeSurfaceCallback`. Kept on
    /// the router so the Notification-vs-event refactor doesn't leak
    /// into `GhosttyApp`.
    static func emit(_ event: GhosttyEvent) {
        guard let sink else {
            log.debug("event dropped — no sink installed yet")
            return
        }
        sink(event)
    }

    // MARK: - Decoding

    // swiftlint:disable:next cyclomatic_complexity
    private static func decode(
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> GhosttyEvent? {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = surfaceView(from: target),
                  let cstr = action.action.set_title.title
            else { return nil }
            let raw = String(cString: cstr)
            let sanitized = sanitizeTitle(raw)
            // User content — keep `.private` in Release so terminal
            // titles (which often include working paths or branch
            // names) don't end up in unified log / sysdiagnose.
            log.notice("SET_TITLE \(sanitized, privacy: .private)")
            return .setTitle(view, title: sanitized)

        case GHOSTTY_ACTION_PWD:
            guard let view = surfaceView(from: target),
                  let cstr = action.action.pwd.pwd
            else { return nil }
            let pwd = String(cString: cstr)
            // Working directory is user content — `.private` so the
            // unified log doesn't accumulate the user's project tree.
            log.notice("PWD \(pwd, privacy: .private)")
            return .setPwd(view, pwd: pwd)

        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = action.action.goto_tab.rawValue
            log.notice("GOTO_TAB raw=\(raw, privacy: .public)")
            return .gotoTab(rawIndex: raw)

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let view = surfaceView(from: target) else { return nil }
            let payload = action.action.child_exited
            log.notice("CHILD_EXITED code=\(payload.exit_code, privacy: .public)")
            return .childExited(view, exitCode: payload.exit_code, atMs: payload.timetime_ms)

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let view = surfaceView(from: target) else { return nil }
            let payload = action.action.desktop_notification
            let title = payload.title.map { String(cString: $0) } ?? ""
            let body = payload.body.map { String(cString: $0) } ?? ""
            // Shell-supplied title can carry secrets the user pasted
            // into a command — strip it from the log even though
            // the in-app notification panel still shows it.
            log.notice("DESKTOP_NOTIFICATION title=\(title, privacy: .private)")
            return .desktopNotification(view, title: title, body: body)

        case GHOSTTY_ACTION_RING_BELL:
            guard let view = surfaceView(from: target) else { return nil }
            log.notice("RING_BELL")
            return .ringBell(view)

        case GHOSTTY_ACTION_END_SEARCH:
            guard let view = surfaceView(from: target) else { return nil }
            log.notice("END_SEARCH")
            return .endSearch(view)

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let view = surfaceView(from: target) else { return nil }
            let raw = action.action.search_total.total
            let total: Int? = raw < 0 ? nil : Int(raw)
            log.notice("SEARCH_TOTAL total=\(raw, privacy: .public)")
            return .searchTotal(view, total: total)

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let view = surfaceView(from: target) else { return nil }
            let raw = action.action.search_selected.selected
            let selected: Int? = raw < 0 ? nil : Int(raw)
            log.notice("SEARCH_SELECTED selected=\(raw, privacy: .public)")
            return .searchSelected(view, selected: selected)

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            guard let view = surfaceView(from: target) else { return nil }
            let payload = action.action.command_finished
            log.notice("COMMAND_FINISHED exit=\(payload.exit_code, privacy: .public) duration=\(payload.duration, privacy: .public)ns")
            return .commandFinished(view, exitCode: Int(payload.exit_code), durationNs: payload.duration)

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let view = surfaceView(from: target) else { return nil }
            let payload = action.action.mouse_over_link
            // Copy out of libghostty's buffer here: the pointer is only valid
            // for the duration of this callback, and `url` escapes into the
            // surface's `hoverUrl` and the SwiftUI layer.
            let url: String? = if let ptr = payload.url, payload.len > 0 {
                String(bytes: UnsafeRawBufferPointer(start: ptr, count: Int(payload.len)), encoding: .utf8)
            } else {
                nil
            }
            log.debug("MOUSE_OVER_LINK url=\(url ?? "nil", privacy: .private)")
            return .mouseOverLink(view, url: url)

        case GHOSTTY_ACTION_OPEN_URL:
            let payload = action.action.open_url
            // Copy before the callback returns — the URL is handed to
            // NSWorkspace.open after libghostty reclaims the buffer. The
            // failable init also rejects a non-UTF-8 URL rather than opening a
            // replacement-character-laden string.
            guard let ptr = payload.url, payload.len > 0,
                  let url = String(bytes: UnsafeRawBufferPointer(start: ptr, count: Int(payload.len)), encoding: .utf8)
            else { return nil }
            log.notice("OPEN_URL url=\(url, privacy: .private)")
            return .openUrl(url: url)

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = surfaceView(from: target) else { return nil }
            let shape = action.action.mouse_shape
            log.debug("MOUSE_SHAPE \(shape.rawValue, privacy: .public)")
            return .mouseShape(view, shape: shape)

        default:
            return nil
        }
    }

    // MARK: - Target → SurfaceView

    private static func surfaceView(from target: ghostty_target_s) -> SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return SurfaceView.liveView(forUserdata: userdata)
    }

    // MARK: - Title sanitization

    /// Strip bidi / zero-width / control characters and collapse runs of
    /// whitespace into single spaces so titles render cleanly in
    /// `NSWindow.title` and the tab bar's single-line `Text`. We do **not**
    /// truncate — single-line UI containers handle that with ellipsis.
    private static func sanitizeTitle(_ s: String) -> String {
        let bidi: ClosedRange<Unicode.Scalar> = "\u{202A}"..."\u{202E}"
        let bidi2: ClosedRange<Unicode.Scalar> = "\u{2066}"..."\u{2069}"
        let zwsp: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{FEFF}"
        ]
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || scalar == "\r" {
                scalars.append(" ")
                continue
            }
            if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) {
                continue
            }
            if bidi.contains(scalar) || bidi2.contains(scalar) { continue }
            if zwsp.contains(scalar) { continue }
            scalars.append(scalar)
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
