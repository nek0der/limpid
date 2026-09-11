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
#   your terminal app (Terminal, Ghostty, etc.) and toggle
#   on. ScreenCaptureKit needs that permission to expose and capture Limpid's
#   window at its native pixel scale. We deliberately avoid the
#   Accessibility / System Events route so contributors only have to grant
#   one permission.

set -euo pipefail

OUT_DIR=".github/assets"
OUT_PATH="${OUT_DIR}/hero.png"

mkdir -p "${OUT_DIR}"

# Find the most recently built app under DerivedData. Prefer Release because
# Debug builds are ad-hoc signed and show extra Gatekeeper noise on first
# launch. Track modification times without parsing paths through `ls`, because
# a DerivedData or product path may contain spaces.
find_latest_app() {
  local configuration="$1"
  shift
  local latest=""
  local latest_mtime=0
  local candidate
  local mtime
  local product
  for product in "$@"; do
    while IFS= read -r -d '' candidate; do
      mtime="$(stat -f '%m' "${candidate}")"
      if ((mtime > latest_mtime)); then
        latest="${candidate}"
        latest_mtime="${mtime}"
      fi
    done < <(find ~/Library/Developer/Xcode/DerivedData \
      -path "*/Build/Products/${configuration}/${product}" \
      -type d -prune -print0 2>/dev/null)
  done
  printf '%s' "${latest}"
}

APP_PATH="$(find_latest_app Release Limpid.app)"
if [ -z "${APP_PATH}" ]; then
  APP_PATH="$(find_latest_app Debug 'Limpid Dev.app' Limpid.app)"
fi
if [ -z "${APP_PATH}" ]; then
  echo "error: no Limpid.app found under DerivedData." >&2
  echo "       Build first: xcodebuild -project Limpid.xcodeproj -scheme Limpid -configuration Release build" >&2
  exit 1
fi

echo "Launching: ${APP_PATH}"
echo "         LIMPID_DEMO=1 → using DemoFixture, persistence disabled"

APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APP_PATH}/Contents/Info.plist")"
APP_BINARY="${APP_PATH}/Contents/MacOS/${APP_EXECUTABLE}"
APP_PID=""
APP_LOG="$(mktemp -t limpid-screenshot.XXXXXX)"
CAPTURE_LOG="$(mktemp -t limpid-screenshot-capture.XXXXXX)"
CAPTURE_PATH="$(mktemp -t limpid-screenshot-image.XXXXXX)"
CAPTURE_HOME="$(mktemp -d -t limpid-screenshot-home.XXXXXX)"

cleanup() {
  if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
    # Demo persistence is disabled, so terminate this exact process without
    # entering the user's quit-confirmation policy or touching another Limpid.
    kill -TERM "${APP_PID}" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "${APP_PID}" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "${APP_PID}" 2>/dev/null; then
      kill -KILL "${APP_PID}" 2>/dev/null || true
    fi
    wait "${APP_PID}" 2>/dev/null || true
  fi
  rm -f "${APP_LOG}" "${CAPTURE_LOG}" "${CAPTURE_PATH}"
  rm -rf "${CAPTURE_HOME}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Launch the selected bundle's executable directly. `open -a` resolves through
# LaunchServices and can activate an installed copy with the same bundle id.
# Keeping the child pid gives activation, window lookup, capture, and cleanup
# one unambiguous identity. Give it an isolated Application Support directory
# so an installed copy cannot reload the user's settings into the demo process.
# Ignore macOS window restoration so a saved frame cannot replace DemoFixture's
# reproducible 1280×800 frame. Demo mode forces English UI and an opaque toolbar.
CFFIXED_USER_HOME="${CAPTURE_HOME}" LIMPID_DEMO=1 "${APP_BINARY}" \
  -AppleLanguages '(en-US)' \
  -AppleLocale en_US \
  -ApplePersistenceIgnoreState YES \
  >"${APP_LOG}" 2>&1 &
APP_PID=$!

# Let the app boot, run the per-pane initialCommand sends (each
# debounced ~600ms inside `SurfaceView.scheduleInitialCommandIfNeeded`),
# and settle. 4s covers cold-start frame timing in practice.
sleep 4

# Activate only the process started above. The installed app may be running at
# the same time and must keep its current windows and focus untouched.
swift - "${APP_PID}" <<'SWIFT' >/dev/null
import AppKit

guard CommandLine.arguments.count == 2,
      let raw = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: raw)
else { exit(1) }
app.activate(options: [.activateAllWindows])
SWIFT
sleep 1

# Park the pointer off the window before capturing. Sidebar rows reveal
# a delete button on hover, so without this the shot depends on where
# the contributor's cursor happened to rest — the hero would show one
# row with an affordance its neighbours lack, which is the opposite of
# what the design says about the trailing group at rest.
swift - <<'SWIFT' >/dev/null 2>&1 || true
import Cocoa
if let screen = NSScreen.main {
    let f = screen.frame
    // Bottom-right, inset so we don't land on a screen-edge hot corner.
    CGWarpMouseCursorPosition(CGPoint(x: f.maxX - 8, y: f.maxY - 8))
}
SWIFT
sleep 1

# Capture the exact process's normal window through ScreenCaptureKit. Filtering
# by pid avoids collisions with an installed copy; `pointPixelScale` preserves
# Retina detail, and the desktop-independent window filter keeps the rounded
# alpha mask without recording screen pixels behind the corners.
if ! swift - "${APP_PID}" "${CAPTURE_PATH}" <<'SWIFT' 2>"${CAPTURE_LOG}"
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

_ = NSApplication.shared
guard CommandLine.arguments.count == 3,
      let raw = Int32(CommandLine.arguments[1]) else { exit(1) }
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
let windows = content.windows.filter {
    $0.owningApplication?.processID == raw
        && $0.windowLayer == 0
        && $0.frame.width > 100
        && $0.frame.height > 100
}
guard let window = windows.max(by: {
    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
}) else { exit(2) }

let filter = SCContentFilter(desktopIndependentWindow: window)
let configuration = SCStreamConfiguration()
let scale = CGFloat(filter.pointPixelScale)
configuration.width = Int(window.frame.width * scale)
configuration.height = Int(window.frame.height * scale)
configuration.captureResolution = .best
configuration.scalesToFit = true
configuration.showsCursor = false
configuration.ignoreShadowsSingleWindow = true
configuration.shouldBeOpaque = false

let image: CGImage = try await SCScreenshotManager.captureImage(
    contentFilter: filter,
    configuration: configuration
)
guard let destination = CGImageDestinationCreateWithURL(
    outputURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else { exit(3) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(4) }
SWIFT
then
  echo "" >&2
  echo "error: could not capture the launched Limpid window." >&2
  echo "       Screen Recording permission may be missing for the calling terminal." >&2
  echo "" >&2
  echo "  Grant it once and rerun:" >&2
  echo "    System Settings → Privacy & Security → Screen Recording" >&2
  echo "    → click + → add your terminal app → toggle on" >&2
  echo "" >&2
  echo "Capture output:" >&2
  cat "${CAPTURE_LOG}" >&2
  echo "" >&2
  echo "App output:" >&2
  cat "${APP_LOG}" >&2
  exit 1
fi

if [ ! -s "${CAPTURE_PATH}" ]; then
  echo "error: screenshot output is empty" >&2
  exit 1
fi
mv -f "${CAPTURE_PATH}" "${OUT_PATH}"

echo "Saved: ${OUT_PATH}"
echo "       Preview with: open ${OUT_PATH}"
