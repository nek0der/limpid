#!/usr/bin/env bash
# The one review scenario the test target cannot host.
#
# `ReviewProbeScenarios.foreground` opens a pty and spawns processes, and the
# XCTest/Swift Testing target runs its suites in parallel: the descriptors this
# takes reuse the numbers `SettingsFileWatcherTests` asserts are closed, failing
# a test that is correct about its own subject. Everything else the review core
# promises is asserted in that target instead — this script deliberately does
# not duplicate it, so there is one place to add a scenario and one place it can
# rot.
#
# Compiled with the same Swift version and upcoming features as the app target
# (`project.yml`), so the job cannot pass under looser rules than the build.
set -euo pipefail
cd "$(dirname "$0")/.."
review_output="$PWD/build/review-validation"
mkdir -p "$review_output/modules"
swiftc -Xfrontend -disable-sandbox -emit-module -emit-library \
    -module-name Limpid -enable-testing -swift-version 6 \
    -enable-upcoming-feature ExistentialAny \
    -module-cache-path "$review_output/modules" \
    Limpid/Core/Review/ReviewTerminalProbe.swift \
    Limpid/Core/Tmux/TmuxBinding.swift Limpid/Core/Tmux/TmuxClientProbe.swift \
    Limpid/Core/Tmux/TmuxTopology.swift \
    Limpid/Core/Tmux/TmuxSocketPath.swift \
    Limpid/Core/Tmux/TmuxCommand.swift \
    Limpid/Core/Logging/LimpidLogger.swift \
    -o "$review_output/libLimpid.dylib"
cat > "$review_output/RunScenarios.swift" <<'SWIFT'
import Foundation
@testable import Limpid
@main struct RunScenarios {
    static func main() throws {
        try ReviewProbeScenarios.foreground()
        print("PASS a real foreground process on its own terminal is accepted")

    }
}
SWIFT
swiftc -swift-version 6 -enable-upcoming-feature ExistentialAny \
    -module-cache-path "$review_output/modules" \
    -I "$review_output" -L "$review_output" -lLimpid -Xlinker -rpath -Xlinker "$review_output" \
    LimpidTests/Support/ReviewScenarioFailure.swift \
    LimpidTests/Support/ReviewProbeScenarios.swift \
    "$review_output/RunScenarios.swift" -o "$review_output/run"
"$review_output/run" | tee "$review_output/scenarios.log"
