// QuickTerminalPanel.swift
// Limpid — the borderless panel that hosts the quick terminal, and the
// SwiftUI content inside it.

import AppKit
import SwiftUI

/// Thin AppKit boundary: a borderless, non-activating panel that can
/// still take keyboard focus. Everything it shows is SwiftUI, apart from
/// the vibrancy and corner clip in `QuickTerminalRootView`.
final class QuickTerminalPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // Follow the user across Spaces and over full-screen apps, and stay
        // out of ⌘` window cycling, which belongs to the main window.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // The controller decides when the panel hides; AppKit hiding it on
        // deactivation would skip the focus hand-back and the clipboard
        // cleanup that go with it.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        // Borderless windows have no visible title, but assistive
        // technologies read it as the window's name.
        title = String(localized: "Quick Terminal", comment: "Name of the quick terminal panel")
        setAccessibilityLabel(title)
        // Tiling window managers treat the floating subrole as a window
        // they should leave where it is.
        setAccessibilitySubrole(.floatingWindow)
    }

    /// A borderless window refuses key status by default; the terminal
    /// needs it to receive keystrokes.
    override var canBecomeKey: Bool {
        true
    }

    /// Main status belongs to the main window, so menu commands keep
    /// targeting it while the panel only takes keystrokes.
    override var canBecomeMain: Bool {
        false
    }
}

/// The panel's content view: behind-window vibrancy, with the SwiftUI
/// content in a container above it. Both are rounded at the same corners.
///
/// The vibrancy lives here rather than in SwiftUI because only the
/// `maskImage` of an effect view that is the window's content view also
/// shapes the window shadow (see `NSVisualEffectView.h`). A blur drawn
/// inside the content would round with it but leave the shadow, and
/// the square blur beneath it, showing at the corners.
final class QuickTerminalRootView: NSVisualEffectView {
    /// Clips everything SwiftUI draws: the terminal surface, the tint,
    /// and the opaque fill under Reduce Transparency. libghostty renders
    /// into a plain `CALayer` whose IOSurface contents only an ancestor
    /// `masksToBounds` can clip. The view must stay non-flipped for the
    /// `maskedCorners` mapping in `maskedCorners(for:)` to hold.
    private let clipView = NSView()

    /// Last corners applied, so a relayout at the same position does not
    /// rebuild the mask image.
    private var roundedCorners: QuickTerminalCorners?

    init(content: NSView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        material = .underWindowBackground
        blendingMode = .behindWindow
        // The panel is non-activating; following the window's active
        // state would drop the blur whenever another app is frontmost.
        state = .active

        clipView.frame = bounds
        clipView.autoresizingMask = [.width, .height]
        clipView.wantsLayer = true
        clipView.clipsToBounds = true
        addSubview(clipView)
        content.frame = clipView.bounds
        content.autoresizingMask = [.width, .height]
        clipView.addSubview(content)
        setRoundedCorners(.all)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Round `corners` and square the rest, on both the content clip and
    /// the vibrancy mask. The caller invalidates the window shadow once
    /// the frame has settled.
    func setRoundedCorners(_ corners: QuickTerminalCorners) {
        guard corners != roundedCorners else { return }
        roundedCorners = corners
        let radius = QuickTerminalLayout.cornerRadius
        if let layer = clipView.layer {
            layer.cornerRadius = radius
            layer.cornerCurve = .continuous
            layer.maskedCorners = Self.maskedCorners(for: corners)
            layer.masksToBounds = true
        }
        maskImage = Self.maskImage(corners: corners, radius: radius)
    }

    /// Screen corners to layer corners. `clipView` is non-flipped, so its
    /// layer keeps Core Animation's macOS default of y growing upward:
    /// `MinY` is the bottom edge and `MaxY` the top (on iOS, where y grows
    /// downward, the same constants name the opposite edges).
    private static func maskedCorners(for corners: QuickTerminalCorners) -> CACornerMask {
        let pairs: [(QuickTerminalCorners, CACornerMask)] = [
            (.topLeading, .layerMinXMaxYCorner),
            (.topTrailing, .layerMaxXMaxYCorner),
            (.bottomLeading, .layerMinXMinYCorner),
            (.bottomTrailing, .layerMaxXMinYCorner)
        ]
        return pairs.reduce(into: []) { mask, pair in
            if corners.contains(pair.0) {
                mask.insert(pair.1)
            }
        }
    }

    /// A small stretchable image whose opaque area is the rounded panel
    /// shape. Only the cap regions keep their size as the panel grows, so
    /// each cap must hold a whole corner: a continuous curve leaves the
    /// straight edge about 1.53 × the radius from the corner, and we give
    /// it twice the radius.
    ///
    /// The shape comes from SwiftUI's continuous rounded rectangle, the
    /// same curve family as the clip layer's `.continuous` corner curve,
    /// so the blur's edge and the content's edge coincide. The image is
    /// drawn flipped to match SwiftUI's y-down path space, where `top`
    /// means the top of the screen.
    ///
    /// `nonisolated` so the drawing handler does not inherit main-actor
    /// isolation: AppKit may run it off the main thread when it renders
    /// the image, and an inherited isolation check would trap there.
    private nonisolated static func maskImage(corners: QuickTerminalCorners, radius: CGFloat) -> NSImage {
        let cap = (radius * 2).rounded(.up)
        let size = NSSize(width: cap * 2 + 1, height: cap * 2 + 1)
        let shape = UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: corners.contains(.topLeading) ? radius : 0,
                bottomLeading: corners.contains(.bottomLeading) ? radius : 0,
                bottomTrailing: corners.contains(.bottomTrailing) ? radius : 0,
                topTrailing: corners.contains(.topTrailing) ? radius : 0
            ),
            style: .continuous
        )
        let path = shape.path(in: CGRect(origin: .zero, size: size)).cgPath
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path)
            context.setFillColor(.black)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }
}

/// State the panel's SwiftUI content observes. Owned by the controller and
/// separate from it so the content does not retain the controller.
@MainActor
@Observable
final class QuickTerminalContentModel {
    /// The one surface the quick terminal shows. Setting it to `nil` makes
    /// SwiftUI dismantle the representable, which is what lets the view
    /// deallocate after the shell exits.
    var surfaceView: SurfaceView?

    /// Mirrors the controller's `isVisible`; the controller sets it in
    /// `show()` and `hide()`. The controller denies a clipboard request
    /// that arrives while the panel is hidden, but SwiftUI can read the
    /// pending request before that deny runs and begin a sheet on the
    /// ordered-out panel, where nobody can answer it.
    var isPanelVisible = false

    /// Mirrors `surfaceView.creationFailed`, which is KVO-observable but not
    /// observable by SwiftUI, so the panel can show the same failure card
    /// a pane does instead of an empty frame.
    var isSurfaceCreationFailed = false

    @ObservationIgnored let settingsStore: SettingsStore
    @ObservationIgnored let reduceTransparencyResolver: ReduceTransparencyResolver
    @ObservationIgnored let clipboard: ClipboardConfirmationCoordinator
    @ObservationIgnored weak var panel: NSWindow?

    init(
        settingsStore: SettingsStore,
        reduceTransparencyResolver: ReduceTransparencyResolver,
        clipboard: ClipboardConfirmationCoordinator
    ) {
        self.settingsStore = settingsStore
        self.reduceTransparencyResolver = reduceTransparencyResolver
        self.clipboard = clipboard
    }

    /// The pending clipboard request, when it comes from a view in this
    /// panel and the panel is up. The main window presents requests from
    /// its own views; the controller denies the panel's while it is hidden.
    var panelClipboardRequest: PendingClipboardRequest? {
        guard isPanelVisible,
              let request = clipboard.pending,
              let panel,
              request.view?.window === panel
        else { return nil }
        return request
    }
}

struct QuickTerminalContent: View {
    let model: QuickTerminalContentModel

    var body: some View {
        ZStack {
            QuickTerminalBackdrop(
                appearance: model.settingsStore.settings.appearance,
                reduceTransparency: model.reduceTransparencyResolver.shouldReduceTransparency
            )
            if let surfaceView = model.surfaceView {
                QuickTerminalSurfaceRepresentable(surfaceView: surfaceView)
                    .padding(.horizontal, QuickTerminalLayout.terminalInsetHorizontal)
                    .padding(.vertical, QuickTerminalLayout.terminalInsetVertical)
                if model.isSurfaceCreationFailed {
                    PaneCreationFailureCard(surfaceView: surfaceView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.55))
                }
            }
        }
        .ignoresSafeArea()
        .sheet(item: Binding(
            get: { model.panelClipboardRequest },
            set: { newValue in
                // Dismissal by Esc or a click outside is a Deny, as in the
                // main window: libghostty must always get an answer.
                if newValue == nil, model.panelClipboardRequest != nil {
                    model.clipboard.deny()
                }
            }
        )) { request in
            ClipboardConfirmationSheet(
                request: request,
                onAllow: { model.clipboard.allow() },
                onDeny: { model.clipboard.deny() }
            )
            .limpidAccentPropagated(accent)
        }
        .environment(\.locale, model.settingsStore.appLanguage.locale ?? .current)
        .limpidAccentPropagated(accent)
    }

    private var accent: Color {
        LimpidColor.accent(for: model.settingsStore.settings.appearance.accentColor)
    }
}

/// Same fill the main window's terminal column paints, because the forced
/// `background-opacity=0` leaves the surface itself transparent. The
/// behind-window vibrancy under it is `QuickTerminalRootView`.
private struct QuickTerminalBackdrop: View {
    let appearance: AppearanceSettings
    let reduceTransparency: Bool

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            LimpidColor.terminalColumnBackground.opacity(appearance.backgroundOpacity * 0.5)
        }
    }
}

/// Mounts the quick terminal's surface. Reuses `PaneContainerNSView`,
/// which is independent of panes and brings the native scrollbar, and
/// repeats `PaneHostRepresentable`'s creation retries: `createSurface`
/// only runs once the view has a window, and the first mount can land
/// before it has one.
struct QuickTerminalSurfaceRepresentable: NSViewRepresentable {
    let surfaceView: SurfaceView

    func makeNSView(context: Context) -> PaneContainerNSView {
        let container = PaneContainerNSView(frame: .zero)
        container.mount(surfaceView)
        DispatchQueue.main.async { [surfaceView] in
            if surfaceView.surface == nil, surfaceView.window != nil {
                surfaceView.createSurface()
            }
        }
        return container
    }

    func updateNSView(_ container: PaneContainerNSView, context: Context) {
        container.mount(surfaceView)
        if surfaceView.window != nil, surfaceView.surface == nil {
            surfaceView.createSurface()
        }
    }

    /// Runs once the shell has exited and the content dropped the view.
    /// Detaching it here releases the reference the hierarchy holds, so
    /// the view can deallocate and free its libghostty surface.
    static func dismantleNSView(_ container: PaneContainerNSView, coordinator: ()) {
        container.surfaceView?.removeFromSuperview()
    }
}
