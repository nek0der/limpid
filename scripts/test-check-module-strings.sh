#!/usr/bin/env bash
# Weir — self-test for `check-module-strings.sh`.
#
# Without this, a change in the shape the compiler writes, or a checker that
# stopped reading a table, would pass every new string unchecked.
#
# Run from the repo root:
#   scripts/test-check-module-strings.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="${REPO_ROOT}/scripts/check-module-strings.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '{ "strings": { "Known": {} } }\n' > "$TMP/catalog.xcstrings"
mkdir -p "$TMP/known" "$TMP/new" "$TMP/deleted" "$TMP/empty"
touch "$TMP/A.swift" "$TMP/B.swift"
printf '{ "source": "%s", "tables": { "Localizable": [{ "key": "Known" }] } }\n' "$TMP/A.swift" > "$TMP/known/A.stringsdata"
printf '{ "source": "%s", "tables": { "Localizable": [{ "key": "New" }] } }\n' "$TMP/B.swift" > "$TMP/new/B.stringsdata"
printf '{ "source": "%s", "tables": { "Localizable": [{ "key": "Gone" }] } }\n' "$TMP/Deleted.swift" > "$TMP/deleted/C.stringsdata"

failures=0

"$CHECK" "$TMP/known" "$TMP/catalog.xcstrings" \
  || { echo "✗ a key in the catalog was refused" >&2; failures=$((failures + 1)); }

if output="$("$CHECK" "$TMP/new" "$TMP/catalog.xcstrings" 2>&1)"; then
  echo "✗ a key missing from the catalog passed" >&2
  failures=$((failures + 1))
elif [[ "$output" != *"'New' is not in Localizable.xcstrings"* ]]; then
  echo "✗ a missing key failed for another reason: $output" >&2
  failures=$((failures + 1))
fi

"$CHECK" "$TMP/deleted" "$TMP/catalog.xcstrings" \
  || { echo "✗ a key of a deleted source was required" >&2; failures=$((failures + 1)); }

# A wrong directory must not read as "nothing is missing".
if "$CHECK" "$TMP/empty" "$TMP/catalog.xcstrings" 2>/dev/null; then
  echo "✗ a directory with no .stringsdata passed" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  exit 1
fi
echo "✓ check-module-strings: a missing key fails, a known key passes"
