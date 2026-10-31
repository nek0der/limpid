#!/usr/bin/env bash
# Weir — self-test for `regenerate-project-if-stale.sh`.
#
# The script is what makes `make build` regenerate the Xcode project after a
# file is added, removed, or renamed, or project.yml is edited. If it stopped
# noticing those edits, a new file would silently stay out of the build; if it
# fired on every run, every build would pay for a regeneration. This drives it
# against a throwaway tree with a stand-in `xcodegen` that counts its calls,
# including the edits that land in the same second as the last generation.
#
# Run from the repo root:
#   scripts/test-regenerate-project-if-stale.sh
#
# Exits 0 on success, 1 on any failing case (with a per-case diagnostic).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${REPO_ROOT}/scripts/regenerate-project-if-stale.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "✗ script not found at $SCRIPT" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The stand-in writes the project file and counts calls. Setting
# XCODEGEN_FAIL makes it fail without writing, like a broken spec.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/xcodegen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo call >> "$COUNT_FILE"
if [[ -n "${XCODEGEN_FAIL:-}" ]]; then
  exit 1
fi
mkdir -p App.xcodeproj
echo generated > App.xcodeproj/project.pbxproj
EOF
chmod +x "$TMP/bin/xcodegen"

mkdir -p "$TMP/tree/src/App" "$TMP/tree/tests"
touch "$TMP/tree/src/App/A.swift" "$TMP/tree/tests/ATests.swift"
echo "name: App" > "$TMP/tree/project.yml"
export COUNT_FILE="$TMP/count"
: > "$COUNT_FILE"

failures=0

calls() {
  wc -l < "$COUNT_FILE" | tr -d ' '
}

run() {
  (cd "$TMP/tree" && PATH="$TMP/bin:$PATH" "$SCRIPT" "$@" \
    App.xcodeproj/project.pbxproj build/xcodegen.inputs project.yml src tests)
}

expect_calls() {
  local label="$1" want="$2" got
  got="$(calls)"
  if [[ "$got" == "$want" ]]; then
    echo "✓ $label"
  else
    echo "✗ $label: xcodegen ran $got time(s) in total, expected $want" >&2
    failures=$((failures + 1))
  fi
}

run
expect_calls "a missing project is generated" 1

run
expect_calls "an unchanged tree does not regenerate" 1

# No sleep between the edit and the run: the same-second case is the one an
# mtime comparison misses.
touch "$TMP/tree/src/App/B.swift"
run
expect_calls "adding a file in the same second regenerates" 2

mv "$TMP/tree/src/App/B.swift" "$TMP/tree/src/App/C.swift"
run
expect_calls "renaming a file regenerates" 3

rm "$TMP/tree/src/App/C.swift"
run
expect_calls "removing a file regenerates" 4

echo "  options: {}" >> "$TMP/tree/project.yml"
run
expect_calls "editing project.yml regenerates" 5

touch "$TMP/tree/src/App/.DS_Store"
run
expect_calls "Finder metadata is ignored" 5

printf 'edited\n' > "$TMP/tree/src/App/A.swift"
run
expect_calls "editing a file's contents does not regenerate" 5

rm -r "$TMP/tree/App.xcodeproj"
run
expect_calls "a deleted project is generated again" 6

run --force
expect_calls "--force always regenerates" 7

echo "edited outside the script" >> "$TMP/tree/App.xcodeproj/project.pbxproj"
run
expect_calls "a project changed outside the script is regenerated" 8

touch "$TMP/tree/src/App/D.swift"
if XCODEGEN_FAIL=1 run 2>/dev/null; then
  echo "✗ a failing xcodegen did not fail the script" >&2
  failures=$((failures + 1))
else
  echo "✓ a failing xcodegen fails the script"
fi
run
expect_calls "a failed generation is retried on the next run" 10

run
expect_calls "the retried generation is recorded" 10

if [[ $failures -gt 0 ]]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "All cases passed"
