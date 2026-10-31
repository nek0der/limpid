// DomainModuleStringsTests.swift
// Weir — a string worded in the static Domain module resolves through the app's catalog.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

/// `LocalizedStringResource` looks in the main bundle unless told otherwise,
/// and the catalog lives in the app. A module with a bundle of its own would
/// read its text from there and show English, so this reads a string as a
/// person in Japanese would.
struct DomainModuleStringsTests {
    @Test func aDomainString_readsTheAppCatalog() {
        #expect(PromptWaitText.line(.signIn).resolved(in: Locale(identifier: "ja")) == "サインイン待ち")
    }
}
