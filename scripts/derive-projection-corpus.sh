#!/usr/bin/env bash
# Regenerates rust/fixtures/projection/*/{agent-states,sessions,cwd-events,...}
# by replaying the recorded hook fixtures through the hook runtime.
#
# The records the reader projects are derived, not hand-written, so a provider
# schema change updates the writer fixtures and the reader corpus together.
# Run this after touching a scenario or a hook fixture, then review the diff.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo run --locked --quiet --package limpid-agent-hook --example derive-projection-corpus
git status --short -- rust/fixtures/projection
