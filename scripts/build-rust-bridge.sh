#!/usr/bin/env bash

set -euo pipefail

find_cargo() {
  if command -v cargo >/dev/null 2>&1; then
    command -v cargo
    return
  fi

  local candidate
  for candidate in /opt/homebrew/opt/rustup/bin/cargo /usr/local/opt/rustup/bin/cargo; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  echo "error: cargo was not found; install rustup with Homebrew and initialize the pinned toolchain" >&2
  exit 1
}

build_architecture="${CURRENT_ARCH:-}"
if [[ -z "$build_architecture" || "$build_architecture" == "undefined_arch" ]]; then
  build_architecture="${ARCHS:-${NATIVE_ARCH_ACTUAL:-}}"
fi

case "$build_architecture" in
  arm64)
    rust_target="aarch64-apple-darwin"
    ;;
  x86_64)
    rust_target="x86_64-apple-darwin"
    ;;
  *)
    echo "error: unsupported Xcode architecture: ${build_architecture:-unknown}" >&2
    exit 1
    ;;
esac

case "${CONFIGURATION:-Debug}" in
  Release)
    cargo_profile_flag="--release"
    cargo_profile_directory="release"
    ;;
  *)
    cargo_profile_flag=""
    cargo_profile_directory="debug"
    ;;
esac

: "${DERIVED_FILE_DIR:?Xcode must provide DERIVED_FILE_DIR}"
: "${SRCROOT:?Xcode must provide SRCROOT}"

cargo_bin="$(find_cargo)"
# Homebrew installs rustup proxies beside Cargo. Xcode's restricted PATH does
# not include that directory, but Cargo still invokes the sibling `rustc` by
# name when it queries the compiler or builds the crate.
cargo_bin_directory="$(dirname "$cargo_bin")"
export PATH="$cargo_bin_directory:$PATH"
cargo_target_directory="$DERIVED_FILE_DIR/cargo-target"
library_output_directory="$DERIVED_FILE_DIR/limpid-rust"
library_name="liblimpid_rust_bridge.a"

mkdir -p "$library_output_directory"

build_arguments=(
  build
  --locked
  --package limpid-rust-bridge
  --target "$rust_target"
)
if [[ -n "$cargo_profile_flag" ]]; then
  build_arguments+=("$cargo_profile_flag")
fi

cd "$SRCROOT"
CARGO_TARGET_DIR="$cargo_target_directory" "$cargo_bin" "${build_arguments[@]}"
built_library="$cargo_target_directory/$rust_target/$cargo_profile_directory/$library_name"
linked_library="$library_output_directory/$library_name"
if ! cmp -s "$built_library" "$linked_library"; then
  cp "$built_library" "$linked_library"
fi
