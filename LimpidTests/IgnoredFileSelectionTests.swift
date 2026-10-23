// IgnoredFileSelectionTests.swift
// Limpid — which ignored files a new worktree gets: patterns, `**`, whole folders, and the paths never used.

import Foundation
import Testing
@testable import Limpid

struct IgnoredFileSelectionTests {
    @Test func aPlainName_matchesAtAnyDepth_andALeadingSlash_onlyAtTheTop() {
        let ignored = [".env", "apps/web/.env", "config/master.key", "notes/config/master.key"]
        #expect(IgnoredFileSelection.select(patterns: [".env"], ignored: ignored) == [".env", "apps/web/.env"])
        #expect(IgnoredFileSelection.select(patterns: ["/.env"], ignored: ignored) == [".env"])
        // A `/` inside makes it a path from the top too.
        #expect(IgnoredFileSelection.select(patterns: ["config/master.key"], ignored: ignored) == ["config/master.key"])
    }

    @Test func aStar_staysInOnePart_andTwoStars_crossParts() {
        let ignored = [".env", ".env.local", "a/.env.test", "secrets/x/y.pem", "secrets/z.pem"]
        #expect(IgnoredFileSelection.select(patterns: [".env*"], ignored: ignored) == [".env", ".env.local", "a/.env.test"])
        #expect(IgnoredFileSelection.select(patterns: ["secrets/*.pem"], ignored: ignored) == ["secrets/z.pem"])
        #expect(IgnoredFileSelection.select(patterns: ["secrets/**/*.pem"], ignored: ignored) == ["secrets/x/y.pem", "secrets/z.pem"])
        #expect(IgnoredFileSelection.select(patterns: ["**/.env.test"], ignored: ignored) == ["a/.env.test"])
        // `a/**/b` is also `a/b`.
        #expect(IgnoredFileSelection.select(patterns: ["a/**/b"], ignored: ["a/b", "a/x/y/b", "c/b"]) == ["a/b", "a/x/y/b"])
        #expect(IgnoredFileSelection.select(patterns: ["?env"], ignored: [".env", "xxenv", "a/.env"]) == [".env", "a/.env"])
    }

    /// Git lists a folder it ignores whole once, with a slash: a pattern
    /// naming the folder copies all of it, and a full path inside it is
    /// copied on its own.
    @Test func aFolderGitIgnoresWhole_isCopiedWhole_orForThePathsNamedInIt() {
        let ignored = ["node_modules/", "config/", ".env"]
        #expect(IgnoredFileSelection.select(patterns: ["node_modules/"], ignored: ignored) == ["node_modules"])
        #expect(IgnoredFileSelection.select(patterns: ["node_modules"], ignored: ignored) == ["node_modules"])
        #expect(IgnoredFileSelection.select(patterns: ["config/master.key"], ignored: ignored) == ["config/master.key"])
        // A wildcard inside is not walked for.
        #expect(IgnoredFileSelection.select(patterns: ["config/*.key"], ignored: ignored).isEmpty)
        // A path inside a folder already picked goes with it.
        #expect(IgnoredFileSelection.select(patterns: ["config", "config/master.key"], ignored: ignored) == ["config"])
    }

    /// A trailing slash names a folder only, as in a `.gitignore`.
    @Test func aTrailingSlash_namesAFolderOnly() {
        #expect(IgnoredFileSelection.select(patterns: ["build/"], ignored: ["build", "out/build/"]) == ["out/build"])
        #expect(IgnoredFileSelection.select(patterns: ["/build/"], ignored: ["build/", "out/build/"]) == ["build"])
    }

    /// What the ignored files' menu adds names that one path.
    @Test func aPathPickedFromTheMenu_isAnchored() {
        let pattern = IgnoredFileSelection.pattern(forListed: ".env")
        #expect(pattern == "/.env")
        #expect(IgnoredFileSelection.select(patterns: [pattern], ignored: [".env", "apps/.env"]) == [".env"])
    }

    @Test func pathsOutsideTheFolder_orInGit_areNeverUsed() {
        #expect(IgnoredFileSelection.problem(of: "~/.ssh/id_rsa") == .homeFolder)
        #expect(IgnoredFileSelection.problem(of: "../other/.env") == .leavesFolder)
        #expect(IgnoredFileSelection.problem(of: "a/../../b") == .leavesFolder)
        #expect(IgnoredFileSelection.problem(of: "/../b") == .leavesFolder)
        #expect(IgnoredFileSelection.problem(of: ".git") == .namesGitFolder)
        #expect(IgnoredFileSelection.problem(of: "sub/.git/config") == .namesGitFolder)
        #expect(IgnoredFileSelection.problem(of: ".github/x") == nil)
        #expect(IgnoredFileSelection.problem(of: "./.env") == nil)
        // A leading slash is the project's folder, never the disk's root.
        #expect(IgnoredFileSelection.problem(of: "/etc/passwd") == nil)
        #expect(IgnoredFileSelection.select(patterns: ["/etc/passwd"], ignored: [".env"]).isEmpty)
        let ignored = ["../up", ".git/", ".env"]
        #expect(IgnoredFileSelection.select(patterns: ["*", "../up", ".git"], ignored: ignored) == [".env"])
    }

    @Test func noPatterns_orEmptyOnes_pickNothing() {
        #expect(IgnoredFileSelection.select(patterns: [], ignored: [".env"]).isEmpty)
        #expect(IgnoredFileSelection.select(patterns: ["", "  ", "/"], ignored: [".env"]).isEmpty)
        #expect(IgnoredFileSelection.Pattern("  ./config/  ") == IgnoredFileSelection.Pattern("config/"))
    }
}
