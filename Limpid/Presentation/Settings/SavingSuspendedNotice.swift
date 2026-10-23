// SavingSuspendedNotice.swift
// Limpid — what Limpid says while it has stopped saving the person's sessions or settings.

import Foundation

/// What Limpid tells while a file this launch could not take in has
/// stopped saving: which file, why, and what to do. Without it the
/// person would go on changing sessions or settings that are lost when
/// Limpid quits. Settings → General shows it at its top; the settings'
/// part is also an alert at launch (`atLaunch`).
struct SavingSuspendedNotice: Equatable {
    /// One sentence per file whose saving stopped: the sessions first.
    let sentences: [String]
    /// The files the sentences name, for Show in Finder to select.
    let files: [URL]

    /// `nil` while both files are being saved. `suspendedSessionFile` is
    /// `state.json` while its saving is suspended.
    static func make(
        suspendedSessionFile: URL?,
        settings: SettingsSavingSuspension?,
        settingsFile: URL,
        locale: Locale
    ) -> Self? {
        var sentences: [String] = []
        var files: [URL] = []
        if let suspendedSessionFile {
            sentences.append(SavingSuspendedText.sessionNotSaved(locale: locale))
            files.append(suspendedSessionFile)
        }
        if let settings {
            sentences.append(SavingSuspendedText.settingsNotSaved(settings, locale: locale))
            files.append(settingsFile)
        }
        return sentences.isEmpty ? nil : Self(sentences: sentences, files: files)
    }

    /// The alert shown at launch: the settings only, as the session's
    /// trouble is told by the alert that it was not restored
    /// (`SessionLoadIssue`), which every suspension of its saving comes
    /// with. `nil` while settings are saved.
    static func atLaunch(settings: SettingsSavingSuspension?, settingsFile: URL, locale: Locale) -> Self? {
        make(suspendedSessionFile: nil, settings: settings, settingsFile: settingsFile, locale: locale)
    }
}

/// The words of `SavingSuspendedNotice`.
enum SavingSuspendedText {
    static func sessionNotSaved(locale: Locale) -> String {
        LocalizedStringResource(
            // swiftlint:disable:next line_length
            "Your sessions aren’t being saved: state.json can’t be read by this version and couldn’t be set aside. Move it out of the folder, then quit and reopen Limpid.",
            comment: "Settings, General, and the alert that the session was not restored: saving sessions is suspended"
        ).resolved(in: locale)
    }

    /// The text of the alert that the session was not restored: its own
    /// `detail`, then, while the session is not being saved, that too, so
    /// the person learns it at launch and not only in Settings.
    static func loadIssueMessage(detail: String, isSessionSavingSuspended: Bool, locale: Locale) -> String {
        guard isSessionSavingSuspended else { return detail }
        return detail + "\n\n" + sessionNotSaved(locale: locale)
    }

    static func settingsNotSaved(_ suspension: SettingsSavingSuspension, locale: Locale) -> String {
        switch suspension {
        case .unreadable:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your settings aren’t being saved: settings.json can’t be read by this version and couldn’t be set aside. Move it out of the folder, then quit and reopen Limpid.",
                comment: "Settings, General, and an alert at launch: saving settings is suspended, as the file cannot be read"
            ).resolved(in: locale)
        case .notMoved:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your settings aren’t being saved: settings.json couldn’t be updated to this version’s format, so it is read as it was. Quit and reopen Limpid to try again.",
                comment: "Settings, General, and an alert at launch: saving settings is suspended, as the older file could not be migrated"
            ).resolved(in: locale)
        case .newerVersion:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your settings aren’t being saved: settings.json was written by a newer version of Limpid, so this version reads it but doesn’t write over it. Open that version to change your settings.",
                comment: "Settings, General, and an alert at launch: saving settings is suspended, as a newer version wrote the file"
            ).resolved(in: locale)
        case .newerVersionUnreadable:
            LocalizedStringResource(
                // swiftlint:disable:next line_length
                "Your settings aren’t being saved: settings.json was written by a newer version of Limpid in a form this version can’t read, so this version uses its defaults and leaves the file as it is. Open that version to change your settings.",
                comment: "Settings, General, and a launch alert: saving settings is suspended, as a newer version wrote an unreadable file"
            ).resolved(in: locale)
        }
    }

    static func launchTitle(locale: Locale) -> String {
        LocalizedStringResource("Settings Aren’t Being Saved", comment: "The alert at launch while saving settings is suspended: its title")
            .resolved(in: locale)
    }

    static func openSettings(locale: Locale) -> String {
        LocalizedStringResource("Open Settings").resolved(in: locale)
    }

    static func showFiles(locale: Locale) -> String {
        LocalizedStringResource("Show in Finder", comment: "Settings, General: selects the files that are not being saved in Finder")
            .resolved(in: locale)
    }
}
