// HighImpactCommandTests.swift
// Limpid — which shell commands count as high impact, and which look alike but do not.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Limpid

struct HighImpactCommandTests {
    @Test(arguments: [
        "rm -rf build",
        "rm -r build",
        "rm -R build",
        "rm --recursive build",
        "/bin/rm -fr build",
        "git push --force",
        "git push -f origin main",
        "git push --force-with-lease",
        "git push origin +main",
        "git -C repo push --force",
        "git reset --hard HEAD~1",
        "git clean -fdx",
        "git clean --force",
        "sudo ls",
        "dd if=/dev/zero of=/dev/disk2",
        "mkfs /dev/sdb1",
        "mkfs.ext4 /dev/sdb1",
        "chmod -R 777 .",
        "chmod -R 0777 .",
        "chmod -R a+rwx .",
        "chmod -R o+w .",
        "chmod -R +w .",
        "chmod -R a=rw .",
        "chmod -R 666 .",
        "chmod -R 002 .",
        "FOO=1 rm -rf x",
        "make && rm -rf build",
        "ls; sudo reboot",
        "cat x | sudo tee y",
        "true || git reset --hard",
        "echo ok\nrm -rf x",
        "sleep 1 & rm -rf x",
        "\\rm -rf x",
        "\"rm\" -rf x",
        "'rm' -rf x",
        "env rm -rf x",
        "command rm -rf x",
        "nohup rm -rf x",
        "time rm -rf x",
        "xargs rm -rf",
        "bash -c 'rm -rf x'",
        "sh -c \"rm -rf x\"",
        "eval rm -rf x",
        "(rm -rf x)",
        "{ rm -rf x; }",
        "echo $(rm -rf x)",
        "X=$(rm -rf y)",
        "echo `rm -rf x`",
        "if true; then rm -rf x; fi",
        "! rm -rf x",
        "RM -rf x",
        "SUDO ls",
        "git reset --har",
        "git reset --ha",
        "git clean --forc",
        "git push --forc",
        "rm --rec x",
        "rm --r x",
        "git reset --h",
        "git --namespace foo push -f",
        "git --config-env k=ENV push -f",
        "chmod -R 77 .",
        "$'\\x72m' -rf x"
    ])
    func isHighImpact_knownCommands_areHighImpact(_ command: String) {
        #expect(HighImpactCommand.isHighImpact(command))
    }

    @Test(arguments: [
        "ls -la",
        "rm file.txt",
        "rm -f file.txt",
        "git push origin main",
        "git reset --soft HEAD~1",
        "git clean -n",
        "chmod -R 755 .",
        "chmod -R u+w .",
        "chmod 777 file",
        "dd of=/tmp/x",
        "make test",
        "npm run build 2>&1 | tail",
        "git push --follow-tags",
        "git reset -- file",
        "rm -- -file",
        "chmod -R 75 .",
    ])
    func isHighImpact_ordinaryCommands_areNot(_ command: String) {
        #expect(!HighImpactCommand.isHighImpact(command))
    }

    /// Caution over precision: a word that only names one is sent to
    /// Limpid as well.
    @Test func isHighImpact_aMentionCounts() {
        #expect(HighImpactCommand.isHighImpact("echo sudo"))
    }
}
