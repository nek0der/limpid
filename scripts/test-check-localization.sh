#!/usr/bin/env bash
# Weir — self-test for `check-localization.sh`.
#
# Feeds the checker small catalogs with known-good and known-bad entries,
# including plural `variations`, a plural nested in a device variation, and
# `substitutions`, and asserts the exit code and, for a failure, the reason the
# checker printed. Without this, a regression in the traversal (say, only
# reading top-level string units) would pass every plural string unchecked,
# and a malformed fixture would pass a failing case by crashing.
#
# Run from the repo root:
#   scripts/test-check-localization.sh
#
# Exits 0 on success, 1 on any failing case (with a per-case diagnostic).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="${REPO_ROOT}/scripts/check-localization.sh"

if [[ ! -x "$CHECK" ]]; then
  echo "✗ checker not found at $CHECK" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0

# Writes a catalog whose "strings" object is the given JSON text.
catalog() {
  local name="$1" body="$2"
  printf '{ "sourceLanguage": "en", "version": "1.0", "strings": %s }\n' "$body" > "$TMP/$name.xcstrings"
  printf '%s' "$TMP/$name.xcstrings"
}

# A failing case must fail for the stated reason, not because a fixture is
# malformed JSON and the interpreter crashed: REASON has to appear in stderr.
expect() {
  local label="$1" want="$2" path="$3" reason="${4:-}" got=0 err
  err="$("$CHECK" "$path" 2>&1 > /dev/null)" || got=$?
  if [[ "$want" == pass && "$got" -eq 0 ]]; then
    echo "✓ $label"
  elif [[ "$want" == fail && "$got" -ne 0 && "$err" == *"$reason"* ]]; then
    echo "✓ $label"
  else
    echo "✗ $label: expected $want${reason:+ ($reason)}, exit code $got" >&2
    printf '%s\n' "$err" | sed 's/^/    /' >&2
    failures=$((failures + 1))
  fi
}

translated='{ "stringUnit": { "state": "translated", "value": "x" } }'

expect "a translated key passes" pass "$(catalog ok "{
  \"Open\": { \"localizations\": { \"ja\": $translated } }
}")"

expect "a key without ja fails" fail "$(catalog missing '{
  "Open": { "localizations": { "en": { "stringUnit": { "state": "translated", "value": "Open" } } } }
}')" "no ja localization"

expect "a key with no localizations at all fails" fail "$(catalog bare '{ "Open": {} }')" "no ja localization"

expect "a ja entry still marked needs_review fails" fail "$(catalog review '{
  "Open": { "localizations": { "ja": { "stringUnit": { "state": "needs_review", "value": "開く" } } } }
}')" "ja state is needs_review"

expect "a key marked shouldTranslate false is skipped" pass "$(catalog skip '{
  "%@": { "shouldTranslate": false }
}')"

expect "a plural with every ja form translated passes" pass "$(catalog plural-ok "{
  \"%lld files\": { \"localizations\": { \"ja\": { \"variations\": { \"plural\": {
    \"one\": $translated, \"other\": $translated
  } } } } }
}")"

expect "a plural with one ja form untranslated fails" fail "$(catalog plural-bad "{
  \"%lld files\": { \"localizations\": { \"ja\": { \"variations\": { \"plural\": {
    \"one\": $translated,
    \"other\": { \"stringUnit\": { \"state\": \"new\", \"value\": \"\" } }
  } } } } }
}")" "ja state is new, translated"

expect "a ja entry with no string units fails" fail "$(catalog empty-ja '{
  "Open": { "localizations": { "ja": {} } }
}')" "ja has no string units"

expect "a plural inside a device variation is checked" fail "$(catalog device-plural "{
  \"%lld files\": { \"localizations\": { \"ja\": { \"variations\": { \"device\": {
    \"mac\": { \"variations\": { \"plural\": {
      \"one\": $translated,
      \"other\": { \"stringUnit\": { \"state\": \"needs_review\", \"value\": \"\" } }
    } } }
  } } } } }
}")" "ja state is needs_review, translated"

expect "a substitution with every ja form translated passes" pass "$(catalog subst-ok "{
  \"%1\$@ moved %#@files@\": { \"localizations\": { \"ja\": {
    \"stringUnit\": { \"state\": \"translated\", \"value\": \"x\" },
    \"substitutions\": { \"files\": { \"variations\": { \"plural\": {
      \"one\": $translated, \"other\": $translated
    } } } }
  } } }
}")"

expect "a substitution with one ja form untranslated fails" fail "$(catalog subst-bad "{
  \"%1\$@ moved %#@files@\": { \"localizations\": { \"ja\": {
    \"stringUnit\": { \"state\": \"translated\", \"value\": \"x\" },
    \"substitutions\": { \"files\": { \"variations\": { \"plural\": {
      \"one\": $translated,
      \"other\": { \"stringUnit\": { \"state\": \"new\", \"value\": \"\" } }
    } } } }
  } } }
}")" "ja state is new, translated"

expect "the repository catalog passes" pass "${REPO_ROOT}/Weir/Resources/Localizable.xcstrings"

if [[ $failures -gt 0 ]]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
echo "All cases passed"
