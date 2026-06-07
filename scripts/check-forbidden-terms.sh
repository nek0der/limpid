#!/usr/bin/env bash
# Limpid guardrail — fail if competitor product names or foreign issue
# references appear in tracked source/config. Neutral dependencies and
# industry conventions (ghostty, tmux, POSIX, AppKit, Terminal.app) are
# intentionally NOT banned: we describe what we rely on, we just don't frame
# our work as mirroring a competitor.
#
# Used by .pre-commit-config.yaml, .github/workflows/guardrails.yml, and as the
# pre-release Definition-of-Done check. `git grep` only sees tracked files, so
# the gitignored docs/ tree is out of scope by design.
#
# Escape hatch: add a reviewed exception to .forbidden-terms-allow, one
# "path:substring" fragment per line (e.g. an attribution that must name the
# upstream project). An entry suppresses any matching line in that file.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Every term wraps in `\b` (PCRE word boundary, -P) so common English words
# don't false-match; `-i` makes it case-insensitive. The companion
# `test-check-forbidden-terms.sh` pins each entry with a positive and a
# negative case so an accidental edit can't silently disable one.
pattern='\b(cmux|manaflow|superisland|notchi|wezterm|alacritty|kitty|iterm2?|vs ?code|vscode|calyx|warp|zellij|tabby|hyper(\.app)?|rio|orca|stablyai|gitlens|lazygit)\b'

# Skip this script + its allow-list (they name the terms by necessity) and the
# vendored upstream shell-integration (it legitimately credits Kitty and uses
# the `kitty-shell-cwd://` OSC protocol token — that tree is upstream code).
hits=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  path="${line%%:*}"
  allowed=0
  if [[ -f .forbidden-terms-allow ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" || "$entry" == \#* ]] && continue
      apath="${entry%%:*}"
      asub="${entry#*:}"
      if [[ "$path" == "$apath" && "$line" == *"$asub"* ]]; then
        allowed=1
        break
      fi
    done < .forbidden-terms-allow
  fi
  [[ $allowed -eq 0 ]] && hits+="$line"$'\n'
done < <(git grep -nIPi "$pattern" -- \
  ':!scripts/check-forbidden-terms.sh' \
  ':!scripts/test-check-forbidden-terms.sh' \
  ':!.forbidden-terms-allow' \
  ':!Limpid/Resources/ghostty/shell-integration' \
  2>/dev/null || true)

if [[ -n "${hits//[$'\n\t ']/}" ]]; then
  {
    echo "✗ Forbidden competitor names / foreign issue refs in tracked files:"
    printf '%s' "$hits"
    echo
    echo "Rewrite to the neutral technical reason (see CONTRIBUTING.md), or add a"
    echo "reviewed exception to .forbidden-terms-allow."
  } >&2
  exit 1
fi
echo "✓ check-forbidden-terms: clean."
