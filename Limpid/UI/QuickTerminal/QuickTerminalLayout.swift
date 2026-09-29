// QuickTerminalLayout.swift
// Limpid — geometry of the quick terminal panel: its frame for each
// position and size, the frames it animates between, and its corners.

import CoreGraphics

/// Corners of the quick terminal panel in screen terms: `top` is the
/// edge at the larger screen y, and `leading` is the left edge whatever
/// the layout direction, because the corners follow the screen edge the
/// panel is attached to, not the reading order of its content.
struct QuickTerminalCorners: OptionSet, Hashable {
    let rawValue: UInt8

    static let topLeading = QuickTerminalCorners(rawValue: 1 << 0)
    static let topTrailing = QuickTerminalCorners(rawValue: 1 << 1)
    static let bottomLeading = QuickTerminalCorners(rawValue: 1 << 2)
    static let bottomTrailing = QuickTerminalCorners(rawValue: 1 << 3)

    static let all: QuickTerminalCorners = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
}

/// Where the panel sits on screen. Pure geometry so every position and
/// size can be checked against a fixed visible frame.
enum QuickTerminalLayout {
    /// Radius of the panel's rounded corners.
    ///
    /// macOS has no public API for the system window corner radius (SDK
    /// 26.5), so we match it by eye and by pixels. On macOS 27.0 every
    /// window kind we captured has the same corner, and a continuous-curve
    /// radius of 17pt reproduces it to within a Retina pixel, where 16pt
    /// is visibly tighter. macOS 26 used 16pt for titlebar-only windows
    /// and more with a toolbar, so there is no single value to match.
    /// When we build with the macOS 27 SDK, check whether
    /// `NSView.cornerConfiguration` (WWDC26) can supply the system value;
    /// this constant is the single place to replace behind
    /// `if #available(macOS 27, *)`.
    static let cornerRadius: CGFloat = 17

    /// Space between the panel edge and the terminal's text, on every side.
    ///
    /// A pane never touches a window corner, so libghostty's own padding
    /// (`GhosttyConfigBridge.windowPaddingX` and `windowPaddingY`) is
    /// enough there. The panel's terminal runs
    /// to the rounded corners, where that left the first line against the
    /// curve. 14pt clears a 17pt continuous corner and reads like the inner
    /// margin of other floating system panels.
    static let terminalInset: CGFloat = 14

    /// What we add around the surface so the text sits `terminalInset`
    /// from the edge, on top of libghostty's own padding.
    static let terminalInsetHorizontal: CGFloat = terminalInset - CGFloat(GhosttyConfigBridge.windowPaddingX)
    static let terminalInsetVertical: CGFloat =
        terminalInset - CGFloat(GhosttyConfigBridge.windowPaddingY)

    /// Width of the centered panel as a share of the visible frame. Its
    /// height follows the size setting.
    static let centerWidthFraction: CGFloat = 0.6

    /// Corners left exposed at `position`. The corners on the attached
    /// screen edge stay square so the panel meets that edge flush; the
    /// centered panel touches no edge and rounds all four.
    static func roundedCorners(for position: QuickTerminalPosition) -> QuickTerminalCorners {
        switch position {
        case .top: [.bottomLeading, .bottomTrailing]
        case .bottom: [.topLeading, .topTrailing]
        case .left: [.topTrailing, .bottomTrailing]
        case .right: [.topLeading, .bottomLeading]
        case .center: .all
        }
    }

    /// Scale the centered panel grows from while it fades in.
    static let centerStartScale: CGFloat = 0.96

    /// Frame of the fully shown panel inside `visibleFrame`.
    static func targetFrame(
        position: QuickTerminalPosition,
        sizePercent: Int,
        visibleFrame: CGRect
    ) -> CGRect {
        let fraction = CGFloat(QuickTerminalSettings.normalizedSizePercent(sizePercent)) / 100
        let height = (visibleFrame.height * fraction).rounded()
        let width = (visibleFrame.width * fraction).rounded()
        switch position {
        case .top:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - height,
                width: visibleFrame.width,
                height: height
            )
        case .bottom:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: height)
        case .left:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: width, height: visibleFrame.height)
        case .right:
            return CGRect(
                x: visibleFrame.maxX - width,
                y: visibleFrame.minY,
                width: width,
                height: visibleFrame.height
            )
        case .center:
            let centerWidth = (visibleFrame.width * centerWidthFraction).rounded()
            return CGRect(
                x: (visibleFrame.midX - centerWidth / 2).rounded(),
                y: (visibleFrame.midY - height / 2).rounded(),
                width: centerWidth,
                height: height
            )
        }
    }

    /// Frame the panel animates from on show and back to on hide.
    ///
    /// Past a screen edge there may be another display: with two displays
    /// stacked, the strip above the lower one is the upper one, and the
    /// slide would be drawn there. When the slide path touches any of
    /// `otherScreenFrames`, we keep the target frame so the panel only
    /// fades in place on its own screen.
    static func animationFrame(
        position: QuickTerminalPosition,
        target: CGRect,
        otherScreenFrames: [CGRect]
    ) -> CGRect {
        let hidden = hiddenFrame(position: position, target: target)
        guard position != .center else { return hidden }
        let path = hidden.union(target)
        let crossesDisplay = otherScreenFrames.contains { $0.intersects(path) }
        return crossesDisplay ? target : hidden
    }

    /// The target moved fully past its edge, or for `center` the same
    /// frame scaled down around its middle.
    static func hiddenFrame(position: QuickTerminalPosition, target: CGRect) -> CGRect {
        switch position {
        case .top:
            return target.offsetBy(dx: 0, dy: target.height)
        case .bottom:
            return target.offsetBy(dx: 0, dy: -target.height)
        case .left:
            return target.offsetBy(dx: -target.width, dy: 0)
        case .right:
            return target.offsetBy(dx: target.width, dy: 0)
        case .center:
            let width = (target.width * centerStartScale).rounded()
            let height = (target.height * centerStartScale).rounded()
            return CGRect(
                x: (target.midX - width / 2).rounded(),
                y: (target.midY - height / 2).rounded(),
                width: width,
                height: height
            )
        }
    }
}
