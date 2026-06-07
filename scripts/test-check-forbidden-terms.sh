#!/usr/bin/env bash
# Limpid — self-test for `check-forbidden-terms.sh`.
#
# Spawns a throwaway git repo, copies the guardrail in, plants fixtures with
# known-forbidden / known-allowed / vendored-excluded content, runs the
# guardrail, and asserts the expected exit codes. Catches the regression a
# regex edit would otherwise ship silently — without this, swapping
# `\bcmux\b` for `cmux` (or accidentally deleting an entry) would only be
# caught when the term actually leaked into a real commit.
#
# Run from the repo root:
#   scripts/test-check-forbidden-terms.sh
#
# Exits 0 on success, 1 on any failing case (with a per-case diagnostic).
# Suitable for `.github/workflows/guardrails.yml` and pre-commit too.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GUARDRAIL="${REPO_ROOT}/scripts/check-forbidden-terms.sh"

if [[ ! -x "$GUARDRAIL" ]]; then
  echo "✗ guardrail not found at $GUARDRAIL" >&2
  exit 1
fi

# `mktemp -d` returns an absolute path on both macOS and Linux. The trap
# wipes the throwaway repo even if a case fails mid-run.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passes=0
fails=0
note() { printf '  ✓ %s\n' "$1"; passes=$((passes + 1)); }
warn() { printf '  ✗ %s\n' "$1" >&2; fails=$((fails + 1)); }

run_case() {
  local name="$1"
  local expect="$2"   # "pass" or "fail"
  shift 2
  local sandbox
  sandbox="$(mktemp -d -p "$TMP")"
  pushd "$sandbox" >/dev/null
  git init -q
  git config user.email "test@example.com"
  git config user.name "test"
  mkdir -p scripts
  cp "$GUARDRAIL" scripts/
  # `"$@"` runs the caller's setup, which writes fixtures into `pwd`.
  "$@"
  git add -A
  git commit -qm "$name"

  local actual rc
  if scripts/check-forbidden-terms.sh >/dev/null 2>&1; then
    actual="pass"
    rc=0
  else
    actual="fail"
    rc=$?
  fi
  popd >/dev/null

  if [[ "$actual" == "$expect" ]]; then
    note "$name (exit=$rc, expected $expect)"
  else
    warn "$name (exit=$rc, expected $expect, got $actual)"
  fi
}

# Cases ----------------------------------------------------------------------

# Clean tree → guardrail exits 0.
run_case "clean repo passes" pass bash -c '
  echo "hello world" > README.md
'

# Every term in the pattern should fail on at least one canonical phrasing.
# Pin one per entry so a regex edit dropping a term doesn't silently slip
# through. Cases are written as separate run_case calls so a single failure
# shows the offending term, not "case 3 of 17 failed."

run_case "cmux is caught" fail bash -c '
  echo "inspired by cmux" > note.md
'
run_case "Calyx is caught" fail bash -c '
  echo "Calyx-style worktree" > note.md
'
run_case "WezTerm is caught" fail bash -c '
  echo "Comparable to WezTerm" > note.md
'
run_case "Alacritty is caught" fail bash -c '
  echo "Alacritty-style perf" > note.md
'
run_case "Kitty bare word is caught" fail bash -c '
  echo "Kitty would do" > note.md
'
run_case "iTerm and iTerm2 are caught" fail bash -c '
  echo "see iTerm2 docs" > note.md
'
run_case "VS Code with space is caught" fail bash -c '
  echo "Works like VS Code" > note.md
'
run_case "vscode no space is caught" fail bash -c '
  echo "vscode behavior" > note.md
'
run_case "Warp is caught" fail bash -c '
  echo "Warp-inspired" > note.md
'
run_case "Zellij is caught" fail bash -c '
  echo "Zellij multiplexer" > note.md
'
run_case "Tabby is caught" fail bash -c '
  echo "Tabby UI" > note.md
'
run_case "Hyper bare word is caught" fail bash -c '
  echo "Hyper terminal" > note.md
'
run_case "Hyper.app suffix is caught" fail bash -c '
  echo "Hyper.app does" > note.md
'
run_case "Rio is caught" fail bash -c '
  echo "Rio terminal" > note.md
'
run_case "manaflow is caught" fail bash -c '
  echo "manaflow launched" > note.md
'
run_case "Orca is caught" fail bash -c '
  echo "the Orca pattern" > note.md
'
run_case "stablyai is caught" fail bash -c '
  echo "see stablyai/orca" > note.md
'
run_case "GitLens is caught" fail bash -c '
  echo "like GitLens does" > note.md
'
run_case "lazygit is caught" fail bash -c '
  echo "lazygit community convention" > note.md
'

# Word-boundary cases — these must NOT trigger. The pattern relies on `\b`
# to avoid clobbering common English. If anyone drops a `\b` we want to
# know.
run_case "hypertext (substring of hyper) is safe" pass bash -c '
  echo "hypertext markup" > note.md
'
run_case "warping (substring of warp) is safe" pass bash -c '
  echo "warping spacetime" > note.md
'
run_case "scenario (substring of rio) is safe" pass bash -c '
  echo "common scenario" > note.md
'
run_case "Rio de Janeiro (bare Rio is bounded) is caught" fail bash -c '
  echo "Rio de Janeiro" > note.md
'
# The Rio-de-Janeiro case documents a known limitation: a literal
# capital-R "Rio" anywhere in the tree trips the guardrail. The fix is
# `.forbidden-terms-allow`, never deleting `\brio\b`.

# Allow-list: a path:substring entry should suppress its matching line.
run_case "allow-list suppresses THIRD-PARTY-NOTICES Kitty" pass bash -c '
  echo "Kitty (MIT) — see vendored shell integration" > THIRD-PARTY-NOTICES
  echo "THIRD-PARTY-NOTICES:Kitty" > .forbidden-terms-allow
'
run_case "allow-list suppresses a neutral lazygit mention" pass bash -c '
  mkdir -p src
  echo "// we do not run real tools like lazygit here" > src/demo.swift
  echo "src/demo.swift:lazygit" > .forbidden-terms-allow
'

# Vendored upstream path: pattern matches inside `Limpid/Resources/ghostty/
# shell-integration/` must be ignored — the guardrail hard-codes this exclude.
run_case "vendored ghostty shell-integration is excluded" pass bash -c '
  mkdir -p Limpid/Resources/ghostty/shell-integration
  echo "Based on Kitty" > Limpid/Resources/ghostty/shell-integration/note.bash
'

# A forbidden term in a non-excluded path under the same project tree still
# fails — exclude scope is path-narrow, not the whole repo.
run_case "Kitty outside the vendored tree is still caught" fail bash -c '
  mkdir -p Limpid/UI
  echo "// Mirrors Kitty" > Limpid/UI/note.swift
'

# Summary --------------------------------------------------------------------

echo
if [[ $fails -eq 0 ]]; then
  echo "✓ test-check-forbidden-terms: $passes case(s) passed."
  exit 0
fi
echo "✗ test-check-forbidden-terms: $fails failure(s) of $((passes + fails)) case(s)." >&2
exit 1
