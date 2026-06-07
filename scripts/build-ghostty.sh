#!/usr/bin/env bash
# Build libghostty xcframework for Limpid.
#
# Requirements:
#   - zig 0.15.2 installed (Ghostty 1.3.1 pins this exactly).
#     Recommended: `brew install zig@0.15` (keg-only formula).
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
ZIG_BIN="/opt/homebrew/opt/zig@0.15/bin/zig"

if [[ ! -x "${ZIG_BIN}" ]]; then
  echo "✗ zig 0.15.2 not found at ${ZIG_BIN}" >&2
  echo "  Install with: brew install zig@0.15" >&2
  exit 1
fi

if [[ ! -d "${GHOSTTY_DIR}" ]]; then
  echo "✗ vendor/ghostty submodule missing" >&2
  echo "  Initialize with: git submodule update --init --recursive" >&2
  exit 1
fi

echo "→ Building libghostty xcframework using $(${ZIG_BIN} version)..."
cd "${GHOSTTY_DIR}"
"${ZIG_BIN}" build \
  -Demit-xcframework=true \
  -Doptimize=ReleaseFast \
  -Dsentry=false \
  -Di18n=false

XCFRAMEWORK="${GHOSTTY_DIR}/macos/GhosttyKit.xcframework"
if [[ ! -d "${XCFRAMEWORK}" ]]; then
  echo "✗ Build finished but xcframework not found at ${XCFRAMEWORK}" >&2
  exit 1
fi

echo "✓ Built ${XCFRAMEWORK}"
