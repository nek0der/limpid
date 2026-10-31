#!/usr/bin/env bash
# Build libghostty xcframework for Weir.
#
# Requirements:
#   - The Zig release named by `minimum_zig_version` in
#     vendor/ghostty/build.zig.zon, installed from Homebrew:
#     `brew install zig@<version>`, e.g. `brew install zig@0.17`.
#     While that release is Homebrew's current one, `zig@<version>` is an
#     alias of `zig` and installs under opt/zig; once a newer release
#     ships it becomes its own keg-only formula under opt/zig@<version>.
#     We look in both and take only a Zig whose version matches exactly,
#     so the build does not drift with whatever `zig` is on PATH.
#   - vendor/ghostty submodule initialized.
#
# Output:
#   vendor/ghostty/macos/GhosttyKit.xcframework
#   Weir/Resources/terminfo/{67/ghostty,78/xterm-ghostty}
#
# Usage:
#   ./scripts/build-ghostty.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="${REPO_ROOT}/vendor/ghostty"

if [[ ! -d "${GHOSTTY_DIR}" ]]; then
  echo "✗ vendor/ghostty submodule missing" >&2
  echo "  Initialize with: git submodule update --init --recursive" >&2
  exit 1
fi

ZIG_VERSION="$(sed -n 's/^ *\.minimum_zig_version = "\(.*\)",$/\1/p' "${GHOSTTY_DIR}/build.zig.zon")"
if [[ -z "${ZIG_VERSION}" ]]; then
  echo "✗ minimum_zig_version not found in ${GHOSTTY_DIR}/build.zig.zon" >&2
  exit 1
fi
# Homebrew formulas name the minor release (zig@0.17), not the patch.
ZIG_FORMULA="zig@${ZIG_VERSION%.*}"

ZIG_BIN=""
for candidate in "/opt/homebrew/opt/${ZIG_FORMULA}/bin/zig" "/opt/homebrew/opt/zig/bin/zig"; do
  if [[ -x "${candidate}" && "$("${candidate}" version)" == "${ZIG_VERSION}" ]]; then
    ZIG_BIN="${candidate}"
    break
  fi
done
if [[ -z "${ZIG_BIN}" ]]; then
  echo "✗ No zig ${ZIG_VERSION} at /opt/homebrew/opt/${ZIG_FORMULA} or /opt/homebrew/opt/zig" >&2
  echo "  Install with: brew install ${ZIG_FORMULA}" >&2
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

# Keep the complete compiled alias pair on the same vendor revision as the
# library. ncurses selects the hexadecimal directory from the first character
# of TERM, so the directory names must survive unchanged.
TERMINFO_SOURCE="${GHOSTTY_DIR}/zig-out/share/terminfo"
TERMINFO_DEST="${REPO_ROOT}/Weir/Resources/terminfo"
for entry in "67/ghostty" "78/xterm-ghostty"; do
  if [[ ! -f "${TERMINFO_SOURCE}/${entry}" ]]; then
    echo "Built terminfo entry missing: ${TERMINFO_SOURCE}/${entry}" >&2
    exit 1
  fi
  mkdir -p "${TERMINFO_DEST}/$(dirname "${entry}")"
  cp "${TERMINFO_SOURCE}/${entry}" "${TERMINFO_DEST}/${entry}"
done

echo "✓ Built ${XCFRAMEWORK}"
echo "Synced ${TERMINFO_DEST}"
