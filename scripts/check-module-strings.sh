#!/usr/bin/env bash
# Weir — fail when a string a static module compiled is missing from the app's catalog.
#
# A static module has no resources of its own, so WeirDomain's strings live in
# the app's catalog. A key missing there shows in English with nothing to say
# so, and `check-localization.sh` reads only what the catalog already holds. The
# compiler writes each file's keys to a `.stringsdata`, and those are what we
# compare.
#
# Usage: scripts/check-module-strings.sh SEARCH_DIRECTORY [CATALOG]
# Default catalog: Weir/Resources/Localizable.xcstrings

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEARCH_DIRECTORY="$1"
CATALOG="${2:-${REPO_ROOT}/Weir/Resources/Localizable.xcstrings}"

python3 -I - "$SEARCH_DIRECTORY" "$CATALOG" <<'PY'
import json
import pathlib
import sys

search_directory, catalog_path = sys.argv[1:3]
with open(catalog_path, encoding="utf-8") as handle:
    catalog = json.load(handle).get("strings", {})

paths = list(pathlib.Path(search_directory).rglob("*.stringsdata"))
if not paths:
    print(f"error: no .stringsdata under {search_directory}", file=sys.stderr)
    sys.exit(1)

missing = []
for path in paths:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    # A file the compiler wrote for a source since deleted stays in the build
    # folder, and its keys are no longer anyone's.
    if not pathlib.Path(data["source"]).exists():
        continue
    for key in (entry["key"] for entry in data.get("tables", {}).get("Localizable", [])):
        if key not in catalog:
            missing.append((data["source"], key))

for source, key in sorted(set(missing)):
    print(f"{source}: error: {key!r} is not in Localizable.xcstrings; add it with en and ja", file=sys.stderr)
sys.exit(1 if missing else 0)
PY
