#!/usr/bin/env bash
# Writes the THIRD-PARTY-NOTICES that ships, the committed file with its Rust
# crate section filled from Cargo.lock by generate-crate-notices.py.
#
# Usage: write-notices.sh <output>
#
# The Xcode build calls this after the Rust bridge is built, so the crates it
# names are already in Cargo's registry and LIMPID_NOTICES_OFFLINE=1 keeps it
# off the network. Without that variable Cargo may download what is missing.
set -euo pipefail

output="${1:?usage: write-notices.sh <output>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

cargo_bin="$(command -v cargo || true)"
for candidate in /opt/homebrew/opt/rustup/bin/cargo /usr/local/opt/rustup/bin/cargo; do
  [[ -z "$cargo_bin" && -x "$candidate" ]] && cargo_bin="$candidate"
done
if [[ -z "$cargo_bin" ]]; then
  echo "error: cargo was not found; it is needed to list the Rust crates for THIRD-PARTY-NOTICES" >&2
  exit 1
fi
# Cargo runs the sibling rustc by name; Xcode's PATH does not reach it.
cargo_directory="$(dirname "$cargo_bin")"
export PATH="$cargo_directory:$PATH"

metadata_arguments=(metadata --format-version 1 --locked
  --manifest-path "$repo_root/Cargo.toml"
  --filter-platform aarch64-apple-darwin)
if [[ "${LIMPID_NOTICES_OFFLINE:-0}" == 1 ]]; then
  metadata_arguments+=(--offline)
fi

# Written beside the output and moved into place, so a failed run never leaves
# a partial file where the app bundle expects the notices.
partial="$(mktemp "$(dirname "$output")/.THIRD-PARTY-NOTICES.XXXXXX")"
trap 'rm -f "$partial"' EXIT
"$cargo_bin" "${metadata_arguments[@]}" \
  | python3 -I "$repo_root/scripts/generate-crate-notices.py" "$repo_root/THIRD-PARTY-NOTICES" > "$partial"
chmod 644 "$partial"
mv -f "$partial" "$output"
trap - EXIT
