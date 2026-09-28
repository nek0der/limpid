#!/usr/bin/env bash
# Limpid — self-test for `check-release-archive.sh`.
#
# Builds fake .xcarchive trees that stand in for a distributable archive and
# for each way one can break, then asserts the checker's verdict. The real
# archive takes minutes to produce, so this is what keeps an edit to the
# checker from silently accepting the v0.1.5 generic-archive layout again.
#
# Run from the repo root:
#   scripts/test-check-release-archive.sh
#
# Exits 0 on success, 1 on any failing case (with a per-case diagnostic).
# Needs macOS for `plutil` and `PlistBuddy`, like the checker itself.

# The case mutations are invoked indirectly through run_case.
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECKER="${REPO_ROOT}/scripts/check-release-archive.sh"

if [[ ! -x "$CHECKER" ]]; then
  echo "FAIL: checker not found at $CHECKER" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passes=0
fails=0

# Writes the layout `xcodebuild archive` produced for a good Release archive
# on Xcode 26, unsigned, into the directory given as $1.
make_good_archive() {
  local archive="$1"
  local app="$archive/Products/Applications/Limpid.app/Contents"
  mkdir -p "$app/MacOS" "$app/Library/LaunchAgents" "$app/Frameworks/Sparkle.framework"
  for binary in Limpid AgentIntegrationService AgentIntegrationHookHelper; do
    printf '#!/bin/sh\n' > "$app/MacOS/$binary"
    chmod +x "$app/MacOS/$binary"
  done
  plutil -create xml1 "$app/Library/LaunchAgents/dev.limpid.agent-integration-service.plist"
  plutil -insert Label -string dev.limpid.agent-integration-service \
    "$app/Library/LaunchAgents/dev.limpid.agent-integration-service.plist"
  plutil -create xml1 "$archive/Info.plist"
  plutil -insert ApplicationProperties -dictionary "$archive/Info.plist"
  plutil -insert ApplicationProperties.ApplicationPath -string Applications/Limpid.app \
    "$archive/Info.plist"
}

# $1 case name, $2 expected verdict ("pass" or "fail"), then a command that
# mutates the good archive whose path it receives as its last argument.
run_case() {
  local name="$1" expect="$2"
  shift 2
  local archive
  archive="$(mktemp -d -p "$TMP")/Limpid.xcarchive"
  make_good_archive "$archive"
  "$@" "$archive"

  local actual
  if "$CHECKER" "$archive" >/dev/null 2>&1; then
    actual="pass"
  else
    actual="fail"
  fi
  if [[ "$actual" == "$expect" ]]; then
    printf '  ok   %s\n' "$name"
    passes=$((passes + 1))
  else
    printf '  FAIL %s (expected %s, got %s)\n' "$name" "$expect" "$actual" >&2
    fails=$((fails + 1))
  fi
}

unchanged() { :; }

# What v0.1.5 shipped: tools installed beside the app, and no
# ApplicationProperties because Xcode no longer saw a single app.
generic_archive() {
  mkdir -p "$1/Products/usr/local/bin"
  printf '#!/bin/sh\n' > "$1/Products/usr/local/bin/AgentIntegrationService"
  plutil -remove ApplicationProperties "$1/Info.plist"
}
stray_product() { mkdir -p "$1/Products/usr/local/bin"; }
no_application_properties() { plutil -remove ApplicationProperties "$1/Info.plist"; }
missing_service() { rm "$1/Products/Applications/Limpid.app/Contents/MacOS/AgentIntegrationService"; }
missing_hook_helper() { rm "$1/Products/Applications/Limpid.app/Contents/MacOS/AgentIntegrationHookHelper"; }
missing_sparkle() { rm -r "$1/Products/Applications/Limpid.app/Contents/Frameworks/Sparkle.framework"; }
missing_service_plist() {
  rm "$1/Products/Applications/Limpid.app/Contents/Library/LaunchAgents/dev.limpid.agent-integration-service.plist"
}
malformed_service_plist() {
  printf 'not a plist' > \
    "$1/Products/Applications/Limpid.app/Contents/Library/LaunchAgents/dev.limpid.agent-integration-service.plist"
}
dev_service_plist() {
  cp "$1/Products/Applications/Limpid.app/Contents/Library/LaunchAgents/dev.limpid.agent-integration-service.plist" \
    "$1/Products/Applications/Limpid.app/Contents/Library/LaunchAgents/dev.limpid.agent-integration-service.dev.plist"
}
missing_archive() { rm -r "$1"; }

run_case "a distributable archive passes" pass unchanged
run_case "the v0.1.5 generic archive fails" fail generic_archive
run_case "a stray product beside the app fails" fail stray_product
run_case "a missing ApplicationProperties fails" fail no_application_properties
run_case "a missing AgentIntegrationService fails" fail missing_service
run_case "a missing AgentIntegrationHookHelper fails" fail missing_hook_helper
run_case "a missing Sparkle.framework fails" fail missing_sparkle
run_case "a missing release service plist fails" fail missing_service_plist
run_case "a malformed release service plist fails" fail malformed_service_plist
run_case "a bundled development service plist fails" fail dev_service_plist
run_case "a missing archive fails" fail missing_archive

echo
if [[ $fails -eq 0 ]]; then
  echo "test-check-release-archive: $passes case(s) passed."
  exit 0
fi
echo "test-check-release-archive: $fails failure(s) of $((passes + fails)) case(s)." >&2
exit 1
