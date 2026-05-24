#!/usr/bin/env bash
# scripts/screenshot.sh
# Limpid — Regenerate the README hero shot from the demo session.
# Run from the repo root. Requires a recent Release build of
# `Limpid.app` somewhere under Xcode DerivedData (we don't rebuild
# here so the script stays fast and decoupled from the toolchain).
#
# Usage:
#   xcodebuild -project Limpid.xcodeproj -scheme Limpid \
#     -configuration Release build
#   ./scripts/screenshot.sh
#
# Output: .github/assets/hero.png (committed to git so README shows
# it on GitHub without a separate asset host).
#
# One-time setup:
#   System Settings → Privacy & Security → Screen Recording → add
#   your terminal app (Terminal / iTerm / Ghostty / etc.) and toggle
#   on. We need that permission for both `screencapture` itself and
#   for `CGWindowListCopyWindowInfo` to expose Limpid's bounds so the
#   crop is tight. We deliberately avoid the Accessibility / System
#   Events route so contributors only have to grant one permission.

set -euo pipefail

OUT_DIR=".github/assets"
OUT_PATH="${OUT_DIR}/hero.png"

mkdir -p "${OUT_DIR}"

# Find the most recently built Limpid.app under DerivedData. Prefer
# Release because Debug builds are ad-hoc signed and show extra
# Gatekeeper noise on first launch.
APP_PATH="$(
  ls -dt ~/Library/Developer/Xcode/DerivedData/Limpid-*/Build/Products/Release/Limpid.app 2>/dev/null \
    | head -1
)"
if [ -z "${APP_PATH}" ]; then
  APP_PATH="$(
    ls -dt ~/Library/Developer/Xcode/DerivedData/Limpid-*/Build/Products/Debug/Limpid.app 2>/dev/null \
      | head -1
  )"
fi
if [ -z "${APP_PATH}" ]; then
  echo "error: no Limpid.app found under DerivedData." >&2
  echo "       Build first: xcodebuild -project Limpid.xcodeproj -scheme Limpid -configuration Release build" >&2
  exit 1
fi

echo "Launching: ${APP_PATH}"
echo "         LIMPID_DEMO=1 → using DemoFixture, persistence disabled"

# Stop any running instance so `tell application "Limpid"` targets
# the freshly-launched demo process and not a stale dev window.
osascript -e 'quit app "Limpid"' >/dev/null 2>&1 || true
sleep 1

# `open -a` honors the calling shell's environment, so LIMPID_DEMO
# propagates into the app process. Force English UI regardless of
# the contributor's macOS system language so the hero shot on the
# (English) README stays consistent. Demo mode also forces the
# chrome opaque in `SettingsStore.init` (see `DemoFixture.isDemoActive`)
# so the capture doesn't bleed through to the contributor's wallpaper.
LIMPID_DEMO=1 open -a "${APP_PATH}" --args -AppleLanguages '(en-US)' -AppleLocale en_US

# Let the app boot, run the per-pane initialCommand sends (each
# debounced ~600ms inside `SurfaceView.scheduleInitialCommandIfNeeded`),
# and settle. 4s covers cold-start frame timing in practice.
sleep 4

osascript -e 'tell application "Limpid" to activate' >/dev/null
sleep 1

# Query Limpid's on-screen rect via CGWindowList. This only needs
# Screen Recording permission (which `screencapture` already requires
# below), so contributors don't have to grant Accessibility too.
BOUNDS=$(
  swift - <<'SWIFT' 2>/dev/null || true
import Cocoa
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let wins = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(1) }
for w in wins where (w["kCGWindowOwnerName"] as? String) == "Limpid" {
    guard let b = w["kCGWindowBounds"] as? [String: CGFloat],
          let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
          wd > 100, ht > 100 else { continue }
    print("\(Int(x)),\(Int(y)),\(Int(wd)),\(Int(ht))")
    exit(0)
}
exit(1)
SWIFT
)
if [[ -z "${BOUNDS}" ]]; then
  echo "" >&2
  echo "error: could not locate Limpid window — Screen Recording permission" >&2
  echo "       likely missing for the calling terminal." >&2
  echo "" >&2
  echo "  Grant it once and rerun:" >&2
  echo "    System Settings → Privacy & Security → Screen Recording" >&2
  echo "    → click + → add your terminal app → toggle on" >&2
  echo "" >&2
  osascript -e 'quit app "Limpid"' >/dev/null 2>&1 || true
  exit 1
fi

# `-o` strips the drop shadow (cleaner README inline);
# `-x` silences the shutter sound.
screencapture -x -o "-R${BOUNDS}" "${OUT_PATH}"

osascript -e 'quit app "Limpid"' >/dev/null 2>&1 || true

if [ ! -f "${OUT_PATH}" ]; then
  echo "error: screenshot was not written to ${OUT_PATH}" >&2
  exit 1
fi

echo "Saved: ${OUT_PATH}"
echo "       Preview with: open ${OUT_PATH}"
