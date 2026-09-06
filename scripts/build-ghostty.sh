#!/usr/bin/env bash
# Build libghostty xcframework for Limpid.
#
# Requirements:
#   - zig 0.16.0 installed. The exact requirement is
#     `minimum_zig_version` in vendor/ghostty/build.zig.zon.
#     Recommended: `brew install zig@0.16` (keg-only formula), so the
#     build does not drift with whatever `zig` is on PATH.
#   - vendor/ghostty submodule initialized.
#
# Output:
#   vendor/ghostty/macos/GhosttyKit.xcframework
#
# Usage:
#   ./scripts/build-ghostty.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="${REPO_ROOT}/vendor/ghostty"
ZIG_BIN="/opt/homebrew/opt/zig@0.16/bin/zig"

if [[ ! -x "${ZIG_BIN}" ]]; then
  echo "✗ zig 0.16.0 not found at ${ZIG_BIN}" >&2
  echo "  Install with: brew install zig@0.16" >&2
  exit 1
fi

if [[ ! -d "${GHOSTTY_DIR}" ]]; then
  echo "✗ vendor/ghostty submodule missing" >&2
  echo "  Initialize with: git submodule update --init --recursive" >&2
  exit 1
fi

echo "→ Building libghostty xcframework using $(${ZIG_BIN} version)..."
cd "${GHOSTTY_DIR}"
# We consume only the xcframework. Leaving the macOS app bundle in the
# build graph costs time and, since it copies gettext output we disable
# with -Di18n=false, fails outright.
"${ZIG_BIN}" build \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Doptimize=ReleaseFast \
  -Dsentry=false \
  -Di18n=false

XCFRAMEWORK="${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"
if [[ ! -d "${XCFRAMEWORK}" ]]; then
  echo "✗ Build finished but xcframework not found at ${XCFRAMEWORK}" >&2
  exit 1
fi

echo "✓ Built ${XCFRAMEWORK}"
