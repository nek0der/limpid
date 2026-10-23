// HostedViews.swift
// Limpid — walking and waiting on views a test hosts in an AppKit window.

import AppKit
import SwiftUI

/// Hosts `view` as the content of a titled window of `width` by `height`,
/// for a test that reads what SwiftUI laid out. The window is never shown,
/// but AppKit only lays a hosting view out at its window's size once it has
/// one. The caller closes the window when done (`defer { window.close() }`);
/// it is not released on close, so the host stays readable until then.
@MainActor
func hostedInWindow<Content: View>(
    _ view: Content,
    width: CGFloat,
    height: CGFloat
) -> (window: NSWindow, host: NSHostingView<Content>) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    window.contentView = host
    return (window, host)
}

/// The height `view` asks for, with no window to fit, as a sheet or a
/// panel sizes itself from it. Read before any layout pass, so a view whose
/// body needs an environment object the test did not give still measures.
@MainActor
func fittingHeight(of view: some View) -> CGFloat {
    NSHostingView(rootView: view).fittingSize.height
}

/// Every view under `view`, depth first.
@MainActor
func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

/// Lays `host` out until `condition` holds or `timeout` passes. SwiftUI
/// runs its update and AppKit lays out the rows it asked for over more than
/// one turn of the run loop, so a test waits for what it is about to check
/// rather than for a fixed time, which was either too long or, on a busy
/// machine, too short.
@MainActor
func settle(_ host: NSView, timeout: Duration = .seconds(2), until condition: () -> Bool) async {
    await pollUntil(timeout: timeout, interval: .milliseconds(10)) {
        host.layoutSubtreeIfNeeded()
        return condition()
    }
}

/// Lays `host` out until `value` reads the same twice in a row, and returns
/// it; `nil` if it never did within `timeout`. For a value a test keeps to
/// compare with a later one: the first layout to produce one can be a
/// passing one, made before the window settled its sizes, and a value taken
/// from it would make the comparison depend on the machine. Named apart from
/// `settle`, which waits for a condition, so a call site says which wait it
/// is: both take a trailing closure, and only its type told them apart.
@MainActor
func settledValue<Value: Equatable>(in host: NSView, timeout: Duration = .seconds(2), _ value: () -> Value?) async -> Value? {
    var last: Value?
    var settled: Value?
    await pollUntil(timeout: timeout, interval: .milliseconds(10)) {
        host.layoutSubtreeIfNeeded()
        let current = value()
        defer { last = current }
        guard let current, current == last else { return false }
        settled = current
        return true
    }
    return settled
}

/// Where a view was last laid out, as SwiftUI reports it through
/// `onGeometryChange`.
@MainActor
final class FrameRecorder {
    var frame: CGRect?
}
