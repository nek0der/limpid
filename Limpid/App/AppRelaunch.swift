// AppRelaunch.swift
// Limpid — quits and opens Limpid again, for a setting that only applies at launch.

import AppKit
import OSLog

private let log = Logger.limpid("app.relaunch")

/// "Relaunch" beside a setting that needs it (the menu bar's language).
/// The quit goes through the usual confirmation,
/// so agents are asked about as ⌘Q asks; a quit the person cancels
/// opens nothing later.
@MainActor
enum AppRelaunch {
    static func relaunch() {
        // A helper that waits for this process to end, then opens the app
        // again. Started before the quit so it is in place however the quit
        // ends; killed if the quit is canceled. The bundle path goes in
        // as an argument, never into the script text.
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath
        ]
        do {
            try waiter.run()
        } catch {
            log.error("relaunch helper failed to start: \(String(describing: error), privacy: .private)")
            return
        }
        NSApp.terminate(nil)
        // `terminate` returns only when the quit was canceled: the app
        // delegate answers at once (`LimpidAppDelegate.applicationShouldTerminate`).
        waiter.terminate()
    }
}
