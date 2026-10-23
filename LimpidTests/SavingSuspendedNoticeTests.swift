// SavingSuspendedNoticeTests.swift
// Limpid — what Limpid says while it has stopped saving the sessions or the settings.

import Foundation
import Testing
@testable import Limpid

struct SavingSuspendedNoticeTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let folder = URL(fileURLWithPath: "/tmp/limpid-notice")
    private static let sessionFile = folder.appendingPathComponent("state.json")
    private static let settingsFile = folder.appendingPathComponent("settings.json")

    /// Nothing is shown while both files are saved, in Settings or at launch.
    @Test func bothFilesSaved_showNothing() {
        #expect(SavingSuspendedNotice.make(
            suspendedSessionFile: nil, settings: nil, settingsFile: Self.settingsFile, locale: Self.english
        ) == nil)
        #expect(SavingSuspendedNotice.atLaunch(settings: nil, settingsFile: Self.settingsFile, locale: Self.english) == nil)
    }

    /// Settings → General names each file whose saving stopped, the
    /// sessions first, with what to do; they are the files Show in Finder
    /// selects.
    @Test func eachSuspendedFile_isNamed_sessionsFirst() throws {
        let notice = try #require(SavingSuspendedNotice.make(
            suspendedSessionFile: Self.sessionFile,
            settings: .unreadable,
            settingsFile: Self.settingsFile,
            locale: Self.japanese
        ))
        #expect(notice.files == [Self.sessionFile, Self.settingsFile])
        #expect(notice.sentences == [
            "セッションを保存していません。このバージョンでは state.json を読み込めず、退避もできませんでした。state.json をフォルダの外に移動してから、Limpid を終了して再度開いてください。",
            "設定を保存していません。このバージョンでは settings.json を読み込めず、退避もできませんでした。settings.json をフォルダの外に移動してから、Limpid を終了して再度開いてください。"
        ])
    }

    /// An older settings file read as it was is not called unreadable.
    @Test func anOlderSettingsFileNotMoved_isToldApart() throws {
        let notice = try #require(SavingSuspendedNotice.make(
            suspendedSessionFile: nil,
            settings: .notMoved,
            settingsFile: Self.settingsFile,
            locale: Self.english
        ))
        #expect(notice.files == [Self.settingsFile])
        #expect(notice.sentences.count == 1)
        #expect(notice.sentences[0].hasPrefix("Your settings aren’t being saved: settings.json couldn’t be updated"))
        #expect(notice.sentences[0].hasSuffix("so it is read as it was. Quit and reopen Limpid to try again."))
    }

    /// A file a newer build wrote is told apart, and says where to change
    /// the settings.
    @Test func aNewerSettingsFile_isToldApart() {
        #expect(SavingSuspendedText.settingsNotSaved(.newerVersion, locale: Self.japanese)
            == "設定を保存していません。settings.json は新しいバージョンの Limpid が書き込んだため、このバージョンは読み込むだけで上書きしません。設定を変更するには、そのバージョンの Limpid を開いてください。")
        #expect(SavingSuspendedText.settingsNotSaved(.newerVersion, locale: Self.english)
            .hasPrefix("Your settings aren’t being saved: settings.json was written by a newer version of Limpid"))
    }

    /// One this build cannot decode says the defaults are in use, not the
    /// file.
    @Test func aNewerSettingsFileThatDoesNotDecode_saysTheDefaultsAreInUse() {
        // swiftlint:disable:next line_length
        let japanese = "設定を保存していません。settings.json は新しいバージョンの Limpid がこのバージョンでは読めない形で書き込んだため、このバージョンはデフォルトの設定を使い、ファイルはそのまま残します。設定を変更するには、そのバージョンの Limpid を開いてください。"
        #expect(SavingSuspendedText.settingsNotSaved(.newerVersionUnreadable, locale: Self.japanese) == japanese)
        #expect(SavingSuspendedText.settingsNotSaved(.newerVersionUnreadable, locale: Self.english)
            .contains("this version uses its defaults and leaves the file as it is"))
    }

    /// The launch alert tells the settings alone.
    @Test func theLaunchAlert_tellsTheSettings() throws {
        let alert = try #require(SavingSuspendedNotice.atLaunch(
            settings: .unreadable,
            settingsFile: Self.settingsFile,
            locale: Self.japanese
        ))
        #expect(alert.files == [Self.settingsFile])
        #expect(alert.sentences == [SavingSuspendedText.settingsNotSaved(.unreadable, locale: Self.japanese)])
    }

    /// The alert that the session was not restored also says it is not
    /// being saved, and only then.
    @Test func theRestoreAlert_saysTheSessionIsNotSaved_whenItIsNot() {
        let detail = "A fresh window was opened instead."
        #expect(SavingSuspendedText.loadIssueMessage(detail: detail, isSessionSavingSuspended: false, locale: Self.english)
            == detail)
        #expect(SavingSuspendedText.loadIssueMessage(detail: detail, isSessionSavingSuspended: true, locale: Self.english)
            == detail + "\n\n" + SavingSuspendedText.sessionNotSaved(locale: Self.english))
    }
}
