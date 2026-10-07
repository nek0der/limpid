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
# Empty until created, so the cleanup installed next removes only what exists
# however early the script stops.
APP_LOG=""
CAPTURE_LOG=""
CAPTURE_PATH=""
CAPTURE_HOME_PATH=""

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
  local file
  for file in "${APP_LOG}" "${CAPTURE_LOG}" "${CAPTURE_PATH}"; do
    [[ -n "${file}" ]] && rm -f -- "${file}"
  done
  # The exact path `mktemp` returned, never one derived from it.
  if [[ -n "${CAPTURE_HOME_PATH}" ]]; then
    rm -rf -- "${CAPTURE_HOME_PATH}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

APP_LOG="$(mktemp -t limpid-screenshot.XXXXXX)"
CAPTURE_LOG="$(mktemp -t limpid-screenshot-capture.XXXXXX)"
CAPTURE_PATH="$(mktemp -t limpid-screenshot-image.XXXXXX)"
# A shell reports its directory by the physical path, and a pane header
# abbreviates it to `~` only when that path sits under the home the app is
# given. The temporary directory is the wrong place for that home: it lives
# under `/private/var`, and the app's home lookup drops the `/private`, so the
# two never match and the header would show the full temporary path. The
# repository's ignored `build/` holds no symlinks once resolved, so both
# sides agree there.
#
# Two steps, so a failed `mktemp` stops the script here: nested inside the
# `cd`, its failure would leave `cd ""` in the current directory.
mkdir -p build
CAPTURE_HOME_PATH="$(mktemp -d "$(pwd -P)/build/limpid-screenshot-home.XXXXXX")"
CAPTURE_HOME="$(cd "${CAPTURE_HOME_PATH}" && pwd -P)"
# Pane headers show each shell's working directory, and the demo shells start
# wherever the app was launched from, so launched from here they would put
# the contributor's own paths in the hero. They start instead in this
# directory inside the isolated home, which mirrors the worktree the demo's
# split tab belongs to, so its headers read `~/code/limpid-feat-agents`.
DEMO_SHELL_DIR="${CAPTURE_HOME}/code/limpid-feat-agents"
mkdir -p "${DEMO_SHELL_DIR}"

# Launch the selected bundle's executable directly. `open -a` resolves through
# LaunchServices and can activate an installed copy with the same bundle id.
# Keeping the child pid gives activation, window lookup, capture, and cleanup
# one unambiguous identity. Give it an isolated Application Support directory
# so an installed copy cannot reload the user's settings into the demo process.
# Ignore macOS window restoration so a saved frame cannot replace DemoFixture's
# reproducible 1280×800 frame. Demo mode forces English UI and an opaque toolbar.
# The subshell `exec`s the app, so `$!` is the app's own pid.
(
  cd "${DEMO_SHELL_DIR}"
  CFFIXED_USER_HOME="${CAPTURE_HOME}" LIMPID_DEMO=1 exec "${APP_BINARY}" \
    -AppleLanguages '(en-US)' \
    -AppleLocale en_US \
    -ApplePersistenceIgnoreState YES
) >"${APP_LOG}" 2>&1 &
APP_PID=$!

# Let the app boot, run the per-pane initialCommand sends (each
# debounced ~600ms inside `SurfaceView.scheduleInitialCommandIfNeeded`),
# and settle. 4s covers cold-start frame timing in practice.
sleep 4

# Activate only the process started above. The installed app may be running at
# the same time and must keep its current windows and focus untouched. This
# fails when the app is not running, which is the first place a launch that
# died (or a `cd` into the demo directory that failed) shows.
if ! swift - "${APP_PID}" <<'SWIFT' >/dev/null
import AppKit

guard CommandLine.arguments.count == 2,
      let raw = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: raw)
else { exit(1) }
app.activate(options: [.activateAllWindows])
SWIFT
then
  echo "" >&2
  echo "error: the demo app is not running, so nothing was captured." >&2
  echo "" >&2
  echo "App output:" >&2
  cat "${APP_LOG}" >&2
  exit 1
fi
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

# Check where the demo shells actually run before capturing anything. The
# headers show each shell's directory, and a hero must never carry a
# contributor's real path, so a shell outside the isolated home, a shell whose
# directory cannot be read, or no shell at all stops the run here. `login` is
# skipped: it is the root-owned wrapper the shells start under, its directory
# is not readable, and it draws nothing.
descendants() {
  local child
  for child in $(pgrep -P "$1"); do
    echo "${child}"
    descendants "${child}"
  done
}
SHELL_COUNT=0
for pid in $(descendants "${APP_PID}"); do
  # A process that exited since `pgrep` listed it draws nothing.
  ps -p "${pid}" >/dev/null 2>&1 || continue
  [ "$(ps -o comm= -p "${pid}")" = "/usr/bin/login" ] && continue
  # `lsof` fails on a directory it cannot read; that has to reach the error
  # below rather than stop the script through errexit.
  cwd="$(lsof -a -d cwd -Fn -p "${pid}" 2>/dev/null | sed -n 's/^n//p')" || cwd=""
  if [ -z "${cwd}" ] || { [ "${cwd}" != "${CAPTURE_HOME}" ] && [[ "${cwd}" != "${CAPTURE_HOME}/"* ]]; }; then
    echo "" >&2
    echo "error: a demo shell runs outside the screenshot's isolated home." >&2
    echo "       pid ${pid} ($(ps -o comm= -p "${pid}")): ${cwd:-<unreadable>}" >&2
    echo "       Its directory would show in a pane header, so nothing was captured." >&2
    exit 1
  fi
  SHELL_COUNT=$((SHELL_COUNT + 1))
done
if [ "${SHELL_COUNT}" -eq 0 ]; then
  echo "" >&2
  echo "error: found no demo shell to check, so nothing was captured." >&2
  echo "" >&2
  echo "App output:" >&2
  cat "${APP_LOG}" >&2
  exit 1
fi

# Capture the exact process's normal window through ScreenCaptureKit. Filtering
# by pid avoids collisions with an installed copy; `pointPixelScale` preserves
# Retina detail, and the desktop-independent window filter keeps the rounded
# alpha mask without recording screen pixels behind the corners.
#
# The hero is the fixture's 1280×800-point window at 2x, 2560×1600 pixels. A
# capture that is anything else is refused rather than written: one run
# produced a 620×388 image that a later run of the same build did not
# reproduce, so the size is checked instead of assumed. The window gets a few
# seconds to reach the fixture's frame, the display it is on must be 2x, and
# the image must come out at exactly that size.
CAPTURE_STATUS=0
swift - "${APP_PID}" "${CAPTURE_PATH}" <<'SWIFT' 2>"${CAPTURE_LOG}" || CAPTURE_STATUS=$?
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

_ = NSApplication.shared
guard CommandLine.arguments.count == 3,
      let raw = Int32(CommandLine.arguments[1]) else { exit(1) }
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
let expectedPoints = CGSize(width: 1280, height: 800)
let expectedScale: CGFloat = 2

func report(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func largestWindow() async throws -> SCWindow? {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    return content.windows.filter {
        $0.owningApplication?.processID == raw
            && $0.windowLayer == 0
            && $0.frame.width > 100
            && $0.frame.height > 100
    }.max(by: {
        $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
    })
}

var found = try await largestWindow()
let deadline = Date().addingTimeInterval(5)
while found?.frame.size != expectedPoints, Date() < deadline {
    try await Task.sleep(for: .milliseconds(250))
    found = try await largestWindow()
}
guard let window = found else { exit(2) }
guard window.frame.size == expectedPoints else {
    report("window is \(window.frame.size) points, expected \(expectedPoints)")
    exit(5)
}

let filter = SCContentFilter(desktopIndependentWindow: window)
let scale = CGFloat(filter.pointPixelScale)
guard scale == expectedScale else {
    report("window is on a \(scale)x display at \(window.frame.origin); the hero needs a 2x (Retina) display")
    exit(6)
}
let configuration = SCStreamConfiguration()
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
guard image.width == configuration.width, image.height == configuration.height else {
    report("captured \(image.width)×\(image.height) pixels, expected \(configuration.width)×\(configuration.height)")
    exit(7)
}
guard let destination = CGImageDestinationCreateWithURL(
    outputURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else { exit(3) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(4) }
SWIFT

if [ "${CAPTURE_STATUS}" -ge 5 ] && [ "${CAPTURE_STATUS}" -le 7 ]; then
  echo "" >&2
  echo "error: the Limpid window could not be captured at the hero's size (2560×1600)." >&2
  echo "       $(cat "${CAPTURE_LOG}")" >&2
  echo "       The demo opens its window at (100, 100) on the main display, which" >&2
  echo "       has to be a 2x (Retina) display; leave the window there and rerun." >&2
  exit 1
elif [ "${CAPTURE_STATUS}" -ne 0 ]; then
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
