// LoginShellPathTests.swift
// Limpid — the login shell's PATH: reading and merging it, and waiting for it across canceled callers.

import Foundation
import Testing
@testable import Limpid

@Suite(.timeLimit(.minutes(1)))
struct LoginShellPathTests {
    @Test func theReadsValue_reachesTheCaller() async throws {
        let shell = LoginShellPath { "/opt/bin:/usr/bin" }
        #expect(try await shell.path() == "/opt/bin:/usr/bin")
    }

    @Test func aCallerCancelledWhileWaiting_stopsAtOnce_andTheNextOneGetsTheRead() async throws {
        let gate = Gate<String?>()
        let shell = LoginShellPath { await gate.wait() }
        let waiting = Task { try await shell.path() }
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(10)) { gate.requests == 1 }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }

        let next = Task { try await shell.path() }
        gate.open(with: "/opt/bin")
        #expect(try await next.value == "/opt/bin")
        // One read for both callers.
        #expect(gate.requests == 1)
    }

    @Test func aCallerCancelledBeforeItWaits_stopsAtOnce() async {
        let gate = Gate<String?>()
        let shell = LoginShellPath { await gate.wait() }
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await shell.path()
        }
        await #expect(throws: CancellationError.self) { try await waiting.value }
        gate.open(with: nil)
    }

    @Test func ofTwoCallers_theOneCancelled_doesNotStopTheOther() async throws {
        let gate = Gate<String?>()
        let shell = LoginShellPath { await gate.wait() }
        let first = Task { try await shell.path() }
        let second = Task { try await shell.path() }
        await pollUntil(timeout: .seconds(5), interval: .milliseconds(10)) { gate.requests == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        gate.open(with: "/opt/bin")
        #expect(try await second.value == "/opt/bin")
    }

    @Test func theLoginShellsPath_isReadPastWhatItsProfilePrints_andGoesAfterTheAppsOwn() {
        let marker = LoginShellPath.marker
        let output = "Welcome back\n\(marker)/opt/homebrew/bin:/usr/bin:/my/nvm/bin\(marker)\nbye from .zlogout"
        #expect(LoginShellPath.loginPath(in: output) == "/opt/homebrew/bin:/usr/bin:/my/nvm/bin")
        #expect(LoginShellPath.loginPath(in: "no marker at all") == nil)
        // Opened from the Dock: the login shell's order goes first.
        #expect(LoginShellPath.merged(inherited: "/usr/bin:/bin:/usr/sbin:/sbin", login: "/opt/homebrew/bin:/usr/bin")
            == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        // A shell that printed `$PATH` unexpanded adds nothing.
        #expect(LoginShellPath.merged(inherited: "/usr/bin", login: "$PATH:.") == "/usr/bin")
        // The app's order wins; the login shell adds only what is missing.
        #expect(LoginShellPath.merged(inherited: "/my/nvm/bin:/usr/bin", login: "/opt/homebrew/bin:/usr/bin:/my/nvm/bin")
            == "/my/nvm/bin:/usr/bin:/opt/homebrew/bin")
        #expect(LoginShellPath.merged(inherited: "/usr/bin:/bin", login: nil) == "/usr/bin:/bin")
        #expect(LoginShellPath.merged(inherited: "", login: nil) == nil)
    }
}
