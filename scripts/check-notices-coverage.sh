#!/usr/bin/env bash
# Limpid guardrail — fail if a bundled third-party component is missing from
# THIRD-PARTY-NOTICES. The list below IS the manifest: when you bundle a new
# dependency or vendored script, add its name here AND to THIRD-PARTY-NOTICES.
# Keeps the shipped attribution honest as the dependency set drifts.
#
# Run by .github/workflows/guardrails.yml and as a pre-release Definition-of-Done
# check. Matching is a plain substring search, so use the canonical project name.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

notices="THIRD-PARTY-NOTICES"

# Every third-party component that ships inside Limpid.app / the DMG.
required=(
  "Ghostty"        # libghostty, statically linked (MIT)
  "Sparkle"        # auto-update framework (MIT)
  "Kitty"          # GPLv3 shell-integration scripts vendored via ghostty
  "bash-preexec"   # MIT, bundled under Resources/.../shell-integration/bash
  "Nerd Fonts"     # codepoint tables embedded in GhosttyKit (OFL-1.1 / MIT)
  "JetBrains Mono" # default monospace face embedded in GhosttyKit (OFL-1.1)
  "FreeType"       # libghostty C dep (FTL)
  "libpng"         # libghostty C dep
  "zlib"           # libghostty C dep
  "Oniguruma"      # libghostty C dep (BSD-2)
  "simdutf"        # libghostty C dep (Apache-2.0 OR MIT)
  "SPIRV-Cross"    # libghostty C dep (Apache-2.0)
  "glslang"        # libghostty C dep (BSD-3-Clause and others)
  "Highway"        # libghostty C dep (Apache-2.0)
  "Wuffs"          # libghostty C dep (Apache-2.0)
  "stb"            # libghostty C dep (Public Domain OR MIT)
  "Dear ImGui"     # libghostty C dep (MIT)
  "libintl"        # libghostty C dep (LGPL-2.1)
  "libxev"         # libghostty Zig dep (MIT)
  "uucode"         # libghostty Zig dep (MIT)
  "vaxis"          # libghostty Zig dep (MIT)
  "z2d"            # libghostty Zig dep (MPL-2.0)
  "zf"             # libghostty Zig dep (MIT)
  "zig-objc"       # libghostty Zig dep (MIT)
)

if [[ ! -f "$notices" ]]; then
  echo "✗ $notices not found." >&2
  exit 1
fi

missing=()
for name in "${required[@]}"; do
  grep -qiF -- "$name" "$notices" || missing+=("$name")
done

if (( ${#missing[@]} )); then
  {
    echo "✗ Bundled components missing from $notices:"
    printf '  - %s\n' "${missing[@]}"
    echo
    echo "Add each to $notices (name + license + copyright), then update the"
    echo "manifest list in this script."
  } >&2
  exit 1
fi
echo "✓ check-notices-coverage: all ${#required[@]} bundled components are acknowledged."
