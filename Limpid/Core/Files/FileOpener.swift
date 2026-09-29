// FileOpener.swift
// Limpid — opens a local file in the reader's chosen app, at a line when that
// app accepts one. Shared by Review and terminal links.

import AppKit
import Foundation
import OSLog

private let log = Logger.limpid("files")

/// The application state exposed before asking macOS to open a file.
///
/// A configured application can disappear after it has been selected, for
/// example when it is removed or its volume is unmounted. Keep that distinct
/// from the default-app case so callers can guide the reader to Settings
/// without discarding a preference that may become valid again.
enum FileApplicationResolution: Equatable {
    case macOSDefault
    case configured(FileApplication, bundleURL: URL)
    case configuredApplicationMissing(FileApplication)

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

enum FileOpenerError: LocalizedError {
    case configuredApplicationMissing(FileApplication)

    var errorDescription: String? {
        switch self {
        case let .configuredApplicationMissing(application):
            String(localized: "The app selected for opening files, \(application.lastKnownDisplayName), is no longer available.")
        }
    }
}

/// A line launch whose helper is not installed. Never shown: the file opens
/// without the line instead.
private struct MissingEditorHelper: Error {
    let path: String
}

/// The pure resolution overloads accept dependencies as closures, which keeps
/// the persistence contract testable without altering a user's default
/// application or launching another process.
enum FileOpener {
    /// Builds a persisted preference from a selected `.app` bundle.
    static func application(fromBundleAt bundleURL: URL) -> FileApplication? {
        guard let bundle = Bundle(url: bundleURL), let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return FileApplication(
            bundleIdentifier: bundleIdentifier,
            lastKnownDisplayName: displayName
        )
    }

    /// Resolves the durable bundle identifier when the action is invoked.
    /// This intentionally does not rewrite settings when lookup fails.
    static func application(
        for preference: FileApplication?,
        bundleURLForIdentifier: (String) -> URL?
    ) -> FileApplicationResolution {
        guard let preference else { return .macOSDefault }
        guard let bundleURL = bundleURLForIdentifier(preference.bundleIdentifier) else {
            return .configuredApplicationMissing(preference)
        }
        return .configured(preference, bundleURL: bundleURL)
    }

    /// The live `NSWorkspace` adapter for `application(for:bundleURLForIdentifier:)`.
    static func application(for preference: FileApplication?) -> FileApplicationResolution {
        application(for: preference) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Opens `fileURL` asynchronously. With a position, the handling app is
    /// looked up first — the configured one, or the file type's default — so
    /// a default editor that takes a line number gets one too. When that
    /// launch fails, the file still opens, only without the line.
    static func open(
        _ fileURL: URL,
        at position: FilePosition? = nil,
        with application: FileApplicationResolution
    ) async throws {
        let applicationURL: URL?
        switch application {
        case .macOSDefault:
            applicationURL = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        case let .configured(_, bundleURL):
            applicationURL = bundleURL
        case let .configuredApplicationMissing(preference):
            throw FileOpenerError.configuredApplicationMissing(preference)
        }

        if let position,
           let applicationURL,
           let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier,
           let launch = EditorLineLaunch.make(
               bundleIdentifier: bundleIdentifier,
               applicationURL: applicationURL,
               file: fileURL,
               position: position
           )
        {
            do {
                try await perform(launch, applicationURL: applicationURL)
                return
            } catch {
                log.error("line launch failed, opening without the line: \(String(describing: error), privacy: .private)")
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        if case let .configured(_, bundleURL) = application {
            _ = try await NSWorkspace.shared.open([fileURL], withApplicationAt: bundleURL, configuration: configuration)
        } else {
            _ = try await NSWorkspace.shared.open(fileURL, configuration: configuration)
        }
    }

    private static func perform(_ launch: EditorLineLaunch, applicationURL: URL) async throws {
        switch launch {
        case let .url(url):
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        case let .process(executable, arguments):
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw MissingEditorHelper(path: executable.path)
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // The helpers hand the file to the running editor and exit; we do
            // not wait for them or read their output.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
    }
}
