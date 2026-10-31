#!/usr/bin/env bash
# Weir — run xcodegen when the Xcode project is missing or its inputs changed.
#
# xcodegen expands each `path:` in project.yml into the files present when it
# runs, and the generated project is not tracked. Adding, removing, or renaming
# a file therefore needs a regeneration that project.yml's timestamp alone
# never triggers, and a stale project builds without the new file. We decide
# from content rather than mtimes: the macOS make (3.81) compares mtimes to the
# whole second, so a file added in the same second as the last generation
# would be missed for good. The inputs are project.yml's checksum plus the
# sorted list of files under the given directories, recorded in RECORD only
# after xcodegen succeeds, so a failed run is retried on the next build. The
# record also carries the generated project's checksum: a plain `xcodegen` or
# an Xcode edit outside this script would otherwise leave a project built
# from other inputs that the record still vouches for.
#
# Usage: scripts/regenerate-project-if-stale.sh [--force] PBXPROJ RECORD SPEC DIR...

set -euo pipefail

usage() {
  echo "usage: $0 [--force] PBXPROJ RECORD SPEC DIR..." >&2
  exit 2
}

force=false
if [[ "${1:-}" == "--force" ]]; then
  force=true
  shift
fi
[[ $# -ge 4 ]] || usage

pbxproj="$1"
record="$2"
spec="$3"
shift 3

# Finder litter is not part of the project, and a byte-wise sort keeps the list
# identical across locales so an unchanged tree never looks different.
# `cksum` is POSIX, so the self-test runs unchanged on the Linux CI runner.
inputs="$(
  printf 'spec %s\n' "$(cksum < "$spec")"
  find "$@" -type f ! -name '.DS_Store' -print | LC_ALL=C sort
)"

project_line() {
  printf 'project %s' "$(cksum < "$pbxproj")"
}

if [[ "$force" == false ]] && [[ -f "$pbxproj" ]] && [[ -f "$record" ]] \
  && [[ "$inputs"$'\n'"$(project_line)" == "$(cat "$record")" ]]; then
  exit 0
fi

xcodegen --spec "$spec"

# A unique temporary name keeps two makes in the same tree from tripping over
# each other's rename.
mkdir -p "$(dirname "$record")"
tmp="$(mktemp "$record.XXXXXX")"
printf '%s\n%s\n' "$inputs" "$(project_line)" > "$tmp"
mv "$tmp" "$record"
