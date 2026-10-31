// NotificationDeliveryStatusTests.swift
// Weir — whether a notification is seen: macOS's permission, a Focus Weir cannot read, and which rows start read.

import Foundation
import Testing
import UserNotifications
@testable import Weir

struct NotificationDeliveryStatusTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test func aFocusWeirCannotRead_isUnknown_ratherThanGuessedOff() {
        #expect(NotificationDeliveryStatus(permission: .allowed).focus == .unknown)
    }

    @Test(arguments: [
        (UNAuthorizationStatus.authorized, UNAlertStyle.banner, NotificationDeliveryStatus.Permission.allowed),
        (.authorized, .alert, .allowed),
        (.authorized, .none, .allowedWithoutBanners),
        (.provisional, .banner, .allowedWithoutBanners),
        (.denied, .banner, .denied),
        (.notDetermined, .none, .notAsked)
    ])
    func macOSPermission_readsAsWhetherABannerWouldShow(
        _ status: UNAuthorizationStatus,
        _ style: UNAlertStyle,
        _ permission: NotificationDeliveryStatus.Permission
    ) {
        #expect(WeirNotificationManager.permission(for: status, alertStyle: style) == permission)
    }

    @Test(arguments: [
        NotificationDeliveryStatus(permission: .allowed, focus: .unknown),
        NotificationDeliveryStatus(permission: .allowed, focus: .off)
    ])
    func aBannerThatWillShow_saysNothing(_ status: NotificationDeliveryStatus) {
        #expect(NotificationDeliveryStatusText.notice(status, locale: Self.english) == nil)
    }

    @Test(arguments: [
        (NotificationDeliveryStatus(permission: .denied, focus: .unknown), "macOS の通知はオフです。"),
        (NotificationDeliveryStatus(permission: .notAsked, focus: .off), "macOS で通知の許可がまだ確認されていません。"),
        (NotificationDeliveryStatus(permission: .allowedWithoutBanners, focus: .unknown), "macOS のバナー表示がオフです。"),
        (NotificationDeliveryStatus(permission: .allowed, focus: .on), "集中モードがオンのため、バナーが表示されないことがあります。"),
        // A permission that keeps every banner away is said before a Focus.
        (NotificationDeliveryStatus(permission: .denied, focus: .on), "macOS の通知はオフです。")
    ])
    func aBannerThatMayNotShow_saysWhy(_ status: NotificationDeliveryStatus, _ text: String) {
        #expect(NotificationDeliveryStatusText.notice(status, locale: Self.japanese) == text)
    }

    @Test func theNotice_readsInEnglish() {
        #expect(NotificationDeliveryStatusText.notice(NotificationDeliveryStatus(permission: .denied), locale: Self.english)
            == "macOS notifications are off.")
        #expect(NotificationDeliveryStatusText.notice(NotificationDeliveryStatus(permission: .allowed, focus: .on), locale: Self.english)
            == "A Focus is on, so banners may not show.")
    }

    @Test("visible delivery keeps agent rows unread until runtime handling")
    @MainActor func initialReadState_agentRowsRequireRuntimeHandling() {
        #expect(WeirNotificationManager.initialReadState(kind: .desktop, isSourceVisible: true))
        #expect(!WeirNotificationManager.initialReadState(kind: .agentFinished, isSourceVisible: true))
        #expect(!WeirNotificationManager.initialReadState(kind: .agentNeedsInput, isSourceVisible: true))
        #expect(!WeirNotificationManager.initialReadState(kind: .agentError, isSourceVisible: true))
    }
}
