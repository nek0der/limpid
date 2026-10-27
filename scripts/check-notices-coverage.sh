#!/usr/bin/env bash
# Limpid guardrail — fail if a bundled third-party component is missing from
# THIRD-PARTY-NOTICES, or is named there without the license text its terms
# require us to ship. Six checks:
#
#   1. Named components. The `required` list below is the manifest for what
#      is not a Rust crate: when you bundle a new dependency or vendored
#      script, add its name here AND to THIRD-PARTY-NOTICES.
#   2. Reproduced texts. Components whose license asks for its text (or its
#      copyright notice) to travel with binaries are listed in `texts` with a
#      line of that text, so a summary line alone does not pass.
#   3. libghostty components. `ghostty_components` is the static list of
#      what the macOS build of GhosttyKit.xcframework links or embeds into
#      Limpid (not everything ghostty vendors: zlib, stb, libintl, harfbuzz,
#      fontconfig and the Linux and wasm deps stay out). Each needs a
#      `Component: <name> <version>` header and a line of its license text.
#      Re-derive the list when the vendor/ghostty pin moves; the header
#      comment of the list says how.
#   4. Rust crates. The committed file leaves them to a marker line, and
#      scripts/write-notices.sh fills it from `cargo metadata` when the app is
#      built, so a Dependabot bump needs no hand edit. Every check here reads
#      that filled-in copy, which takes cargo and, unless Cargo's registry
#      already holds the crates, network access. The generator itself refuses
#      a crate without an MIT text; here the committed file must hold no
#      `Crate:` header of its own, and a built app must carry exactly the copy
#      this checkout generates.
#   5. The Rust standard library. The staticlib also bundles std and the
#      crates std depends on. Their list is tied to the toolchain that
#      rust-toolchain.toml pins, so a toolchain bump fails here until the
#      list is re-derived; where that toolchain is installed, its rlibs are
#      compared with the list as well.
#   6. A built app, when one is at hand. The archive also holds zlib, stb,
#      libintl and others that the app does not link; the list in check 3
#      assumes they stay out. When a built Limpid binary exists, `nm` proves
#      it: zlib must still come from the system's libz, and none of the
#      unshipped libraries may define a symbol. Defined symbols are read from
#      the binary's dSYM when there is one, since a stripped binary no longer
#      lists them. Without a binary (CI's guardrail job) the check is
#      skipped; LIMPID_NOTICES_REQUIRE_BINARY=1 makes that a failure.
#
# Every license line is matched inside the block of its own header (the
# lines between the rules that follow that header and the next rule), so
# one component's text cannot stand in for another's.
#
# Run by .github/workflows/guardrails.yml, by the release-archive job of
# .github/workflows/ci.yml on the archive it builds, and as a pre-release
# Definition-of-Done check. Name matching is a plain substring search, so use
# the canonical project name.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

notices="THIRD-PARTY-NOTICES"

# Every non-Rust third-party component that ships inside Limpid.app / the DMG.
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
  "Dear Bindings"  # generator of libghostty's dcimgui C wrapper (MIT)
  "libintl"        # libghostty C dep (LGPL-2.1)
  "libxev"         # libghostty Zig dep (MIT)
  "uucode"         # libghostty Zig dep (MIT)
  "vaxis"          # libghostty Zig dep (MIT)
  "z2d"            # libghostty Zig dep (MPL-2.0)
  "tiny-skia"      # BSD-3-Clause source of z2d's sparse_coverage.zig
  "zf"             # libghostty Zig dep (MIT)
  "zig-objc"       # libghostty Zig dep (MIT)
  "Octicons"       # SVG drawings in the asset catalog (MIT)
  "Rust standard library" # linked into the bridge staticlib (MIT elected)
)

# "header prefix|a line of the text we must reproduce". The line must sit in
# the block whose header starts with the prefix; a section header matches
# without its "N. " number. Each line is matched whole and literally, so pick
# one that only the full text contains.
texts=(
  "Ghostty (libghostty)|Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors"
  "Sparkle|Copyright (c) 2006-2013 Andy Matuschak."
  "Sparkle|EXTERNAL LICENSES"
  "Sparkle|Copyright 2003-2005 Colin Percival"
  "Sparkle|Copyright (c) 2008-2010 Yuta Mori All Rights Reserved."
  "Sparkle|Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>"
  "Sparkle|3. This notice may not be removed or altered from any source distribution."
  "Sparkle|Copyright (c) 2011 Mark Hamlin."
  "Script: bash-preexec 0.6.0 |Copyright (c) 2017 Ryan Caloras and contributors (see https://github.com/rcaloras/bash-preexec)"
  "Script: bash-preexec 0.6.0 |Permission is hereby granted, free of charge, to any person obtaining a copy"
  "Octicons|Copyright (c) 2026 GitHub Inc."
  "GNU General Public License, version 3|                    GNU GENERAL PUBLIC LICENSE"
  "GNU General Public License, version 3|                       Version 3, 29 June 2007"
  "GNU General Public License, version 3|                     END OF TERMS AND CONDITIONS"
  "Rust: standard library 1.98.1 |Copyright (c) The Rust Project Contributors"
  "Rust: standard library 1.98.1 |  library/backtrace             2014 Alex Crichton"
  "Rust: standard library 1.98.1 |  library/std/src/sync/mpmc     2019 The Crossbeam Project Developers"
  "Rust: Unicode data in core 1.98.1 |Copyright © 1991-2024 Unicode, Inc."
  "Rust: Unicode data in core 1.98.1 |UNICODE LICENSE V3"
  "Rust: compiler_builtins 0.1.160 |---- LLVM Exceptions to the Apache 2.0 License ----"
  "Rust: compiler_builtins 0.1.160 |      Copyright (c) 2009-2016 by the contributors listed in CREDITS.TXT"
  "Rust: compiler_builtins 0.1.160 |    Copyright (c) 2018 Jorge Aparicio"
  "Rust: compiler_builtins 0.1.160 |      Copyright © 2005-2020 Rich Felker, et al."
)

# "Component header prefix|a line of its license text", for each part of
# GhosttyKit.xcframework that the macOS app links or embeds. We derived it by
# checking which archive members of ghostty-internal.a define symbols that
# are defined in a linked Limpid binary (`nm`), and by searching the Release
# binary for each library's strings and each font's bytes. A component that
# is only in the xcframework (its objects never linked) does not belong here.
# The list holds for the 1fa2d91ee pin, rebased onto upstream 0fe113a35. Its
# arm64 archive has the same members as the previous pin's (24be2f1), apart
# from two Zig compilation units that were renamed. Among the Zig packages,
# only z2d's version and uucode's Unicode data (now 18.0.0) changed the notices.
ghostty_components=(
  "FreeType 2.13.2 |                    The FreeType Project LICENSE"
  "FreeType 2.13.2 |    Portions of this software are copyright © 2023 The FreeType"
  "FreeType 2.13.2 |Copyright (C) 2001-2002 by Francesco Zappa Nardelli"
  "libpng 1.6.43 | * Copyright (c) 1995-2024 The PNG Reference Library Authors."
  "Oniguruma 6.9.9 |Copyright (c) 2002-2021  K.Kosako  <kkosako0@gmail.com>"
  "Oniguruma 6.9.9 |2. Redistributions in binary form must reproduce the above copyright"
  "simdutf 9.0.0 |Copyright 2021 The simdutf authors"
  "simdutf 9.0.0 |Copyright (c) 2016-     Facebook, Inc            (Adam Paszke)"
  "Highway 1.2.0 |Copyright (c) The Highway Project Authors. All rights reserved."
  "SPIRV-Cross, ghostty package 13.1.1 |Copyright (c) 2014-2020 The Khronos Group Inc."
  "glslang 14.2.0 |Here, glslang proper means core GLSL parsing, HLSL parsing, and SPIR-V code"
  "Wuffs 0.4.0-alpha |Copyright 2023 The Wuffs Authors"
  "Dear ImGui 1.92.5-docking |Copyright (c) 2014-2025 Omar Cornut"
  "Dear Bindings 0.17 |Copyright (c) 2021-2022 Ben Carter"
  "Dear Bindings 0.17 |Permission is hereby granted, free of charge, to any person obtaining a copy"
  "JetBrains Mono 2.304 |Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2014 Ryan L McIntyre"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2014, Ryan L McIntyre (https://ryanlmcintyre.com)."
  "Nerd Fonts Symbols Only 3.4.0 |Attribution 4.0 International"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2015 konpa"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2022 Fonticons, Inc. (https://fontawesome.com)"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2017 André Luiz Gava"
  "Nerd Fonts Symbols Only 3.4.0 |This is free and unencumbered software released into the public domain."
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2013 Joe Loughry"
  "Nerd Fonts Symbols Only 3.4.0 |Pictogrammers Free License"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2023 GitHub Inc."
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2021, Gabriele Lana gabriele.lana@gmail.com"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2016 Ryan L McIntyre"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright 2013 Kim Silkebækken and other contributors"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) 2014 Jesse Weed"
  "Nerd Fonts Symbols Only 3.4.0 |Copyright (c) <dates>, <Erik Flowers> (<URL|email>),"
  "Zig 0.17.0 runtime |Copyright (c) Zig contributors"
  "libxev |Copyright (c) 2023 Mitchell Hashimoto"
  "libxev |Copyright (c) 2021 kprotty"
  "vaxis 0.6.0 |Copyright (c) 2023 Tim Culverhouse"
  "zf 0.11.0 |Copyright (c) Nathan Craddock"
  "zig-objc |Copyright (c) 2023 Mitchell Hashimoto"
  "uucode 0.2.0 |Copyright (c) 2026 Jacob Sandlund"
  "uucode 0.2.0 |Copyright (c) 2008-2009 Bjoern Hoehrmann <bjoern@hoehrmann.de>"
  "z2d 0.12.2-pre |//   Copyright © 2024-2026 Chris Marchesi"
  "z2d 0.12.2-pre |Mozilla Public License Version 2.0"
  "z2d 0.12.2-pre |Copyright © 2000 Keith Packard, member of The XFree86 Project, Inc."
  "z2d 0.12.2-pre |  Copyright 2020 Yevhenii Reizner"
  "z2d 0.12.2-pre |Copyright (c) 2011 Google Inc. All rights reserved."
  "z2d 0.12.2-pre |Copyright (c) 2020 Yevhenii Reizner All rights reserved."
  "z2d 0.12.2-pre |  * Neither the name of the copyright holder nor the names of its"
)

# The license grant every standard-library crate's reproduced text must
# contain. Each is offered under MIT (alone or as one choice), and we elect it.
crate_grant="Permission is hereby granted, free of charge, to any"

# The targets Xcode builds the bridge staticlib for.
rust_targets=("aarch64-apple-darwin")

# The Rust standard library the bridge links, for the toolchain below. To
# re-derive the lists when rust-toolchain.toml moves:
#   1. `ls "$(rustc --print sysroot)/lib/rustlib/aarch64-apple-darwin/lib"`
#      lists the rlibs the toolchain ships for the target.
#   2. `ar t target/<profile>/liblimpid_rust_bridge.a` names, by rlib, the
#      objects the bridge bundles; an rlib with no member there goes to
#      rust_std_not_linked.
#   3. The release's library/Cargo.lock
#      (https://github.com/rust-lang/rust/blob/<version>/library/Cargo.lock)
#      pins each registry crate; reproduce that version's LICENSE-MIT under a
#      `Std crate: <name> <version>` header.
#   4. share/doc/rust/COPYRIGHT-library.html in the sysroot lists the in-tree
#      exceptions (core's Unicode data and others) and the `Rust:` blocks
#      reproduce what applies to the linked part; compiler_builtins' and
#      libm's LICENSE.txt live under library/compiler-builtins.
#   5. Update rust_std_toolchain and the `Rust: ... <version>` prefixes in
#      `texts`.
rust_std_toolchain="1.98.1"
rust_std_crates=(
  "addr2line 0.25.1"
  "adler2 2.0.1"
  "cfg-if 1.0.4"
  "gimli 0.32.3"
  "hashbrown 0.17.1"
  "libc 0.2.185"
  "memchr 2.7.6"
  "miniz_oxide 0.8.9"
  "object 0.37.3"
  "rustc-demangle 0.1.27"
)
# In-tree crates of the rust-lang/rust repository that the bridge links,
# covered by the `Rust:` blocks.
rust_std_runtime=(core alloc std panic_unwind unwind std_detect compiler_builtins
  rustc_std_workspace_core rustc_std_workspace_alloc)
# rlibs the toolchain ships for the target that never link into the bridge.
rust_std_not_linked=(
  panic_abort              # the bridge keeps the default panic = "unwind"
  test getopts             # the test harness and its option parser
  proc_macro rustc_literal_escaper # used by procedural macros at compile time
  profiler_builtins        # -C instrument-coverage only
  sysroot rustc_std_workspace_std # build plumbing for test and proc_macro
)

fail=0

# Print each "prefix|line" entry on stdin whose line is missing from the
# block of a header that starts with prefix. A block is the text between the
# rule that closes a header and the next rule (64 `-` or `=`), and a section
# header is matched without its "N. " number. With contains=1 the line only
# has to occur within a body line. A prefix that heads no block is reported
# as such.
missing_in_blocks() {
  awk -v contains="${1:-0}" '
    FNR == NR {
      n++
      key[n] = $0; sub(/\|.*/, "", key[n])
      want[n] = $0; sub(/^[^|]*\|/, "", want[n])
      next
    }
    length($0) == 64 && ($0 ~ /^-+$/ || $0 ~ /^=+$/) {
      in_header = !in_header
      if (in_header) for (i = 1; i <= n; i++) active[i] = 0
      next
    }
    in_header {
      if (NF == 0) next
      header = $0
      sub(/^[0-9]+\. /, "", header)
      for (i = 1; i <= n; i++) if (index(header, key[i]) == 1) { active[i] = 1; headed[i] = 1 }
      next
    }
    {
      for (i = 1; i <= n; i++) {
        if (!active[i] || found[i]) continue
        if (contains ? index($0, want[i]) : $0 == want[i]) found[i] = 1
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        label = key[i]; sub(/ +$/, "", label)
        if (!headed[i]) print label ": no block headed \"" key[i] "\""
        else if (!found[i]) print label ": " want[i]
      }
    }
  ' - "$shipped"
}

if [[ ! -f "$notices" ]]; then
  echo "✗ $notices not found." >&2
  exit 1
fi

# The copy that ships: the committed file with its Rust crate section filled
# in. Every check below reads it, and messages name the file it comes from.
shipped="$(mktemp)"
trap 'rm -f "$shipped"' EXIT
if ! scripts/write-notices.sh "$shipped"; then
  echo "✗ scripts/write-notices.sh could not fill in the Rust crates of $notices." >&2
  exit 1
fi

# -- 1. Named components -------------------------------------------------------

missing=()
for name in "${required[@]}"; do
  grep -qiF -- "$name" "$shipped" || missing+=("$name")
done
if (( ${#missing[@]} )); then
  {
    echo "✗ Bundled components missing from $notices:"
    printf '  - %s\n' "${missing[@]}"
    echo
    echo "Add each to $notices (name + license + copyright), then update the"
    echo "manifest list in this script."
  } >&2
  fail=1
fi

# -- 2. Reproduced texts -------------------------------------------------------

# A bundled resource that carries a GPL header obliges us to ship the GPL's
# text, whatever the manifest says, so a new GPL script cannot slip in under a
# link to gnu.org.
if grep -rlqF "GNU General Public License" Limpid/Resources 2>/dev/null; then
  gpl_listed=0
  for entry in "${texts[@]}"; do
    [[ "${entry%%|*}" == "GNU General Public License"* ]] && gpl_listed=1
  done
  if (( ! gpl_listed )); then
    echo "✗ Limpid/Resources ships a GPL-licensed file, but this script checks no GPL text." >&2
    fail=1
  fi
fi

missing_texts="$(printf '%s\n' "${texts[@]}" | missing_in_blocks)"
if [[ -n "$missing_texts" ]]; then
  {
    echo "✗ License texts missing from $notices (block: expected line):"
    printf '%s\n' "$missing_texts" | sed 's/^/  - /'
    echo
    echo "Reproduce the full license text of each component, copied from the"
    echo "version we ship."
  } >&2
  fail=1
fi

# The texts only reach recipients if the build writes the filled-in copy into
# the app bundle and the DMG takes that copy.
# shellcheck disable=SC2016 # the variable is the literal text we look for
if ! grep -qF '"$SRCROOT/scripts/write-notices.sh"' project.yml; then
  echo "✗ project.yml no longer writes $notices into the app bundle." >&2
  fail=1
fi
# shellcheck disable=SC2016 # the variables are the literal text we look for
if ! grep -qF 'cp "${APP_PATH}/Contents/Resources/THIRD-PARTY-NOTICES" "${DMG_STAGING}/"' scripts/package-dmg.sh; then
  echo "✗ scripts/package-dmg.sh no longer copies the app's $notices to the DMG root." >&2
  fail=1
fi

# -- 3. libghostty components -------------------------------------------------

missing=()
listed_prefixes=()
for entry in "${ghostty_components[@]}"; do
  listed_prefixes+=("${entry%%|*}")
done
while IFS= read -r line; do
  [[ -n "$line" ]] && missing+=("$line")
done < <(printf 'Component: %s\n' "${ghostty_components[@]}" | missing_in_blocks)
# A header the list does not know is a component nobody re-checked.
while IFS= read -r header; do
  known=0
  for prefix in "${listed_prefixes[@]}"; do
    [[ "$header" == "Component: $prefix"* ]] && known=1
  done
  (( known )) || missing+=("unlisted header: $header")
done < <(grep '^Component: ' "$shipped" || true)
if (( ${#missing[@]} )); then
  {
    echo "✗ libghostty components incomplete in $notices:"
    printf '  - %s\n' "${missing[@]}"
    echo
    echo "Reproduce each linked component's license text under its header, and"
    echo "keep ghostty_components in this script in step with the header list."
  } >&2
  fail=1
fi

# -- 4. Rust crates ------------------------------------------------------------

# A header in the committed file would ship beside the generated one, and the
# next bump would leave it naming a version the app no longer links.
if grep -q '^Crate: ' "$notices"; then
  {
    echo "✗ $notices names Rust crates itself; scripts/generate-crate-notices.py writes them:"
    grep '^Crate: ' "$notices" | sed 's/^/  - /'
  } >&2
  fail=1
fi
crate_count="$(grep -c '^Crate: ' "$shipped" || true)"
if (( crate_count == 0 )); then
  echo "✗ The filled-in $notices names no Rust crates; the generator found none under the bridge." >&2
  fail=1
fi

# -- 5. The Rust standard library ---------------------------------------------

pinned_toolchain="$(awk -F'"' '/^channel *=/ { print $2; exit }' rust-toolchain.toml 2>/dev/null || true)"
if [[ "$pinned_toolchain" != "$rust_std_toolchain" ]]; then
  {
    echo "✗ rust-toolchain.toml pins Rust '${pinned_toolchain:-?}', but the standard-library"
    echo "  notices in $notices are for $rust_std_toolchain. Re-derive rust_std_crates and"
    echo "  the 'Rust:' blocks as the comment above rust_std_toolchain in this script says."
  } >&2
  fail=1
fi

std_entries=()
for crate in "${rust_std_crates[@]}"; do
  std_entries+=("Std crate: $crate |$crate_grant")
done
missing_std="$(printf '%s\n' "${std_entries[@]}" | missing_in_blocks 1)"
while IFS= read -r header; do
  [[ -z "$header" ]] && continue
  key="$(awk '{ print $3, $4 }' <<< "$header")"
  known=0
  for crate in "${rust_std_crates[@]}"; do
    [[ "$key" == "$crate" ]] && known=1
  done
  (( known )) || missing_std="${missing_std:+$missing_std
}unlisted header: $header"
done < <(grep '^Std crate: ' "$shipped" || true)
if [[ -n "$missing_std" ]]; then
  {
    echo "✗ Rust standard-library crates incomplete in $notices:"
    printf '%s\n' "$missing_std" | sed 's/^/  - /'
  } >&2
  fail=1
fi

# Where the pinned toolchain is installed for the target, its rlibs must be
# the ones the lists above account for, at the versions they name. An rlib
# records the registry path it was built from, as /rust/deps/<name>-<version>/.
rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
std_lib_dir=""
for dir in "$rustup_home/toolchains/$rust_std_toolchain"-*/lib/rustlib/"${rust_targets[0]}"/lib; do
  if [[ -d "$dir" ]]; then
    std_lib_dir="$dir"
    break
  fi
done
checked_rlibs=0
if [[ -n "$std_lib_dir" ]]; then
  unknown=()
  for rlib in "$std_lib_dir"/lib*.rlib; do
    [[ -f "$rlib" ]] || continue
    base="${rlib##*/}"
    base="${base#lib}"
    name="${base%-*}"
    accounted=0
    for known_name in "${rust_std_runtime[@]}" "${rust_std_not_linked[@]}"; do
      [[ "$name" == "$known_name" ]] && accounted=1
    done
    for crate in "${rust_std_crates[@]}"; do
      crate_name="${crate%% *}"
      [[ "$name" == "${crate_name//-/_}" ]] || continue
      accounted=1
      if grep -aqF "/rust/deps/$crate_name-" "$rlib" \
        && ! grep -aqF "/rust/deps/$crate_name-${crate#* }/" "$rlib"; then
        unknown+=("$name: built from a version other than ${crate#* }")
      fi
    done
    (( accounted )) || unknown+=("$name: in no rust_std_* list")
    checked_rlibs=$((checked_rlibs + 1))
  done
  if (( ${#unknown[@]} )); then
    {
      echo "✗ The Rust $rust_std_toolchain rlibs in $std_lib_dir disagree with this script:"
      printf '  - %s\n' "${unknown[@]}"
    } >&2
    fail=1
  fi
fi

# -- 6. A built app ------------------------------------------------------------

# Built binaries to check: LIMPID_NOTICES_BINARY (colon-separated), and the
# `make release-check` archive when it exists. Each must link libghostty.
binaries=()
if [[ -n "${LIMPID_NOTICES_BINARY:-}" ]]; then
  IFS=: read -r -a binaries <<< "$LIMPID_NOTICES_BINARY"
fi
release_check_binary="build/ReleaseCheck/Limpid.xcarchive/Products/Applications/Limpid.app/Contents/MacOS/Limpid"
[[ -f "$release_check_binary" ]] && binaries+=("$release_check_binary")

# zlib functions libpng and FreeType call; each must stay an import from libz.
zlib_imports=(_inflate _deflate _crc32 _adler32)
# Name prefixes of libraries the archive holds but the app must not link.
unshipped_prefixes="_libintl_|_stbi_|_hb_|_Fc[A-Z]|_xmlParse|_sentry_"
# A symbol libghostty always defines. A symbol table without it has been
# stripped, and cannot show what the binary defines.
defined_sentinel="_ghostty_init"

# The dSYM Xcode wrote for a binary: an archive keeps it under dSYMs/, a
# build products folder next to the .app.
dsym_for() {
  local binary="$1" app name
  app="${binary%/Contents/MacOS/*}"
  name="${binary##*/}"
  [[ "$app" == *.app ]] || return 0
  local candidates=("${app}.dSYM")
  if [[ "$app" == */Products/Applications/*.app ]]; then
    candidates+=("${app%/Products/Applications/*}/dSYMs/${app##*/}.dSYM")
  fi
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate/Contents/Resources/DWARF/$name" ]]; then
      printf '%s\n' "$candidate/Contents/Resources/DWARF/$name"
      return 0
    fi
  done
}

checked_binaries=0
if (( ${#binaries[@]} )) && command -v nm >/dev/null 2>&1; then
  for binary in "${binaries[@]}"; do
    if [[ ! -f "$binary" ]]; then
      echo "✗ LIMPID_NOTICES_BINARY names $binary, which does not exist." >&2
      fail=1
      continue
    fi
    # The app must carry the copy this checkout fills in, not the committed
    # file with its marker line, nor a copy from an older Cargo.lock.
    if [[ "$binary" == */Contents/MacOS/* ]]; then
      bundled="${binary%/Contents/MacOS/*}/Contents/Resources/THIRD-PARTY-NOTICES"
      if ! cmp -s "$bundled" "$shipped"; then
        echo "✗ $bundled is missing or differs from the $notices this checkout fills in; rebuild the app." >&2
        fail=1
      fi
    fi
    # Built as a whole array so bash 3.2 never expands an empty one.
    nm_args=(-m)
    if lipo -archs "$binary" 2>/dev/null | grep -qw arm64; then
      nm_args+=(-arch arm64)
    fi
    imports="$(nm "${nm_args[@]}" "$binary" 2>/dev/null || true)"
    for name in "${zlib_imports[@]}"; do
      if ! grep -qE "\(undefined\) external $name \(from libz\)$" <<< "$imports"; then
        echo "✗ $binary does not import $name from the system libz; the bundled zlib may be linked, and $notices does not cover it." >&2
        fail=1
      fi
    done
    # Release binaries are stripped; their dSYM keeps the full symbol table.
    # A dSYM is only used once its UUIDs are read and equal the binary's, so
    # a stale one left beside a rebuilt binary cannot answer for it.
    symbol_file="$binary"
    dsym="$(dsym_for "$binary")"
    if [[ -n "$dsym" ]]; then
      binary_uuids=""
      dsym_uuids=""
      if command -v dwarfdump >/dev/null 2>&1; then
        binary_uuids="$(dwarfdump --uuid "$binary" 2>/dev/null | awk '$1 == "UUID:" { print $2, $3 }' | LC_ALL=C sort || true)"
        dsym_uuids="$(dwarfdump --uuid "$dsym" 2>/dev/null | awk '$1 == "UUID:" { print $2, $3 }' | LC_ALL=C sort || true)"
      fi
      if [[ -z "$binary_uuids" || -z "$dsym_uuids" ]]; then
        if [[ "${LIMPID_NOTICES_REQUIRE_BINARY:-0}" == 1 ]]; then
          echo "✗ Could not read the UUIDs of $binary and $dsym (is dwarfdump installed?), so the dSYM cannot stand in for the stripped binary." >&2
          fail=1
        else
          echo "• Could not read the UUIDs of $binary and its dSYM; skipped its symbol check."
        fi
        continue
      fi
      if [[ "$binary_uuids" != "$dsym_uuids" ]]; then
        echo "✗ $dsym does not match $binary (its UUIDs differ); rebuild both." >&2
        fail=1
        continue
      fi
      symbol_file="$dsym"
    fi
    symbols="$(nm "${nm_args[@]}" "$symbol_file" 2>/dev/null || true)"
    defined="$(grep -vE '\(undefined\)' <<< "$symbols" || true)"
    if ! grep -qE " external $defined_sentinel$" <<< "$defined"; then
      echo "✗ $symbol_file lists no defined $defined_sentinel: it is stripped and has no dSYM beside it, or it does not link libghostty." >&2
      fail=1
      continue
    fi
    # Every defined symbol counts, external or not: a library linked with
    # hidden visibility still ships its code.
    leaked="$(grep -E " (${unshipped_prefixes})[^ ]*$" <<< "$defined" | head -5 || true)"
    if [[ -n "$leaked" ]]; then
      {
        echo "✗ $binary defines symbols of a library $notices treats as not linked:"
        printf '%s\n' "$leaked" | sed 's/^/  /'
      } >&2
      fail=1
    fi
    checked_binaries=$((checked_binaries + 1))
  done
fi

# The release-archive CI job sets this, so a renamed archive path or a
# missing nm cannot turn the check into a silent skip there.
if [[ "${LIMPID_NOTICES_REQUIRE_BINARY:-0}" == 1 ]] && (( checked_binaries == 0 )); then
  echo "✗ LIMPID_NOTICES_REQUIRE_BINARY is set, but no built binary was checked (none found at $release_check_binary or in LIMPID_NOTICES_BINARY, or nm is missing)." >&2
  fail=1
fi

if (( fail )); then
  exit 1
fi
echo "✓ check-notices-coverage: ${#required[@]} bundled components, ${#texts[@]} license texts, ${#listed_prefixes[@]} libghostty license lines, ${crate_count} Rust crates and ${#rust_std_crates[@]} Rust ${rust_std_toolchain} standard-library crates are acknowledged; ${checked_rlibs} toolchain rlibs and ${checked_binaries} built binaries checked."
