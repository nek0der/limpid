#!/usr/bin/env bash
# scripts/test-screenshot-app.sh
# Weir — self-test for the app `screenshot.sh` launches.
#
# `make screenshot` hands the script the app this project just built. Were the
# script to search DerivedData anyway, it would take the newest Weir.app of
# any worktree and put another branch's build in the hero. This runs the script
# against a throwaway home whose DerivedData holds a newer app than the one
# handed over, with apps that have no executable, so nothing is ever launched:
# the script names the app it picked and stops at reading its Info.plist.
#
# Run from the repo root:
#   scripts/test-screenshot-app.sh
#
# Exits 0 on success, 1 on any failing case (with a per-case diagnostic).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPT="${REPO_ROOT}/scripts/screenshot.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HANDED="$TMP/project/Build/Products/Release/Weir.app"
NEWER="$TMP/home/Library/Developer/Xcode/DerivedData/Other-abc/Build/Products/Release/Weir.app"
mkdir -p "$HANDED" "$NEWER" "$TMP/cwd"
touch -t 202001010000 "$HANDED"

failures=0

# Runs the script from a scratch directory (it creates `.github/assets` and
# `build/` relative to where it runs) and prints the app it named.
launched() {
  local output
  output="$(cd "$TMP/cwd" && env HOME="$TMP/home" "$@" "$SCRIPT" 2>&1 || true)"
  printf '%s\n' "$output" | sed -n 's/^Launching: //p'
}

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name: launched '$actual', expected '$expected'" >&2
    failures=$((failures + 1))
  fi
}

check "the app handed over wins over a newer one in DerivedData" \
  "$HANDED" "$(launched WEIR_SCREENSHOT_APP="$HANDED")"
check "without one, the newest Release app in DerivedData is used" \
  "$NEWER" "$(launched)"

if ((failures > 0)); then
  echo "✗ test-screenshot-app: $failures case(s) failed." >&2
  exit 1
fi
echo "✓ test-screenshot-app: 2 case(s) passed."
