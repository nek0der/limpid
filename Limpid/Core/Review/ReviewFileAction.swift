// ReviewFileAction.swift
// Limpid — resolves and opens reviewed worktree files outside the app.

import AppKit
import Foundation

/// The application state Review exposes before asking macOS to open a file.
///
/// A configured application can disappear after it has been selected, for
/// example when it is removed or its volume is unmounted. Keep that distinct
/// from the default-app case so callers can guide the reader to Settings
/// without discarding a preference that may become valid again.
enum ReviewFileApplicationResolution: Equatable {
    case macOSDefault
    case configured(ReviewFileApplication, bundleURL: URL)
    case configuredApplicationMissing(ReviewFileApplication)

    /// The selected application's last-known name, including when it cannot
    /// currently be found. `nil` means macOS will select the file-type default.
    var displayName: String? {
        switch self {
        case .macOSDefault:
            nil
        case let .configured(application, _), let .configuredApplicationMissing(application):
            application.lastKnownDisplayName
        }
    }

}

enum ReviewFileActionError: LocalizedError {
    case configuredApplicationMissing(ReviewFileApplication)

    var errorDescription: String? {
        switch self {
        case let .configuredApplicationMissing(application):
            String(localized: "The selected review app, \(application.lastKnownDisplayName), is no longer available.")
        }
    }
}

/// The boundary between Review's Git-relative paths and macOS file actions.
///
/// The pure resolution overloads deliberately accept dependencies as closures.
/// That makes the persistence and containment contracts testable without
/// altering a user's default application or launching another process.
enum ReviewFileAction {
    /// Builds a persisted preference from a selected `.app` bundle.
    static func application(fromBundleAt bundleURL: URL) -> ReviewFileApplication? {
        guard let bundle = Bundle(url: bundleURL), let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return ReviewFileApplication(
            bundleIdentifier: bundleIdentifier,
            lastKnownDisplayName: displayName
        )
    }

    /// Resolves the durable bundle identifier when the action is invoked.
    /// This intentionally does not rewrite settings when lookup fails.
    static func application(
        for preference: ReviewFileApplication?,
        bundleURLForIdentifier: (String) -> URL?
    ) -> ReviewFileApplicationResolution {
        guard let preference else { return .macOSDefault }
        guard let bundleURL = bundleURLForIdentifier(preference.bundleIdentifier) else {
            return .configuredApplicationMissing(preference)
        }
        return .configured(preference, bundleURL: bundleURL)
    }

    /// The live `NSWorkspace` adapter for `application(for:bundleURLForIdentifier:)`.
    static func application(for preference: ReviewFileApplication?) -> ReviewFileApplicationResolution {
        application(for: preference) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Resolves a Git-relative or absolute file path only when its canonical
    /// location remains under the canonical repository root. Resolving both
    /// sides closes the parent-symlink escape that lexical prefix checks miss.
    static func fileURL(for path: String, in repositoryRoot: URL) -> URL? {
        guard !path.isEmpty else { return nil }
        let candidate = if path.hasPrefix("/") {
            URL(fileURLWithPath: path)
        } else {
            repositoryRoot.appendingPathComponent(path)
        }

        let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var rootPath = root.path
        if !rootPath.hasSuffix("/") {
            rootPath += "/"
        }
        guard resolved.path.hasPrefix(rootPath) else { return nil }
        return resolved
    }

    /// Opens `fileURL` asynchronously. The default case lets Launch Services
    /// choose the user's normal handler; a configured application is passed by
    /// its freshly-resolved bundle URL. Both APIs are the non-deprecated
    /// `NSWorkspace.OpenConfiguration` variants.
    static func open(
        _ fileURL: URL,
        with application: ReviewFileApplicationResolution
    ) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        switch application {
        case .macOSDefault:
            _ = try await NSWorkspace.shared.open(fileURL, configuration: configuration)
        case let .configured(_, bundleURL):
            _ = try await NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: bundleURL,
                configuration: configuration
            )
        case let .configuredApplicationMissing(preference):
            throw ReviewFileActionError.configuredApplicationMissing(preference)
        }
    }

    /// Shows the file in Finder without changing the reader's app preference.
    static func revealInFinder(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
