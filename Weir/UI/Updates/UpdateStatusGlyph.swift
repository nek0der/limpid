// UpdateStatusGlyph.swift
// Weir — what an update control shows for each update state: its glyph, words, and progress.

import SwiftUI

/// The glyph for an update state, in `color`: a symbol, or a progress ring
/// while the update downloads or unpacks. The left rail's update control
/// draws it.
struct UpdateStatusGlyph: View {
    let state: UpdateState
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch state {
        case .checking:
            // The glyph alone says it is checking; the spin is decoration.
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
                .foregroundStyle(color)
        case .downloading, .extracting:
            ProgressRing(progress: state.progress ?? 0, color: color)
        case .installing:
            Image(systemName: "arrow.down.circle.fill")
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .foregroundStyle(color)
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(color)
        case .notFound:
            Image(systemName: "checkmark.circle").foregroundStyle(color)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
        case .available, .readyToInstall, .idle:
            Image(systemName: "shippingbox.fill").foregroundStyle(color)
        }
    }
}

extension UpdateState {
    /// The tooltip and VoiceOver label of an update control. A catalog
    /// resource, so it follows the window's language.
    var helpText: LocalizedStringResource {
        switch self {
        case .idle:
            ""
        case .checking:
            "Checking for updates…"
        case let .available(item, _):
            "Update available: \(item.displayVersion)"
        case let .downloading(item, _, _, _):
            "Downloading \(item.displayVersion)…"
        case .extracting:
            "Preparing update…"
        case let .readyToInstall(item, _):
            "Ready to install \(item.displayVersion)"
        case .installing:
            "Installing update…"
        case .installed:
            "Update installed"
        case .notFound:
            "You’re up to date"
        case .error:
            "Update failed"
        }
    }

    /// How far a download or unpacking has come, 0 to 1; `nil` in every
    /// other state.
    var progress: Double? {
        switch self {
        case let .downloading(_, expected, received, _):
            Self.downloadProgress(received: received, expected: expected)
        case let .extracting(progress):
            progress
        default:
            nil
        }
    }

    /// A download's progress. Zero while the size is not known, and never
    /// past the end when more arrives than the feed said.
    static func downloadProgress(received: UInt64, expected: UInt64?) -> Double {
        guard let expected, expected > 0 else { return 0 }
        return min(1.0, Double(received) / Double(expected))
    }

    /// The progress as VoiceOver reads it ("42%"). Empty in the states with
    /// no progress, which SwiftUI then leaves out, so they read as a plain
    /// button.
    func progressValueText(locale: Locale) -> String {
        progress.map { Self.progressText($0, locale: locale) } ?? ""
    }

    static func progressText(_ progress: Double, locale: Locale) -> String {
        progress.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}

/// A thin progress ring for an update control. Two strokes, a faint track
/// and the foreground, match macOS 26's inline progress styling without a
/// full `ProgressView`.
struct ProgressRing: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(WeirMotion.progress, value: progress)
        }
        .frame(width: 14, height: 14)
    }
}
