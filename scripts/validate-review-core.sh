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
    -module-name Weir -enable-testing -swift-version 6 \
    -enable-upcoming-feature ExistentialAny \
    -module-cache-path "$review_output/modules" \
    Weir/Core/Review/ReviewTerminalProbe.swift \
    Weir/Core/Process/ProcessNames.swift Weir/Core/Process/ProcessLiveness.swift \
    Weir/Core/Tmux/TmuxBinding.swift Weir/Core/Tmux/TmuxClientProbe.swift \
    Weir/Core/Tmux/TmuxTopology.swift \
    Weir/Core/Tmux/TmuxSocketPath.swift \
    Weir/Core/Tmux/TmuxCommand.swift Weir/Core/Git/ProcessDrain.swift \
    Weir/Core/Logging/WeirLogger.swift \
    -o "$review_output/libWeir.dylib"
cat > "$review_output/RunScenarios.swift" <<'SWIFT'
import Foundation
@testable import Weir
@main struct RunScenarios {
    static func main() throws {
        try ReviewProbeScenarios.foreground()
        print("PASS a real foreground process on its own terminal is accepted")

    }
}
SWIFT
swiftc -swift-version 6 -enable-upcoming-feature ExistentialAny \
    -module-cache-path "$review_output/modules" \
    -I "$review_output" -L "$review_output" -lWeir -Xlinker -rpath -Xlinker "$review_output" \
    WeirTests/Support/ReviewValidationFailure.swift \
    WeirTests/Support/ReviewProbeScenarios.swift WeirTests/Support/TestProcess.swift \
    "$review_output/RunScenarios.swift" -o "$review_output/run"
"$review_output/run" | tee "$review_output/scenarios.log"
